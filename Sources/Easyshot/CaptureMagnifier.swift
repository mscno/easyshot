import AppKit
import ScreenCaptureKit
import EasyshotCore

/// Pixels under the pointer for the selection loupe. Nothing is sampled while the magnifier is off. While on,
/// one tiny native-pixel screenshot is in flight at a time and requests are capped at the display refresh rate;
/// a frozen backdrop is cropped instead of captured.
@MainActor final class PixelSampler {
    private(set) var image: CGImage?
    private(set) var hex: String?
    private(set) var sampledPoint: CGPoint?
    private(set) var captures = 0
    private(set) var captureMilliseconds = 0.0
    var onUpdate: (() -> Void)?
    var frozen: () -> [CGDirectDisplayID: CGImage] = { [:] }
    private var content: SCShareableContent?
    private var filters: [CGDirectDisplayID: (SCDisplay,SCContentFilter)] = [:]
    private var loading = false
    private var inFlight = false
    private var pending: CGPoint?
    private var generation = 0
    var averageMilliseconds: Double { captures == 0 ? 0 : captureMilliseconds/Double(captures) }
    func reset() { generation += 1; image = nil; hex = nil; sampledPoint = nil; pending = nil; content = nil; filters = [:]; inFlight = false; loading = false }
    func request(_ point: CGPoint) { pending = point; pump() }
    private func pump() {
        guard !inFlight,!loading,let point = pending,let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let rect = PixelLoupe.sampleRect(around: point,scale: screen.backingScaleFactor)
        let quartz = CaptureGeometry.quartz(rect,primaryHeight: NSScreen.primaryHeight)
        let displayQuartz = CaptureGeometry.quartz(screen.frame,primaryHeight: NSScreen.primaryHeight)
        if let still = frozen()[screen.displayID] {
            pending = nil
            if let crop = ScreenshotPixels.cropRect(quartz,display: displayQuartz,width: still.width,height: still.height),let part = still.cropping(to: crop) { publish(part,at: point) }
            return
        }
        guard let content else { load(); return }
        guard let (display,filter) = filter(for: screen.displayID,content: content) else { pending = nil; return }
        pending = nil; inFlight = true
        let config = SCStreamConfiguration()
        config.sourceRect = CaptureGeometry.sourceRect(quartz,in: display.frame)
        config.width = PixelLoupe.samplePixels; config.height = PixelLoupe.samplePixels
        config.showsCursor = false; config.captureResolution = .best
        let token = generation
        let started = ProcessInfo.processInfo.systemUptime
        Task {
            let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,configuration: config)
            guard token == generation else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime-started
            captures += 1; captureMilliseconds += elapsed*1000
            if let image { publish(image,at: point) }
            // At most one sample per display frame, however fast the pointer moves.
            if elapsed < 1.0/60 { try? await Task.sleep(for: .seconds(1.0/60-elapsed)) }
            guard token == generation else { return }
            inFlight = false; pump()
        }
    }
    private func load() {
        loading = true
        let token = generation
        Task {
            let shared = try? await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly: true)
            guard token == generation else { return }
            content = shared; loading = false
            if shared != nil { pump() }
        }
    }
    private func filter(for id: CGDirectDisplayID,content: SCShareableContent) -> (SCDisplay,SCContentFilter)? {
        if let cached = filters[id] { return cached }
        guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        // Exclude Easyshot itself so the dimming, crosshair and loupe never appear inside the loupe.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let entry = (display,SCContentFilter(display: display,excludingApplications: own,exceptingWindows: []))
        filters[id] = entry; return entry
    }
    private func publish(_ part: CGImage,at point: CGPoint) {
        image = part; sampledPoint = point; hex = Self.centerHex(part); onUpdate?()
    }
    /// sRGB hex of the centre pixel, the one under the crosshair.
    nonisolated static func centerHex(_ image: CGImage) -> String? {
        var pixel = [UInt8](repeating: 0,count: 4)
        let ok = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress,width: 1,height: 1,bitsPerComponent: 8,bytesPerRow: 4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image,in: CGRect(x: -CGFloat(image.width/2),y: -CGFloat(image.height/2),width: CGFloat(image.width),height: CGFloat(image.height)))
            return true
        }
        return ok ? PixelLoupe.hex(red: pixel[0],green: pixel[1],blue: pixel[2]) : nil
    }
}

/// Crosshair and loupe drawing for `SelectionView`, in the view's local coordinates.
enum MagnifierChrome {
    static let loupeSize = CGSize(width: 168,height: 230)
    static let zoom: CGFloat = 7
    static func crosshair(at p: CGPoint,in ctx: CGContext,bounds: CGRect) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        for (color,phase) in [(NSColor.black.withAlphaComponent(0.75),CGFloat(0)),(NSColor.white,CGFloat(4))] {
            ctx.setStrokeColor(color.cgColor); ctx.setLineDash(phase: phase,lengths: [4,4])
            ctx.move(to: CGPoint(x: bounds.minX,y: p.y.rounded()+0.5)); ctx.addLine(to: CGPoint(x: bounds.maxX,y: p.y.rounded()+0.5))
            ctx.move(to: CGPoint(x: p.x.rounded()+0.5,y: bounds.minY)); ctx.addLine(to: CGPoint(x: p.x.rounded()+0.5,y: bounds.maxY))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
    static func loupe(pointer p: CGPoint,in ctx: CGContext,bounds: CGRect,image: CGImage?,hex: String?,caption: [String]) {
        let box = PixelLoupe.placement(pointer: p,size: loupeSize,in: bounds)
        let side = CGFloat(PixelLoupe.samplePixels)*zoom
        let well = CGRect(x: box.midX-side/2,y: box.maxY-side-6,width: side,height: side)
        NSColor.black.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: box,xRadius: 12,yRadius: 12).fill()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: well,cornerWidth: 7,cornerHeight: 7,transform: nil)); ctx.clip()
        if let image { ctx.interpolationQuality = .none; ctx.draw(image,in: well) } else { NSColor.darkGray.setFill(); well.fill() }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(0.5)
        for i in 1..<PixelLoupe.samplePixels {
            let o = CGFloat(i)*zoom
            ctx.move(to: CGPoint(x: well.minX+o,y: well.minY)); ctx.addLine(to: CGPoint(x: well.minX+o,y: well.maxY))
            ctx.move(to: CGPoint(x: well.minX,y: well.minY+o)); ctx.addLine(to: CGPoint(x: well.maxX,y: well.minY+o))
        }
        ctx.strokePath()
        let centre = CGRect(x: well.midX-zoom/2,y: well.midY-zoom/2,width: zoom,height: zoom)
        ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(2); ctx.stroke(centre.insetBy(dx: -1,dy: -1))
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1); ctx.stroke(centre)
        ctx.restoreGState()
        let font = NSFont.monospacedSystemFont(ofSize: 10.5,weight: .medium)
        var y = well.minY-17
        for line in caption {
            (line as NSString).draw(at: CGPoint(x: box.minX+12,y: y),withAttributes: [.font: font,.foregroundColor: NSColor.white.withAlphaComponent(0.92)]); y -= 15
        }
        if let hex {
            let swatch = CGRect(x: box.maxX-24,y: box.minY+10,width: 12,height: 12)
            if let color = NSColor(hexString: hex) { color.setFill(); NSBezierPath(roundedRect: swatch,xRadius: 3,yRadius: 3).fill() }
            ("\(hex)  C: copy" as NSString).draw(at: CGPoint(x: box.minX+12,y: box.minY+9),withAttributes: [.font: font,.foregroundColor: NSColor.white])
        }
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6,let value = UInt32(digits,radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF)/255,green: CGFloat((value >> 8) & 0xFF)/255,blue: CGFloat(value & 0xFF)/255,alpha: 1)
    }
}
