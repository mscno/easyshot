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
        func cpu() -> Double { var usage = rusage(); getrusage(RUSAGE_SELF,&usage); return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)*1000+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1000 }
        let began = CACurrentMediaTime(),cpuBegan = cpu()
        for i in 0..<frames { frame(i) }
        if let last { CVPixelBufferLockBaseAddress(last,.readOnly); CVPixelBufferUnlockBaseAddress(last,.readOnly) }
        let ms = (CACurrentMediaTime()-began)*1000/Double(frames),cpuMs = (cpu()-cpuBegan)/Double(frames)
        print(String(format: "INFO: recording effects at %d×%d with clicks, caption and camera: %.2f ms/frame wall, %.2f ms/frame CPU (%.0f fps max)",w,h,ms,cpuMs,1000/ms))
        print(last != nil ? "PASS: composite produced frames" : "FAIL: composite returned nil")
        return last != nil ? 0 : 1
    }

    /// Editor tools, secret detection on rendered text, backgrounds, retention, pause/resume writing,
    /// recording overlay styles and reframed Studio export.
    @MainActor static func editorTest() async -> Int32 {
        var checks = 0,failures = 0
        func check(_ ok: Bool,_ name: String) { checks += 1; if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL"): \(name)"); fflush(stdout) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("easyshot-editor-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let store = ClipStore(directory: folder.appendingPathComponent("History"))

        // A text screenshot with three kinds of secret on separate lines.
        let lines = ["OPENAI_API_KEY=sk-proj-Q7wErTy8uIoP2aSdFgH4jKlZ","contact mads@example.com today","ssh deploy@10.42.17.9 -p 22","build 6ef6e5e passed"]
        guard let ctx = EditorModel.context(width: 1100,height: 360) else { print("FAIL: context"); return 1 }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0,y: 0,width: 1100,height: 360))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: false)
        for (i,line) in lines.enumerated() { (line as NSString).draw(at: CGPoint(x: 40,y: 290-i*80),withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 30,weight: .regular),.foregroundColor: NSColor.black]) }
        NSGraphicsContext.current = nil
        let image = ctx.makeImage()!
        let clip = Clip(path: folder.appendingPathComponent("text.png").path,kind: "Test",width: image.width,height: image.height)
        let editor = EditorModel(image: image,clip: clip,store: store)
        let analysis = await editor.analyze().value
        let kinds = Set(analysis?.secrets.map(\.kind) ?? [])
        check(kinds.isSuperset(of: [.apiKey,.email,.ipv4]),"OCR finds the API key, email and IP address (\(kinds.map(\.rawValue).sorted()))")
        check(!kinds.contains(.gitSHA) && !kinds.contains(.highEntropy),"a short git SHA is not proposed by default")
        if let key = analysis?.secrets.first(where: { $0.kind == .apiKey }) {
            check(key.rect.minY > 270 && key.rect.maxY < 345 && key.rect.minX > 230 && key.rect.minX < 330 && key.rect.maxX > 800,"API key box covers the value on the first line, not the variable name (x \(Int(key.rect.minX))…\(Int(key.rect.maxX)))")
        } else { check(false,"API key box") }
        check((analysis?.lines.count ?? 0) >= 4,"text lines are available for snapping")
        editor.findSecrets()
        for _ in 0..<50 where editor.scanning { try? await Task.sleep(for: .milliseconds(20)) }
        let found = editor.proposals.count
        check(found >= 3,"Find secrets proposes \(found) redactions")
        editor.redactProposals()
        let redacted = NSBitmapImageRep(cgImage: editor.render()!)
        if let box = editor.marks.first?.rect {
            let pixel = redacted.colorAt(x: Int(box.midX),y: image.height-Int(box.midY))?.usingColorSpace(.sRGB)
            check((pixel?.brightnessComponent ?? 1) < 0.05,"Redact all paints solid boxes")
        } else { check(false,"Redact all adds marks") }
        check(editor.proposals.isEmpty && editor.marks.count == found,"proposals become \(found) redaction marks")

        // Highlighter snapping to the second line (y 210…250).
        editor.marks = []
        editor.add(Mark(tool: .highlight,points: [CGPoint(x: 60,y: 226),CGPoint(x: 300,y: 232)],color: [1,0.85,0.2,1],width: 6))
        if let h = editor.marks.last?.rect { check(h.height > 20 && h.minY < 226 && h.maxY > 232,"highlighter snaps to the text line height (\(Int(h.minY))…\(Int(h.maxY)))") }

        // Arrow styles, text presets and the irreversible mosaic.
        let blank = EditorModel(image: Diagnostics.patternImage(width: 400,height: 300),clip: clip,store: store)
        let base = NSBitmapImageRep(cgImage: blank.render()!)
        for style in ArrowStyle.allCases {
            blank.marks = []
            blank.add(Mark(tool: .arrow,points: [CGPoint(x: 40,y: 40),CGPoint(x: 340,y: 240)],color: [1,0,0,1],width: 6,arrow: style))
            let rendered = NSBitmapImageRep(cgImage: blank.render()!)
            // Sample just behind the tip along the curve's final direction, inside the head.
            let a = CGPoint(x: 40,y: 40),b = CGPoint(x: 340,y: 240)
            let control = blank.marks.first?.bend.map { ArrowGeometry.control(from: a,to: b,through: $0) } ?? CGPoint(x: 190,y: 140)
            let angle = ArrowGeometry.tangentAngle(a,control,b,atEnd: true)
            let tip = rendered.colorAt(x: Int(b.x-7*cos(angle)),y: 300-Int(b.y-7*sin(angle)))?.usingColorSpace(.sRGB)
            check(blank.marks.first?.hasBend == (style == .curved || style == .tapered) && (tip?.redComponent ?? 0) > 0.9 && (tip?.greenComponent ?? 1) < 0.2,"\(style.rawValue) arrow renders its head")
        }
        blank.marks = []
        for preset in TextPreset.allCases {
            blank.marks = [Mark(tool: .text,points: [CGPoint(x: 60,y: 120),CGPoint(x: 60,y: 120)],color: [0.2,0.4,1,1],width: 6,text: "Label",preset: preset)]
            let rendered = NSBitmapImageRep(cgImage: blank.render()!)
            let changed = stride(from: 40,to: 300,by: 7).contains { x in stride(from: 120,to: 190,by: 5).contains { y in rendered.colorAt(x: x,y: y) != base.colorAt(x: x,y: y) } }
            check(changed,"\(preset.rawValue) text preset renders")
        }
        blank.marks = [Mark(tool: .pixelate,points: [CGPoint(x: 20,y: 20),CGPoint(x: 300,y: 220)],color: [0,0,0,1],width: 1,seed: 42)]
        let first = blank.render()!,second = blank.render()!
        check(NSBitmapImageRep(cgImage: first).representation(using: .png,properties: [:]) == NSBitmapImageRep(cgImage: second).representation(using: .png,properties: [:]),"pixelation is stable across redraws")
        if let crop = Diagnostics.patternImage(width: 400,height: 300).cropping(to: CGRect(x: 20,y: 80,width: 280,height: 200)),let scrambled = EditorModel.scrambledMosaic(crop,seed: 42) {
            let plain = EditorModel.context(width: scrambled.width,height: scrambled.height)!
            plain.draw(crop,in: CGRect(x: 0,y: 0,width: scrambled.width,height: scrambled.height))
            let a = NSBitmapImageRep(cgImage: scrambled),b = NSBitmapImageRep(cgImage: plain.makeImage()!)
            var moved = 0
            for x in 0..<a.pixelsWide { for y in 0..<a.pixelsHigh where abs((a.colorAt(x: x,y: y)?.redComponent ?? 0)-(b.colorAt(x: x,y: y)?.redComponent ?? 0)) > 0.12 { moved += 1 } }
            check(moved > a.pixelsWide*a.pixelsHigh/2,"mosaic blocks are shuffled away from their source positions (\(moved)/\(a.pixelsWide*a.pixelsHigh))")
        }

        // Crop with a 16:9 aspect and combining beside.
        blank.marks = []; blank.cropAspect = .sixteenNine
        let corner = blank.cropCorner(anchor: CGPoint(x: 10,y: 10),point: CGPoint(x: 390,y: 290),tolerance: 4)
        blank.add(Mark(tool: .crop,points: [CGPoint(x: 10,y: 10),corner],color: [1,0,0,1],width: 2))
        check(abs(Double(blank.image.width)/Double(blank.image.height)-16/9) < 0.02,"16:9 crop (\(blank.image.width)×\(blank.image.height))")
        let other = folder.appendingPathComponent("other.png")
        try? ScreenshotPixels.png(Diagnostics.patternImage(width: 100,height: 50)).write(to: other)
        let width = blank.image.width
        blank.combine(other,horizontal: true)
        check(blank.image.width == width+124,"combine beside adds width plus a gap")

        // Backgrounds and layout.
        let distinct = (0..<Backdrops.count).filter { i in
            guard let b = Backdrops.image(i,size: CGSize(width: 120,height: 80)) else { return false }
            let rep = NSBitmapImageRep(cgImage: b)
            return rep.colorAt(x: 2,y: 2) != rep.colorAt(x: 117,y: 77)
        }.count
        check(Backdrops.count == 20 && distinct == 20,"20 generated backgrounds, each a gradient (\(distinct))")
        let framed = EditorModel(image: Diagnostics.patternImage(width: 200,height: 100),clip: clip,store: store)
        framed.backdrop = .gradient(14); framed.padding = 20; framed.aspect = .square; framed.alignment = .topLeft; framed.corner = 12
        let square = framed.render()!
        check(square.width == 240 && square.height == 240,"square background canvas")
        let topLeft = NSBitmapImageRep(cgImage: square).colorAt(x: 30,y: 30),bottomRight = NSBitmapImageRep(cgImage: square).colorAt(x: 200,y: 200)
        check(topLeft != nil && bottomRight != nil && topLeft != bottomRight,"top-left alignment places the screenshot at the top")
        // A window capture with a transparent 40 px margin below the window.
        let shadowed = EditorModel.context(width: 200,height: 140)!
        shadowed.draw(Diagnostics.patternImage(width: 200,height: 100),in: CGRect(x: 0,y: 40,width: 200,height: 100))
        let balanced = EditorModel(image: shadowed.makeImage()!,clip: clip,store: store)
        balanced.padding = 30; balanced.autoBalance = true
        check(balanced.visibleBounds() == CGRect(x: 0,y: 0,width: 200,height: 100),"auto-balance finds the opaque window")
        check(balanced.render()?.height == 160,"auto-balance pads the visible window evenly")
        let legacy = #"{"png":"","marks":[],"padding":12,"background":[0.1,0.2,0.3,1],"shadow":false}"#
        if let project = try? JSONDecoder().decode(EditorProject.self,from: Data(legacy.utf8)) {
            framed.apply(project)
            check(framed.backdrop == .color(0.1,0.2,0.3) && framed.aspect == .auto && framed.padding == 12,"projects from earlier versions still open")
        } else { check(false,"legacy project decodes") }

        // Retention removes internal copies only.
        let internalFolder = store.support.appendingPathComponent("Captures")
        try? FileManager.default.createDirectory(at: internalFolder,withIntermediateDirectories: true)
        let oldInternal = internalFolder.appendingPathComponent("old.png"),oldExternal = folder.appendingPathComponent("user.png"),fresh = internalFolder.appendingPathComponent("new.png")
        for url in [oldInternal,oldExternal,fresh] { try? Data([1]).write(to: url) }
        store.clips = [Clip(path: oldInternal.path,date: Date(timeIntervalSinceNow: -9*86_400),kind: "Area",width: 1,height: 1),
                       Clip(path: oldExternal.path,date: Date(timeIntervalSinceNow: -9*86_400),kind: "Area",width: 1,height: 1),
                       Clip(path: fresh.path,kind: "Area",width: 1,height: 1)]
        store.applyRetention(.week)
        check(store.clips.map(\.path) == [fresh.path],"week retention keeps only recent history")
        check(!FileManager.default.fileExists(atPath: oldInternal.path) && FileManager.default.fileExists(atPath: oldExternal.path),"retention deletes internal copies, never files in the user's folder")

        await pauseTest(folder,check)
        overlayStyleTest(check)
        await studioAspectTest(folder,check)
        print("\(checks-failures)/\(checks) editor checks passed. Artifacts: \(folder.path)")
        return failures == 0 ? 0 : 1
    }

    /// 6 s of 30 fps frames with a pause from 2 s to 4 s, written through the recorder's own retiming.
    @MainActor static func pauseTest(_ folder: URL,_ check: @MainActor (Bool,String) -> Void) async {
        do {
            let url = folder.appendingPathComponent("paused.mp4")
            let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: 320,AVVideoHeightKey: 180])
            writer.add(input); writer.startWriting()
            var clock = PauseClock(frameDuration: 1/30.0)
            var started = false
            for i in 0..<180 {
                if i == 60 { clock.pause() }
                if i == 120 { clock.resume() }
                let pts = CMTime(value: 1_000_000+Int64(i),timescale: 30)
                guard let (time,delta) = Recorder.map(pts,track: 0,clock: &clock) else { continue }
                guard let buffer = pixelBuffer(width: 320,height: 180,fill: UInt8(i)) else { continue }
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil,imageBuffer: buffer,formatDescriptionOut: &format)
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: 30),presentationTimeStamp: pts,decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil,imageBuffer: buffer,formatDescription: format!,sampleTiming: &timing,sampleBufferOut: &sample)
                guard let sample,let retimed = Recorder.retimed(sample,by: delta) else { continue }
                if !started { writer.startSession(atSourceTime: time); started = true }
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                if !input.append(retimed) { throw writer.error ?? ShotError.message("append failed") }
            }
            input.markAsFinished(); await writer.finishWriting()
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try await asset.loadTracks(withMediaType: .video)[0],outputSettings: nil)
            reader.add(output); reader.startReading()
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sample) > 0 { times.append(sample.presentationTimeStamp.seconds) } }
            times.sort()
            let maxGap = zip(times,times.dropFirst()).map { $1-$0 }.max() ?? 0
            check(abs(duration-4) < 0.05 && times.count == 120,"pause removes 2 s: \(String(format: "%.2f",duration)) s, \(times.count) frames")
            check(maxGap < 1/30.0+0.002,"no frozen frame or gap across the pause (largest step \(String(format: "%.3f",maxGap)) s)")
        } catch { check(false,"pause/resume writer: \(error.localizedDescription)") }
    }

    static func overlayStyleTest(_ check: (Bool,String) -> Void) {
        guard let input = pixelBuffer(width: 640,height: 360,fill: 20),let camera = pixelBuffer(width: 320,height: 180,fill: 200) else { check(false,"overlay buffers"); return }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil,nil,[kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: 640,kCVPixelBufferHeightKey as String: 360,kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,&pool)
        var style = RecordingEffects.Style(); style.cameraShape = .square; style.cameraCorner = .topLeft; style.cameraSize = .large; style.clickFilled = true
        let effects = RecordingEffects(source: CGRect(x: 0,y: 0,width: 640,height: 360),clicks: true,keys: true,style: style)
        let feed = CameraFeed(); feed.inject(camera); effects.camera = feed
        effects.addClick(CGPoint(x: 500,y: 250)); effects.setKey("h",typed: true); effects.setKey("i",typed: true)
        guard let pool,let output = effects.composite(input,pool: pool) else { check(false,"styled composite"); return }
        CVPixelBufferLockBaseAddress(output,.readOnly); defer { CVPixelBufferUnlockBaseAddress(output,.readOnly) }
        let base = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self),stride = CVPixelBufferGetBytesPerRow(output)
        func value(_ x: Int,_ y: Int) -> UInt8 { base[y*stride+x*4+1] }
        // Buffer rows run top to bottom: a top-left square bubble starts ~15 px in; the frame's corner stays untouched.
        check(value(40,40) > 120 && value(3,3) < 60,"square camera bubble in the top-left corner")
        check(value(500,250) > 40,"filled click highlight paints the click point")
        check(value(320,330) < 60 && (300..<340).contains { y in (250..<390).contains { x in value(x,y) > 150 } },"typed keys accumulate into a bottom caption")
    }

    /// A 2 s synthetic 1280×720 recording exported as vertical 9:16 with the dot cursor.
    @MainActor static func studioAspectTest(_ folder: URL,_ check: @MainActor (Bool,String) -> Void) async {
        do {
            let url = folder.appendingPathComponent("wide.mp4")
            let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: 1280,AVVideoHeightKey: 720])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: nil)
            writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
            for i in 0..<60 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                guard let buffer = pixelBuffer(width: 1280,height: 720,fill: UInt8(i*3)) else { continue }
                adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(i),timescale: 30))
            }
            input.markAsFinished(); await writer.finishWriting()
            var track = CursorTrack(width: 1280,height: 720,scale: 1)
            track.samples = [.init(t: 0,x: 100,y: 360),.init(t: 2,x: 1200,y: 360)]
            var plan = StudioPlan(); plan.aspect = .vertical; plan.cursorStyle = .dot; plan.background = .none
            let out = folder.appendingPathComponent("vertical.mp4")
            let began = Date()
            try await StudioExporter.export(video: url,track: track,plan: plan,to: out)
            let size = try await StudioExporter.videoSize(AVURLAsset(url: out))
            check(size.height == 720 && abs(size.width/size.height-9/16) < 0.01,"vertical 9:16 export \(Int(size.width))×\(Int(size.height)) in \(String(format: "%.2f",Date().timeIntervalSince(began))) s")
            plan.aspect = .square; plan.background = .gradient(17); plan.padding = 0.06; plan.output = .p1080
            let squareURL = folder.appendingPathComponent("square.mp4")
            try await StudioExporter.export(video: url,track: track,plan: plan,to: squareURL)
            check(try await StudioExporter.videoSize(AVURLAsset(url: squareURL)) == CGSize(width: 720,height: 720),"square export with a mesh background")
        } catch { check(false,"Studio aspect export: \(error.localizedDescription)") }
    }
}
