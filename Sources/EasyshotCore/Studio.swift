import Foundation
import CoreGraphics

/// Cursor telemetry recorded beside a Studio recording. Positions are video pixels
/// with a top-left origin; times are seconds from the first video frame.
public struct CursorTrack: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public var t: Double; public var x: Double; public var y: Double; public var b: Int
        public init(t: Double, x: Double, y: Double, b: Int = 0) { self.t = t; self.x = x; self.y = y; self.b = b }
    }
    public struct Click: Codable, Equatable, Sendable {
        public var t: Double; public var x: Double; public var y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }
    /// A cursor bitmap. Sizes and hotspot are screen points, top-left origin.
    public struct Shape: Codable, Equatable, Sendable {
        public var png: Data; public var w: Double; public var h: Double; public var hx: Double; public var hy: Double
        public init(png: Data, w: Double, h: Double, hx: Double, hy: Double) { self.png = png; self.w = w; self.h = h; self.hx = hx; self.hy = hy }
    }
    public struct ShapeChange: Codable, Equatable, Sendable {
        public var t: Double; public var i: Int
        public init(t: Double, i: Int) { self.t = t; self.i = i }
    }
    public var version = 1
    public var width: Double; public var height: Double
    /// Video pixels per screen point.
    public var scale: Double
    public var samples: [Sample] = []
    public var clicks: [Click] = []
    /// Keystroke times only; key identities are never recorded.
    public var keys: [Double] = []
    public var shapes: [Shape] = []
    public var shapeChanges: [ShapeChange] = []
    public init(width: Double, height: Double, scale: Double) { self.width = width; self.height = height; self.scale = scale }

    public static func sidecarURL(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".\(video.lastPathComponent).easyshot-cursor.json")
    }
    public static func planURL(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".\(video.lastPathComponent).easyshot-studio.json")
    }
    public func shape(at t: Double) -> Int {
        var lo = 0, hi = shapeChanges.count
        while lo < hi { let mid = (lo+hi)/2; if shapeChanges[mid].t <= t { lo = mid+1 } else { hi = mid } }
        return lo == 0 ? (shapeChanges.first?.i ?? 0) : shapeChanges[lo-1].i
    }
}

public struct ZoomSegment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Ramp-in begins at `start`; ramp-out ends at `end`.
    public var start: Double; public var end: Double
    public var scale: Double
    /// Where to aim while zooming in. Nil follows the cursor.
    public var anchorX: Double?; public var anchorY: Double?
    public init(start: Double, end: Double, scale: Double, anchor: CGPoint? = nil) {
        self.start = start; self.end = end; self.scale = scale
        anchorX = anchor.map { Double($0.x) }; anchorY = anchor.map { Double($0.y) }
    }
    public var anchor: CGPoint? { anchorX.flatMap { x in anchorY.map { CGPoint(x: x, y: $0) } } }
}

public enum StudioBackground: Codable, Equatable, Hashable, Sendable {
    case none
    case gradient(Int)
    case color(Double, Double, Double)
    case image(String)
}

public enum StudioOutput: String, Codable, CaseIterable, Sendable {
    case source, p1080, p2160
    public var title: String { switch self { case .source: "Source"; case .p1080: "1080p"; case .p2160: "4K" } }
    /// Canvas size keeping the source aspect, with even dimensions for the encoder. Never upscales.
    public func size(for source: CGSize) -> CGSize {
        let bound: CGSize? = switch self { case .source: nil; case .p1080: CGSize(width: 1920, height: 1080); case .p2160: CGSize(width: 3840, height: 2160) }
        var factor = 1.0
        if let bound {
            let landscape = source.width >= source.height
            let box = landscape ? bound : CGSize(width: bound.height, height: bound.width)
            factor = min(1, box.width/source.width, box.height/source.height)
        }
        func even(_ v: CGFloat) -> CGFloat { max(2, (v*factor/2).rounded()*2) }
        return CGSize(width: even(source.width), height: even(source.height))
    }
}

/// Output framing. Non-source aspects crop the recording to that shape and follow the zoom and cursor.
public enum StudioAspect: String, Codable, CaseIterable, Sendable {
    case source, landscape, square, vertical
    public var title: String { switch self { case .source: "Original"; case .landscape: "16:9"; case .square: "1:1"; case .vertical: "9:16" } }
    public var ratio: Double? { switch self { case .source: nil; case .landscape: 16/9; case .square: 1; case .vertical: 9/16 } }
}

public enum StudioCursorStyle: String, Codable, CaseIterable, Sendable {
    case macOS, halo, dot
    public var title: String { switch self { case .macOS: "macOS"; case .halo: "Highlighted"; case .dot: "Dot" } }
}

public struct StudioPlan: Codable, Equatable, Sendable {
    public var autoZoom = true
    public var zoom = 1.8
    public var segments: [ZoomSegment] = []
    public var showCursor = true
    public var cursorScale = 1.5
    /// 0 follows raw input; 1 is the smoothest glide.
    public var smoothing = 0.55
    public var transition = 0.6
    public var background: StudioBackground = .gradient(0)
    /// Inset as a fraction of the shorter canvas side.
    public var padding = 0.07
    /// Corner radius as a fraction of the shorter video side.
    public var cornerRadius = 0.018
    public var shadow = true
    public var motionBlur = false
    /// 0...1; 0.5 is the default strength.
    public var motionBlurAmount = 0.5
    public var output: StudioOutput = .source
    public var hevc = false
    public var aspect: StudioAspect = .source
    public var cursorStyle: StudioCursorStyle = .macOS
    public init() {}

    /// Visible source size at zoom 1: the largest rectangle of the output aspect inside the recording.
    public static func viewport(source: CGSize, aspect: StudioAspect) -> CGSize {
        guard let ratio = aspect.ratio, source.width > 0, source.height > 0 else { return source }
        return source.width/source.height > ratio ? CGSize(width: source.height*ratio, height: source.height) : CGSize(width: source.width, height: source.width/ratio)
    }
    /// Encoded frame size: the framed viewport, bounded by the output preset, never upscaled.
    public func canvasSize(for source: CGSize) -> CGSize { output.size(for: Self.viewport(source: source, aspect: aspect)) }
}

extension StudioPlan {
    /// Plans saved by earlier versions lack newer keys; missing keys take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StudioPlan()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        autoZoom = try v(.autoZoom, d.autoZoom); zoom = try v(.zoom, d.zoom); segments = try v(.segments, d.segments)
        showCursor = try v(.showCursor, d.showCursor); cursorScale = try v(.cursorScale, d.cursorScale); smoothing = try v(.smoothing, d.smoothing)
        transition = try v(.transition, d.transition); background = try v(.background, d.background); padding = try v(.padding, d.padding)
        cornerRadius = try v(.cornerRadius, d.cornerRadius); shadow = try v(.shadow, d.shadow); motionBlur = try v(.motionBlur, d.motionBlur)
        motionBlurAmount = try v(.motionBlurAmount, d.motionBlurAmount); output = try v(.output, d.output); hevc = try v(.hevc, d.hevc)
        aspect = try v(.aspect, d.aspect); cursorStyle = try v(.cursorStyle, d.cursorStyle)
    }
}

public enum StudioPlanner {
    public static let clusterGap = 2.5
    public static let lead = 0.2
    public static let hold = 1.2
    /// Groups clicks and typing into zoom segments. Typing aims at the last click,
    /// since keystroke positions are not recorded.
    public static func segments(for track: CursorTrack, duration: Double, zoom: Double, transition: Double = 0.6) -> [ZoomSegment] {
        var events: [(t: Double, p: CGPoint)] = track.clicks.map { ($0.t, CGPoint(x: $0.x, y: $0.y)) }
        for key in track.keys {
            let click = track.clicks.last { $0.t <= key }
            let point = click.map { CGPoint(x: $0.x, y: $0.y) } ?? StudioTimeline.raw(track.samples, at: key) ?? CGPoint(x: track.width/2, y: track.height/2)
            events.append((key, point))
        }
        events.sort { $0.t < $1.t }
        let far = 0.5*max(track.width, track.height)
        var clusters: [[(t: Double, p: CGPoint)]] = []
        for event in events {
            if let last = clusters.last?.last {
                let dt = event.t-last.t; let distance = hypot(event.p.x-last.p.x, event.p.y-last.p.y)
                if dt <= clusterGap && !(distance > far && dt > 0.8) { clusters[clusters.count-1].append(event); continue }
            }
            clusters.append([event])
        }
        var result: [ZoomSegment] = []
        for cluster in clusters {
            let first = cluster[0]
            var segment = ZoomSegment(start: max(0, first.t-transition-lead), end: min(duration, cluster.last!.t+hold+transition), scale: zoom, anchor: first.p)
            if let previous = result.last, segment.start <= previous.end+0.5 {
                segment.start = previous.start; segment.anchorX = previous.anchorX; segment.anchorY = previous.anchorY
                result[result.count-1] = segment
            } else if segment.end-segment.start >= transition {
                result.append(segment)
            }
        }
        return result
    }
}

/// Precomputed cursor and camera paths. Built once per plan change; every query
/// during rendering is O(1) or O(log n).
public struct StudioTimeline: Sendable {
    public static let rate = 120.0
    public let size: CGSize
    /// Viewport size at zoom 1 (the full frame unless the plan reframes to another aspect).
    public let base: CGSize
    public let duration: Double
    public let plan: StudioPlan
    private let cursor: [CGPoint]
    private let camera: [CGPoint]
    private let segments: [ZoomSegment]
    private let clicks: [Double]

    public init(track: CursorTrack, plan: StudioPlan, duration: Double) {
        self.size = CGSize(width: track.width, height: track.height)
        let base = StudioPlan.viewport(source: size, aspect: plan.aspect)
        self.base = base
        let reframed = base.width < size.width-0.5 || base.height < size.height-0.5
        self.duration = max(0, duration)
        self.plan = plan
        self.segments = plan.segments.sorted { $0.start < $1.start }
        self.clicks = track.clicks.map(\.t)
        let count = Int((self.duration*Self.rate).rounded(.up))+2
        let steps = 2, dt = 1/(Self.rate*Double(steps))
        let center = CGPoint(x: track.width/2, y: track.height/2)
        let start = Self.raw(track.samples, at: 0) ?? center
        let omega = plan.smoothing <= 0.001 ? .infinity : 60*pow(0.1, plan.smoothing)
        var cursor = [CGPoint](); cursor.reserveCapacity(count)
        var camera = [CGPoint](); camera.reserveCapacity(count)
        var p = start, v = CGPoint.zero
        var cam = start, camV = CGPoint.zero, target = start
        var index = 0
        for i in 0..<count {
            for s in 0..<steps {
                let t = (Double(i)+Double(s)/Double(steps))/Self.rate
                let goal = Self.raw(track.samples, at: t, hint: &index) ?? center
                if omega.isInfinite { p = goal; v = .zero } else { Self.spring(&p, &v, goal, omega, dt) }
                let zoom = Self.zoom(segments, at: t, transition: plan.transition)
                if zoom < 1.01 && !reframed { target = p }
                else if let segment = Self.active(segments, at: t), t < segment.start+plan.transition, let anchor = segment.anchor { target = anchor }
                else {
                    // Keep the camera still while the cursor stays inside the middle of the view.
                    let half = CGSize(width: base.width/(2*zoom)*0.55, height: base.height/(2*zoom)*0.55)
                    target.x = min(max(target.x, p.x-half.width), p.x+half.width)
                    target.y = min(max(target.y, p.y-half.height), p.y+half.height)
                }
                Self.spring(&cam, &camV, target, 5, dt)
            }
            cursor.append(p); camera.append(cam)
        }
        self.cursor = cursor; self.camera = camera
    }

    /// Exact critically damped spring step; stable for any time step.
    static func spring(_ x: inout CGPoint, _ v: inout CGPoint, _ target: CGPoint, _ omega: Double, _ dt: Double) {
        let decay = exp(-omega*dt)
        func axis(_ x: inout CGFloat, _ v: inout CGFloat, _ target: CGFloat) {
            let change = x-target, temp = (v+omega*change)*dt
            v = (v-omega*temp)*decay; x = target+(change+temp)*decay
        }
        axis(&x.x, &v.x, target.x); axis(&x.y, &v.y, target.y)
    }
    public static func raw(_ samples: [CursorTrack.Sample], at t: Double) -> CGPoint? { var hint = 0; return raw(samples, at: t, hint: &hint) }
    static func raw(_ samples: [CursorTrack.Sample], at t: Double, hint: inout Int) -> CGPoint? {
        guard let first = samples.first else { return nil }
        if t <= first.t { return CGPoint(x: first.x, y: first.y) }
        if hint >= samples.count || samples[hint].t > t { hint = 0 }
        while hint+1 < samples.count && samples[hint+1].t <= t { hint += 1 }
        let a = samples[hint]
        guard hint+1 < samples.count else { return CGPoint(x: a.x, y: a.y) }
        let b = samples[hint+1], f = (t-a.t)/max(b.t-a.t, 1e-6)
        return CGPoint(x: a.x+(b.x-a.x)*f, y: a.y+(b.y-a.y)*f)
    }
    static func ease(_ x: Double) -> Double { let x = min(1, max(0, x)); return x < 0.5 ? 4*x*x*x : 1-pow(-2*x+2, 3)/2 }
    static func active(_ segments: [ZoomSegment], at t: Double) -> ZoomSegment? { segments.last { $0.start <= t && t <= $0.end } }
    static func zoom(_ segments: [ZoomSegment], at t: Double, transition: Double) -> Double {
        var zoom = 1.0
        for segment in segments where segment.start <= t && t <= segment.end {
            let tr = min(transition, (segment.end-segment.start)/2)
            let weight = min(ease((t-segment.start)/tr), ease((segment.end-t)/tr))
            zoom = max(zoom, 1+(segment.scale-1)*weight)
        }
        return zoom
    }
    private func lookup(_ track: [CGPoint], _ t: Double) -> CGPoint {
        let x = min(max(0, t*Self.rate), Double(track.count-1)); let i = Int(x), f = x-Double(i)
        guard i+1 < track.count else { return track[i] }
        return CGPoint(x: track[i].x+(track[i+1].x-track[i].x)*f, y: track[i].y+(track[i+1].y-track[i].y)*f)
    }
    public func zoom(at t: Double) -> Double { Self.zoom(segments, at: t, transition: plan.transition) }
    /// Zoom change per second, used to scale optional motion blur.
    public func zoomVelocity(at t: Double) -> Double { (zoom(at: t+1/240)-zoom(at: t-1/240))*120 }
    public func cursor(at t: Double) -> CGPoint { lookup(cursor, t) }
    /// Visible source rectangle in video pixels, top-left origin, always inside the frame.
    public func viewport(at t: Double) -> CGRect {
        let z = zoom(at: t), w = base.width/z, h = base.height/z
        let c = lookup(camera, t)
        let x = min(max(c.x-w/2, 0), size.width-w), y = min(max(c.y-h/2, 0), size.height-h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
    /// A brief press: the cursor shrinks to 85% and springs back.
    public func pressScale(at t: Double) -> Double {
        var lo = 0, hi = clicks.count
        while lo < hi { let mid = (lo+hi)/2; if clicks[mid] <= t { lo = mid+1 } else { hi = mid } }
        guard lo > 0 else { return 1 }
        let age = t-clicks[lo-1]
        guard age < 0.3 else { return 1 }
        return 1-0.15*sin(Double.pi*age/0.3)
    }
}
