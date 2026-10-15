import AppKit
import SwiftUI
import EasyshotCore

let accent = Color(red: 0.64, green: 0.53, blue: 1)
let canvasColor = Color(red: 0.075, green: 0.078, blue: 0.095)

struct SavedRegion: Codable {
    var x: Double; var y: Double; var width: Double; var height: Double
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    var rect: CGRect { CGRect(x: x,y: y,width: width,height: height) }
}

struct RegionPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var region: SavedRegion
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    @Published var folder: String { didSet { save() } }
    @Published var copyToClipboard: Bool { didSet { save() } }
    @Published var saveToDisk: Bool { didSet { save() } }
    @Published var format: String { didSet { save() } }
    @Published var showPreview: Bool { didSet { save() } }
    @Published var snapOnDraw: Bool { didSet { save() } }
    @Published var windowShadow: Bool { didSet { save() } }
    @Published var captureCursor: Bool { didSet { save() } }
    @Published var delay: Double { didSet { save() } }
    @Published var systemAudio: Bool { didSet { save() } }
    @Published var microphone: Bool { didSet { save() } }
    @Published var fps: Int { didSet { save() } }
    @Published var recordCursor: Bool { didSet { save() } }
    @Published var recordCamera: Bool { didSet { save() } }
    @Published var showClicks: Bool { didSet { save() } }
    @Published var showKeys: Bool { didSet { save() } }
    @Published var studio: Bool { didSet { save() } }
    @Published var hideDesktopIcons: Bool { didSet { save() } }
    @Published var lastRegion: SavedRegion? { didSet { save() } }
    @Published var presets: [RegionPreset] { didSet { save() } }
    @Published var selection: CaptureSelection { didSet { save() } }
    @Published var uploadKey: String { didSet { save() } }
    @Published var cloudBaseURL: String { didSet { save() } }

    let defaults: UserDefaults
    private let folderAccess: CaptureFolderAccess
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folderAccess = CaptureFolderAccess(defaults: defaults)
        let d = defaults
        folder = d.string(forKey: "folder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Screenshots").path
        copyToClipboard = d.object(forKey: "copy") as? Bool ?? true
        saveToDisk = d.object(forKey: "save") as? Bool ?? true
        format = d.string(forKey: "format") ?? "png"
        showPreview = d.object(forKey: "preview") as? Bool ?? false
        snapOnDraw = d.bool(forKey: "snapOnDraw")
        windowShadow = d.object(forKey: "shadow") as? Bool ?? true
        captureCursor = d.bool(forKey: "cursor")
        delay = d.double(forKey: "delay")
        systemAudio = d.object(forKey: "audio") as? Bool ?? true
        microphone = d.bool(forKey: "microphone")
        fps = d.object(forKey: "fps") as? Int ?? 30
        recordCursor = d.object(forKey: "recordCursor") as? Bool ?? true
        recordCamera = d.bool(forKey: "recordCamera")
        showClicks = d.object(forKey: "showClicks") as? Bool ?? true
        showKeys = Distribution.isAppStore ? false : d.bool(forKey: "showKeys")
        studio = d.bool(forKey: "studio")
        hideDesktopIcons = d.bool(forKey: "hideDesktopIcons")
        lastRegion = d.data(forKey: "region").flatMap { try? JSONDecoder().decode(SavedRegion.self,from: $0) }
        presets = d.data(forKey: "presets").flatMap { try? JSONDecoder().decode([RegionPreset].self,from: $0) } ?? []
        selection = d.data(forKey: "captureSelection").flatMap { try? JSONDecoder().decode(CaptureSelection.self,from: $0) } ?? CaptureSelection()
        uploadKey = CaptureKeyAction.sanitizedUploadKey(d.string(forKey: "uploadKey") ?? "")
        cloudBaseURL = d.string(forKey: "cloudBaseURL") ?? Bundle.main.object(forInfoDictionaryKey: "EasyshotCloudURL") as? String ?? "http://localhost:8080"
    }
    /// Only http(s) server addresses are accepted; plain http is for local development.
    static func validatedServerURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed),let scheme = url.scheme?.lowercased(),scheme == "https" || scheme == "http",url.host != nil else { return nil }
        return url
    }
    func save() {
        let d = defaults
        d.set(folder,forKey: "folder"); d.set(copyToClipboard,forKey: "copy"); d.set(saveToDisk,forKey: "save")
        d.set(format,forKey: "format"); d.set(showPreview,forKey: "preview"); d.set(snapOnDraw,forKey: "snapOnDraw")
        d.set(windowShadow,forKey: "shadow"); d.set(captureCursor,forKey: "cursor"); d.set(delay,forKey: "delay")
        d.set(systemAudio,forKey: "audio"); d.set(microphone,forKey: "microphone"); d.set(fps,forKey: "fps")
        d.set(recordCursor,forKey: "recordCursor"); d.set(recordCamera,forKey: "recordCamera")
        d.set(showClicks,forKey: "showClicks"); d.set(showKeys,forKey: "showKeys"); d.set(studio,forKey: "studio"); d.set(hideDesktopIcons,forKey: "hideDesktopIcons")
        d.set(try? JSONEncoder().encode(lastRegion),forKey: "region")
        d.set(try? JSONEncoder().encode(presets),forKey: "presets")
        d.set(try? JSONEncoder().encode(selection),forKey: "captureSelection")
        d.set(uploadKey,forKey: "uploadKey"); d.set(cloudBaseURL,forKey: "cloudBaseURL")
    }
    var folderURL: URL {
        folderAccess.restore() ?? URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }
    var hasCaptureFolderPermission: Bool { !Distribution.isAppStore || folderAccess.restore() != nil }
    var folderDescription: String { hasCaptureFolderPermission ? folderURL.path : "Choose a screenshots folder" }
    func restoreCaptureFolderAccess() { _ = folderAccess.restore() }
    @discardableResult func chooseCaptureFolder() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose a screenshots folder"
        panel.message = "Choose Documents/Screenshots or another folder. Easyshot will remember your choice."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if hasCaptureFolderPermission { panel.directoryURL = folderURL }
        guard panel.runModal() == .OK,let url = panel.url else { return false }
        try folderAccess.select(url)
        folder = url.path
        return true
    }
    func captureFolder() throws -> URL {
        #if APP_STORE
        if let url = folderAccess.restore() { return url }
        guard try chooseCaptureFolder(),let url = folderAccess.restore() else {
            throw ShotError.message("Capture cancelled. Choose a screenshots folder in Settings to save files.")
        }
        return url
        #else
        return folderURL
        #endif
    }
}

struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var date: Date = Date()
    var kind: String
    var width: Int
    var height: Int
    var text: String?
    var url: URL { URL(fileURLWithPath: path) }
    var isVideo: Bool { url.pathExtension.lowercased() == "mp4" || url.pathExtension.lowercased() == "mov" }
    var image: NSImage? { isVideo ? nil : NSImage(contentsOf: url) }
}

@MainActor final class ClipStore: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var error: String?
    let support: URL
    init(directory: URL? = nil) {
        if Distribution.isAppStore { Preferences.shared.restoreCaptureFolderAccess() }
        support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("Easyshot",isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: support,withIntermediateDirectories: true)
            let file = support.appendingPathComponent("history.json")
            if FileManager.default.fileExists(atPath: file.path) { clips = try JSONDecoder().decode([Clip].self,from: Data(contentsOf: file)) }
        } catch { self.error = "Could not load capture history: \(error.localizedDescription)" }
        applyRetention()
    }
    func persist() {
        do { try JSONEncoder().encode(clips).write(to: support.appendingPathComponent("history.json"),options: .atomic) }
        catch { self.error = "Could not save capture history: \(error.localizedDescription)" }
    }
    func add(_ clip: Clip) { clips.insert(clip,at: 0); persist() }
    func update(_ clip: Clip) { if let i = clips.firstIndex(where: { $0.id == clip.id }) { clips[i] = clip; persist() } }
    func removeFromHistory(_ clip: Clip) { clips.removeAll { $0.id == clip.id }; persist() }
    nonisolated static func encode(_ image: CGImage,as ext: String) throws -> Data {
        if ext == "jpg" {
            guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg,properties: [.compressionFactor: 0.95]) else { throw ShotError.message("Unable to encode screenshot.") }
            return jpeg
        }
        return try ScreenshotPixels.png(image)
    }
    /// Same result as `write`, but PNG/JPEG encoding and the disk write run off the main thread so a
    /// Retina capture never freezes the UI or delays the clipboard.
    func writeDetached(image: CGImage,kind: String,copyOverride: Bool? = nil) async throws -> Clip {
        let p = Preferences.shared
        let ext = p.format
        let folder = try p.saveToDisk ? p.captureFolder() : support.appendingPathComponent("Captures",isDirectory: true)
        let url = folder.appendingPathComponent(CaptureFiles.filename(extension: ext))
        let data = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let data = try Self.encode(image,as: ext)
            try data.write(to: url,options: .atomic)
            return data
        }.value
        let clip = Clip(path: url.path,kind: kind,width: image.width,height: image.height)
        add(clip)
        if copyOverride ?? p.copyToClipboard { copy(clip,image: NSImage(cgImage: image,size: .zero),encodedPNG: ext == "png" ? data : nil) }
        return clip
    }
    func write(image: CGImage,kind: String,destination: URL? = nil,copyOverride: Bool? = nil) throws -> Clip {
        let p = Preferences.shared
        let ext = p.format
        let folder = try destination ?? (p.saveToDisk ? p.captureFolder() : support.appendingPathComponent("Captures",isDirectory: true))
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CaptureFiles.filename(extension: ext))
        let data = try Self.encode(image,as: ext)
        try data.write(to: url,options: .atomic)
        let clip = Clip(path: url.path,kind: kind,width: image.width,height: image.height)
        add(clip)
        if copyOverride ?? p.copyToClipboard { copy(clip,image: NSImage(cgImage: image,size: .zero),encodedPNG: ext == "png" ? data : nil) }
        return clip
    }
    func copy(_ clip: Clip,image suppliedImage: NSImage? = nil,encodedPNG: Data? = nil) {
        NSPasteboard.general.clearContents()
        if clip.url.pathExtension.lowercased() == "gif" {
            NSPasteboard.general.writeObjects([clip.url as NSURL])
            if let data = try? Data(contentsOf: clip.url) { NSPasteboard.general.setData(data,forType: NSPasteboard.PasteboardType("com.compuserve.gif")) }
        } else if let image = suppliedImage ?? clip.image {
            NSPasteboard.general.writeObjects([image,clip.url as NSURL])
            // A default PNG capture is already encoded. Reuse its bytes instead of decoding
            // the saved file and doing a second full-size PNG compression on the main thread.
            if let data = encodedPNG ?? (clip.url.pathExtension.lowercased() == "png" ? try? Data(contentsOf: clip.url,options: .mappedIfSafe) : nil) {
                NSPasteboard.general.setData(data,forType: .png)
            } else if let cg = image.cgImage(forProposedRect: nil,context: nil,hints: nil),let data = NSBitmapImageRep(cgImage: cg).representation(using: .png,properties: [:]) {
                NSPasteboard.general.setData(data,forType: .png)
            }
        } else { NSPasteboard.general.writeObjects([clip.url as NSURL]) }
    }
}

enum ShotError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let s): return s } }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID() }
    static var pointerScreen: NSScreen { screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens[0] }
    /// The menu-bar screen is CoreGraphics' main display. Reading it there avoids building AppKit's screen list,
    /// which also registers a headless `--mcp` process with LaunchServices.
    static var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }
}
