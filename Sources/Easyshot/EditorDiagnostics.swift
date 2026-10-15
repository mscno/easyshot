import AppKit
import AVFoundation
import CoreImage
import Vision
import EasyshotCore

/// Offline checks for the editor and recording pipeline. None need Screen Recording access.
enum EditorDiagnostics {
    /// Starts a diagnostic named on the command line; returns false when none was requested.
    @MainActor static func launch(_ arguments: [String]) -> Bool {
        let run: (() async -> Int32)?
        if arguments.contains("--effects-bench") { run = effectsBench }
        else if arguments.contains("--editor-test") { run = editorTest }
        else { run = nil }
        guard let run else { return false }
        Task { let result = await run(); fflush(stdout); exit(result) }
        return true
    }

    static func pixelBuffer(width: Int,height: Int,fill: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,&buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer,[])
        let base = CVPixelBufferGetBaseAddress(buffer)!, stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { memset(base+y*stride,Int32(fill &+ UInt8(truncatingIfNeeded: y)),width*4) }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        return buffer
    }

    /// Per-frame cost of recording overlays (clicks, keystroke caption, camera bubble) at 1440p.
    static func effectsBench() async -> Int32 {
        let w = 2560, h = 1440, frames = 240
        guard let input = pixelBuffer(width: w,height: h,fill: 60),let camera = pixelBuffer(width: 1280,height: 720,fill: 140) else { print("FAIL: buffers"); return 1 }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil,[kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,[kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: w,kCVPixelBufferHeightKey as String: h,kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,&pool)
        guard let pool else { print("FAIL: pool"); return 1 }
        let effects = RecordingEffects(source: CGRect(x: 0,y: 0,width: 1280,height: 720),clicks: true,keys: true)
        let feed = CameraFeed(); feed.inject(camera); effects.camera = feed
        var last: CVPixelBuffer?
        func frame(_ i: Int) {
            if i % 10 == 0 { effects.addClick(CGPoint(x: 200+Double(i%50)*15,y: 300)) }
            if i % 30 == 0 { effects.setKey("⌘⇧\(i%7)") }
            last = effects.composite(input,pool: pool)
        }
        for i in 0..<20 { frame(i) }
        let began = CACurrentMediaTime()
        for i in 0..<frames { frame(i) }
        if let last { CVPixelBufferLockBaseAddress(last,.readOnly); CVPixelBufferUnlockBaseAddress(last,.readOnly) }
        let ms = (CACurrentMediaTime()-began)*1000/Double(frames)
        print(String(format: "INFO: recording effects at %d×%d with clicks, caption and camera: %.2f ms/frame (%.0f fps max)",w,h,ms,1000/ms))
        print(last != nil ? "PASS: composite produced frames" : "FAIL: composite returned nil")
        return last != nil ? 0 : 1
    }

    static func editorTest() async -> Int32 { 0 }
}
