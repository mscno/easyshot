import AppKit
import AVFoundation
import CoreImage
import ApplicationServices

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

final class RecordingEffects: @unchecked Sendable {
    struct Click { var point: CGPoint; var time: TimeInterval }
    struct Key { var text: String; var time: TimeInterval }
    let clicksEnabled: Bool
    let keysEnabled: Bool
    let source: CGRect
    var camera: CameraFeed?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private let lock = NSLock()
    private var clicks: [Click] = []
    private var key: Key?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    init(source: CGRect,clicks: Bool,keys: Bool) { self.source = source; clicksEnabled = clicks; keysEnabled = keys }
    @MainActor func start(cameraEnabled: Bool) async throws {
        #if !APP_STORE
        if keysEnabled && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw ShotError.message("Allow Easyshot in System Settings → Privacy & Security → Accessibility to show command shortcuts, or turn that option off.")
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
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let f = event.modifierFlags
                guard !f.intersection([.command,.control,.option]).isEmpty else { return }
                var text = ""
                if f.contains(.control) { text += "⌃" }; if f.contains(.option) { text += "⌥" }
                if f.contains(.shift) { text += "⇧" }; if f.contains(.command) { text += "⌘" }
                text += (event.charactersIgnoringModifiers ?? "").uppercased()
                self?.setKey(text)
            }
        }
        #endif
    }
    @MainActor func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        camera?.stop(); camera = nil
    }
    func addClick(_ point: CGPoint) { lock.lock(); clicks.append(Click(point: point,time: ProcessInfo.processInfo.systemUptime)); lock.unlock() }
    func setKey(_ text: String) { lock.lock(); key = Key(text: text,time: ProcessInfo.processInfo.systemUptime); lock.unlock() }
    func composite(_ input: CVPixelBuffer,pool: CVPixelBufferPool) -> CVPixelBuffer? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); clicks.removeAll { now-$0.time > 0.7 }; let clicks = self.clicks; let key = self.key; lock.unlock()
        let cameraBuffer = camera?.latestFrame()
        guard !clicks.isEmpty || cameraBuffer != nil || (key != nil && now-key!.time < 1.8) else { return input }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess,let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer,[]); defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        let w = CVPixelBufferGetWidth(buffer); let h = CVPixelBufferGetHeight(buffer)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),width: w,height: h,bitsPerComponent: 8,bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: info) else { return nil }
        let image = CIImage(cvPixelBuffer: input)
        guard let base = ci.createCGImage(image,from: image.extent) else { return nil }
        ctx.draw(base,in: CGRect(x: 0,y: 0,width: w,height: h))
        let scale = CGFloat(w)/max(source.width,1)
        for click in clicks {
            guard source.contains(click.point) else { continue }
            let age = now-click.time
            let radius = (14+age*20)*scale
            let p = CGPoint(x: (click.point.x-source.minX)*scale,y: CGFloat(h)-(click.point.y-source.minY)*scale)
            ctx.setStrokeColor(NSColor(srgbRed: 0.72,green: 0.58,blue: 1,alpha: max(0,1-age/0.7)).cgColor)
            ctx.setLineWidth(3*scale); ctx.strokeEllipse(in: CGRect(x: p.x-radius,y: p.y-radius,width: radius*2,height: radius*2))
        }
        if let cameraBuffer {
            let cameraImage = CIImage(cvPixelBuffer: cameraBuffer)
            if let shot = ci.createCGImage(cameraImage,from: cameraImage.extent) {
                let size = min(CGFloat(w),CGFloat(h))*0.23
                let bubble = CGRect(x: CGFloat(w)-size-24*scale,y: 24*scale,width: size,height: size)
                ctx.saveGState(); ctx.addEllipse(in: bubble); ctx.clip()
                let factor = max(size/CGFloat(shot.width),size/CGFloat(shot.height))
                let rect = CGRect(x: bubble.midX-CGFloat(shot.width)*factor/2,y: bubble.midY-CGFloat(shot.height)*factor/2,width: CGFloat(shot.width)*factor,height: CGFloat(shot.height)*factor)
                ctx.translateBy(x: bubble.midX*2,y: 0); ctx.scaleBy(x: -1,y: 1); ctx.draw(shot,in: rect); ctx.restoreGState()
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(3*scale); ctx.strokeEllipse(in: bubble)
            }
        }
        if let key,now-key.time < 1.8 {
            let text = NSAttributedString(string: key.text,attributes: [.font: NSFont.systemFont(ofSize: 22*scale,weight: .semibold),.foregroundColor: NSColor.white])
            let size = text.size(); let box = CGRect(x: (CGFloat(w)-size.width)/2-18*scale,y: 24*scale,width: size.width+36*scale,height: size.height+20*scale)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor); ctx.addPath(CGPath(roundedRect: box,cornerWidth: 10*scale,cornerHeight: 10*scale,transform: nil)); ctx.fillPath()
            let previous = NSGraphicsContext.current; NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: false)
            text.draw(at: CGPoint(x: box.minX+18*scale,y: box.minY+10*scale)); NSGraphicsContext.current = previous
        }
        return buffer
    }
}
