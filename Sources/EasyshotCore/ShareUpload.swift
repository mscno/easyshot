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
