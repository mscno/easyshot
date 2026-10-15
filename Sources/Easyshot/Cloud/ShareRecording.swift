import Foundation
import EasyshotCore

/// One Record & Share recording: the server video (created as recording starts, so the link exists
/// immediately), the spool, its uploader and progress reports for the watch page and library.
@MainActor final class ShareRecording {
    let spool: SegmentSpool
    private(set) var uploader: ShareUploader
    let client: CloudClient
    let progress: ProgressReporter
    private(set) var video: CloudVideo?
    private var creation: Task<CloudVideo,Error>?
    private let title: String?
    /// Retrying a finished file: progress reports `recording: false`, and a vanished storage upload restarts on a new link.
    private let retrying: Bool

    /// Creates the spool at `url` and starts creating the server video; `linked` runs when the link exists.
    init(client: CloudClient,url: URL,title: String?,linked: @escaping @MainActor (CloudVideo) -> Void) throws {
        self.client = client; self.title = title; retrying = false
        spool = try SegmentSpool(url: url)
        progress = ProgressReporter(client: client)
        uploader = ShareUploader(client: client,spool: spool)
        let uploader = uploader
        spool.onAppend = { total in Task { await uploader.spooled(total: total) } }
        creation = start(existing: nil) { [weak self] video in self?.video = video; linked(video) }
    }
    /// Retry: upload an existing local recording to `video` (or a new video when the original was never
    /// created), resuming from the parts its journal shows stored.
    init(client: CloudClient,file: URL,video: CloudVideo?,title: String?) throws {
        self.client = client; self.title = title; retrying = true
        spool = try SegmentSpool(finished: file)
        progress = ProgressReporter(client: client,recording: false)
        uploader = ShareUploader(client: client,spool: spool,resume: video != nil)
        self.video = video
        creation = start(existing: video) { _ in }
    }
    private func start(existing: CloudVideo?,created: @escaping @MainActor (CloudVideo) -> Void) -> Task<CloudVideo,Error> {
        let client = client,uploader = uploader,progress = progress,title = title
        return Task {
            do {
                let target: CloudVideo
                if let existing { target = existing } else { target = try await client.createVideo(title: title) }
                if target.status == "ready" { created(target); return target }
                await progress.attach(target.id)
                await uploader.onProgress { bytes in Task { await progress.report(bytes: bytes) } }
                await uploader.attach(videoID: target.id,minimumPartBytes: target.upload?.minPartBytes,urlLifetime: target.upload?.partUrlTtlSeconds)
                created(target)
                return target
            } catch { await uploader.fail(error); throw error }
        }
    }
    func creationValue() async throws -> CloudVideo {
        guard let creation else { throw CloudError.invalidResponse }
        return try await creation.value
    }
    /// Uploads the rest of the spool, then completes. Returns the ready video.
    func finish(durationMs: Int,width: Int,height: Int) async throws -> CloudVideo {
        do { return try await finishOnce(durationMs: durationMs,width: width,height: height) }
        catch CloudError.uploadFailed(404) where retrying {
            // Storage no longer has the multipart upload (it was aborted as stale): start over on a new link.
            await uploader.discardJournal()
            uploader = ShareUploader(client: client,spool: spool)
            creation = start(existing: nil) { [weak self] video in self?.video = video }
            return try await finishOnce(durationMs: durationMs,width: width,height: height)
        }
    }
    private func finishOnce(durationMs: Int,width: Int,height: Int) async throws -> CloudVideo {
        guard let creation else { throw CloudError.invalidResponse }
        let video = try await creation.value; self.video = video
        // The server committed before a previous process removed its journal. No PUTs
        // are needed, including when that journal is missing or was only partly written.
        if video.status == "ready" { await uploader.discardJournal(); await progress.close(); return video }
        await progress.stopped(bytes: await uploader.uploadedBytes)
        let parts = try await uploader.finish(total: spool.total)
        let ready = try await client.completeVideo(video.id,parts: parts,durationMs: durationMs,width: width,height: height)
        await uploader.discardJournal(); await progress.close()
        self.video = ready
        return ready
    }
    /// Stops uploading and deletes the server video, if it was created.
    func cancel() async {
        await uploader.cancel(); await progress.close()
        await uploader.discardJournal()
        if let video = try? await creation?.value { try? await client.deleteVideo(video.id) }
    }
}

/// Reports upload progress at most once a second, coalesced, through `ProgressThrottle`. Reports never
/// affect the upload: failures are ignored, and a server without the endpoint (404/405) turns them off.
actor ProgressReporter {
    private let client: CloudClient
    private var videoID: String?
    private var throttle = ProgressThrottle()
    private var flush: Task<Void,Never>?
    /// Reports handed to the network, for diagnostics.
    private(set) var sent: [ProgressThrottle.Report] = []
    private(set) var unsupported = false
    private var recording: Bool
    init(client: CloudClient,recording: Bool = true) { self.client = client; self.recording = recording }
    func attach(_ id: String) { videoID = id }
    func report(bytes: Int) {
        guard videoID != nil else { return }
        if let report = throttle.update(.init(uploadedBytes: bytes,recording: recording),now: Self.now) { send(report) }
        schedule()
    }
    /// Recording stopped; the upload continues. Reported at once, and every later report says so.
    func stopped(bytes: Int) { recording = false; report(bytes: bytes) }
    /// Stops reporting: the upload finished or was cancelled.
    func close() { throttle.disable(); flush?.cancel(); flush = nil }
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private func schedule() {
        guard flush == nil,let deadline = throttle.deadline else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0,deadline-Self.now)))
            await self?.flushNow()
        }
    }
    private func flushNow() {
        flush = nil
        if let report = throttle.flush(now: Self.now) { send(report) }
        schedule()
    }
    private func send(_ report: ProgressThrottle.Report) {
        guard let id = videoID else { return }
        sent.append(report)
        // One request at a time, in order, so the server never sees progress go backwards.
        let client = client,previous = sending
        sending = Task { [weak self] in
            await previous?.value
            if let supported = try? await client.reportProgress(id,uploadedBytes: report.uploadedBytes,recording: report.recording),!supported { await self?.markUnsupported() }
        }
    }
    private var sending: Task<Void,Never>?
    private func markUnsupported() { unsupported = true; close() }
}
