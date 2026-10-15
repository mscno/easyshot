import AppKit
import SwiftUI
import AVFoundation
import EasyshotCore

/// Post-capture cards: one nonactivating Liquid Glass panel per capture, stacked in the corner of the capture's
/// display. Cards keep the on-demand session alive; the app exits once the last card, editor and pin are gone.
@MainActor final class QuickAccess {
    static let cardSize = CGSize(width: 268,height: 210)
    static let lastClosedKey = "quickAccessLastClosed"
    unowned let controller: AppController
    private(set) var stack = QuickAccessStack<UUID>()
    private var panels: [UUID: NSPanel] = [:]
    private var clips: [UUID: Clip] = [:]
    private var visibleFrames: [UUID: CGRect] = [:]
    private var timer: Timer?
    private var modal = false
    init(controller: AppController) { self.controller = controller }
    var isActive: Bool { !stack.isEmpty }
    var cardCount: Int { stack.cards.count }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func syncAutoClose() {
        let seconds = Preferences.shared.quickAccessAutoClose
        let value: TimeInterval? = seconds > 0 ? TimeInterval(seconds) : nil
        if stack.autoClose != value { stack.setAutoClose(value,now: now) }
    }

    func show(_ clip: Clip,on screen: NSScreen) {
        syncAutoClose()
        clips[clip.id] = clip; visibleFrames[clip.id] = screen.visibleFrame
        for old in stack.add(clip.id,now: now) { removePanel(old,animated: true) }
        let panel = panels[clip.id] ?? makePanel(clip)
        if panels[clip.id] == nil {
            // Slide in from the screen edge, like the native screenshot thumbnail.
            panels[clip.id] = panel
            let target = frames()[clip.id] ?? .zero
            panel.setFrame(target.offsetBy(dx: target.width+40,dy: 0),display: false); panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        layout(animated: true); schedule()
    }
    func update(_ clip: Clip) { if clips[clip.id] != nil { clips[clip.id] = clip } }
    func close(_ id: UUID,animated: Bool = true) {
        guard stack.cards.contains(id) else { return }
        stack.close(id)
        UserDefaults.standard.set(id.uuidString,forKey: Self.lastClosedKey)
        removePanel(id,animated: animated)
        layout(animated: true); schedule()
        if stack.isEmpty { controller.finishIfIdle() }
    }
    func closeAll() { for id in stack.cards { close(id,animated: false) } }
    /// Reopens the most recently closed card, including one closed by an earlier Easyshot session.
    @discardableResult func restore() -> Bool {
        if let id = stack.recentlyClosed.last,let clip = clips[id] { show(clip,on: screen(for: visibleFrames[id])); return true }
        guard let raw = UserDefaults.standard.string(forKey: Self.lastClosedKey),let id = UUID(uuidString: raw),
              !stack.cards.contains(id),let clip = controller.store.clips.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: clip.path) else { return false }
        show(clip,on: .pointerScreen); return true
    }
    func setHovered(_ hovered: Bool) {
        guard !modal else { return }
        stack.setHovered(hovered,now: now); schedule()
    }

    private func screen(for frame: CGRect?) -> NSScreen { NSScreen.screens.first { $0.visibleFrame == frame } ?? .pointerScreen }
    /// Newest card nearest the corner, per display.
    private func frames() -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        let groups = Dictionary(grouping: stack.cards.reversed()) { visibleFrames[$0] ?? NSScreen.pointerScreen.visibleFrame }
        for (visible,ids) in groups {
            for (id,frame) in zip(ids,QuickAccessStack<UUID>.frames(count: ids.count,size: Self.cardSize,in: visible)) { result[id] = frame }
        }
        return result
    }
    private func layout(animated: Bool) {
        let targets = frames()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !reduceMotion ? 0.2 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (id,frame) in targets { panels[id]?.animator().setFrame(frame,display: true); panels[id]?.animator().alphaValue = 1 }
        }
    }
    private func removePanel(_ id: UUID,animated: Bool) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        guard animated,!reduceMotion else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = QuickPreviewLifetime.slideOutSeconds
            panel.animator().setFrame(panel.frame.offsetBy(dx: panel.frame.width+40,dy: 0),display: true); panel.animator().alphaValue = 0
        } completionHandler: { panel.orderOut(nil) }
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard let deadline = stack.nextDeadline else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.05,deadline-now),repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for id in self.stack.expired(now: self.now) { self.close(id) }
                self.schedule()
            }
        }
    }
    private func makePanel(_ clip: Clip) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero,size: Self.cardSize),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        let host = SwipeHostingView(rootView: QuickAccessCard(clip: clip,cloud: CloudSession.isAvailable,perform: { [weak self] action in self?.perform(action,clip.id) },hover: { [weak self] in self?.setHovered($0) }))
        host.onSwipe = { [weak self] in self?.close(clip.id) }
        panel.contentView = host
        return panel
    }

    enum Action { case annotate, copy, save, link, pin, text, trim, gif, close }
    private func perform(_ action: Action,_ id: UUID) {
        guard let clip = clips[id] else { return }
        switch action {
        case .close: close(id)
        case .annotate,.trim: close(id); controller.editor(clip)
        case .pin: close(id); controller.pin(clip)
        case .copy: controller.store.copy(clip); controller.showToast("Copied",symbol: "doc.on.doc",hideAfter: 1.2)
        case .save: saveAs(clip)
        case .link:
            guard CloudSession.shared.isSignedIn else { close(id); controller.requireSignIn(); return }
            Task { await controller.uploadClip(clip) }
        case .text: copyText(clip)
        case .gif: exportGIF(clip)
        }
    }
    private func saveAs(_ clip: Clip) {
        modal = true; stack.setHovered(true,now: now); schedule()
        defer { modal = false; stack.setHovered(false,now: now); schedule() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = clip.url.lastPathComponent
        panel.directoryURL = try? Preferences.shared.captureFolder()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: clip.url,to: url)
            controller.showToast("Saved",symbol: "square.and.arrow.down",detail: url.lastPathComponent,hideAfter: 1.6)
        } catch { controller.fail(error) }
    }
    private func copyText(_ clip: Clip) {
        guard let image = clip.image?.cgImage(forProposedRect: nil,context: nil,hints: nil) else { return }
        controller.pendingExports += 1
        Task {
            defer { controller.pendingExports -= 1; controller.finishIfIdle() }
            do {
                let text = try await CaptureEngine.recognize(image)
                var updated = clip; updated.text = text; controller.store.update(updated); update(updated)
                if text.isEmpty { controller.showToast("No text found",symbol: "text.viewfinder",hideAfter: 2) }
                else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType: .string); controller.showToast("Text copied",symbol: "text.viewfinder",detail: CaptureTextSummary.detail(text),hideAfter: 2) }
            } catch { controller.fail(error) }
        }
    }
    private func exportGIF(_ clip: Clip) {
        controller.pendingExports += 1
        controller.showToast("Exporting GIF…",symbol: "photo.stack",spinner: true,hideAfter: nil)
        Task {
            defer { controller.pendingExports -= 1; controller.finishIfIdle() }
            do {
                let folder = try Preferences.shared.saveToDisk ? Preferences.shared.captureFolder() : controller.store.support.appendingPathComponent("Captures")
                try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(CaptureFiles.filename(extension: "gif"))
                try await VideoTools.gif(clip.url,to: url)
                let saved = Clip(path: url.path,kind: "GIF",width: clip.width,height: clip.height)
                controller.store.add(saved); if Preferences.shared.copyToClipboard { controller.store.copy(saved) }
                controller.hideToast(); show(saved,on: screen(for: visibleFrames[clip.id]))
            } catch { controller.hideToast(); controller.fail(error) }
        }
    }
}

enum CaptureTextSummary {
    static func detail(_ text: String) -> String {
        let lines = text.split(separator: "\n",omittingEmptySubsequences: true)
        let first = lines.first.map(String.init) ?? ""
        return lines.count > 1 ? "\(first) · \(lines.count) lines" : first
    }
}

/// Trackpad swipes dismiss a card; ordinary clicks and drags go to SwiftUI.
final class SwipeHostingView<Content: View>: NSHostingView<Content> {
    var onSwipe: (() -> Void)?
    private var travel: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { super.scrollWheel(with: event); return }
        if event.phase == .began { travel = 0 }
        travel += event.scrollingDeltaX
        if abs(travel) > 60,abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { travel = 0; onSwipe?() }
    }
}

struct QuickAccessCard: View {
    let clip: Clip
    let cloud: Bool
    let perform: (QuickAccess.Action) -> Void
    let hover: (Bool) -> Void
    @State private var thumbnail: NSImage?
    @State private var duration: Double?
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(0.06))
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                if clip.isVideo { Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4) }
            }
            .frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                Button { perform(.close) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)).symbolRenderingMode(.hierarchical) }
                    .buttonStyle(.plain).padding(6).help("Close · swipe to dismiss").accessibilityLabel("Close")
            }
            .overlay(alignment: .bottomLeading) {
                if let duration { Text(String(format: "%d:%02d",Int(duration)/60,Int(duration)%60)).font(.system(size: 10,weight: .semibold,design: .monospaced)).padding(.horizontal,6).padding(.vertical,3).background(.black.opacity(0.55),in: Capsule()).foregroundStyle(.white).padding(7) }
            }
            .onTapGesture { perform(clip.isVideo ? .trim : .annotate) }
            .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }
            .help(clip.isVideo ? "Click to trim · drag into any app" : "Click to annotate · drag into any app")
            HStack(spacing: 0) {
                button("doc.on.doc","Copy",.copy)
                button("square.and.arrow.down","Save As…",.save)
                if clip.isVideo {
                    button("scissors","Trim",.trim)
                    button("photo.stack","Export GIF",.gif)
                } else {
                    button("pencil.tip.crop.circle","Annotate",.annotate)
                    if cloud { button("link","Upload & copy link",.link) }
                    button("pin","Pin to screen",.pin)
                    button("text.viewfinder","Copy text",.text)
                }
            }
        }
        .padding(10).frame(width: QuickAccess.cardSize.width-8,height: QuickAccess.cardSize.height-8)
        .glassEffect(.regular,in: RoundedRectangle(cornerRadius: 16))
        .frame(width: QuickAccess.cardSize.width,height: QuickAccess.cardSize.height)
        .onHover(perform: hover)
        .task {
            if clip.isVideo { thumbnail = await VideoTools.thumbnail(clip.url); duration = try? await AVURLAsset(url: clip.url).load(.duration).seconds }
            else { thumbnail = clip.image }
        }
    }
    func button(_ symbol: String,_ title: String,_ action: QuickAccess.Action) -> some View {
        Button { perform(action) } label: { Image(systemName: symbol).font(.system(size: 14)).frame(maxWidth: .infinity,minHeight: 30).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}
