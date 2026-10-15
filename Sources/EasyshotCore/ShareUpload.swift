import Foundation

/// Cuts a growing byte stream into multipart-upload parts. Every part except the last is at least
/// `partSize` bytes (S3 requires ≥ 5 MiB); parts are byte ranges of the local spool file, so nothing
/// is held in memory while uploads catch up.
public struct PartPlanner: Equatable, Sendable {
    public static let minimumPartSize = 5*1024*1024
    public struct Part: Equatable, Hashable, Sendable {
        public var number: Int; public var range: Range<Int>
        public init(number: Int,range: Range<Int>) { self.number = number; self.range = range }
    }
    public let partSize: Int
    public private(set) var planned = 0
    public private(set) var nextNumber = 1
    public private(set) var finished = false
    public init(partSize: Int = PartPlanner.minimumPartSize) { self.partSize = max(Self.minimumPartSize,partSize) }
    /// Full parts available now that `total` bytes have been written.
    public mutating func parts(upTo total: Int) -> [Part] {
        guard !finished else { return [] }
        var out: [Part] = []
        while total-planned >= partSize {
            out.append(Part(number: nextNumber,range: planned..<planned+partSize)); planned += partSize; nextNumber += 1
        }
        return out
    }
    /// The remaining parts once the stream is complete: full parts, then a final shorter one.
    /// An empty stream still yields one empty part, because a multipart upload needs at least one.
    public mutating func finish(total: Int) -> [Part] {
        var out = parts(upTo: total)
        if total > planned || nextNumber == 1 { out.append(Part(number: nextNumber,range: planned..<total)); planned = total; nextNumber += 1 }
        finished = true
        return out
    }
    /// Plans a finished file from scratch, as a retry does.
    public static func whole(size: Int,partSize: Int = PartPlanner.minimumPartSize) -> [Part] {
        var planner = PartPlanner(partSize: partSize); return planner.finish(total: size)
    }
}

/// Uploaded parts and their entity tags, in the shape `complete` needs.
public struct PartLedger: Equatable, Sendable {
    public private(set) var etags: [Int: String] = [:]
    public private(set) var expected: Set<Int> = []
    public init() {}
    public mutating func expect(_ number: Int) { expected.insert(number) }
    /// S3 returns the ETag quoted; the quotes are part of the value and must be sent back unchanged.
    public mutating func record(_ number: Int,etag: String) { etags[number] = etag }
    public var pending: Set<Int> { expected.subtracting(etags.keys) }
    public var isComplete: Bool { !expected.isEmpty && pending.isEmpty }
    public var completed: [(number: Int,etag: String)] { etags.keys.sorted().map { ($0,etags[$0]!) } }
    public var uploadedBytes: Int = 0
}

/// Exponential retry delays: 0.5 s doubling to a 20 s ceiling, with ±20 % jitter from `unit` (0…1).
public struct Backoff: Sendable {
    public var base: Double = 0.5,cap: Double = 20,jitter: Double = 0.2
    public init(base: Double = 0.5,cap: Double = 20,jitter: Double = 0.2) { self.base = base; self.cap = cap; self.jitter = jitter }
    public func delay(attempt: Int,unit: Double = 0.5) -> Double {
        let raw = min(cap,base*pow(2,Double(max(0,attempt))))
        return raw*(1+jitter*(min(1,max(0,unit))*2-1))
    }
    /// Network failures and server-side errors are worth retrying; client errors (other than an expired
    /// presigned URL, 403, and throttling, 429) are not.
    public static func retryable(status: Int) -> Bool { status == 0 || status == 403 || status == 408 || status == 429 || status >= 500 }
    /// Transport failures that a later attempt can fix; cancellation, bad URLs and TLS trust failures cannot.
    public static func transient(_ code: URLError.Code) -> Bool {
        switch code {
        case .cancelled,.badURL,.unsupportedURL,.userAuthenticationRequired,.userCancelledAuthentication,.serverCertificateUntrusted,
             .serverCertificateHasBadDate,.serverCertificateNotYetValid,.serverCertificateHasUnknownRoot,.clientCertificateRejected,
             .clientCertificateRequired,.appTransportSecurityRequiresSecureConnection,.fileDoesNotExist,.noPermissionsToReadFile: return false
        default: return true
        }
    }
}

/// WebVTT captions from timed phrases.
public enum WebVTT {
    public struct Cue: Equatable, Sendable {
        public var start: Double; public var end: Double; public var text: String
        public init(start: Double,end: Double,text: String) { self.start = start; self.end = end; self.text = text }
    }
    public static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0,seconds)*1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d",ms/3_600_000,ms/60_000%60,ms/1000%60,ms%1000)
    }
    /// Long phrases are split on word boundaries into cues of at most `maxCharacters`, sharing the
    /// phrase's time in proportion to their length, so captions stay readable.
    public static func cues(_ phrases: [Cue],maxCharacters: Int = 84) -> [Cue] {
        var out: [Cue] = []
        for phrase in phrases {
            let words = phrase.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty,phrase.end > phrase.start else { continue }
            var lines: [String] = [],line = ""
            for word in words {
                if !line.isEmpty,line.count+1+word.count > maxCharacters { lines.append(line); line = word } else { line = line.isEmpty ? word : line+" "+word }
            }
            lines.append(line)
            let total = Double(lines.reduce(0) { $0+$1.count }),span = phrase.end-phrase.start
            var t = phrase.start
            for (i,text) in lines.enumerated() {
                let end = i == lines.count-1 ? phrase.end : t+span*Double(text.count)/total
                out.append(Cue(start: t,end: end,text: text)); t = end
            }
        }
        return out
    }
    public static func document(_ cues: [Cue]) -> String {
        var text = "WEBVTT\n"
        for (i,cue) in cues.enumerated() {
            // "-->" inside a cue would end its timing line early.
            let body = cue.text.replacingOccurrences(of: "-->",with: "→").replacingOccurrences(of: "\n\n",with: "\n")
            text += "\n\(i+1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(body)\n"
        }
        return text
    }
}

/// Upload progress for the server (`POST /v1/videos/{id}/progress`): at most one report per `interval`,
/// coalesced to the latest value, unchanged values dropped. The switch to `recording: false` at stop is
/// sent at once. A server without the endpoint disables reporting for that video.
public struct ProgressThrottle: Sendable {
    public struct Report: Equatable, Sendable {
        public var uploadedBytes: Int; public var recording: Bool
        public init(uploadedBytes: Int,recording: Bool) { self.uploadedBytes = uploadedBytes; self.recording = recording }
    }
    public let interval: Double
    public private(set) var disabled = false
    public private(set) var pending: Report?
    private var lastSent: Double?
    private var last: Report?
    public init(interval: Double = 1) { self.interval = interval }
    /// The report to send now, or nil (it is kept as `pending` when the interval has not passed).
    public mutating func update(_ report: Report,now: Double) -> Report? {
        guard !disabled,report != last else { pending = nil; return nil }
        let stopping = !report.recording && last?.recording != false
        if stopping || lastSent.map({ now-$0 >= interval }) ?? true { return sent(report,now: now) }
        pending = report; return nil
    }
    /// When the pending report may go out.
    public var deadline: Double? { pending == nil || disabled ? nil : (lastSent ?? 0)+interval }
    /// Sends the pending report once its interval has passed.
    public mutating func flush(now: Double) -> Report? {
        guard let pending,!disabled,let deadline,now >= deadline else { return nil }
        return sent(pending,now: now)
    }
    public mutating func disable() { disabled = true; pending = nil }
    private mutating func sent(_ report: Report,now: Double) -> Report { last = report; lastSent = now; pending = nil; return report }
}

/// Parts already stored for a server video, saved next to the recording so a retry after a failed
/// upload sends only what is missing. Parts are byte ranges planned with `partSize`.
public struct UploadJournal: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var number: Int; public var start: Int; public var end: Int; public var etag: String
        public init(number: Int,start: Int,end: Int,etag: String) { self.number = number; self.start = start; self.end = end; self.etag = etag }
    }
    public var videoID: String
    public var partSize: Int
    public var parts: [Entry] = []
    public init(videoID: String,partSize: Int) { self.videoID = videoID; self.partSize = partSize }
    public mutating func record(_ part: PartPlanner.Part,etag: String) {
        parts.removeAll { $0.number == part.number }
        parts.append(Entry(number: part.number,start: part.range.lowerBound,end: part.range.upperBound,etag: etag))
    }
    /// Entries that match the plan for a finished file of `size` bytes, by number and byte range. Anything
    /// else (a different last part, a file that changed) is uploaded again under the same number.
    public func reusable(size: Int) -> [Int: String] {
        let plan = Dictionary(uniqueKeysWithValues: PartPlanner.whole(size: size,partSize: partSize).map { ($0.number,$0.range) })
        var out: [Int: String] = [:]
        for entry in parts where plan[entry.number] == entry.start..<entry.end { out[entry.number] = entry.etag }
        return out
    }
    /// `.<name>.easyshot-upload.json` beside the recording, hidden like the Studio sidecars.
    public static func url(for recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(".\(recording.lastPathComponent).easyshot-upload.json")
    }
}

public enum ShareLinks {
    /// The watch page serves its poster at `<share_url>/thumbnail.jpg`.
    public static func thumbnail(_ shareURL: String) -> String {
        var base = shareURL
        while base.hasSuffix("/") { base.removeLast() }
        return base+"/thumbnail.jpg"
    }
    /// GitHub renders an image link: the poster, clicking through to the watch page.
    public static func githubMarkdown(title: String,shareURL: String) -> String {
        let alt = title.replacingOccurrences(of: "\\",with: "\\\\").replacingOccurrences(of: "[",with: "\\[").replacingOccurrences(of: "]",with: "\\]")
            .replacingOccurrences(of: "\n",with: " ")
        return "[![\(alt.isEmpty ? "Recording" : alt)](\(thumbnail(shareURL)))](\(shareURL))"
    }
}
