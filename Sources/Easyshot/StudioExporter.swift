import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import EasyshotCore

/// Renders a Studio plan on the GPU. Static layers (background, shadow, corner mask,
/// cursor bitmaps) are built once per plan; each frame is a short lazy Core Image graph:
/// cursor over source, crop to viewport, scale into the canvas, blend over background.
final class StudioRenderer: @unchecked Sendable {
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "Easyshot Studio"]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
    private struct State {
        var timeline: StudioTimeline
        var inner: CGRect
        var background: CIImage?
        var mask: CIImage?
        /// Highlight halo or dot sprite for the non-macOS cursor styles, at cursor scale 1.
        var marker: CIImage?
    }
    let track: CursorTrack
    let video: CGSize
    let canvas: CGSize
    private let lock = NSLock()
    private var state: State
    private let cursors: [CIImage?]

    init(track: CursorTrack, plan: StudioPlan, duration: Double, video: CGSize, canvas: CGSize) {
        self.track = track; self.video = video; self.canvas = canvas
        cursors = track.shapes.map { shape in
            guard let rep = NSBitmapImageRep(data: shape.png), let image = rep.cgImage else { return nil }
            return CIImage(cgImage: image)
        }
        state = Self.build(track: track, plan: plan, duration: duration, video: video, canvas: canvas)
    }
    var plan: StudioPlan { lock.lock(); defer { lock.unlock() }; return state.timeline.plan }
    var timeline: StudioTimeline { lock.lock(); defer { lock.unlock() }; return state.timeline }
    func update(plan: StudioPlan, duration: Double) {
        let next = Self.build(track: track, plan: plan, duration: duration, video: video, canvas: canvas)
        lock.lock(); state = next; lock.unlock()
    }

    private static func build(track: CursorTrack, plan: StudioPlan, duration: Double, video: CGSize, canvas: CGSize) -> State {
        let timeline = StudioTimeline(track: track, plan: plan, duration: duration)
        let bounds = CGRect(origin: .zero, size: canvas)
        let marker = cursorMarker(plan.cursorStyle, scale: track.scale)
        guard plan.background != .none else { return State(timeline: timeline, inner: bounds, marker: marker) }
        let pad = plan.padding*min(canvas.width, canvas.height)
        let available = bounds.insetBy(dx: pad, dy: pad)
        // The visible content has the framed viewport's aspect, which differs from the video when reframed.
        let content = timeline.base
        let fit = min(available.width/content.width, available.height/content.height)
        let size = CGSize(width: (content.width*fit).rounded(), height: (content.height*fit).rounded())
        let inner = CGRect(x: ((canvas.width-size.width)/2).rounded(), y: ((canvas.height-size.height)/2).rounded(), width: size.width, height: size.height)
        let radius = plan.cornerRadius*min(size.width, size.height)
        var layer = backgroundImage(plan.background, canvas: canvas)
        if plan.shadow {
            let shape = CIFilter.roundedRectangleGenerator()
            shape.extent = inner.offsetBy(dx: 0, dy: -0.012*canvas.height); shape.radius = Float(radius)
            shape.color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.5)
            if let shadow = shape.outputImage?.applyingGaussianBlur(sigma: 0.022*min(canvas.width, canvas.height)) { layer = shadow.composited(over: layer) }
        }
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = inner; mask.radius = Float(radius); mask.color = .white
        // Rasterize once so per-frame work is a texture read, not a blur.
        let background = context.createCGImage(layer, from: bounds).map { CIImage(cgImage: $0) }
        let maskImage = mask.outputImage.flatMap { context.createCGImage($0, from: inner) }.map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: inner.minX, y: inner.minY)) }
        return State(timeline: timeline, inner: inner, background: background, mask: maskImage, marker: marker)
    }
    /// A soft highlight drawn under the cursor (halo) or a dot replacing it, in video pixels at cursor scale 1.
    static func cursorMarker(_ style: StudioCursorStyle, scale: Double) -> CIImage? {
        guard style != .macOS else { return nil }
        let r = (style == .halo ? 22 : 9)*scale, size = Int(ceil(r*2+4*scale))
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let circle = CGRect(x: CGFloat(size)/2-r, y: CGFloat(size)/2-r, width: r*2, height: r*2)
        if style == .halo {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 0.38)); ctx.fillEllipse(in: circle)
        } else {
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 0.9)); ctx.fillEllipse(in: circle)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)); ctx.setLineWidth(2.5*scale); ctx.strokeEllipse(in: circle)
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
    static func backgroundImage(_ background: StudioBackground, canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        switch background {
        case .none: return CIImage(color: .black).cropped(to: bounds)
        case .color(let r, let g, let b): return CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: bounds)
        case .gradient(let index):
            return Backdrops.image(index, size: canvas).map { CIImage(cgImage: $0) } ?? CIImage(color: .black).cropped(to: bounds)
        case .image(let path):
            guard let image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]), image.extent.width > 0 else {
                return backgroundImage(.gradient(0), canvas: canvas)
            }
            let fill = max(canvas.width/image.extent.width, canvas.height/image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY).concatenating(CGAffineTransform(scaleX: fill, y: fill)), highQualityDownsample: true)
            return scaled.transformed(by: CGAffineTransform(translationX: (canvas.width-scaled.extent.width)/2, y: (canvas.height-scaled.extent.height)/2)).cropped(to: bounds)
        }
    }

    func render(_ source: CIImage, at t: Double) -> CIImage {
        lock.lock(); let state = self.state; lock.unlock()
        let timeline = state.timeline, plan = timeline.plan
        let w = source.extent.width, h = source.extent.height
        let sx = w/max(track.width, 1), sy = h/max(track.height, 1)
        var image = source
        if plan.showCursor, let marker = state.marker {
            let p = timeline.cursor(at: t), m = sx*plan.cursorScale*timeline.pressScale(at: t)
            let e = marker.extent
            image = marker.transformed(by: CGAffineTransform(scaleX: m, y: m).concatenating(CGAffineTransform(translationX: p.x*sx-e.width*m/2, y: h-p.y*sy-e.height*m/2)), highQualityDownsample: true).composited(over: image)
        }
        if plan.showCursor, plan.cursorStyle != .dot, !cursors.isEmpty, let cursor = cursors[min(track.shape(at: t), cursors.count-1)] {
            let shape = track.shapes[min(track.shape(at: t), track.shapes.count-1)]
            let p = timeline.cursor(at: t)
            let s = track.scale*sx*plan.cursorScale*timeline.pressScale(at: t)
            let k = s*shape.w/max(cursor.extent.width, 1)
            let x = p.x*sx-shape.hx*s, y = h-p.y*sy-(shape.h-shape.hy)*s
            image = cursor.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: x, y: y)), highQualityDownsample: true).composited(over: image)
        }
        let v = timeline.viewport(at: t)
        let crop = CGRect(x: v.minX*sx, y: h-v.maxY*sy, width: v.width*sx, height: v.height*sy)
        let inner = state.inner
        let scale = inner.width/crop.width
        let transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: inner.height/crop.height))
            .concatenating(CGAffineTransform(translationX: inner.minX, y: inner.minY))
        image = image.clampedToExtent().cropped(to: crop).transformed(by: transform, highQualityDownsample: scale < 1).cropped(to: inner)
        if plan.motionBlur {
            let speed = abs(timeline.zoomVelocity(at: t))
            if speed > 0.05 {
                let blur = CIFilter.zoomBlur()
                blur.inputImage = image.clampedToExtent(); blur.center = CGPoint(x: inner.midX, y: inner.midY)
                blur.amount = Float(min(speed*6, 14)*canvas.width/1920*plan.motionBlurAmount*2)
                image = blur.outputImage?.cropped(to: inner) ?? image
            }
        }
        if let background = state.background, let mask = state.mask {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image; blend.backgroundImage = background; blend.maskImage = mask
            image = blend.outputImage ?? image
        }
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }
}

enum StudioExporter {
    static func loadTrack(for video: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: CursorTrack.sidecarURL(for: video)) else { return nil }
        return try? JSONDecoder().decode(CursorTrack.self, from: data)
    }
    static func loadPlan(for video: URL) -> StudioPlan? {
        (try? Data(contentsOf: CursorTrack.planURL(for: video))).flatMap { try? JSONDecoder().decode(StudioPlan.self, from: $0) }
    }
    static func savePlan(_ plan: StudioPlan, for video: URL) { try? JSONEncoder().encode(plan).write(to: CursorTrack.planURL(for: video), options: .atomic) }

    /// A composition used both for live preview and export, so they always match.
    static func composition(asset: AVAsset, renderer: StudioRenderer) async throws -> AVMutableVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            request.finish(with: renderer.render(request.sourceImage, at: request.compositionTime.seconds), context: StudioRenderer.context)
        }
        let fps = (try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)).flatMap { $0 } ?? 60
        // Zooms and the cursor move during still screens, so render a constant frame rate.
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(60, max(30, Double(fps).rounded()))))
        composition.renderSize = renderer.canvas
        return composition
    }
    static func videoSize(_ asset: AVAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ShotError.message("This recording has no video track.") }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// Hardware-encoded export at the plan's output size, with audio kept.
    static func export(video: URL, track: CursorTrack, plan: StudioPlan, to output: URL, range: ClosedRange<Double>? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let size = try await videoSize(asset)
        let renderer = StudioRenderer(track: track, plan: plan, duration: duration, video: size, canvas: plan.canvasSize(for: size))
        let composition = try await composition(asset: asset, renderer: renderer)
        let preset = plan.hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw ShotError.message("Cannot export this recording.") }
        session.videoComposition = composition
        if let range { session.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600), end: CMTime(seconds: range.upperBound, preferredTimescale: 600)) }
        let monitor = progress.map { report in
            Task { for await state in session.states(updateInterval: 0.2) { if case .exporting(let p) = state { report(p.fractionCompleted) } } }
        }
        defer { monitor?.cancel() }
        try await session.export(to: output, as: .mp4)
    }
}
