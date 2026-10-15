import AppKit
import SwiftUI
import ScreenCaptureKit
import ImageIO
import EasyshotCore

/// The floating recording pill: timer, pause/resume and stop. Easyshot's own windows are excluded
/// from display and area recordings, and window recordings capture only the chosen window,
/// so the pill never appears in the video.
struct RecordingPill: View {
    @ObservedObject var controller: AppController
    var body: some View {
        let paused = controller.recordingPaused
        HStack(spacing: 12) {
            Circle().fill(paused ? .orange : .red).frame(width: 7,height: 7)
            Text(controller.timeString).font(.system(size: 14,weight: .medium,design: .monospaced))
            if paused { Text("Paused").font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            Button { controller.togglePause() } label: { Image(systemName: paused ? "play.fill" : "pause.fill").frame(width: 16) }
                .buttonStyle(.glass).help(paused ? "Resume recording" : "Pause recording")
            Button { Task { await controller.stopRecording() } } label: { Label("Stop",systemImage: "stop.fill").font(.system(size: 12,weight: .semibold)) }
                .buttonStyle(.glassProminent).tint(.red)
        }.padding(14).glassEffect(.regular,in: Capsule()).preferredColorScheme(.dark)
    }
}

extension AppController {
    func togglePause() {
        guard recording,let recorder else { return }
        recordingPaused.toggle(); recorder.setPaused(recordingPaused)
        status = recordingPaused ? "Recording paused" : "Recording…"
    }
    /// Adds a finished recording to history, or with "Record as GIF" converts it and keeps only the GIF.
    func deliverRecording(_ clip: Clip) async {
        let p = Preferences.shared
        guard p.recordAsGIF else { store.add(clip); if p.copyToClipboard { store.copy(clip) }; showPreview(clip); return }
        do {
            let folder = try p.saveToDisk ? p.captureFolder() : store.support.appendingPathComponent("Captures")
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(CaptureFiles.filename(extension: "gif"))
            try await VideoTools.gif(clip.url,to: url)
            let properties = CGImageSourceCreateWithURL(url as CFURL,nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0,0,nil) as? [CFString: Any] }
            let gif = Clip(path: url.path,kind: "GIF",width: properties?[kCGImagePropertyPixelWidth] as? Int ?? clip.width,height: properties?[kCGImagePropertyPixelHeight] as? Int ?? clip.height)
            store.add(gif); if p.copyToClipboard { store.copy(gif) }; showPreview(gif)
            for file in [clip.url,CursorTrack.sidecarURL(for: clip.url),CursorTrack.planURL(for: clip.url)] { try? FileManager.default.removeItem(at: file) }
        } catch {
            store.add(clip); showPreview(clip)
            store.error = "GIF export failed: \(error.localizedDescription) The MP4 recording was kept."
        }
    }
}

extension CaptureEngine {
    /// With "Clean desktop", display and area recordings hide desktop icons and can replace the wallpaper
    /// with a solid color. Finder windows and the Dock stay visible; only desktop-level windows are removed.
    func recordingFilter(for target: CaptureTarget,default filter: SCContentFilter,configuration: SCStreamConfiguration) -> SCContentFilter {
        let p = Preferences.shared
        guard p.cleanDesktop,let content else { return filter }
        let display: SCDisplay?
        switch target {
        case .window: return filter
        case .display(let id): display = content.displays.first { $0.displayID == id }
        case .region(let rect):
            let quartz = CaptureGeometry.quartz(rect,primaryHeight: NSScreen.primaryHeight)
            func area(_ d: SCDisplay) -> CGFloat { let r = d.frame.intersection(quartz); return r.isNull ? 0 : r.width*r.height }
            display = content.displays.max { area($0) < area($1) }
        }
        guard let display else { return filter }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier || $0.processID == ProcessInfo.processInfo.processIdentifier }
        var hidden: Set<String> = ["com.apple.finder"]
        if p.replaceWallpaper {
            hidden.formUnion(["com.apple.dock","com.apple.wallpaper.agent","com.apple.WallpaperAgent"])
            let c = p.wallpaperColor
            configuration.backgroundColor = CGColor(srgbRed: c[0],green: c[1],blue: c[2],alpha: 1)
        }
        let apps = content.applications.filter { hidden.contains($0.bundleIdentifier) }
        let pids = Set(apps.map(\.processID))
        let exceptions = content.windows.filter { window in window.windowLayer >= 0 && window.owningApplication.map { pids.contains($0.processID) } == true }
        return SCContentFilter(display: display,excludingApplications: own+apps,exceptingWindows: exceptions)
    }
}
