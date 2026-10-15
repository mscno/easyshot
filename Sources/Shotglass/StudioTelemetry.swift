import AppKit
import CoreMedia
import ShotglassCore

/// Records cursor position, buttons, keystroke timing and cursor shapes during a
/// Studio recording. Video frames stay untouched; the cursor is re-rendered at export.
/// Reads only public WindowServer state, so no Accessibility or Input Monitoring access is needed.
final class CursorTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private let source: CGRect
    private let scale: Double
    private var track: CursorTrack
    private var timer: DispatchSourceTimer?
    private var origin: Double?
    private var last: (t: Double, x: Double, y: Double, b: Int)?
    private var emitted = -1.0
    private var lastKey = -1.0
    private var shapeHashes: [Int: Int] = [:]
    private var lastShape = -1
    private var ticks = 0

    /// `source` is the captured rectangle in global Quartz points; `pixels` is the video size.
    init(source: CGRect, pixels: CGSize) {
        self.source = source; scale = pixels.width/max(source.width, 1)
        track = CursorTrack(width: pixels.width, height: pixels.height, scale: scale)
    }
    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Samples on the recording queue at the capture frame rate. Each tick reads a few
    /// WindowServer values; cursor bitmaps are checked on the main thread at 10 Hz.
    func start(fps: Int, queue: DispatchQueue) {
        Task { @MainActor in self.sampleShape(at: Self.now()) }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1/Double(max(fps, 24))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        let shapeEvery = max(1, Int((0.1/interval).rounded()))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.now()
            self.sample(at: now)
            self.ticks += 1
            if self.ticks % shapeEvery == 0 { Task { @MainActor in self.sampleShape(at: now) } }
        }
        self.timer = timer
        timer.resume()
    }
    /// The first video frame's presentation time defines t = 0.
    func setOrigin(_ pts: CMTime) { lock.lock(); if origin == nil { origin = pts.seconds }; lock.unlock() }

    private func sample(at now: Double) {
        guard let location = CGEvent(source: nil)?.location else { return }
        var buttons = 0
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { buttons |= 1 }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) { buttons |= 2 }
        let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let x = ((location.x-source.minX)*scale*10).rounded()/10, y = ((location.y-source.minY)*scale*10).rounded()/10
        lock.lock(); defer { lock.unlock() }
        let keyTime = now-since
        if since < 0.5 && keyTime > lastKey+0.001 { lastKey = keyTime; track.keys.append(keyTime) }
        if buttons & 1 != 0 && (last?.b ?? 0) & 1 == 0 { track.clicks.append(.init(t: now, x: x, y: y)) }
        // Store only changes. Before a change after a still period, repeat the last
        // position so interpolation does not drift across the pause.
        if let last, last.x == x && last.y == y && last.b == buttons { self.last = (now, x, y, buttons); return }
        if let last, last.t > emitted { track.samples.append(.init(t: last.t, x: last.x, y: last.y, b: last.b)) }
        track.samples.append(.init(t: now, x: x, y: y, b: buttons))
        last = (now, x, y, buttons); emitted = now
    }
    @MainActor private func sampleShape(at now: Double) {
        let cursor = NSCursor.currentSystem ?? .arrow
        guard let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bytes = image.dataProvider?.data as Data? else { return }
        var hasher = Hasher(); hasher.combine(bytes); hasher.combine(cursor.hotSpot.x); hasher.combine(cursor.hotSpot.y)
        let key = hasher.finalize()
        lock.lock(); let known = shapeHashes[key]; lock.unlock()
        let index: Int
        if let known { index = known }
        else {
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            let size = cursor.image.size
            lock.lock()
            index = track.shapes.count
            track.shapes.append(.init(png: png, w: size.width, h: size.height, hx: cursor.hotSpot.x, hy: cursor.hotSpot.y))
            shapeHashes[key] = index
            lock.unlock()
        }
        lock.lock()
        if index != lastShape { lastShape = index; track.shapeChanges.append(.init(t: now, i: index)) }
        lock.unlock()
    }

    /// Stops sampling and writes the sidecar. Times become relative to the first frame.
    func finish(video: URL) throws {
        timer?.cancel(); timer = nil
        lock.lock(); var track = self.track; let origin = self.origin; lock.unlock()
        guard let origin else { return }
        track.samples = track.samples.map { var s = $0; s.t = (s.t-origin)*1000; s.t = s.t.rounded()/1000; return s }
        if let firstInside = track.samples.firstIndex(where: { $0.t >= 0 }), firstInside > 0 {
            track.samples.removeFirst(firstInside-1); track.samples[0].t = 0
        }
        track.clicks = track.clicks.map { var c = $0; c.t -= origin; return c }.filter { $0.t >= 0 }
        track.keys = track.keys.map { $0-origin }.filter { $0 >= 0 }
        track.shapeChanges = track.shapeChanges.map { var c = $0; c.t = max(0, c.t-origin); return c }
        let encoder = JSONEncoder(); encoder.outputFormatting = []
        try encoder.encode(track).write(to: CursorTrack.sidecarURL(for: video), options: .atomic)
    }
    func cancel() { timer?.cancel(); timer = nil }
}
