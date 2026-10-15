import AppKit
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import EasyshotCore
import ApplicationServices
#if !APP_STORE
import ServiceManagement
#endif

struct CaptureRequest {
    let mode: CaptureMode
    let unified: Bool
    let purpose: String
    let drawImmediately: Bool
    let drawNewArea: Bool
}

@MainActor final class AppController: NSObject,ObservableObject,NSApplicationDelegate,NSWindowDelegate {
    static let shared = AppController()
    #if !APP_STORE
    lazy var updates: AppUpdates = {
        let manager = AppUpdates()
        manager.isCapturing = { [weak self] in self?.captureWorkActive ?? false }
        manager.sessionFinished = { [weak self] in self?.finishIfIdle() }
        return manager
    }()
    #endif
    var captureWorkActive: Bool {
        overlay.onComplete != nil || !overlay.windows.isEmpty || busy || pendingExports > 0 || pendingCapture != nil || launcherPending || recording || recorder != nil || scrolling != nil
    }
    lazy var store = ClipStore()
    let engine = CaptureEngine()
    lazy var overlay = CaptureOverlay(engine: engine)
    @Published var permitted = false
    @Published var busy = false
    @Published var recording = false
    @Published var recordingSeconds = 0
    @Published var scrollFrames = 0
    @Published var scrollNotice = "Scroll the content, then add another frame."
    @Published var autoScrolling = false
    /// Chosen before the second frame; fixed afterwards.
    @Published var scrollAxis: ScrollStitcher.Axis = .vertical
    @Published var status = "Ready when you are"
    var mainWindow: NSWindow?
    var preview: NSPanel?
    var previewTimer: Timer?
    var previewLifetime = QuickPreviewLifetime()
    var pendingCapture: CaptureRequest?
    var launcherPending = false
    var auxiliaryWindows: [NSWindow] = []
    var recorder: Recorder?
    var recordingEffects: RecordingEffects?
    var recordURL: URL?
    var recordSize = CGSize.zero
    var recordTimer: Timer?
    var recordPanel: NSPanel?
    var scrolling: (target: CaptureTarget,frames: [CGImage])?
    var scrollPanel: NSPanel?
    var scrollTask: Task<Void,Never>?
    var workspaceObserver: NSObjectProtocol?
    var permissionTimer: Timer?
    var startupTask: Task<Void,Never>?
    var launched = false
    var pendingLaunch: LaunchAction?
    var pendingEdit: String?
    var settingsWindow: NSWindow?
    var returnToCaptureAfterSettings = false
    var idleExitTask: Task<Void,Never>?
    var toastPanel: NSPanel?
    var toastTask: Task<Void,Never>?
    var pendingExports = 0
    /// Created on the first card so plain capture sessions pay nothing for it.
    var quickAccess: QuickAccess?
    /// Global Cocoa frame of the latest capture target; Quick Access cards appear on its display.
    var lastCaptureFrame: CGRect?
    var sessionActivity: SessionActivity {
        var activity: SessionActivity = []
        if overlay.onComplete != nil || !overlay.windows.isEmpty { activity.insert(.selection) }
        if busy || pendingExports > 0 || pendingCapture != nil || launcherPending { activity.insert(.processing) }
        if recording || recorder != nil { activity.insert(.recording) }
        if scrolling != nil { activity.insert(.scrolling) }
        if previewLifetime.isActive || toastPanel != nil || quickAccess?.isActive == true { activity.insert(.preview) }
        if mainWindow?.isVisible == true || settingsWindow?.isVisible == true || auxiliaryWindows.contains(where: { $0.isVisible }) { activity.insert(.toolWindow) }
        #if !APP_STORE
        if updates.holdsSession { activity.insert(.toolWindow) }
        #endif
        return activity
    }
    func finishIfIdle() {
        guard launched else { return }
        idleExitTask?.cancel()
        #if !APP_STORE
        updates.resumeInstallationIfReady()
        #endif
        idleExitTask = Task {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard sessionActivity.shouldExit else { return }
            #if !APP_STORE
            if updates.checkBackgroundIfDue() { return }
            #endif
            NSApp.terminate(nil)
        }
    }
    func hidePreviewImmediately() {
        previewTimer?.invalidate(); previewTimer = nil
        previewLifetime.invalidate(); preview?.orderOut(nil); preview = nil
    }
    func dismissPreview() { dismissPreview(generation: previewLifetime.generation) }
    func dismissPreview(generation: UInt64) {
        guard previewLifetime.isCurrent(generation),let panel = preview else { return }
        previewTimer?.invalidate(); previewTimer = nil
        let destination = panel.frame.offsetBy(dx: panel.frame.width+32,dy: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = QuickPreviewLifetime.slideOutSeconds
            panel.animator().setFrame(destination,display: true); panel.animator().alphaValue = 0
        } completionHandler: { [weak self,weak panel] in
            Task { @MainActor in
                panel?.orderOut(nil)
                guard let self,self.previewLifetime.dismiss(generation) else { return }
                self.preview = nil; self.finishIfIdle()
            }
        }
    }
    func drainPendingCapture() {
        guard !busy,let next = pendingCapture else { return }
        pendingCapture = nil
        capture(next.mode,unified: next.unified,purpose: next.purpose,drawImmediately: next.drawImmediately,drawNewArea: next.drawNewArea)
    }
    func rememberApplication(_ app: NSRunningApplication?) {
        guard let app,app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !["com.raycast.macos","com.apple.Spotlight","com.runningwithcrayons.Alfred","com.runningwithcrayons.Alfred-5"].contains(app.bundleIdentifier ?? "") else { return }
        engine.previousApp = app
    }
    func route(_ action: LaunchAction) {
        idleExitTask?.cancel(); launcherPending = false
        if !CloudSession.isAvailable,[.upload,.pasteUpload,.cloud].contains(action) {
            status = "Easyshot Cloud is not available in this edition."; finishIfIdle(); return
        }
        switch action {
        case .capture: capture(Preferences.shared.selection.mode,unified: true,drawNewArea: Preferences.shared.selection.drawNew)
        case .draw: capture(.area,unified: true,drawImmediately: true)
        case .repeatArea: capture(.lastRegion)
        case .library: openMain()
        case .settings: openSettings()
        case .fullscreen: capture(.fullscreen)
        case .window: capture(.window)
        case .activeWindow: capture(.activeWindow)
        case .upload:
            guard CloudSession.shared.isSignedIn else { requireSignIn(); return }
            capture(.area,unified: true,purpose: "Upload",drawNewArea: Preferences.shared.selection.drawNew)
        case .pasteUpload: pasteUpload()
        case .cloud: openMain(); DispatchQueue.main.async { NotificationCenter.default.post(name: .showCloud,object: nil) }
        case .captureText: capture(.area,unified: true,purpose: "Text / QR",drawNewArea: Preferences.shared.selection.drawNew)
        case .restoreOverlay:
            let cards = quickAccess ?? QuickAccess(controller: self); quickAccess = cards
            if !cards.restore() { showToast("Nothing to restore",symbol: "rectangle.stack",hideAfter: 2) }
        case .record: toggleRecord()
        }
    }
    /// App Intents (Shortcuts, Spotlight, user-assigned keyboard shortcuts) take the same path as launcher URLs.
    func runIntent(_ action: LaunchAction) {
        startupTask?.cancel(); launcherPending = false; idleExitTask?.cancel()
        if launched { route(action) } else { pendingLaunch = action }
    }
    func application(_ application: NSApplication,open urls: [URL]) {
        if let path = urls.compactMap(LaunchAction.editPath).last {
            startupTask?.cancel(); launcherPending = false; idleExitTask?.cancel()
            if launched { openForEditing(path) } else { pendingEdit = path }
            return
        }
        guard let action = urls.compactMap({ LaunchAction(url: $0) }).last else { return }
        startupTask?.cancel(); launcherPending = false; idleExitTask?.cancel()
        if launched { route(action) } else { pendingLaunch = action }
    }
    /// `grace` gives a non-default launch (Shortcuts running an App Intent) time to claim the session before the
    /// default capture bar opens. Ordinary launches and launcher URLs never wait.
    func scheduleLauncher(grace: Double = 0) {
        idleExitTask?.cancel(); launcherPending = true
        startupTask?.cancel()
        startupTask = Task {
            await Task.yield()
            if grace > 0 { try? await Task.sleep(for: .seconds(grace)) }
            guard !Task.isCancelled else { return }
            if let path = pendingEdit { pendingEdit = nil; openForEditing(path); return }
            route(pendingLaunch ?? .capture); pendingLaunch = nil
        }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow,window === settingsWindow,returnToCaptureAfterSettings {
            returnToCaptureAfterSettings = false
            DispatchQueue.main.async { self.route(.capture) }
        } else { finishIfIdle() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        StartupTrace.mark("didFinishLaunching")
        if CommandLine.arguments.contains("--startup-benchmark") {
            NSApp.setActivationPolicy(.accessory)
            Task { let result = await Diagnostics.startupBenchmark(controller: self); exit(result) }
            return
        }
        if CommandLine.arguments.contains("--escape-exit-test") {
            NSApp.setActivationPolicy(.accessory); launched = true
            guard let screen = NSScreen.screens.first else { exit(1) }
            // Exercise cancellation on an offscreen window, without sending OS input.
            overlay.windows = [overlay.makeSelectionWindow(for: screen)]
            overlay.onComplete = { _ in exit(1) }
            let event = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: 0,context: nil,characters: "\u{1b}",charactersIgnoringModifiers: "\u{1b}",isARepeat: false,keyCode: 53)!
            guard overlay.interceptEscape(event),overlay.windows.isEmpty,overlay.onComplete == nil else { exit(1) }
            print("PASS: Escape consumes the key, cancels selection, and exits the on-demand app")
            return
        }
        if CommandLine.arguments.contains("--idle-exit-test") {
            NSApp.setActivationPolicy(.accessory); launched = true; finishIfIdle(); return
        }
        if CommandLine.arguments.contains("--live-selection-test") {
            NSApp.setActivationPolicy(.accessory)
            Task { let result = await Diagnostics.liveSelectionTest(controller: self); fflush(stdout); exit(result) }
            return
        }
        if CommandLine.arguments.contains("--capture-test") {
            Task { let result = await Diagnostics.captureTest(controller: self); fflush(stdout); exit(result) }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--cloud-test"),CommandLine.arguments.indices.contains(flag+1) {
            let base = CommandLine.arguments[flag+1]
            Task { let result = await CloudDiagnostics.run(base: base); fflush(stdout); exit(result) }
            return
        }
        if CommandLine.arguments.contains("--studio-test") {
            Task { let result = await Diagnostics.studioTest(); fflush(stdout); exit(result) }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { let result = await Diagnostics.run(); fflush(stdout); exit(result) }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        rememberApplication(NSWorkspace.shared.frontmostApplication)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,object: nil,queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.rememberApplication(app) }
        }
        // Remove the old resident-app launch behavior when migrating an installation.
        #if !APP_STORE
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        #endif
        let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        installMenu(); launched = true; scheduleLauncher(grace: defaultLaunch || pendingLaunch != nil ? 0 : 0.35)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2,repeats: true) { [weak self] _ in
            Task { @MainActor in self?.permitted = CGPreflightScreenCaptureAccess() }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            Task { await self.smokeTest() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { scheduleLauncher(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder != nil {
            Task {
                if recording { await stopRecording() }
                else { while recorder != nil { try? await Task.sleep(for: .milliseconds(100)) } }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "About Easyshot",action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent: "")
        #if !APP_STORE
        let update = submenu.addItem(withTitle: "Check for Updates…",action: #selector(checkForUpdates),keyEquivalent: "")
        update.target = self
        #endif
        submenu.addItem(.separator())
        let settings = submenu.addItem(withTitle: "Settings…",action: #selector(openSettings),keyEquivalent: ","); settings.target = self
        submenu.addItem(withTitle: "Hide Easyshot",action: #selector(NSApplication.hide(_:)),keyEquivalent: "h")
        submenu.addItem(.separator()); submenu.addItem(withTitle: "Quit Easyshot",action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q")
        app.submenu = submenu; menu.addItem(app)
        let edit = NSMenuItem(); edit.title = "Edit"; let edits = NSMenu(title: "Edit")
        for (title,selector,key) in [("Undo","undo:","z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] { edits.addItem(withTitle: title,action: NSSelectorFromString(selector),keyEquivalent: key) }
        edit.submenu = edits; menu.addItem(edit)
        let window = NSMenuItem(); window.title = "Window"; let windows = NSMenu(title: "Window")
        let pins = windows.addItem(withTitle: "Show / unlock pinned images",action: #selector(unlockPins),keyEquivalent: ""); pins.target = self
        windows.addItem(withTitle: "Minimize",action: #selector(NSWindow.performMiniaturize(_:)),keyEquivalent: "m")
        window.submenu = windows; menu.addItem(window); NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
    #if !APP_STORE
    @objc func checkForUpdates() { updates.checkNow() }
    #endif
    @objc func openCaptureBar() { route(.capture) }
    @objc func menuCapture(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String,let mode = CaptureMode(rawValue: raw) { capture(mode) } }
    @objc func openMain() {
        showMain()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .showLibrary,object: nil) }
    }
    @objc func drawNewCapture() { route(.draw) }
    @objc func unlockPins() { auxiliaryWindows.compactMap { $0 as? NSPanel }.forEach { $0.ignoresMouseEvents = false; $0.orderFrontRegardless() } }
    @objc func openSettings() {
        permitted = engine.permission
        returnToCaptureAfterSettings = !overlay.windows.isEmpty
        overlay.close()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 490,height: 575),styleMask: [.titled,.closable,.fullSizeContentView],backing: .buffered,defer: false)
            window.title = "Easyshot Settings"; window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = glassWindowContent(BasicSettingsView(controller: self))
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func settingsDone() {
        returnToCaptureAfterSettings = false; settingsWindow?.orderOut(nil); route(.capture)
    }
    @objc func captureText() { capture(.area,purpose: "Text / QR") }
    @objc func startScroll() { capture(.area,purpose: "Scrolling capture") }
    @objc func toggleRecord() { if recording { Task { await stopRecording() } } else { capture(.area,purpose: "Recording") } }

    func showMain() {
        permitted = engine.permission
        overlay.close(); NSApp.setActivationPolicy(.accessory)
        if mainWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 1160,height: 790),styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing: .buffered,defer: false)
            window.title = "Easyshot"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.backgroundColor = .clear; window.isOpaque = false; window.isReleasedWhenClosed = false
            window.minSize = CGSize(width: 980,height: 690)
            window.contentView = glassWindowContent(WorkspaceView(controller: self,store: store))
            window.delegate = self; window.center(); mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func requestPermission() {
        if !CGRequestScreenCaptureAccess() { openPrivacy() }
        permitted = CGPreflightScreenCaptureAccess()
    }
    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func openPrivacyPolicy() {
        openWindow(title: "Privacy · Easyshot",size: CGSize(width: 560,height: 520),view: PrivacyView())
    }
    func capture(_ mode: CaptureMode,unified: Bool = false,purpose: String = "Screenshot",drawImmediately: Bool = false,drawNewArea: Bool = false) {
        idleExitTask?.cancel()
        guard !recording,scrolling == nil else { if recording { status = "Stop the current recording before starting another capture." }; return }
        if busy {
            // Keep the newest launch request while finishing the current file/clipboard write.
            pendingCapture = CaptureRequest(mode: mode,unified: unified,purpose: purpose,drawImmediately: drawImmediately,drawNewArea: drawNewArea)
            return
        }
        StartupTrace.mark("captureRequested")
        hidePreviewImmediately()
        Preferences.shared.selection = CaptureSelection(mode: mode,drawNew: drawImmediately || drawNewArea)
        overlay.close(); settingsWindow?.orderOut(nil)
        rememberApplication(NSWorkspace.shared.frontmostApplication)
        mainWindow?.orderOut(nil); NSApp.setActivationPolicy(.accessory)
        let interactive = unified || mode == .area || mode == .window || (mode == .lastRegion && Preferences.shared.lastRegion == nil)
        if interactive {
            // Native transparent selection needs no desktop snapshot, stream, or metadata wait.
            overlay.show(mode: mode,purpose: purpose,drawImmediately: drawImmediately,drawNewArea: drawNewArea) { [weak self] target in self?.perform(target,purpose: self?.overlay.state.purpose ?? purpose) }
            permitted = !overlay.state.needsPermission
            return
        }
        permitted = engine.permission
        guard permitted else {
            overlay.show(mode: mode,purpose: purpose,drawImmediately: drawImmediately,drawNewArea: drawNewArea) { [weak self] target in self?.perform(target,purpose: self?.overlay.state.purpose ?? purpose) }
            return
        }
        busy = true
        Task {
            do {
                try await engine.refresh()
                StartupTrace.mark("shareableContentReady")
                busy = false
                if pendingCapture != nil { drainPendingCapture(); return }
                if mode == .activeWindow,!unified {
                    guard let window = engine.activeWindow() else { throw ShotError.message("No active application window found.") }
                    perform(.window(window),purpose: purpose)
                } else if mode == .fullscreen,!unified { perform(.display(NSScreen.pointerScreen.displayID),purpose: purpose) }
                else if mode == .lastRegion,!unified,Preferences.shared.lastRegion != nil { perform(.region(overlay.savedOrDefaultRegion()),purpose: purpose) }
                else {
                    overlay.show(mode: mode,purpose: purpose,drawImmediately: drawImmediately,drawNewArea: drawNewArea) { [weak owner = self] target in owner?.perform(target,purpose: owner?.overlay.state.purpose ?? purpose) }
                }
            } catch { busy = false; fail(error); drainPendingCapture(); finishIfIdle() }
        }
    }
    func perform(_ target: CaptureTarget,purpose: String) {
        guard !StartupTrace.enabled else { return }
        busy = true
        engine.previousApp?.activate(options: [])
        lastCaptureFrame = cocoaFrame(target)
        // A frozen selection captures the stills it showed; a timer means the user wants a later moment.
        let frozen = Preferences.shared.delay > 0 ? nil : overlay.takeFrozenHandoff()
        Task {
            do {
                let delay = Preferences.shared.delay
                if delay > 0 { status = "Capturing in \(Int(delay)) seconds…"; try await Task.sleep(for: .seconds(delay)) }
                // Area/full-screen selection opens before capture metadata is needed.
                // Refresh on the capture action, after removing the overlay.
                try await engine.refresh()
                if purpose == "Recording" { try await startRecording(target) }
                else if purpose == "Scrolling capture" { try await beginScroll(target) }
                else if purpose == "Text / QR" { try await captureText(target,frozen: frozen) }
                else {
                    var image = try await engine.image(target,frozen: frozen)
                    if case .window(let window) = target,let plan = WindowBackdropRenderer.plan(windowFrame: CaptureGeometry.quartz(window.frame,primaryHeight: NSScreen.primaryHeight)) {
                        let plain = image
                        image = await Task.detached(priority: .userInitiated) { WindowBackdropRenderer.render(plain,plan: plan) }.value
                    }
                    let uploading = purpose == "Upload"
                    // PNG encoding and the file write happen off the main thread; the link replaces the image on the clipboard.
                    let clip = try await store.writeDetached(image: image,kind: targetName(target),copyOverride: uploading ? false : nil)
                    status = "\(Preferences.shared.saveToDisk ? "Saved" : "In history")\(Preferences.shared.copyToClipboard && !uploading ? " and copied" : "") · \(image.width) × \(image.height)"
                    if uploading { await uploadClip(clip) }
                    showPreview(clip)
                }
            } catch { fail(error) }
            busy = false; drainPendingCapture(); finishIfIdle()
        }
    }
    /// Capture Text: on-device OCR straight to the clipboard. The screenshot is kept only when the user opts in.
    func captureText(_ target: CaptureTarget,frozen: [CGDirectDisplayID: CGImage]?) async throws {
        let image = try await engine.image(target,frozen: frozen)
        let text = try await CaptureEngine.recognize(image)
        if text.isEmpty {
            status = "No text or QR code found."
            showToast("No text found",symbol: "text.viewfinder",hideAfter: 2.5)
        } else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType: .string)
            status = "Recognized text copied"
            showToast("Text copied",symbol: "text.viewfinder",detail: CaptureTextSummary.detail(text),hideAfter: 2.5)
        }
        if Preferences.shared.saveCapturedText {
            var clip = try await store.writeDetached(image: image,kind: "Text",copyOverride: false)
            clip.text = text; store.update(clip)
        }
    }
    func cocoaFrame(_ target: CaptureTarget) -> CGRect? {
        switch target {
        case .region(let rect): return rect
        case .display(let id): return NSScreen.screens.first { $0.displayID == id }?.frame
        case .window(let window): return CaptureGeometry.quartz(window.frame,primaryHeight: NSScreen.primaryHeight)
        }
    }
    /// The display holding most of the latest capture, else the one under the pointer.
    var captureScreen: NSScreen {
        guard let frame = lastCaptureFrame else { return .pointerScreen }
        func area(_ s: NSScreen) -> CGFloat { let r = s.frame.intersection(frame); return r.isNull ? 0 : r.width*r.height }
        return NSScreen.screens.max { area($0) < area($1) }.flatMap { area($0) > 0 ? $0 : nil } ?? .pointerScreen
    }
    // MARK: Easyshot Cloud
    func requireSignIn() {
        status = "Sign in to Easyshot Cloud to upload screenshots."
        openSettings()
    }
    func copyLink(_ link: String) -> Bool {
        guard let url = ShareLink.validated(link) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString,forType: .string)
        return true
    }
    /// Upload a saved capture and leave its share link on the clipboard.
    func uploadClip(_ clip: Clip) async {
        pendingExports += 1; defer { pendingExports -= 1 }
        showToast("Uploading…",symbol: "icloud.and.arrow.up",spinner: true,hideAfter: nil)
        do {
            let url = clip.url
            let image = try await Task.detached(priority: .userInitiated) { try UploadableImage.load(from: url) }.value
            try await finishUpload(image)
        } catch { uploadFailed(error) }
    }
    /// Convert whatever image is on the clipboard into a link, for pasting into SSH sessions and chats.
    func pasteUpload() {
        guard CloudSession.shared.isSignedIn else { requireSignIn(); return }
        let image: UploadableImage?
        do { image = try UploadableImage.fromPasteboard() } catch { uploadFailed(error); return }
        guard let image else { showToast("No image on the clipboard",symbol: "exclamationmark.triangle.fill",hideAfter: 3); return }
        pendingExports += 1
        showToast("Uploading…",symbol: "icloud.and.arrow.up",spinner: true,hideAfter: nil)
        Task {
            defer { pendingExports -= 1 }
            do { try await finishUpload(image) } catch { uploadFailed(error) }
        }
    }
    private func finishUpload(_ image: UploadableImage) async throws {
        let shot = try await CloudSession.shared.upload(image)
        guard copyLink(shot.shareURL) else { throw CloudError.invalidResponse }
        status = "Link copied · \(shot.shareURL)"
        showToast("Link copied",symbol: "link",detail: shot.shareURL,hideAfter: 2.5)
    }
    private func uploadFailed(_ error: Error) {
        status = error.localizedDescription
        if case CloudError.notSignedIn = error { hideToast(); requireSignIn(); return }
        showToast("Upload failed",symbol: "exclamationmark.triangle.fill",detail: error.localizedDescription,hideAfter: 6)
    }
    func showToast(_ text: String,symbol: String,detail: String? = nil,spinner: Bool = false,hideAfter: Double?) {
        toastTask?.cancel(); idleExitTask?.cancel()
        let host = NSHostingView(rootView: ToastView(text: text,symbol: symbol,detail: detail,spinner: spinner))
        let size = host.fittingSize
        let screen = NSScreen.pointerScreen
        let frame = CGRect(x: screen.visibleFrame.midX-size.width/2,y: screen.visibleFrame.minY+80,width: size.width,height: size.height)
        let panel = toastPanel ?? NSPanel(contentRect: frame,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView = host; panel.setFrame(frame,display: true); panel.orderFrontRegardless()
        toastPanel = panel
        if let hideAfter {
            toastTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(hideAfter)) } catch { return }
                self?.hideToast()
            }
        }
    }
    func hideToast() {
        toastTask?.cancel(); toastTask = nil
        toastPanel?.orderOut(nil); toastPanel = nil
        finishIfIdle()
    }
    private func targetName(_ target: CaptureTarget) -> String { switch target { case .display: return "Screen"; case .window: return "Window"; case .region: return "Area" } }
    func fail(_ error: Error) {
        status = error.localizedDescription; store.error = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
        finishIfIdle()
    }
    func showPreview(_ clip: Clip) {
        hidePreviewImmediately()
        switch Preferences.shared.postCapture {
        case .none: finishIfIdle(); return
        case .overlay:
            idleExitTask?.cancel()
            let cards = quickAccess ?? QuickAccess(controller: self); quickAccess = cards
            cards.show(clip,on: captureScreen); return
        case .thumbnail: break
        }
        idleExitTask?.cancel()
        let generation = previewLifetime.replace()
        let screen = captureScreen
        let size = CGSize(width: 228,height: 164)
        let finalFrame = CGRect(x: screen.visibleFrame.maxX-size.width-24,y: screen.visibleFrame.minY+24,width: size.width,height: size.height)
        let panel = NSPanel(contentRect: finalFrame.offsetBy(dx: size.width+32,dy: 0),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickPreviewThumbnail(clip: clip,controller: self))
        panel.alphaValue = 0; preview = panel; panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = QuickPreviewLifetime.slideInSeconds
            panel.animator().setFrame(finalFrame,display: true); panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,self.previewLifetime.isCurrent(generation) else { return }
                self.previewTimer = Timer.scheduledTimer(withTimeInterval: QuickPreviewLifetime.visibleSeconds,repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.dismissPreview(generation: generation) }
                }
            }
        }
    }
    func editor(_ clip: Clip) {
        hidePreviewImmediately()
        if clip.isVideo { videoEditor(clip); return }
        guard let cg = clip.image?.cgImage(forProposedRect: nil,context: nil,hints: nil) else { fail(ShotError.message("The capture file is missing or unreadable.")); return }
        let model = EditorModel(image: cg,clip: clip,store: store)
        openWindow(title: "Annotate · Easyshot",size: CGSize(width: 1160,height: 800),view: EditorView(model: model))
    }
    func openWindow<V: View>(title: String,size: CGSize,view: V) {
        let window = NSWindow(contentRect: CGRect(origin: .zero,size: size),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.delegate = self; window.title = title; window.contentView = glassWindowContent(view); window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil); auxiliaryWindows.append(window)
        // Keep only visible windows; retain the new window while it is open.
        auxiliaryWindows.removeAll { !$0.isVisible }; NSApp.activate(ignoringOtherApps: true)
    }
    func glassWindowContent<V: View>(_ view: V) -> NSView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        let host = NSHostingView(rootView: view)
        host.autoresizingMask = [.width,.height]
        backdrop.addSubview(host)
        return backdrop
    }
    func pin(_ clip: Clip) { if let image = clip.image { pinImage(image,title: clip.url.lastPathComponent) } }
    func pinImage(_ image: NSImage,title: String) {
        let scale = min(1,500/max(image.size.width,1),500/max(image.size.height,1))
        let size = CGSize(width: max(220,image.size.width*scale),height: max(160,image.size.height*scale)+44)
        let panel = NSPanel(contentRect: CGRect(origin: .zero,size: size),styleMask: [.titled,.closable,.resizable,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.delegate = self; panel.title = title; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PinnedImage(image: image,panel: panel))
        panel.center(); panel.orderFrontRegardless(); auxiliaryWindows.append(panel)
    }
    func recognize(_ clip: Clip) {
        guard let image = clip.image?.cgImage(forProposedRect: nil,context: nil,hints: nil) else { return }
        pendingExports += 1
        Task {
            defer { pendingExports -= 1; finishIfIdle() }
            do {
                let text = try await CaptureEngine.recognize(image)
                var updated = clip; updated.text = text; store.update(updated)
                if text.isEmpty { status = "No text or QR code found." }
                else { store.copy(updated); NSPasteboard.general.setString(text,forType: .string); status = "Recognized text copied" }
            } catch { fail(error) }
        }
    }
    func savePreset(name: String) {
        guard let last = Preferences.shared.lastRegion else { return }
        Preferences.shared.presets.append(RegionPreset(name: name.isEmpty ? "Area \(Preferences.shared.presets.count+1)" : name,region: last))
    }
    func startRecording(_ target: CaptureTarget) async throws {
        if Preferences.shared.microphone {
            guard #available(macOS 15.0, *) else { throw ShotError.message("Microphone capture requires macOS 15 or later.") }
            if !(await AVCaptureDevice.requestAccess(for: .audio)) { throw ShotError.message("Microphone access was denied. Enable it in System Settings or turn off microphone capture.") }
        }
        let (filter,config) = try engine.configuration(for: target,recording: true)
        let p = Preferences.shared
        let folder = try p.saveToDisk ? p.captureFolder() : store.support.appendingPathComponent("Captures")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CaptureFiles.filename(extension: "mp4"))
        let recorder = Recorder()
        recorder.didFail = { [weak self] error in Task { @MainActor in self?.fail(error); await self?.stopRecording() } }
        let source: CGRect
        switch target {
        case .window(let window): source = window.frame
        case .display(let id): source = engine.content?.displays.first(where: { $0.displayID == id })?.frame ?? filter.contentRect
        case .region(let rect):
            let quartz = CaptureGeometry.quartz(rect,primaryHeight: NSScreen.primaryHeight)
            let display = engine.content?.displays.max { a,b in
                let r1 = a.frame.intersection(quartz); let r2 = b.frame.intersection(quartz)
                return (r1.isNull ? 0 : r1.width*r1.height) < (r2.isNull ? 0 : r2.width*r2.height)
            }
            source = display?.frame.intersection(quartz) ?? quartz
        }
        // Studio animates clicks itself, so baked click rings are skipped to keep frames passthrough.
        let clicks = p.showClicks && !p.studio
        let effects = (clicks || p.showKeys || p.recordCamera) ? RecordingEffects(source: source,clicks: clicks,keys: p.showKeys) : nil
        let telemetry = p.studio ? CursorTelemetry(source: source,pixels: CGSize(width: config.width,height: config.height)) : nil
        do {
            try await effects?.start(cameraEnabled: p.recordCamera)
            try await recorder.start(filter: filter,configuration: config,url: url,effects: effects,telemetry: telemetry)
        } catch { effects?.stop(); throw error }
        recordingEffects = effects
        self.recorder = recorder; recordURL = url; recordSize = CGSize(width: config.width,height: config.height)
        recording = true; recordingSeconds = 0; status = "Recording…"
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1,repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.recordingSeconds += 1
            }
        }
        let screen = NSScreen.pointerScreen
        let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.midX-120,y: screen.visibleFrame.minY+25,width: 240,height: 56),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingControls(controller: self)); panel.orderFrontRegardless(); recordPanel = panel
    }
    var timeString: String { String(format: "%02d:%02d",recordingSeconds/60,recordingSeconds%60) }
    func stopRecording() async {
        guard recording,let recorder else { return }
        recording = false; busy = true; recordTimer?.invalidate(); recordPanel?.orderOut(nil)
        do {
            try await recorder.stop()
            recordingEffects?.stop()
            if let url = recordURL {
                if Preferences.shared.microphone {
                    do { try await VideoTools.mixAudio(url) } catch { store.error = error.localizedDescription }
                }
                let clip = Clip(path: url.path,kind: "Recording",width: Int(recordSize.width),height: Int(recordSize.height))
                store.add(clip); if Preferences.shared.copyToClipboard { store.copy(clip) }; showPreview(clip)
                status = "Recording saved\(Preferences.shared.copyToClipboard ? " and copied" : "")"
            }
        } catch { recordingEffects?.stop(); fail(error) }
        self.recorder = nil; recordingEffects = nil; recordURL = nil; busy = false; finishIfIdle()
    }
    func videoEditor(_ clip: Clip) { openWindow(title: "Recording · Easyshot",size: CGSize(width: 960,height: 680),view: VideoEditorView(clip: clip,controller: self)) }
    func beginScroll(_ target: CaptureTarget) async throws {
        let image = try await engine.image(target)
        scrolling = (target,[image]); scrollFrames = 1; scrollNotice = "Scroll the content, then add another frame."
        engine.previousApp?.activate(options: [])
        let screen = NSScreen.pointerScreen
        let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.midX-340,y: screen.visibleFrame.minY+24,width: 680,height: 94),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollingControls(controller: self)); panel.orderFrontRegardless(); scrollPanel = panel
    }
    func addScrollFrame() {
        guard !busy,let session = scrolling else { return }; busy = true
        Task {
            do {
                let image = try await engine.image(session.target)
                guard let last = session.frames.last else { return }
                let vertical = scrollAxis == .vertical
                if let overlap = ScrollStitcher.overlap(last,image,axis: scrollAxis) {
                    if overlap == (vertical ? image.height : image.width) { scrollNotice = "Same view. Scroll \(vertical ? "down" : "right") before adding a frame." }
                    else { scrolling?.frames.append(image); scrollFrames += 1; scrollNotice = "Frame added · \(overlap) px overlap" }
                } else { scrollNotice = "No overlap found. Scroll back \(vertical ? "up" : "left") a little and try again." }
            } catch { scrollNotice = error.localizedDescription }
            busy = false; drainPendingCapture(); finishIfIdle()
        }
    }
    func finishScroll() {
        guard let session = scrolling,!busy else { return }
        do { let result = try ScrollStitcher.stitch(session.frames,axis: scrollAxis); let clip = try store.write(image: result,kind: "Scrolling"); cancelScroll(); showPreview(clip); status = "Scrolling capture saved" }
        catch { scrollNotice = error.localizedDescription }
    }
    func toggleAutoScroll() {
        #if APP_STORE
        scrollNotice = "Scroll manually, then choose Add Frame."
        #else
        if autoScrolling { scrollTask?.cancel(); return }
        guard !busy,let session = scrolling,case .region(let rect) = session.target else { return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            scrollNotice = "Auto scroll needs Accessibility access. You can also scroll manually and add frames."
            return
        }
        autoScrolling = true
        scrollTask = Task { [weak self] in
            guard let self else { return }
            defer { self.autoScrolling = false; self.busy = false; self.finishIfIdle() }
            let quartz = CaptureGeometry.quartz(rect,primaryHeight: NSScreen.primaryHeight)
            let axis = self.scrollAxis,vertical = axis == .vertical
            var duplicates = 0
            while !Task.isCancelled,let current = self.scrolling,current.frames.count < 50 {
                self.busy = true
                do {
                    let event = vertical ? CGEvent(scrollWheelEvent2Source: nil,units: .pixel,wheelCount: 1,wheel1: -Int32(rect.height*0.55),wheel2: 0,wheel3: 0)
                        : CGEvent(scrollWheelEvent2Source: nil,units: .pixel,wheelCount: 2,wheel1: 0,wheel2: -Int32(rect.width*0.55),wheel3: 0)
                    event?.location = CGPoint(x: quartz.midX,y: quartz.midY)
                    event?.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(650))
                    let image = try await self.engine.image(current.target)
                    guard !Task.isCancelled,self.scrolling != nil,let last = current.frames.last else { break }
                    guard let overlap = ScrollStitcher.overlap(last,image,axis: axis) else { self.scrollNotice = "No overlap. Exclude fixed headers and try a smaller area."; break }
                    if overlap == (vertical ? image.height : image.width) {
                        duplicates += 1
                        if duplicates >= 3 { self.scrollNotice = "End reached. Finish to save your scrolling capture."; break }
                    } else {
                        duplicates = 0; self.scrolling?.frames.append(image); self.scrollFrames += 1
                        self.scrollNotice = "Auto scrolling · \(self.scrollFrames) frames"
                        let extent = self.scrolling?.frames.reduce(0) { $0+(vertical ? $1.height : $1.width) } ?? 0
                        if extent > (vertical ? 40000 : 19000) { self.scrollNotice = "Capture limit reached. Finish to save."; break }
                    }
                } catch is CancellationError { self.scrollNotice = "Auto scroll stopped. Finish to save."; break }
                catch { self.scrollNotice = error.localizedDescription; break }
            }
        }
        #endif
    }
    func cancelScroll() { scrollTask?.cancel(); autoScrolling = false; scrolling = nil; scrollFrames = 0; scrollPanel?.orderOut(nil); scrollPanel = nil; finishIfIdle() }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image,.movie,.json]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if url.pathExtension == "json" { importProject(url); continue }
            if ["mp4","mov"].contains(url.pathExtension.lowercased()) {
                #if APP_STORE
                do {
                    // A panel grant does not survive relaunch. Keep imported
                    // movies in the app container so history stays readable.
                    let folder = store.support.appendingPathComponent("Imports",isDirectory: true)
                    try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                    let copy = folder.appendingPathComponent(CaptureFiles.filename(extension: url.pathExtension.lowercased()))
                    try FileManager.default.copyItem(at: url,to: copy)
                    let clip = Clip(path: copy.path,kind: "Imported",width: 0,height: 0); store.add(clip); videoEditor(clip)
                } catch { fail(error) }
                #else
                let clip = Clip(path: url.path,kind: "Imported",width: 0,height: 0); store.add(clip); videoEditor(clip)
                #endif
            } else if let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil,context: nil,hints: nil) {
                do { let clip = try store.write(image: image,kind: "Imported"); editor(clip) } catch { fail(error) }
            }
        }
    }
    /// `easyshot://edit?path=…`, sent by the MCP server's open_in_editor tool.
    func openForEditing(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else { fail(ShotError.message("Cannot open \(path).")); return }
        if url.pathExtension.lowercased() == "json" { importProject(url); return }
        if let clip = store.clips.first(where: { $0.path == path }) { editor(clip); return }
        let properties = CGImageSourceCreateWithURL(url as CFURL,nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0,0,nil) as? [CFString: Any] }
        let clip = Clip(path: path,kind: "Imported",width: properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,height: properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        store.add(clip); editor(clip)
    }
    func importProject(_ url: URL) {
        struct Project: Codable { var png: Data; var marks: [Mark]; var padding: Double; var background: [Double]; var shadow: Bool }
        do {
            let project = try JSONDecoder().decode(Project.self,from: Data(contentsOf: url))
            guard project.background.count == 4,project.marks.allSatisfy({ $0.color.count == 4 }),let image = NSImage(data: project.png)?.cgImage(forProposedRect: nil,context: nil,hints: nil) else { throw ShotError.message("Invalid Easyshot project.") }
            let clip = Clip(path: url.path,kind: "Project",width: image.width,height: image.height)
            let model = EditorModel(image: image,clip: clip,store: store); model.marks = project.marks; model.padding = project.padding; model.shadow = project.shadow
            model.background = Color(.sRGB,red: project.background[0],green: project.background[1],blue: project.background[2],opacity: project.background[3])
            openWindow(title: "Editable project · Easyshot",size: CGSize(width: 1160,height: 800),view: EditorView(model: model))
        } catch { fail(error) }
    }
    func smokeTest() async {
        // A real app render/capture pipeline smoke test, without touching the user's screenshots directory or clipboard.
        do {
            guard engine.permission else { throw ShotError.message("Screen Recording permission is needed to run capture smoke tests.") }
            try await engine.refresh()
            guard let display = engine.content?.displays.first else { throw ShotError.message("No display.") }
            let image = try await engine.image(.display(display.displayID))
            let out = URL(fileURLWithPath: "/tmp/easyshot-smoke.png")
            try NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:])?.write(to: out)
            print("SMOKE PASS: \(image.width)x\(image.height), \(out.path)")
            status = "Capture smoke test passed"
        } catch { print("SMOKE BLOCKED: \(error.localizedDescription)"); status = error.localizedDescription }
    }
}

extension Notification.Name { static let showCloud = Notification.Name("EasyshotShowCloud"); static let showLibrary = Notification.Name("EasyshotShowLibrary"); static let showSettings = Notification.Name("EasyshotShowSettings") }
