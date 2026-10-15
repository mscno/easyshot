import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision
import ShotglassCore

nonisolated(unsafe) private var mcpChild: pid_t = 0

/// `Shotglass --mcp`: a stdio MCP server spawned by an AI agent. It lives only as long as the agent keeps
/// stdin open. No NSApplication, Dock icon, menu, capture bar or update check; stdout carries protocol JSON only.
enum MCPMode {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--mcp") else { return }
        signal(SIGPIPE,SIG_IGN)
        if let status = respawnDisclaimed() { exit(status) }
        MainActor.assumeIsolated { serve() }
    }
    /// A process spawned by Terminal, Claude or Codex inherits their privacy responsibility, so macOS would check
    /// the agent's Screen Recording grant. Respawn once as our own responsible process; Shotglass's grant then applies.
    private static func respawnDisclaimed() -> Int32? {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>,Int32) -> Int32
        guard getenv("SHOTGLASS_MCP_CHILD") == nil,let path = Bundle.main.executablePath,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),"responsibility_spawnattrs_setdisclaim") else { return nil }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        guard unsafeBitCast(symbol,to: Disclaim.self)(&attributes,1) == 0 else { return nil }
        setenv("SHOTGLASS_MCP_CHILD","1",1)
        var argv = CommandLine.arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid,path,nil,&attributes,&argv,environ) == 0 else { unsetenv("SHOTGLASS_MCP_CHILD"); return nil }
        mcpChild = pid
        for sig in [SIGTERM,SIGINT,SIGHUP] { signal(sig) { kill(mcpChild,$0) } }
        var status: Int32 = 0
        while waitpid(pid,&status,0) == -1 && errno == EINTR {}
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
    @MainActor private static func serve() -> Never {
        let tools = MCPTools()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let server = MCPServerCore(name: "shotglass",version: version,instructions: MCPTools.instructions,tools: MCPTools.definitions) { name,args in await tools.call(name,args) }
        let output = DispatchQueue(label: "shotglass.mcp.output")
        let pending = DispatchGroup()
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard line.contains(where: { !$0.isWhitespace }) else { continue }
                let data = Data(line.utf8)
                pending.enter()
                Task { @MainActor in
                    let reply = await server.handle(data)
                    output.async { if let reply { FileHandle.standardOutput.write(reply) }; pending.leave() }
                }
            }
            pending.wait()
            Task { @MainActor in await tools.shutdown(); exit(0) }
        }
        dispatchMain()
    }
}

@MainActor final class MCPTools {
    static let instructions = "Shotglass captures this Mac's screen natively. Coordinates are global points with the origin at the top left of the main display, the same space as list_displays and list_windows frames. Screenshots save a full-resolution file and return a downscaled preview; map preview pixels to points with the returned frame. Find windows with list_windows. Recordings are MP4 and stop on record_stop, after max_seconds, or when this server exits."
    static let definitions: [MCPTool] = {
        let number: [String: Any] = ["type": "number"]
        let target: [String: Any] = [
            "target": ["type": "string","enum": MCPCaptureTarget.names,"description": "What to capture. Inferred from rect, window_id or app when omitted; otherwise the main display."],
            "display_id": ["type": "integer","description": "Display from list_displays. Defaults to the main display."],
            "window_id": ["type": "integer","description": "Window from list_windows."],
            "app": ["type": "string","description": "Application name or bundle identifier (case-insensitive substring); picks its frontmost window."],
            "title": ["type": "string","description": "Window title substring, alone or with app."],
            "rect": ["type": "object","description": "Area in global points, origin top left of the main display.","properties": ["x": number,"y": number,"width": number,"height": number],"required": ["x","y","width","height"]]
        ]
        let preview: [String: Any] = [
            "include_image": ["type": "boolean","description": "Return a preview image to the agent. Default true."],
            "max_dimension": ["type": "integer","minimum": 64,"maximum": 8192,"description": "Long edge of the preview in pixels. Default 1568. The saved file keeps native pixels."],
            "image_format": ["type": "string","enum": ["jpeg","png"],"description": "Preview encoding. Default jpeg."],
            "save": ["type": "boolean","description": "Save the full-resolution capture to the Screenshots folder and Library. Default true."],
            "copy": ["type": "boolean","description": "Also put the capture on the clipboard. Default false."],
            "cursor": ["type": "boolean","description": "Include the pointer in window captures. Default false."],
            "shadow": ["type": "boolean","description": "Include the window shadow. Default false."]
        ]
        let path: [String: Any] = ["path": ["type": "string","description": "Absolute file path."]]
        return [
            MCPTool("list_displays","Connected displays with ids, frames in points, native pixel sizes and scale."),
            MCPTool("list_windows","On-screen application windows, front to back, with window_id, app, title and frame in points.",properties: [
                "app": ["type": "string","description": "Filter by application name or bundle identifier."],
                "title": ["type": "string","description": "Filter by window title substring."]
            ]),
            MCPTool("screenshot","Capture a display, window, area or the active window at native resolution. Saves a PNG/JPEG (per Settings) and returns its path, metadata and a downscaled preview.",properties: target.merging(preview) { a,_ in a }),
            MCPTool("ocr","Recognize text and QR/barcodes on screen (same targets as screenshot) or in an image file, with each line's frame. Frames are global points for screen targets and pixels for files.",properties: target.merging(path) { a,_ in a }),
            MCPTool("record_start","Start an MP4 screen recording of a display, window, area or the active window. Audio follows Shotglass Settings. Returns a recording_id.",properties: target.merging([
                "fps": ["type": "integer","minimum": 1,"maximum": 120,"description": "Frames per second. Default from Settings."],
                "cursor": ["type": "boolean","description": "Show the pointer. Default true."],
                "max_seconds": ["type": "number","minimum": 1,"maximum": 3600,"description": "Stop automatically after this many seconds. Default 300."]
            ]) { a,_ in a }),
            MCPTool("record_stop","Stop a recording and return its MP4 path and duration.",properties: ["recording_id": ["type": "string","description": "From record_start. Optional when only one recording exists."]]),
            MCPTool("upload","Upload an image file to Shotglass Cloud and return a short share link (expires after 30 days). Requires signing in under Settings → Shotglass Cloud.",properties: path.merging(["copy": ["type": "boolean","description": "Also copy the link to the clipboard. Default false."]]) { a,_ in a },required: ["path"]),
            MCPTool("open_in_editor","Open an image, recording or .shotglass.json project in the Shotglass editor for the user.",properties: path,required: ["path"])
        ]
    }()

    private let engine = CaptureEngine()
    private lazy var store = ClipStore()
    private var refreshed = -Double.infinity
    private var requestedScreen = false
    private struct Recording { let recorder: Recorder; let url: URL; let size: CGSize; let started: Date; var timeout: Task<Void,Never>? }
    private var recordings: [String: Recording] = [:]
    private var finished: [String: [String: Any]] = [:]

    func call(_ name: String,_ args: MCPArguments) async -> [String: Any] {
        do {
            switch name {
            case "list_displays": return MCP.toolResult([MCP.json(["displays": displays()])])
            case "list_windows": return try await listWindows(args)
            case "screenshot": return try await screenshot(args)
            case "ocr": return try await ocr(args)
            case "record_start": return try await recordStart(args)
            case "record_stop": return try await recordStop(args)
            case "upload": return try await upload(args)
            case "open_in_editor": return try await openInEditor(args)
            default: return MCP.toolError("Unknown tool \(name).")
            }
        } catch { return MCP.toolError(error.localizedDescription) }
    }
    func shutdown() async {
        for id in Array(recordings.keys) { _ = try? await finish(id,note: "Stopped because the MCP connection closed.") }
    }

    // MARK: Screen access
    private func requireScreen() throws {
        guard CGPreflightScreenCaptureAccess() else {
            // The request can block for the life of the system prompt; never hold a tool call on it.
            if !requestedScreen { requestedScreen = true; DispatchQueue.global(qos: .utility).async { _ = CGRequestScreenCaptureAccess() } }
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Shotglass"
            throw ShotError.message("\(name) needs Screen Recording permission. Ask the user to open System Settings → Privacy & Security → Screen & System Audio Recording, enable \(name) (\(Bundle.main.bundlePath)), then restart this MCP server.")
        }
    }
    /// Back-to-back tool calls share one WindowServer snapshot instead of re-enumerating every window.
    private func refresh(force: Bool = false) async throws {
        try requireScreen()
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now-refreshed > 0.25 else { return }
        try await engine.refresh(); refreshed = ProcessInfo.processInfo.systemUptime
    }
    /// CoreGraphics only: AppKit screen, workspace and open calls check a process in with LaunchServices, and a
    /// checked-in `--mcp` process would receive the user's shotglass:// launcher URLs instead of a capture session.
    private func displays() -> [[String: Any]] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0,nil,&count)
        var ids = [CGDirectDisplayID](repeating: 0,count: Int(count))
        CGGetActiveDisplayList(count,&ids,&count)
        return ids.prefix(Int(count)).map { id in
            let frame = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixels = mode.map { ($0.pixelWidth,$0.pixelHeight) } ?? (CGDisplayPixelsWide(id),CGDisplayPixelsHigh(id))
            return ["display_id": id,"main": CGDisplayIsMain(id) != 0,"built_in": CGDisplayIsBuiltin(id) != 0,"frame": json(frame),
                    "pixel_width": pixels.0,"pixel_height": pixels.1,"scale": frame.width > 0 ? Double(pixels.0)/frame.width : 1]
        }
    }
    private func json(_ r: CGRect) -> [String: Any] { ["x": r.minX,"y": r.minY,"width": r.width,"height": r.height] }
    private func describe(_ w: SCWindow) -> [String: Any] {
        ["window_id": w.windowID,"app": w.owningApplication?.applicationName ?? "","bundle_id": w.owningApplication?.bundleIdentifier ?? "",
         "pid": w.owningApplication?.processID ?? 0,"title": w.title ?? "","frame": json(w.frame)]
    }
    private func windows(app: String?,title: String?) -> [SCWindow] {
        engine.windows.filter { w in
            (app.map { MCPCaptureTarget.matches($0,name: w.owningApplication?.applicationName,bundle: w.owningApplication?.bundleIdentifier) } ?? true)
                && (title.map { (w.title ?? "").localizedCaseInsensitiveContains($0) } ?? true)
        }
    }
    private func listWindows(_ args: MCPArguments) async throws -> [String: Any] {
        try await refresh(force: true)
        return MCP.toolResult([MCP.json(["windows": windows(app: args.string("app"),title: args.string("title")).map(describe)])])
    }
    private func window(_ target: MCPCaptureTarget) throws -> SCWindow {
        switch target {
        case .activeWindow:
            // Quartz orders windows front to back; the first application window belongs to the active app.
            guard let w = engine.windows.first else { throw ShotError.message("No active window is on screen.") }
            return w
        case .window(let id,let app,let title):
            let match = windows(app: app,title: title).first { id == nil || $0.windowID == id }
            guard let match else { throw ShotError.message("No on-screen window matches. Call list_windows for current window ids.") }
            return match
        default: throw ShotError.message("Not a window target.")
        }
    }
    private func display(_ id: UInt32?) throws -> SCDisplay {
        let all = engine.content?.displays ?? []
        guard let d = id.map({ id in all.first { $0.displayID == id } }) ?? all.first(where: { $0.displayID == CGMainDisplayID() }) ?? all.first else {
            throw ShotError.message("No display with id \(id.map(String.init) ?? "main"). Call list_displays.")
        }
        return d
    }
    /// The native-pixel image and the frame it covers, in global top-left points.
    private func capture(_ target: MCPCaptureTarget,_ args: MCPArguments) async throws -> (image: CGImage,frame: CGRect,kind: String) {
        try await refresh()
        switch target {
        case .display(let id):
            let d = try display(id)
            return (try await engine.image(.display(d.displayID)),d.frame,"Screen")
        case .area(let rect):
            let cocoa = CaptureGeometry.quartz(rect,primaryHeight: NSScreen.primaryHeight)
            return (try await engine.image(.region(cocoa)),rect,"Area")
        case .window,.activeWindow:
            let w = try window(target)
            let image = try await ScreenshotPixels.capture(SCContentFilter(desktopIndependentWindow: w),cursor: args.bool("cursor",default: false),shadow: args.bool("shadow",default: false))
            return (image,w.frame,"Window")
        }
    }

    // MARK: Tools
    private func screenshot(_ args: MCPArguments) async throws -> [String: Any] {
        let target = try MCPCaptureTarget(args)
        let (image,frame,kind) = try await capture(target,args)
        let maxDimension = min(8192,max(64,args.int("max_dimension") ?? 1568))
        let png = args.string("image_format")?.lowercased() == "png"
        // Encode the preview while the full-resolution file is written.
        async let preview: Data? = args.bool("include_image",default: true) ? Task.detached(priority: .userInitiated) { try MCPImages.encode(image,maxDimension: maxDimension,png: png) }.value : nil
        var meta: [String: Any] = ["width": image.width,"height": image.height,"frame": json(frame),"scale": frame.width > 0 ? Double(image.width)/frame.width : 1]
        if args.bool("save",default: true) {
            meta["path"] = try await store.writeDetached(image: image,kind: kind,copyOverride: args.bool("copy",default: false)).path
        } else if args.bool("copy",default: false) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([NSImage(cgImage: image,size: .zero)])
        }
        var content = [[String: Any]]()
        if let data = try await preview {
            let size = ImageFit.size(width: image.width,height: image.height,maxDimension: maxDimension)
            meta["preview"] = ["width": size.width,"height": size.height]
            content.append(MCP.image(data,mimeType: png ? "image/png" : "image/jpeg"))
        }
        content.insert(MCP.json(meta),at: 0)
        return MCP.toolResult(content)
    }
    private func ocr(_ args: MCPArguments) async throws -> [String: Any] {
        let image: CGImage,frame: CGRect,space: String
        if let path = args.string("path") {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,nil),let loaded = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw ShotError.message("Cannot read an image at \(path).") }
            image = loaded; frame = CGRect(x: 0,y: 0,width: loaded.width,height: loaded.height); space = "image_pixels"
        } else {
            (image,frame,_) = try await capture(try MCPCaptureTarget(args),args); space = "screen_points"
        }
        let result = try await Task.detached(priority: .userInitiated) { try MCPImages.recognize(image) }.value
        func place(_ box: CGRect) -> [String: Any] { json(ImageFit.topLeft(box,in: frame).integral) }
        return MCP.toolResult([MCP.json([
            "text": result.lines.map(\.text).joined(separator: "\n"),"coordinate_space": space,
            "lines": result.lines.map { ["text": $0.text,"confidence": Double($0.confidence),"frame": place($0.box)] },
            "codes": result.codes.map { ["payload": $0.payload,"symbology": $0.symbology,"frame": place($0.box)] }
        ])])
    }
    private func recordStart(_ args: MCPArguments) async throws -> [String: Any] {
        let target = try MCPCaptureTarget(args)
        try await refresh(force: true)
        let captureTarget: CaptureTarget
        switch target {
        case .display(let id): captureTarget = .display(try display(id).displayID)
        case .area(let rect): captureTarget = .region(CaptureGeometry.quartz(rect,primaryHeight: NSScreen.primaryHeight))
        case .window,.activeWindow: captureTarget = .window(try window(target))
        }
        let p = Preferences.shared
        if p.microphone,!(await AVCaptureDevice.requestAccess(for: .audio)) { throw ShotError.message("Microphone access was denied. Enable it in System Settings or turn off microphone capture in Shotglass Settings.") }
        let (filter,config) = try engine.configuration(for: captureTarget,recording: true)
        config.showsCursor = args.bool("cursor",default: true)
        config.minimumFrameInterval = CMTime(value: 1,timescale: CMTimeScale(min(120,max(1,args.int("fps") ?? p.fps))))
        let folder = try p.saveToDisk ? p.captureFolder() : store.support.appendingPathComponent("Captures")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CaptureFiles.filename(extension: "mp4"))
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let recorder = Recorder()
        recorder.didFail = { [weak self] error in Task { @MainActor in _ = try? await self?.finish(id,note: "Recording stopped: \(error.localizedDescription)") } }
        try await recorder.start(filter: filter,configuration: config,url: url)
        let limit = min(3600,max(1,args.double("max_seconds") ?? 300))
        recordings[id] = Recording(recorder: recorder,url: url,size: CGSize(width: config.width,height: config.height),started: Date(),timeout: Task { [weak self] in
            do { try await Task.sleep(for: .seconds(limit)) } catch { return }
            _ = try? await self?.finish(id,note: "Stopped automatically after \(Int(limit)) seconds.")
        })
        return MCP.toolResult([MCP.json(["recording_id": id,"path": url.path,"width": config.width,"height": config.height,"max_seconds": limit])])
    }
    private func recordStop(_ args: MCPArguments) async throws -> [String: Any] {
        let ids = Set(recordings.keys).union(finished.keys)
        guard let id = args.string("recording_id") ?? (ids.count == 1 ? ids.first : nil) else {
            throw ShotError.message(ids.isEmpty ? "No recording is in progress." : "Pass recording_id; several recordings exist: \(ids.sorted().joined(separator: ", ")).")
        }
        if let done = finished.removeValue(forKey: id) { return MCP.toolResult([MCP.json(done)]) }
        guard recordings[id] != nil else { throw ShotError.message("Unknown recording_id \(id).") }
        let result = try await finish(id,note: nil)
        finished[id] = nil
        return MCP.toolResult([MCP.json(result)])
    }
    @discardableResult private func finish(_ id: String,note: String?) async throws -> [String: Any] {
        guard let recording = recordings.removeValue(forKey: id) else { return finished[id] ?? [:] }
        recording.timeout?.cancel()
        var result: [String: Any] = ["recording_id": id,"path": recording.url.path,"width": Int(recording.size.width),"height": Int(recording.size.height)]
        if let note { result["note"] = note }
        do {
            try await recording.recorder.stop()
            if Preferences.shared.microphone { try? await VideoTools.mixAudio(recording.url) }
            result["duration_seconds"] = (try? await AVURLAsset(url: recording.url).load(.duration).seconds) ?? Date().timeIntervalSince(recording.started)
            result["bytes"] = (try? FileManager.default.attributesOfItem(atPath: recording.url.path)[.size] as? Int) ?? 0
            store.add(Clip(path: recording.url.path,kind: "Recording",width: Int(recording.size.width),height: Int(recording.size.height)))
        } catch {
            result["error"] = error.localizedDescription
            finished[id] = result
            throw error
        }
        finished[id] = result
        return result
    }
    private func upload(_ args: MCPArguments) async throws -> [String: Any] {
        guard CloudSession.isAvailable else { throw ShotError.message("Shotglass Cloud is not available in this edition.") }
        guard let path = args.string("path") else { throw ShotError.message("Pass the absolute path of an image.") }
        guard CloudSession.shared.isSignedIn else { throw ShotError.message("Not signed in. Ask the user to sign in under Shotglass Settings → Shotglass Cloud.") }
        let url = URL(fileURLWithPath: path)
        let image = try await Task.detached(priority: .userInitiated) { try UploadableImage.load(from: url) }.value
        let shot = try await CloudSession.shared.upload(image)
        if args.bool("copy",default: false),let link = ShareLink.validated(shot.shareURL) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString,forType: .string)
        }
        return MCP.toolResult([MCP.json(["share_url": shot.shareURL,"expires_at": ISO8601DateFormatter().string(from: shot.expiresAt)])])
    }
    /// The editor is UI, so it opens in a normal Shotglass session rather than in this headless process.
    private func openInEditor(_ args: MCPArguments) async throws -> [String: Any] {
        guard let path = args.string("path"),path.hasPrefix("/"),FileManager.default.isReadableFile(atPath: path) else { throw ShotError.message("Pass the absolute path of a readable file.") }
        guard let url = LaunchAction.editURL(path: path) else { throw ShotError.message("Invalid path.") }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = ["-a",Bundle.main.bundlePath,url.absoluteString]
        try open.run()
        await withCheckedContinuation { done in DispatchQueue.global().async { open.waitUntilExit(); done.resume() } }
        guard open.terminationStatus == 0 else { throw ShotError.message("Could not open Shotglass.") }
        return MCP.toolResult([MCP.text("Opened \(path) in the Shotglass editor.")])
    }
}

enum MCPImages {
    /// One resample and one encode. JPEG drops alpha; PNG keeps it.
    static func encode(_ image: CGImage,maxDimension: Int,png: Bool) throws -> Data {
        let size = ImageFit.size(width: image.width,height: image.height,maxDimension: maxDimension)
        var output = image
        if size.width != image.width || size.height != image.height || !png {
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let alpha = png ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
            guard let context = CGContext(data: nil,width: size.width,height: size.height,bitsPerComponent: 8,bytesPerRow: 0,space: space,bitmapInfo: alpha.rawValue) else { throw ShotError.message("Cannot resize screenshot.") }
            if !png { context.setFillColor(CGColor(gray: 1,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: size.width,height: size.height)) }
            context.interpolationQuality = .high
            context.draw(image,in: CGRect(x: 0,y: 0,width: size.width,height: size.height))
            guard let resized = context.makeImage() else { throw ShotError.message("Cannot resize screenshot.") }
            output = resized
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,(png ? UTType.png : UTType.jpeg).identifier as CFString,1,nil) else { throw ShotError.message("Cannot encode screenshot.") }
        CGImageDestinationAddImage(destination,output,png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShotError.message("Cannot encode screenshot.") }
        return data as Data
    }
    struct Recognized: Sendable {
        var lines: [(text: String,confidence: Float,box: CGRect)] = []
        var codes: [(payload: String,symbology: String,box: CGRect)] = []
    }
    static func recognize(_ image: CGImage) throws -> Recognized {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate; text.usesLanguageCorrection = true; text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image,options: [:]).perform([text,codes])
        var result = Recognized()
        result.lines = text.results?.compactMap { o in o.topCandidates(1).first.map { ($0.string,$0.confidence,o.boundingBox) } } ?? []
        result.codes = codes.results?.compactMap { o in o.payloadStringValue.map { ($0,o.symbology.rawValue,o.boundingBox) } } ?? []
        return result
    }
}
