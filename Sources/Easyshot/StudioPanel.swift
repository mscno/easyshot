import AppKit
import SwiftUI
import AVKit
import EasyshotCore

/// Editing state for a Studio recording. Preview and export share one renderer type,
/// so what plays in the editor is what the exported MP4 contains.
@MainActor final class StudioModel: ObservableObject {
    let clip: Clip
    let track: CursorTrack
    @Published var plan: StudioPlan { didSet { if plan != oldValue { schedule() } } }
    @Published var progress: Double?
    @Published var duration = 0.0
    private var renderer: StudioRenderer?
    private var composition: AVMutableVideoComposition?
    private weak var player: AVPlayer?
    private var asset: AVURLAsset?
    private var videoSize = CGSize.zero
    private var pending: Task<Void,Never>?
    private let saved: Bool

    init?(clip: Clip) {
        guard clip.isVideo, let track = StudioExporter.loadTrack(for: clip.url) else { return nil }
        self.clip = clip; self.track = track
        let plan = StudioExporter.loadPlan(for: clip.url)
        self.plan = plan ?? StudioPlan(); saved = plan != nil
    }
    /// Builds a preview player whose frames run through the Studio renderer.
    func makePlayer() async throws -> AVPlayer {
        let asset = AVURLAsset(url: clip.url)
        duration = try await asset.load(.duration).seconds
        if plan.autoZoom && !saved { plan.segments = StudioPlanner.segments(for: track, duration: duration, zoom: plan.zoom, transition: plan.transition) }
        let size = try await StudioExporter.videoSize(asset)
        self.asset = asset; videoSize = size
        let renderer = StudioRenderer(track: track, plan: plan, duration: duration, video: size, canvas: previewCanvas(plan))
        let composition = try await StudioExporter.composition(asset: asset, renderer: renderer)
        let item = AVPlayerItem(asset: asset); item.videoComposition = composition
        let player = AVPlayer(playerItem: item)
        self.renderer = renderer; self.composition = composition; self.player = player
        return player
    }
    /// Preview at most 1440 px on the long side; padding and radii are relative, so it matches export.
    private func previewCanvas(_ plan: StudioPlan) -> CGSize {
        let framed = StudioPlan.viewport(source: videoSize, aspect: plan.aspect)
        let factor = min(1, 1440/max(framed.width, framed.height, 1))
        return CGSize(width: max(2, (framed.width*factor/2).rounded()*2), height: max(2, (framed.height*factor/2).rounded()*2))
    }
    /// A new output aspect changes the frame size, so the preview needs a new composition.
    private func rebuild() {
        guard let asset, let player else { return }
        let plan = self.plan, time = player.currentTime()
        pending = Task { [weak self] in
            guard let self else { return }
            let renderer = StudioRenderer(track: track, plan: plan, duration: duration, video: videoSize, canvas: previewCanvas(plan))
            guard let composition = try? await StudioExporter.composition(asset: asset, renderer: renderer), !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: asset); item.videoComposition = composition
            player.replaceCurrentItem(with: item)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            self.renderer = renderer; self.composition = composition
            StudioExporter.savePlan(plan, for: clip.url)
        }
    }
    private func schedule() {
        pending?.cancel()
        if let renderer, renderer.plan.aspect != plan.aspect { rebuild(); return }
        let plan = self.plan, duration = self.duration, renderer = self.renderer
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let renderer else { return }
            await Task.detached(priority: .userInitiated) { renderer.update(plan: plan, duration: duration) }.value
            guard !Task.isCancelled, let self else { return }
            // A paused player keeps its last frame; reassigning the composition redraws it.
            if let player = self.player, player.rate == 0, let composition = self.composition { player.currentItem?.videoComposition = composition.mutableCopy() as? AVVideoComposition }
            StudioExporter.savePlan(plan, for: self.clip.url)
        }
    }
    func setAutoZoom(_ on: Bool) {
        plan.autoZoom = on
        plan.segments = on ? StudioPlanner.segments(for: track, duration: duration, zoom: plan.zoom, transition: plan.transition) : []
    }
    func setZoom(_ zoom: Double) {
        plan.zoom = zoom
        for i in plan.segments.indices { plan.segments[i].scale = zoom }
    }
    func addSegment(_ start: Double, _ end: Double) {
        let segment = ZoomSegment(start: max(0, min(start, end)), end: min(duration, max(start, end)), scale: plan.zoom)
        guard segment.end-segment.start >= 0.5 else { return }
        plan.segments.removeAll { $0.start < segment.end && segment.start < $0.end }
        plan.segments.append(segment); plan.segments.sort { $0.start < $1.start }
    }
    func export(range: ClosedRange<Double>, controller: AppController) async throws -> Clip {
        progress = 0; controller.pendingExports += 1
        defer { progress = nil; controller.pendingExports -= 1; controller.finishIfIdle() }
        StudioExporter.savePlan(plan, for: clip.url)
        let folder = try Preferences.shared.saveToDisk ? Preferences.shared.captureFolder() : controller.store.support.appendingPathComponent("Captures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CaptureFiles.filename(extension: "mp4"))
        try await StudioExporter.export(video: clip.url, track: track, plan: plan, to: url, range: range) { value in
            Task { @MainActor in if self.progress != nil { self.progress = value } }
        }
        let size = plan.canvasSize(for: CGSize(width: clip.width, height: clip.height))
        return Clip(path: url.path, kind: "Studio", width: Int(size.width), height: Int(size.height))
    }
}

struct StudioSidebar: View {
    @ObservedObject var model: StudioModel
    var exportAction: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Studio", systemImage: "sparkles.rectangle.stack").font(.system(size: 13, weight: .semibold))
                group("Zoom") {
                    Toggle("Auto-zoom on clicks and typing", isOn: Binding(get: { model.plan.autoZoom }, set: { model.setAutoZoom($0) }))
                    slider("Level", Binding(get: { model.plan.zoom }, set: { model.setZoom($0) }), 1.2...3, "%.1f×")
                    Toggle("Motion blur", isOn: $model.plan.motionBlur)
                    if model.plan.motionBlur { slider("Blur strength", $model.plan.motionBlurAmount, 0.1...1, "%.0f%%", percent: true) }
                }
                group("Cursor") {
                    Toggle("Show cursor", isOn: $model.plan.showCursor)
                    Picker("Style", selection: $model.plan.cursorStyle) { ForEach(StudioCursorStyle.allCases, id: \.self) { Text($0.title).tag($0) } }
                    slider("Size", $model.plan.cursorScale, 1...3, "%.1f×")
                    slider("Smoothing", $model.plan.smoothing, 0...1, "%.2f")
                }
                group("Background") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                        swatch(.none) { RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.4)).overlay(Image(systemName: "nosign").font(.system(size: 11))) }
                        ForEach(0..<Backdrops.count, id: \.self) { i in
                            swatch(.gradient(i)) { Image(nsImage: Backdrops.thumbnail(i)).resizable().clipShape(RoundedRectangle(cornerRadius: 6)) }
                        }
                        Button { if let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) { model.plan.background = .image(url.path) } } label: {
                            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)).overlay(Image(systemName: "photo").font(.system(size: 11)))
                        }.buttonStyle(.plain).frame(width: 28, height: 28).help("Current desktop wallpaper")
                        Button { chooseImage() } label: {
                            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)).overlay(Image(systemName: "plus").font(.system(size: 11)))
                        }.buttonStyle(.plain).frame(width: 28, height: 28).help("Choose an image…")
                    }
                    if model.plan.background != .none {
                        slider("Padding", $model.plan.padding, 0...0.16, "%.2f")
                        slider("Corners", $model.plan.cornerRadius, 0...0.06, "%.3f")
                        Toggle("Shadow", isOn: $model.plan.shadow)
                    }
                }
                group("Export") {
                    Picker("Frame", selection: $model.plan.aspect) { ForEach(StudioAspect.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    if model.plan.aspect != .source { Text("Crops to this shape and follows the zoom and cursor.").foregroundStyle(.secondary) }
                    Picker("Size", selection: $model.plan.output) { ForEach(StudioOutput.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker("Codec", selection: $model.plan.hevc) { Text("H.264").tag(false); Text("HEVC").tag(true) }
                    if let progress = model.progress { ProgressView(value: progress).controlSize(.small) }
                    Button { exportAction() } label: { Label("Export Studio MP4", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).tint(accent).disabled(model.progress != nil)
                }
            }.padding(16)
        }.frame(width: 250).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
            .font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
    }
    func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary); content() }
    }
    func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(String(format: format, value.wrappedValue*(percent ? 100 : 1))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }
    func swatch<L: View>(_ background: StudioBackground, @ViewBuilder label: () -> L) -> some View {
        Button { model.plan.background = background } label: { label() }.buttonStyle(.plain).frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(accent, lineWidth: model.plan.background == background ? 2 : 0).padding(-2))
    }
    static func color(_ c: CIColor) -> Color { Color(red: c.red, green: c.green, blue: c.blue) }
    func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.plan.background = .image(url.path) }
    }
}

/// Zoom segments over the recording. Click a segment to remove it; drag across the
/// strip to add one; click empty space to seek.
struct StudioTimelineStrip: View {
    @ObservedObject var model: StudioModel
    var playhead: Double
    var seek: (Double) -> Void
    @State private var drag: (Double, Double)?
    var body: some View {
        GeometryReader { geo in
            let d = max(model.duration, 0.001), w = geo.size.width
            let x: (Double) -> CGFloat = { CGFloat($0/d)*w }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06))
                ForEach(Array(model.track.clicks.enumerated()), id: \.offset) { _, click in
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 8).offset(x: x(click.t), y: geo.size.height-10)
                }
                ForEach(model.plan.segments) { segment in
                    RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.55))
                        .overlay(Text(String(format: "%.1f×", segment.scale)).font(.system(size: 9, weight: .semibold)).lineLimit(1))
                        .frame(width: max(4, x(segment.end)-x(segment.start)), height: geo.size.height-8)
                        .offset(x: x(segment.start), y: 4)
                        .onTapGesture { model.plan.segments.removeAll { $0.id == segment.id } }
                        .help("Zoom \(String(format: "%.1f", segment.scale))× · click to remove")
                }
                if let drag {
                    RoundedRectangle(cornerRadius: 5).stroke(accent, style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: abs(x(drag.1)-x(drag.0)), height: geo.size.height-8).offset(x: x(min(drag.0, drag.1)), y: 4)
                }
                Rectangle().fill(.white).frame(width: 2, height: geo.size.height).offset(x: x(playhead)-1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let a = Double(value.startLocation.x/w)*d, b = Double(min(max(0, value.location.x), w)/w)*d
                drag = abs(value.translation.width) > 4 ? (a, b) : nil
            }.onEnded { value in
                if let drag { model.addSegment(drag.0, drag.1) } else { seek(Double(value.location.x/w)*d) }
                drag = nil
            })
        }.frame(height: 34).help("Drag to add a zoom · click a zoom to remove it")
    }
}
