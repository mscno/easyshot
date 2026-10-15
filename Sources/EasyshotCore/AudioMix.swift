import Foundation

/// Time-aligned mixing of PCM sources (system audio, microphone) into one interleaved stereo stream.
/// Positions are sample indices from the recording's start. Output is released only where every source
/// that has delivered audio has reached, or once one lags more than `maxLag` frames (it is silent there),
/// so a source that stops delivering, like system audio with nothing playing, never stalls the track.
public struct AudioMixTimeline: Sendable {
    public var gains: [Float]
    public let maxLag: Int
    /// Frames already released; every buffer starts here.
    public private(set) var emitted = 0
    private var buffers: [[Float]]
    private var ends: [Int?]
    public init(gains: [Float],maxLag: Int) {
        self.gains = gains; self.maxLag = maxLag
        buffers = Array(repeating: [],count: gains.count); ends = Array(repeating: nil,count: gains.count)
    }
    /// The frame where `source`'s next contiguous samples go, or nil before it has delivered any.
    public func end(of source: Int) -> Int? { ends[source] }
    /// Adds interleaved stereo frames for `source` at frame `start`. Frames before `emitted` are too late and
    /// dropped; a gap since the source's previous samples is silence; an overlap keeps the earlier samples.
    public mutating func write(_ source: Int,start: Int,stereo: [Float]) {
        var frames = stereo.count/2,skip = 0,position = start
        if position < emitted { skip = emitted-position; position = emitted }
        let local = position-emitted,have = buffers[source].count/2
        if local < have { skip += have-local } else if local > have { buffers[source].append(contentsOf: repeatElement(0,count: (local-have)*2)) }
        frames -= skip
        guard frames > 0 else { return }
        buffers[source].append(contentsOf: stereo[(skip*2)...])
        ends[source] = emitted+buffers[source].count/2
    }
    /// The frame up to which output can be released. `final` releases everything delivered.
    public func available(final: Bool) -> Int {
        let active = ends.compactMap { $0 }
        guard let latest = active.max(),let earliest = active.min() else { return emitted }
        return final ? latest : max(emitted,earliest,latest-maxLag)
    }
    /// Mixes and releases up to `maxFrames` frames before `end`: gains applied, then soft-limited.
    public mutating func read(upTo end: Int,maxFrames: Int) -> (start: Int,stereo: [Float])? {
        let frames = min(end-emitted,maxFrames)
        guard frames > 0 else { return nil }
        var out = [Float](repeating: 0,count: frames*2)
        for (source,gain) in gains.enumerated() {
            let n = min(frames*2,buffers[source].count)
            guard n > 0 else { continue }
            buffers[source].withUnsafeBufferPointer { input in for i in 0..<n { out[i] += input[i]*gain } }
            buffers[source].removeFirst(n)
        }
        for i in out.indices { out[i] = Self.limit(out[i]) }
        let start = emitted; emitted += frames
        return (start,out)
    }
    /// Linear below 0.8, then a tanh knee that approaches but never reaches full scale, so summed peaks
    /// bend instead of clipping.
    public static func limit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.8 else { return x }
        let y = 0.8+0.2*tanh((a-0.8)/0.2)
        return x < 0 ? -y : y
    }
}
