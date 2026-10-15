import Foundation

/// Retimes capture samples around pauses. Paused time is cut out of the output timeline, so the
/// first frame after a resume follows the last frame before the pause by exactly one frame:
/// no frozen frame, no silence gap. Times are seconds in the capture clock.
public struct PauseClock: Sendable {
    public struct Cut: Equatable, Sendable { public var start: Double; public var end: Double }
    public let frameDuration: Double
    public private(set) var paused = false
    public private(set) var cuts: [Cut] = []
    private var offset = 0.0
    private var awaitingVideo = false
    private var lastVideo: Double?
    private var lastOutput: [Int: Double] = [:]
    public init(frameDuration: Double) { self.frameDuration = frameDuration }

    public mutating func pause() { paused = true }
    public mutating func resume() { if paused { paused = false; awaitingVideo = true } }
    /// Output time for a sample of `track` (0 is video) at capture time `t`, or nil to drop it.
    /// After a resume, audio waits for the first video frame so all tracks restart together.
    public mutating func map(_ t: Double, track: Int) -> Double? {
        if paused { return nil }
        if awaitingVideo {
            guard track == 0 else { return nil }
            awaitingVideo = false
            if let last = lastVideo, t-last > frameDuration {
                cuts.append(Cut(start: last+frameDuration, end: t)); offset += t-last-frameDuration
            }
        }
        let out = t-offset
        // Writers need increasing times per track; drop anything that would go backwards.
        if let previous = lastOutput[track], out <= previous { return nil }
        lastOutput[track] = out
        if track == 0 { lastVideo = t }
        return out
    }
    /// The output time of any capture-clock instant (for side data such as cursor telemetry), or nil inside a cut.
    public func outputTime(_ t: Double) -> Double? {
        var removed = 0.0
        for cut in cuts {
            if t >= cut.end { removed += cut.end-cut.start } else if t >= cut.start { return nil } else { break }
        }
        return t-removed
    }
    /// Like `outputTime`, but an instant inside a cut maps to where the recording resumes.
    public func clampedOutputTime(_ t: Double) -> Double {
        var removed = 0.0
        for cut in cuts {
            if t >= cut.end { removed += cut.end-cut.start } else if t >= cut.start { return cut.start-removed } else { break }
        }
        return t-removed
    }
    /// Total paused time removed so far.
    public var removed: Double { cuts.reduce(0) { $0+$1.end-$1.start } }
}

public enum HistoryRetention: String, CaseIterable, Codable, Sendable {
    case forever, month, week
    public var title: String { switch self { case .forever: "Forever"; case .month: "1 month"; case .week: "1 week" } }
    public var maxAge: TimeInterval? { switch self { case .forever: nil; case .month: 30*86_400; case .week: 7*86_400 } }
    public func isExpired(_ date: Date, now: Date = Date()) -> Bool { maxAge.map { now.timeIntervalSince(date) > $0 } ?? false }
    /// Files in the user's own folder are never deleted; only copies inside the app's history folder are.
    public static func mayDeleteFile(_ path: String, internalFolder: String) -> Bool {
        let file = (path as NSString).standardizingPath, folder = (internalFolder as NSString).standardizingPath
        return !folder.isEmpty && file.hasPrefix(folder.hasSuffix("/") ? folder : folder+"/")
    }
}
