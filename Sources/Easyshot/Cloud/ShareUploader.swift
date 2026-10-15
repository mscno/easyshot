import Foundation
import EasyshotCore

/// The fragmented-MP4 recording on disk. Segments are appended as the writer emits them; uploads read
/// finished byte ranges back, so a slow network never holds video in memory or blocks the capture queue.
final class SegmentSpool: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written = 0
    /// Called with the new total after each append, on the writer's queue.
    var onAppend: (@Sendable (Int) -> Void)?
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path,contents: nil) else { throw ShotError.message("Could not create \(url.lastPathComponent).") }
        self.url = url; handle = try FileHandle(forWritingTo: url)
    }
    /// An existing, finished file (retrying an upload).
    init(finished url: URL) throws {
        self.url = url
        written = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
    func append(_ data: Data) throws {
        lock.lock()
        do { try handle?.write(contentsOf: data) } catch { lock.unlock(); throw error }
        written += data.count; let total = written
        lock.unlock()
        onAppend?(total)
    }
    var total: Int { lock.lock(); defer { lock.unlock() }; return written }
    func close() { lock.lock(); try? handle?.close(); handle = nil; lock.unlock() }
    func read(_ range: Range<Int>) throws -> Data {
        guard !range.isEmpty else { return Data() }
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(range.lowerBound))
        guard let data = try reader.read(upToCount: range.count),data.count == range.count else { throw ShotError.message("The recording file is shorter than expected.") }
        return data
    }
}

/// Multipart upload of a growing spool: up to three parts in flight, presigned URLs fetched in batches,
/// each part retried with exponential backoff. While recording it never gives up (the network may come
/// back); after `finish` each part gets a bounded number of further attempts.
actor ShareUploader {
    private let client: CloudClient
    private let spool: SegmentSpool
    private var planner = PartPlanner()
    private var videoID: String?
    private var queue: [PartPlanner.Part] = []
    private var ledger = PartLedger()
    private var urls: [Int: (url: URL,expires: Date)] = [:]
    private var inFlight = 0
    private var finishing = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<[(number: Int,etag: String)],Error>] = []
    private let backoff = Backoff()
    static let maxInFlight = 3,attemptsAfterStop = 6,urlLifetime: TimeInterval = 15*60
    /// Bytes stored on the server so far, for progress.
    private(set) var uploadedBytes = 0
    private(set) var retries = 0
    /// Parts a retry skipped because the journal shows them stored.
    private(set) var reusedParts = 0
    /// Stored parts, persisted beside the recording so a retry resumes instead of starting over.
    private let journalURL: URL
    private var journal: UploadJournal?
    private var saved: UploadJournal?
    private var reusable: [Int: String] = [:]
    private var progress: (@Sendable (Int) -> Void)?

    /// `resume` loads the journal of an earlier attempt; a new recording starts a fresh one.
    init(client: CloudClient,spool: SegmentSpool,resume: Bool = false) {
        self.client = client; self.spool = spool
        journalURL = UploadJournal.url(for: spool.url)
        if resume { saved = (try? Data(contentsOf: journalURL)).flatMap { try? JSONDecoder().decode(UploadJournal.self,from: $0) } }
    }
    func onProgress(_ handler: @escaping @Sendable (Int) -> Void) { progress = handler }
    func attach(videoID: String,minimumPartBytes: Int?,urlLifetime: Int?) {
        if planner.nextNumber == 1 {
            let minimum = max(PartPlanner.minimumPartSize,minimumPartBytes ?? 0)
            if let saved,saved.videoID == videoID,saved.partSize >= minimum {
                planner = PartPlanner(partSize: saved.partSize); journal = saved; reusable = saved.reusable(size: spool.total)
            } else {
                if let minimumPartBytes { planner = PartPlanner(partSize: minimumPartBytes) }
                journal = UploadJournal(videoID: videoID,partSize: planner.partSize); saveJournal()
            }
        }
        self.videoID = videoID; pump()
    }
    /// The upload completed; the journal has no further use.
    func discardJournal() { try? FileManager.default.removeItem(at: journalURL); journal = nil }
    private func saveJournal() {
        guard let journal,let data = try? JSONEncoder().encode(journal) else { return }
        try? data.write(to: journalURL,options: .atomic)
    }
    func fail(_ error: Error) { failure = failure ?? error; settle() }
    func cancel() { fail(CancellationError()) }
    /// The spool grew; schedule any newly complete parts.
    func spooled(total: Int) { enqueue(planner.parts(upTo: total)); pump() }
    /// Plans the final part and waits until every part is stored, returning the ETags for `complete`.
    func finish(total: Int) async throws -> [(number: Int,etag: String)] {
        finishing = true
        enqueue(planner.finish(total: total)); pump()
        return try await withCheckedThrowingContinuation { waiters.append($0); settle() }
    }
    private func enqueue(_ parts: [PartPlanner.Part]) {
        for part in parts {
            ledger.expect(part.number)
            if let etag = reusable.removeValue(forKey: part.number) { ledger.record(part.number,etag: etag); uploadedBytes += part.range.count; reusedParts += 1; continue }
            queue.append(part)
        }
        if reusedParts > 0 { progress?(uploadedBytes) }
    }
    private func pump() {
        guard videoID != nil,failure == nil else { settle(); return }
        while inFlight < Self.maxInFlight,!queue.isEmpty {
            let part = queue.removeFirst(); inFlight += 1
            Task { await self.run(part) }
        }
        settle()
    }
    private func settle() {
        guard !waiters.isEmpty else { return }
        let result: Result<[(number: Int,etag: String)],Error>
        if let failure { result = .failure(failure) }
        else if finishing,queue.isEmpty,inFlight == 0,ledger.isComplete { result = .success(ledger.completed) }
        else { return }
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume(with: result) }
    }
    private func run(_ part: PartPlanner.Part) async {
        defer { inFlight -= 1; pump() }
        var attempt = 0,afterStop = 0
        while failure == nil,let id = videoID {
            do {
                let url = try await presigned(part.number,video: id)
                let data = try spool.read(part.range)
                let etag = try await client.putPart(data,to: url)
                ledger.record(part.number,etag: etag); uploadedBytes += data.count
                journal?.record(part,etag: etag); saveJournal()
                progress?(uploadedBytes)
                return
            } catch {
                let status: Int
                if case CloudError.uploadFailed(let code) = error { status = code } else if error is URLError { status = 0 } else { status = -1 }
                if status == 403 { urls[part.number] = nil }
                if finishing { afterStop += 1 }
                guard status >= 0,Backoff.retryable(status: status),afterStop < Self.attemptsAfterStop else { fail(error); return }
                retries += 1
                try? await Task.sleep(for: .seconds(backoff.delay(attempt: attempt,unit: .random(in: 0...1))))
                attempt += 1
            }
        }
    }
    /// One request presigns this part and the next queued ones.
    private func presigned(_ number: Int,video: String) async throws -> URL {
        if let cached = urls[number],cached.expires > Date() { return cached.url }
        let wanted = [number]+queue.prefix(19).map(\.number).filter { urls[$0] == nil }
        let fresh = try await client.presignParts(video,numbers: wanted)
        let expires = Date().addingTimeInterval(Self.urlLifetime-60)
        for (n,url) in fresh { urls[n] = (url,expires) }
        guard let url = fresh[number] else { throw CloudError.invalidResponse }
        return url
    }
}

