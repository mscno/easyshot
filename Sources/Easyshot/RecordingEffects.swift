import AppKit
import AVFoundation
import CoreImage
import ApplicationServices
import Metal

final class CameraFeed: NSObject,AVCaptureVideoDataOutputSampleBufferDelegate,@unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "easyshot.camera")
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw ShotError.message("Camera access was denied. Enable it in System Settings or turn off webcam capture.") }
        guard let device = AVCaptureDevice.default(for: .video) else { throw ShotError.message("No camera is connected.") }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration(); session.sessionPreset = .medium
        guard session.canAddInput(input) else { session.commitConfiguration(); throw ShotError.message("Camera is unavailable.") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true; output.setSampleBufferDelegate(self,queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw ShotError.message("Cannot read camera frames.") }
        session.addOutput(output); session.commitConfiguration()
        await withCheckedContinuation { continuation in queue.async { self.session.startRunning(); continuation.resume() } }
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput sampleBuffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); frame = buffer; lock.unlock()
    }
    /// Diagnostics feed synthetic frames without a camera.
    func inject(_ buffer: CVPixelBuffer) { lock.lock(); frame = buffer; lock.unlock() }
    func latestFrame() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }
    func stop() { queue.async { self.session.stopRunning(); self.lock.lock(); self.frame = nil; self.lock.unlock() } }
}

/// Recording overlays: click rings, a keystroke caption and the webcam bubble. Frames are composited
/// on the GPU with a color-management-free Core Image context; sprites (rings, captions, masks) are
/// rasterized once and reused, so a frame costs a few texture draws rather than a CPU redraw.
final class RecordingEffects: @unchecked Sendable {
    struct Click { var point: CGPoint; var time: TimeInterval }
    struct Key { var text: String; var time: TimeInterval; var typed: Bool }
    struct Style {
        var clickColor: [Double] = [0.72,0.58,1,1]
        var clickScale = 1.0
        var clickFilled = false
        var allKeys = false
        var keysAtTop = false
        var keysLight = false
        var cameraShape: CameraShape = .circle
        var cameraSize: CameraSize = .medium
        var cameraCorner: ScreenCorner = .bottomRight
        static var current: Style {
            let p = Preferences.shared
            return Style(clickColor: p.clickColor,clickScale: p.clickSize,clickFilled: p.clickFilled,allKeys: p.keysAllKeys,keysAtTop: p.keysAtTop,keysLight: p.keysLight,
                         cameraShape: p.cameraShape,cameraSize: p.cameraSize,cameraCorner: p.cameraCorner)
        }
    }
    /// No color management: untouched pixels pass through bit-exact and nothing is converted per frame.
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(),.outputColorSpace: NSNull(),.cacheIntermediates: false,.name: "Easyshot recording effects"]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device,options: options) }
        return CIContext(options: options)
    }()
    let clicksEnabled: Bool
    let keysEnabled: Bool
    let source: CGRect
    let style: Style
    var camera: CameraFeed?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private let lock = NSLock()
    private var clicks: [Click] = []
    private var key: Key?
    // Sprite caches; touched only from the recording queue.
    private var rings: [Int: CIImage] = [:]
    private var caption: (text: String,image: CIImage)?
    private var bubble: (size: Int,mask: CIImage,border: CIImage)?
    init(source: CGRect,clicks: Bool,keys: Bool,style: Style = .current) { self.source = source; clicksEnabled = clicks; keysEnabled = keys; self.style = style }
    @MainActor func start(cameraEnabled: Bool) async throws {
        #if !APP_STORE
        if keysEnabled && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw ShotError.message("Allow Easyshot in System Settings → Privacy & Security → Accessibility to show keystrokes, or turn that option off.")
        }
        #endif
        if cameraEnabled { let camera = CameraFeed(); try await camera.start(); self.camera = camera }
        if clicksEnabled {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] _ in
                let p = NSEvent.mouseLocation
                let point = CGPoint(x: p.x,y: NSScreen.primaryHeight-p.y)
                self?.addClick(point)
            }
        }
        #if !APP_STORE
        if keysEnabled {
            let allKeys = style.allKeys
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let f = event.modifierFlags
                let command = !f.intersection([.command,.control,.option]).isEmpty
                let special = Self.special(event.keyCode)
                guard command || allKeys else { return }
                var text = ""
                if f.contains(.control) { text += "⌃" }; if f.contains(.option) { text += "⌥" }
                if f.contains(.shift) && (command || special != nil) { text += "⇧" }; if f.contains(.command) { text += "⌘" }
                text += special ?? (command ? (event.charactersIgnoringModifiers ?? "").uppercased() : (event.characters ?? ""))
                self?.setKey(text,typed: !command && special == nil)
            }
        }
        #endif
    }
    static func special(_ code: UInt16) -> String? {
        [36: "⏎",48: "⇥",49: "Space",51: "⌫",53: "⎋",117: "⌦",123: "←",124: "→",125: "↓",126: "↑",115: "↖",119: "↘",116: "⇞",121: "⇟",76: "⌤"][code]
    }
    @MainActor func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        camera?.stop(); camera = nil
    }
    func addClick(_ point: CGPoint) { lock.lock(); clicks.append(Click(point: point,time: ProcessInfo.processInfo.systemUptime)); lock.unlock() }
    /// Plain typing within a second accumulates into one caption, like "hello"; shortcuts replace it.
    func setKey(_ text: String,typed: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if typed,let key,key.typed,now-key.time < 1 { self.key = Key(text: String((key.text+text).suffix(24)),time: now,typed: true) }
        else { key = Key(text: text,time: now,typed: typed) }
        lock.unlock()
    }
    func composite(_ input: CVPixelBuffer,pool: CVPixelBufferPool) -> CVPixelBuffer? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); clicks.removeAll { now-$0.time > 0.7 }; let clicks = self.clicks; let key = self.key; lock.unlock()
        let cameraBuffer = camera?.latestFrame()
        let showKey = key.map { now-$0.time < 1.8 } ?? false
        guard !clicks.isEmpty || cameraBuffer != nil || showKey else { return input }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess,let buffer else { return nil }
        let w = CGFloat(CVPixelBufferGetWidth(buffer)),h = CGFloat(CVPixelBufferGetHeight(buffer))
        let scale = w/max(source.width,1)
        var image = CIImage(cvPixelBuffer: input)
        for click in clicks where source.contains(click.point) {
            let age = now-click.time
            let ring = self.ring(radius: (14+age*20)*scale*style.clickScale,scale: scale)
            let p = CGPoint(x: (click.point.x-source.minX)*scale,y: h-(click.point.y-source.minY)*scale)
            let faded = ring.applyingFilter("CIColorMatrix",parameters: ["inputAVector": CIVector(x: 0,y: 0,z: 0,w: CGFloat(max(0,1-age/0.7)))])
            image = faded.transformed(by: CGAffineTransform(translationX: p.x-ring.extent.width/2,y: p.y-ring.extent.height/2)).composited(over: image)
        }
        if let cameraBuffer { image = bubble(CIImage(cvPixelBuffer: cameraBuffer),width: w,height: h,scale: scale).composited(over: image) }
        if showKey,let key {
            let caption = self.caption(key.text,scale: scale)
            let y = style.keysAtTop ? h-caption.extent.height-36*scale : 24*scale
            image = caption.transformed(by: CGAffineTransform(translationX: ((w-caption.extent.width)/2).rounded(),y: y.rounded())).composited(over: image)
        }
        Self.context.render(image.cropped(to: CGRect(x: 0,y: 0,width: w,height: h)),to: buffer,bounds: CGRect(x: 0,y: 0,width: w,height: h),colorSpace: nil)
        return buffer
    }
    private static func sprite(width: Int,height: Int,draw: (CGContext) -> Void) -> CIImage {
        guard let ctx = CGContext(data: nil,width: max(1,width),height: max(1,height),bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue) else { return CIImage.empty() }
        draw(ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }
    /// Ring sprites in 2 px radius steps.
    private func ring(radius: CGFloat,scale: CGFloat) -> CIImage {
        let step = Int((radius/2).rounded())
        if let cached = rings[step] { return cached }
        let r = CGFloat(step*2),line = 3*scale,size = Int(ceil((r+line)*2))
        let c = style.clickColor,filled = style.clickFilled
        let image = Self.sprite(width: size,height: size) { ctx in
            let circle = CGRect(x: CGFloat(size)/2-r,y: CGFloat(size)/2-r,width: r*2,height: r*2)
            let color = CGColor(srgbRed: c[0],green: c[1],blue: c[2],alpha: c.count > 3 ? c[3] : 1)
            if filled { ctx.setFillColor(color.copy(alpha: 0.35) ?? color); ctx.fillEllipse(in: circle) }
            ctx.setStrokeColor(color); ctx.setLineWidth(line); ctx.strokeEllipse(in: circle)
        }
        rings[step] = image
        return image
    }
    private func caption(_ text: String,scale: CGFloat) -> CIImage {
        if let caption,caption.text == text { return caption.image }
        let light = style.keysLight
        let string = NSAttributedString(string: text,attributes: [.font: NSFont.systemFont(ofSize: 22*scale,weight: .semibold),.foregroundColor: light ? NSColor.black : NSColor.white])
        let size = string.size()
        let box = CGSize(width: ceil(size.width+36*scale),height: ceil(size.height+20*scale))
        let image = Self.sprite(width: Int(box.width),height: Int(box.height)) { ctx in
            ctx.setFillColor(light ? CGColor(gray: 1,alpha: 0.92) : CGColor(gray: 0,alpha: 0.78))
            ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero,size: box),cornerWidth: 10*scale,cornerHeight: 10*scale,transform: nil)); ctx.fillPath()
            let previous = NSGraphicsContext.current; NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: false)
            string.draw(at: CGPoint(x: 18*scale,y: 10*scale)); NSGraphicsContext.current = previous
        }
        caption = (text,image)
        return image
    }
    /// The mirrored camera, filled into the chosen shape and size, in the chosen corner.
    private func bubble(_ camera: CIImage,width w: CGFloat,height h: CGFloat,scale: CGFloat) -> CIImage {
        let size = (min(w,h)*style.cameraSize.fraction).rounded()
        if bubble?.size != Int(size) {
            let shapeKind = style.cameraShape
            let shape: (CGRect) -> CGPath = { r in
                switch shapeKind {
                case .circle: CGPath(ellipseIn: r,transform: nil)
                case .rounded: CGPath(roundedRect: r,cornerWidth: r.width*0.2,cornerHeight: r.width*0.2,transform: nil)
                case .square: CGPath(rect: r,transform: nil)
                }
            }
            let rect = CGRect(x: 0,y: 0,width: size,height: size)
            let mask = Self.sprite(width: Int(size),height: Int(size)) { ctx in ctx.setFillColor(.white); ctx.addPath(shape(rect)); ctx.fillPath() }
            let border = Self.sprite(width: Int(size),height: Int(size)) { ctx in ctx.setStrokeColor(CGColor(gray: 1,alpha: 0.8)); ctx.setLineWidth(3*scale); ctx.addPath(shape(rect.insetBy(dx: 1.5*scale,dy: 1.5*scale))); ctx.strokePath() }
            bubble = (Int(size),mask,border)
        }
        guard let bubble else { return CIImage.empty() }
        let e = camera.extent
        let fill = max(size/e.width,size/e.height)
        // Mirror like a selfie view, centred in the square.
        let fitted = camera.transformed(by: CGAffineTransform(translationX: -e.midX,y: -e.midY).concatenating(CGAffineTransform(scaleX: -fill,y: fill)).concatenating(CGAffineTransform(translationX: size/2,y: size/2)))
            .cropped(to: CGRect(x: 0,y: 0,width: size,height: size))
        let shaped = fitted.applyingFilter("CIBlendWithAlphaMask",parameters: [kCIInputBackgroundImageKey: CIImage.empty(),kCIInputMaskImageKey: bubble.mask])
        let framed = bubble.border.composited(over: shaped)
        let margin = 24*scale
        let x = [ScreenCorner.bottomRight,.topRight].contains(style.cameraCorner) ? w-size-margin : margin
        let y = [ScreenCorner.topLeft,.topRight].contains(style.cameraCorner) ? h-size-margin : margin
        return framed.transformed(by: CGAffineTransform(translationX: x.rounded(),y: y.rounded()))
    }
}
