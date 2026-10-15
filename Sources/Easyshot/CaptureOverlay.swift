import AppKit
import SwiftUI
import ScreenCaptureKit
import EasyshotCore
import QuartzCore

@MainActor final class SelectionState: ObservableObject {
    @Published var mode: CaptureMode = .area
    @Published var rect: CGRect = .zero
    @Published var hoveredWindow: SCWindow?
    var hoveredFrame: CGRect = .zero
    @Published var purpose = "Screenshot"
    @Published var fixedWidth = "1280"
    @Published var fixedHeight = "720"
    @Published var drawingNew = false
    @Published var fastDraw = false
    @Published var needsPermission = false
    var drawNew: (() -> Void)?
    var resetArea: (() -> Void)?
    var uploadCapture: (() -> Void)?
    var openLibrary: (() -> Void)?
    var openSettings: (() -> Void)?
    var changed: (() -> Void)?
    var capture: (() -> Void)?
    var cancel: (() -> Void)?
    var applySize: (() -> Void)?
}

final class CaptureToolbarPanel: NSPanel {
    weak var overlay: CaptureOverlay?
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let editor = firstResponder as? NSTextView,editor.isFieldEditor { return super.performKeyEquivalent(with: event) }
        if overlay?.handleKeyboard(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if overlay?.handleKeyboard(event) != true { super.keyDown(with: event) }
    }
}

final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class CaptureOverlay {
    let state = SelectionState()
    let engine: CaptureEngine
    let preferences: Preferences
    var windows: [NSWindow] = []
    var toolbar: NSPanel?
    private(set) var toolbarOccluded = false
    let tooltips = CaptureTooltips()
    var onComplete: ((CaptureTarget) -> Void)?
    var views: [SelectionView] = []
    var clickAnchor: CGPoint?
    var escapeMonitor: Any?
    var selectionGeneration = 0
    var windowRefreshTask: Task<Void,Never>?

    var pointer = CGPoint.zero
    var captureOnDraw: Bool { state.fastDraw || preferences.snapOnDraw }
    var selectionBounds: CGRect { NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) } }
    var targetDisplayID: CGDirectDisplayID = 0
    func drawNew() {
        state.mode = .area; state.drawingNew = true; state.rect = .zero
        clickAnchor = nil; state.fastDraw = false; rememberMode(); redraw()
    }
    /// Clears the current rectangle, any half-finished two-click corner and any drag in flight, then
    /// arms a fresh draw. The saved "last area" stays untouched until a new capture replaces it.
    func resetArea() {
        views.forEach { $0.cancelInteraction() }
        state.mode = .area; state.drawingNew = true; state.rect = .zero
        clickAnchor = nil; state.fastDraw = false
        rememberMode(); redraw()
    }
    func uploadCapture() {
        guard CloudSession.isAvailable,state.purpose == "Screenshot" || state.purpose == "Upload" else { NSSound.beep(); return }
        guard CloudSession.shared.isSignedIn else { close(); AppController.shared.requireSignIn(); return }
        state.purpose = "Upload"; complete()
    }
    init(engine: CaptureEngine,preferences: Preferences = .shared) { self.engine = engine; self.preferences = preferences }
    func show(mode: CaptureMode,purpose: String,drawImmediately: Bool = false,drawNewArea: Bool = false,onComplete: @escaping (CaptureTarget) -> Void) {
        close()
        self.onComplete = onComplete
        clickAnchor = nil
        state.mode = mode; state.purpose = purpose; state.rect = .zero
        state.fastDraw = drawImmediately
        state.drawingNew = drawImmediately || drawNewArea
        state.needsPermission = !CGPreflightScreenCaptureAccess()
        targetDisplayID = NSScreen.pointerScreen.displayID
        if (mode == .area || mode == .lastRegion),!state.drawingNew { state.rect = savedOrDefaultRegion() }
        state.changed = { [weak self] in self?.changeMode() }
        state.capture = { [weak self] in self?.complete() }
        state.drawNew = { [weak self] in self?.drawNew() }
        state.resetArea = { [weak self] in self?.resetArea() }
        state.uploadCapture = { [weak self] in self?.uploadCapture() }
        state.openLibrary = { [weak self] in self?.close(); AppController.shared.openMain() }
        state.openSettings = { AppController.shared.openSettings() }
        state.cancel = { [weak self] in self?.cancel() }
        state.applySize = { [weak self] in
            guard let self,let w = Double(self.state.fixedWidth),let h = Double(self.state.fixedHeight),w > 1,h > 1 else { return }
            let screen = NSScreen.pointerScreen.frame
            self.state.mode = .area; self.state.drawingNew = false; self.state.fastDraw = false
            self.state.rect = CaptureGeometry.clamped(CGRect(x: screen.midX-w/2,y: screen.midY-h/2,width: w,height: h),to: screen)
            self.rememberMode(); self.redraw()
        }
        updateWindowSelection(at: NSEvent.mouseLocation)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.interceptEscape(event) == true { return nil }
            return event
        }
        presentSelectionWindows()
        let screen = NSScreen.pointerScreen
        let panel = CaptureToolbarPanel(contentRect: CGRect(x: screen.visibleFrame.midX-(CloudSession.isAvailable ? 328 : 310),y: screen.visibleFrame.minY+24,width: CloudSession.isAvailable ? 656 : 620,height: 62),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.overlay = self; panel.acceptsMouseMovedEvents = true; panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        tooltips.toolbarFrame = panel.frame
        panel.contentView = NSHostingView(rootView: CaptureToolbar(state: state,tooltips: tooltips))
        panel.orderFrontRegardless(); toolbar = panel
        StartupTrace.mark("toolbarVisible")
        if let active = windows.first(where: { $0.frame == screen.frame }) { active.makeKey(); active.makeFirstResponder(active.contentView) }
        redraw()
        StartupTrace.mark("selectorVisible")
        if !state.needsPermission { startWindowMetadataRefresh() }
    }
    func presentSelectionWindows() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = makeSelectionWindow(for: screen)
            window.orderFrontRegardless()
            // Restore explicit rectangular mouse acceptance after configuring transparency.
            // Visual alpha and input handling are independent; no fake-opacity backdrop.
            window.ignoresMouseEvents = false
            views.append(window.contentView as! SelectionView); windows.append(window)
        }
        if let active = windows.first(where: { $0.frame == NSScreen.pointerScreen.frame }) {
            active.makeKey(); active.makeFirstResponder(active.contentView)
        }
        redraw()
    }
    /// Construct without ordering on screen so the input surface can be tested in isolation.
    func makeSelectionWindow(for screen: NSScreen) -> CaptureOverlayWindow {
        let window = CaptureOverlayWindow(contentRect: screen.frame,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        window.level = .screenSaver
        window.isOpaque = false; window.alphaValue = 1; window.backgroundColor = .clear; window.hasShadow = false; window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false; window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        window.hidesOnDeactivate = false; window.becomesKeyOnlyIfNeeded = false
        window.contentView = SelectionView(frame: CGRect(origin: .zero,size: screen.frame.size),overlay: self,displayID: screen.displayID,displayName: screen.localizedName)
        window.acceptsMouseMovedEvents = true
        return window
    }
    /// App-local interception also covers SwiftUI popovers and field editors.
    @discardableResult func interceptEscape(_ event: NSEvent) -> Bool {
        guard onComplete != nil || !windows.isEmpty else { return false }
        guard event.keyCode == 53 else { return false }
        cancel(); return true
    }
    func cancel() { close(); AppController.shared.finishIfIdle() }
    func rememberMode() { preferences.selection = CaptureSelection(mode: state.mode,drawNew: state.drawingNew) }
    func close() {
        tooltips.dismiss()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        selectionGeneration += 1
        windowRefreshTask?.cancel(); windowRefreshTask = nil
        let hadSelection = onComplete != nil || !windows.isEmpty
        toolbar?.close(); toolbar = nil; toolbarOccluded = false
        windows.forEach { $0.close() }; windows.removeAll(); views.removeAll()
        onComplete = nil
        if hadSelection { engine.previousApp?.activate(options: []) }
    }
    /// Only window mode needs capture metadata. Screen/area selection renders immediately,
    /// and the system compositor keeps the real desktop/video/game visible underneath.
    func startWindowMetadataRefresh() {
        let generation = selectionGeneration
        windowRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.selectionGeneration == generation,self.onComplete != nil else { return }
                if self.state.mode == .window || self.state.mode == .activeWindow {
                    try? await self.engine.refresh()
                    guard !Task.isCancelled,self.selectionGeneration == generation,self.onComplete != nil else { return }
                    if self.updateWindowSelection(at: NSEvent.mouseLocation) { self.redraw() }
                }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
        }
    }
    func updatePointer(at point: CGPoint) {
        pointer = point
        guard state.mode == .fullscreen,let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),screen.displayID != targetDisplayID else { return }
        targetDisplayID = screen.displayID; redraw()
    }
    func updateToolbarVisibility(animated: Bool = true) {
        guard let toolbar else { return }
        let rect = state.rect
        let overlap = toolbar.frame.intersection(rect)
        let hidden = (state.mode == .area || state.mode == .lastRegion) && rect.width > 2 && rect.height > 2 && !overlap.isNull && overlap.width > 0 && overlap.height > 0
        guard hidden != toolbarOccluded else { return }
        toolbarOccluded = hidden
        toolbar.ignoresMouseEvents = hidden
        if hidden { tooltips.dismiss() }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !animated ? 0 : hidden ? 0.16 : 0.2
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            toolbar.animator().alphaValue = hidden ? 0 : 1
        }
    }
    /// Cursor rects only matter once the pointer rests; rebuilding them for every drag event is wasted work.
    func redraw(cursors: Bool = true) {
        updateToolbarVisibility()
        for view in views {
            view.invalidateSelection()
            if cursors { view.window?.invalidateCursorRects(for: view) }
        }
    }
    func savedOrDefaultRegion() -> CGRect {
        if let region = preferences.lastRegion,region.rect.width > 2,region.rect.height > 2 {
            if NSScreen.screens.contains(where: { $0.frame.intersects(region.rect) }) { return CaptureGeometry.clamped(region.rect,to: selectionBounds) }
            return CaptureGeometry.clamped(region.rect,to: NSScreen.pointerScreen.frame)
        }
        let frame = NSScreen.pointerScreen.frame
        return CaptureGeometry.clamped(CGRect(x: frame.midX-320,y: frame.midY-200,width: 640,height: 400),to: frame)
    }
    func changeMode() {
        clickAnchor = nil; state.drawingNew = false; state.fastDraw = false
        state.hoveredWindow = nil
        if state.mode == .lastRegion { state.rect = savedOrDefaultRegion() }
        if state.mode == .area,state.rect.width < 3 { state.rect = savedOrDefaultRegion() }
        updateWindowSelection(at: NSEvent.mouseLocation)
        rememberMode(); redraw()
    }
    @discardableResult func updateWindowSelection(at point: CGPoint) -> Bool {
        updatePointer(at: point)
        let window: SCWindow?,frame: CGRect
        if state.mode == .window {
            let hit = engine.windowHit(at: point)
            window = hit?.window; frame = hit?.frame ?? .zero
        } else if state.mode == .activeWindow {
            window = engine.activeWindow()
            frame = window.map { engine.currentFrame(of: $0) } ?? .zero
        } else { return false }
        guard window?.windowID != state.hoveredWindow?.windowID || window?.title != state.hoveredWindow?.title || frame != state.hoveredFrame else { return false }
        state.hoveredWindow = window; state.hoveredFrame = frame
        return true
    }
    @discardableResult func handleKeyboard(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        if let action = CaptureKeyAction.resolve(event.charactersIgnoringModifiers ?? "",command: flags.contains(.command),otherModifier: flags.contains(.option) || flags.contains(.control),uploadKey: preferences.uploadKey) {
            switch action {
            case .mode(let mode): state.mode = mode; changeMode()
            case .drawNew: drawNew()
            case .resetArea: resetArea()
            case .upload: uploadCapture()
            case .library: state.openLibrary?()
            case .settings: state.openSettings?()
            }
            return true
        }
        guard !flags.contains(.command),!flags.contains(.option),!flags.contains(.control) else { return false }
        switch event.keyCode {
        case 53: cancel()
        case 36,76: if flags.contains(.shift) { uploadCapture() } else { complete() }
        case 51,117: resetArea()
        case 49: state.mode = state.mode == .window ? .area : .window; changeMode()
        case 48:
            let modes = CaptureMode.toolbarOrder
            let i = modes.firstIndex(of: state.mode) ?? 0
            state.mode = modes[(i+(flags.contains(.shift) ? modes.count-1 : 1))%modes.count]; changeMode()
        case 123,124,125,126:
            guard state.mode == .area || state.mode == .lastRegion else { return false }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            state.rect = CaptureGeometry.clamped(state.rect.offsetBy(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,dy: event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0),to: selectionBounds)
            redraw()
        default: return false
        }
        return true
    }
    func complete() {
        if state.needsPermission { close(); AppController.shared.requestPermission(); AppController.shared.finishIfIdle(); return }
        let target: CaptureTarget
        switch state.mode {
        case .area,.lastRegion:
            guard state.rect.width > 2,state.rect.height > 2 else { NSSound.beep(); return }
            preferences.lastRegion = SavedRegion(state.rect)
            target = .region(state.rect)
        case .window:
            guard let window = state.hoveredWindow else { NSSound.beep(); return }
            target = .window(window)
        case .activeWindow:
            guard let window = state.hoveredWindow else { NSSound.beep(); return }
            target = .window(window)
        case .fullscreen: target = .display(targetDisplayID)
        }
        let callback = onComplete
        close(); callback?(target)
    }
}

@MainActor final class SelectionView: NSView {
    unowned let overlay: CaptureOverlay
    let displayID: CGDirectDisplayID
    let displayName: String
    var fullscreenCaption: String {
        let width = Int(bounds.width * (window?.backingScaleFactor ?? NSScreen.screens.first(where: { $0.displayID == displayID })?.backingScaleFactor ?? 1))
        let height = Int(bounds.height * (window?.backingScaleFactor ?? NSScreen.screens.first(where: { $0.displayID == displayID })?.backingScaleFactor ?? 1))
        return "\(displayName) · \(width) × \(height) px"
    }
    override var isOpaque: Bool { false }
    var anchor = CGPoint.zero
    var interaction = RegionInteraction()
    var dragging = false
    /// Set by a keyboard reset mid-gesture so the rest of the drag cannot resurrect the cleared rectangle.
    private var interactionCancelled = false
    private var lastInvalidated = CGRect.null
    func cancelInteraction() { interactionCancelled = true; dragging = false; interaction = RegionInteraction() }
    static let cameraCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 32,height: 28),flipped: false) { _ in
            NSColor.black.setFill(); NSColor.white.setStroke()
            let top = NSBezierPath()
            top.move(to: NSPoint(x: 10,y: 20)); top.line(to: NSPoint(x: 13,y: 24))
            top.line(to: NSPoint(x: 20,y: 24)); top.line(to: NSPoint(x: 23,y: 20)); top.close()
            top.lineWidth = 1.5; top.fill(); top.stroke()
            let body = NSBezierPath(roundedRect: NSRect(x: 4,y: 5,width: 25,height: 16),xRadius: 3,yRadius: 3)
            body.lineWidth = 1.5; body.fill(); body.stroke()
            let lens = NSBezierPath(ovalIn: NSRect(x: 12,y: 8,width: 9,height: 9))
            lens.lineWidth = 1.5; lens.stroke()
            return true
        }
        return NSCursor(image: image,hotSpot: NSPoint(x: 16,y: 14))
    }()
    var tracking: NSTrackingArea?
    init(frame: CGRect,overlay: CaptureOverlay,displayID: CGDirectDisplayID = CGMainDisplayID(),displayName: String = "Display") {
        self.overlay = overlay; self.displayID = displayID; self.displayName = displayName
        super.init(frame: frame)
        // This view draws only selection chrome. The desktop is never sampled or copied.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    /// The rectangle (screen coordinates) this view paints chrome for, mirroring `draw`.
    private var chromeSelection: CGRect {
        let s = overlay.state
        switch s.mode {
        case .window,.activeWindow: return s.hoveredFrame
        case .fullscreen: return window.map { $0.frame } ?? .zero
        default: return s.rect
        }
    }
    /// Repaint only what changed: the old and new selection plus room for handles, border and the size label.
    /// Everything else is the uniform dim, so a large or multi-display desktop never repaints in full per mouse event.
    func invalidateSelection(full: Bool = false) {
        guard let window else { needsDisplay = true; return }
        let current = chromeSelection
        let pad = CGSize(width: 220,height: 110)
        func chrome(_ r: CGRect) -> CGRect { r.isNull ? r : r.insetBy(dx: -pad.width,dy: -pad.height) }
        let dirty = full ? window.frame : chrome(current).union(lastInvalidated)
        lastInvalidated = chrome(current)
        let local = dirty.intersection(window.frame)
        guard !local.isNull,!local.isEmpty else { return }
        if (overlay.state.mode == .fullscreen && current.width > 0) || full || local.width*local.height > bounds.width*bounds.height*0.6 { needsDisplay = true; return }
        setNeedsDisplay(local.offsetBy(dx: -window.frame.minX,dy: -window.frame.minY))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point,from: superview)) ? self : nil }
    func screenPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds,options: [.activeAlways,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect],owner: self,userInfo: nil)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func resetCursorRects() {
        addCursorRect(bounds,cursor: overlay.state.mode == .window ? Self.cameraCursor : .crosshair)
        guard let window,(overlay.state.mode == .area || overlay.state.mode == .lastRegion),!overlay.state.drawingNew else { return }
        let rect = overlay.state.rect.offsetBy(dx: -window.frame.minX,dy: -window.frame.minY)
        let inside = rect.intersection(bounds)
        if !inside.isNull { addCursorRect(inside,cursor: .openHand) }
        for h in RegionInteraction.Handle.allCases {
            let p = h.point(in: rect)
            let cursor: NSCursor = h == .left || h == .right ? .resizeLeftRight : h == .top || h == .bottom ? .resizeUpDown : .crosshair
            let radius = RegionInteraction.handleHitRadius
            let hit = CGRect(x: p.x-radius,y: p.y-radius,width: radius*2,height: radius*2).intersection(bounds)
            if !hit.isNull { addCursorRect(hit,cursor: cursor) }
        }
    }
    override func mouseMoved(with event: NSEvent) {
        overlay.updatePointer(at: screenPoint(event))
        if let anchor = overlay.clickAnchor,(overlay.state.mode == .area || overlay.state.mode == .lastRegion) {
            overlay.state.rect = CaptureGeometry.rectangle(from: anchor,to: screenPoint(event))
            overlay.redraw(cursors: false)
        }
        if overlay.state.mode == .window {
            if overlay.updateWindowSelection(at: screenPoint(event)) { overlay.redraw() }
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        let s = overlay.state
        let point = screenPoint(event)
        interactionCancelled = false
        if s.needsPermission { overlay.complete(); return }
        if s.mode == .window { overlay.updateWindowSelection(at: point); overlay.complete(); return }
        if s.mode == .fullscreen { overlay.updatePointer(at: point); overlay.complete(); return }
        if s.mode == .activeWindow { overlay.complete(); return }
        if let first = overlay.clickAnchor {
            s.rect = CaptureGeometry.rectangle(from: first,to: point)
            guard s.rect.width > 2,s.rect.height > 2 else { overlay.redraw(); return }
            overlay.clickAnchor = nil; s.drawingNew = false; overlay.rememberMode(); overlay.redraw()
            if overlay.captureOnDraw { overlay.complete() }
            return
        }
        anchor = point; dragging = false
        interaction.begin(at: point,rect: s.rect,forceDraw: s.drawingNew || event.modifierFlags.contains(.command))
        if interaction.operation == .draw { s.rect = CGRect(origin: point,size: .zero) }
        overlay.redraw()
    }
    override func mouseDragged(with event: NSEvent) {
        guard !interactionCancelled,overlay.onComplete != nil,overlay.state.mode == .area || overlay.state.mode == .lastRegion else { return }
        dragging = true
        overlay.state.rect = interaction.update(to: screenPoint(event),bounds: overlay.selectionBounds,square: event.modifierFlags.contains(.shift))
        if interaction.operation == .move { NSCursor.closedHand.set() }
        overlay.redraw(cursors: false)
    }
    override func mouseUp(with event: NSEvent) {
        guard !interactionCancelled,overlay.onComplete != nil,overlay.state.mode == .area || overlay.state.mode == .lastRegion else { return }
        if dragging { overlay.state.rect = interaction.update(to: screenPoint(event),bounds: overlay.selectionBounds,square: event.modifierFlags.contains(.shift)) }
        // A click starts two-corner selection. Moving/resizing never captures on release.
        if interaction.operation == .draw {
            if !dragging { if overlay.clickAnchor == nil,overlay.state.rect.width < 3 { overlay.clickAnchor = anchor }; return }
            if overlay.state.rect.width < 3 || overlay.state.rect.height < 3 { return }
            overlay.state.drawingNew = false; overlay.rememberMode()
            if overlay.captureOnDraw { overlay.complete(); return }
        }
        overlay.redraw()
    }
    override func keyDown(with event: NSEvent) {
        if !overlay.handleKeyboard(event) { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,let window else { return }
        ctx.saveGState()
        ctx.setBlendMode(.copy); ctx.clear(dirtyRect)
        ctx.restoreGState()
        let s = overlay.state
        var selection = s.rect
        let selectingWindow = s.mode == .window || s.mode == .activeWindow
        if selectingWindow { selection = s.hoveredFrame }
        if s.mode == .fullscreen,displayID == overlay.targetDisplayID { selection = window.frame }
        else if s.mode == .fullscreen { selection = .zero }
        let local = selection.offsetBy(dx: -window.frame.minX,dy: -window.frame.minY)
        ctx.saveGState()
        ctx.addRect(bounds)
        if selection.width > 0 { ctx.addRect(local) }
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(NSColor.black.withAlphaComponent(selectingWindow ? 0.38 : 0.24).cgColor); ctx.fill(bounds)
        ctx.restoreGState()
        if selection.width > 0 {
            if selectingWindow { ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.13).cgColor); ctx.fill(local) }
            let border = s.mode == .fullscreen ? bounds.insetBy(dx: 2,dy: 2) : local
            let selectingArea = s.mode == .area || s.mode == .lastRegion
            ctx.saveGState()
            if selectingArea {
                // Static alternating dashes stay legible over both light and dark content.
                ctx.setLineWidth(1.5)
                ctx.setLineDash(phase: 0,lengths: [5,5])
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor); ctx.stroke(border)
                ctx.setLineDash(phase: 5,lengths: [5,5])
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.stroke(border)
            } else {
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
                ctx.setLineWidth(3); ctx.stroke(border)
                ctx.setStrokeColor((selectingWindow ? NSColor.systemBlue : NSColor.white).cgColor)
                ctx.setLineWidth(selectingWindow ? 4 : 1.5)
                if selectingWindow { ctx.addPath(CGPath(roundedRect: local.insetBy(dx: 2,dy: 2),cornerWidth: 9,cornerHeight: 9,transform: nil)); ctx.strokePath() } else { ctx.stroke(border) }
            }
            ctx.restoreGState()
            if selectingArea {
                for handle in RegionInteraction.Handle.allCases {
                    let p = handle.point(in: local)
                    let circle = NSBezierPath(ovalIn: CGRect(x: p.x-4.5,y: p.y-4.5,width: 9,height: 9))
                    NSColor.white.setFill(); circle.fill()
                    NSColor.black.withAlphaComponent(0.7).setStroke()
                    circle.lineWidth = 1; circle.stroke()
                }
            }
            let appName = s.hoveredWindow?.owningApplication?.applicationName ?? "Window"
            let title = s.hoveredWindow?.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName
            let label = s.mode == .fullscreen ? fullscreenCaption : selectingWindow ? (title == appName ? appName : "\(appName) · \(title)") : "\(Int(selection.width)) × \(Int(selection.height)) pt"
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12,weight: .semibold),.foregroundColor: NSColor.white,.paragraphStyle: paragraph]
            let size = (label as NSString).size(withAttributes: attributes)
            let width = min(max(selectingWindow ? 260 : 0,size.width + (selectingWindow ? 54 : 20)),max(80,bounds.width-32))
            let height: CGFloat = selectingWindow ? 52 : 26
            let box = CGRect(x: max(16,min(local.midX-width/2,bounds.width-width-16)),y: max(16,min(local.maxY+12,bounds.height-height-16)),width: width,height: height)
            (selectingWindow ? NSColor.systemBlue : NSColor.black.withAlphaComponent(0.85)).setFill()
            NSBezierPath(roundedRect: box,xRadius: 9,yRadius: 9).fill()
            if selectingWindow {
                if let pid = s.hoveredWindow?.owningApplication?.processID {
                    NSRunningApplication(processIdentifier: pid)?.icon?.draw(in: CGRect(x: box.minX+10,y: box.midY-14,width: 28,height: 28))
                }
                (label as NSString).draw(in: CGRect(x: box.minX+44,y: box.minY+28,width: box.width-54,height: 16),withAttributes: attributes)
                let hint = s.mode == .window ? "Click to capture this window" : "Return to capture this window"
                (hint as NSString).draw(in: CGRect(x: box.minX+44,y: box.minY+9,width: box.width-54,height: 15),withAttributes: [.font: NSFont.systemFont(ofSize: 10),.foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            } else {
                (label as NSString).draw(in: box.insetBy(dx: 10,dy: 6),withAttributes: attributes)
            }
        }
    }
}

struct CaptureToolbar: View {
    @ObservedObject var state: SelectionState
    let tooltips: CaptureTooltips
    @ObservedObject var preferences = Preferences.shared
    @State private var options = false
    var hint: String {
        if state.needsPermission { return "Screen Recording access is needed · Click Allow access to continue" }
        if state.mode == .window { return "Click a window to capture · Space: area · Esc: cancel" }
        if state.mode == .activeWindow { return "Capture the previously active application window · Return: capture" }
        if state.mode == .fullscreen { return "Move pointer to choose display · Click display or Return: capture" }
        if state.drawingNew { return (state.fastDraw || preferences.snapOnDraw) ? "Draw anywhere · Release to capture · Shift: square · Esc: cancel" : "Draw anywhere or click two corners · Return: capture · Shift: square" }
        if state.fastDraw || preferences.snapOnDraw { return "Draw a new rectangle to capture · Drag inside to move · D/N: draw anywhere" }
        return "Drag inside to move · Drag outside to redraw · N: draw anywhere · X: reset · Return: capture\(CloudSession.isAvailable ? " · \(preferences.uploadKey.uppercased()): copy link" : "")"
    }
    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 6) {
                Button { state.cancel?() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 26,height: 38)
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction).captureHelp("Cancel · Esc\nClose Easyshot without taking a screenshot.",using: tooltips).accessibilityLabel("Cancel capture")
                HStack(spacing: 3) {
                    ForEach(Array(CaptureMode.toolbarOrder.prefix(3))) { modeButton($0) }
                }
                divider
                HStack(spacing: 3) {
                    ForEach(Array(CaptureMode.toolbarOrder.suffix(2))) { modeButton($0) }
                    Button { tooltips.dismiss(); state.drawNew?() } label: {
                        Image(systemName: "pencil.and.outline").font(.system(size: 20,weight: .regular)).frame(width: 38,height: 40)
                            .background(state.drawingNew ? Color.primary.opacity(0.12) : Color.clear,in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).captureHelp("Draw New Area · D or N\nDraw anywhere, including inside the old rectangle. Hold Shift to draw a square.",using: tooltips).accessibilityLabel("Draw new area")
                    Button { tooltips.dismiss(); state.resetArea?() } label: {
                        Image(systemName: "eraser").font(.system(size: 18,weight: .regular)).frame(width: 34,height: 40)
                    }.buttonStyle(.plain).captureHelp("Reset Area · X or Delete\nClear the rectangle, any half-drawn corner and start drawing from scratch. Your saved last area is kept.",using: tooltips).accessibilityLabel("Reset area")
                }
                divider
                Button { tooltips.dismiss(); options.toggle() } label: {
                    HStack(spacing: 5) { Text("Options"); Image(systemName: "chevron.down").font(.system(size: 8,weight: .semibold)) }
                        .font(.system(size: 12)).padding(.horizontal,7).frame(height: 38)
                }.buttonStyle(.plain).captureHelp("Options\nChoose folder, clipboard, thumbnail, timer and area size. Open Settings or Library.",using: tooltips).accessibilityLabel("Capture options")
                    .popover(isPresented: $options,arrowEdge: .top) { optionsView }
                if CloudSession.isAvailable {
                    Button { tooltips.dismiss(); state.uploadCapture?() } label: {
                        Image(systemName: "link.badge.plus").font(.system(size: 18,weight: .regular)).frame(width: 34,height: 40)
                    }.buttonStyle(.plain).captureHelp("Capture & Copy Link · \(preferences.uploadKey.uppercased()) or ⇧Return\nUpload the capture to Easyshot Cloud and copy a shareable link, for pasting over SSH or into chat.",using: tooltips).accessibilityLabel("Capture and copy link")
                }
                Button(state.needsPermission ? "Allow Access" : state.purpose == "Recording" ? "Record" : state.purpose == "Upload" ? "Upload" : "Capture") { state.capture?() }
                    .buttonStyle(.glassProminent).tint(.accentColor).controlSize(.large).keyboardShortcut(.defaultAction)
                    .font(.system(size: 12,weight: .medium)).captureHelp("\(state.needsPermission ? "Allow Screen Recording Access" : state.purpose == "Recording" ? "Record · Return" : "Capture · Return")\n\(hint)",using: tooltips)
                    .accessibilityHint(hint)
            }.padding(.horizontal,10).padding(.vertical,9)
                .glassEffect(.regular,in: RoundedRectangle(cornerRadius: 15))
        }.frame(maxWidth: .infinity,maxHeight: .infinity)
    }
    var divider: some View { Divider().frame(height: 29).padding(.horizontal,2) }
    func modeButton(_ mode: CaptureMode) -> some View {
        Button { tooltips.dismiss(); state.mode = mode; state.changed?() } label: {
            VStack(spacing: 0) {
                ScreenshotModeSymbol(mode: mode).frame(height: 28)
                Text(mode.key).font(.system(size: 9,weight: .medium,design: .monospaced)).foregroundStyle(.secondary)
            }.frame(width: 38,height: 40)
                .background(state.mode == mode && !state.drawingNew ? Color.primary.opacity(0.12) : Color.clear,in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).captureHelp(mode.captureTooltip,using: tooltips).accessibilityLabel(mode.title)
    }
    var optionsView: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("Save To").font(.system(size: 11,weight: .semibold)).foregroundStyle(.secondary)
            Toggle("Screenshots folder",isOn: $preferences.saveToDisk)
                .captureHelp("Save File\nSave each screenshot in your configured folder.",using: tooltips)
            Text(preferences.folderDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Toggle("Also copy to clipboard",isOn: $preferences.copyToClipboard)
                .captureHelp("Copy to Clipboard\nCopy the screenshot image and its saved file URL.",using: tooltips)
            Toggle("Snap on draw",isOn: Binding(get: { preferences.snapOnDraw || state.fastDraw },set: { preferences.snapOnDraw = $0; state.fastDraw = false }))
                .captureHelp("Snap on Draw\nCapture and close as soon as you finish a new rectangle, by dragging or clicking two corners. Moving and resizing still wait for Capture.",using: tooltips)
            Toggle("Quick Preview · 3 seconds",isOn: $preferences.showPreview)
                .captureHelp("Quick Preview\nShow a three-second thumbnail. Rapid captures replace it; click it to edit.",using: tooltips)
            Divider()
            Text("Timer").font(.system(size: 11,weight: .semibold)).foregroundStyle(.secondary)
            Picker("Timer",selection: $preferences.delay) { Text("None").tag(0.0); Text("3s").tag(3.0); Text("5s").tag(5.0); Text("10s").tag(10.0) }.pickerStyle(.segmented).labelsHidden()
                .captureHelp("Capture Timer\nWait this long after you click Capture before taking the screenshot.",using: tooltips)
            Divider()
            Text("Area size · points").font(.subheadline)
            HStack {
                TextField("Width",text: $state.fixedWidth).accessibilityLabel("Area width")
                    .captureHelp("Area Width\nWidth in screen points. Apply sets the rectangle to this size.",using: tooltips)
                Text("×")
                TextField("Height",text: $state.fixedHeight).accessibilityLabel("Area height")
                    .captureHelp("Area Height\nHeight in screen points. Retina screenshots use the native pixel density.",using: tooltips)
                Button("Apply") { tooltips.dismiss(); state.applySize?(); options = false }
                    .captureHelp("Apply Area Size\nResize and center the rectangle using the width and height above.",using: tooltips)
            }.textFieldStyle(.roundedBorder)
            if !preferences.presets.isEmpty {
                Text("Saved areas").font(.subheadline)
                ScrollView {
                    VStack(alignment: .leading,spacing: 8) {
                        ForEach(preferences.presets) { preset in
                            Button(preset.name) { tooltips.dismiss(); state.rect = preset.region.rect; state.mode = .area; state.drawingNew = false; state.changed?(); options = false }
                                .captureHelp("Saved Area\nRestore the \(preset.name) rectangle.",using: tooltips)
                        }
                    }.frame(maxWidth: .infinity,alignment: .leading)
                }.frame(maxHeight: 130)

            }
            Divider()
            Button("Settings…") { tooltips.dismiss(); options = false; state.openSettings?() }
                .captureHelp("Settings · ⌘,\nConfigure folder, format, clipboard, previews and capture preferences.",using: tooltips)
            Button("Open Library…") { tooltips.dismiss(); options = false; state.openLibrary?() }
                .captureHelp("Library · ⌘L\nBrowse saved captures, edit, pin, copy text and share.",using: tooltips)
            Text("1: screen · 2: window · 3: area\n4: active window · 5: last area\nD/N: draw new · X/Delete: reset area\n\(CloudSession.isAvailable ? "\(preferences.uploadKey.uppercased()) / ⇧Return: capture & copy link · " : "")Return: capture · Esc: close").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 310)
            .background(CapturePopoverLevel())
    }
}

// Keep the options popover above the screen-covering selection windows.
struct CapturePopoverLevel: NSViewRepresentable {
    func makeNSView(context: Context) -> LevelView { LevelView() }
    func updateNSView(_ view: LevelView,context: Context) {}
    final class LevelView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+2)
        }
    }
}

/// The screen/window/area silhouettes follow the native Screenshot toolbar.
struct ScreenshotModeSymbol: View {
    let mode: CaptureMode
    var body: some View {
        if mode == .fullscreen || mode == .window || mode == .area {
            Canvas { context,size in
                let r = CGRect(x: 2,y: 4,width: 25,height: 20)
                let frame = Path(roundedRect: r,cornerRadius: 3)
                context.stroke(frame,with: .color(.primary.opacity(0.72)),style: StrokeStyle(lineWidth: 1.8,dash: mode == .area ? [4,2] : []))
                if mode == .fullscreen {
                    var titlebar = Path(); titlebar.move(to: CGPoint(x: 2,y: 9)); titlebar.addLine(to: CGPoint(x: 27,y: 9))
                    context.stroke(titlebar,with: .color(.primary.opacity(0.72)),lineWidth: 1.7)
                    context.fill(Path(roundedRect: CGRect(x: 6,y: 17,width: 17,height: 3),cornerRadius: 1),with: .color(.primary.opacity(0.72)))
                }
                if mode == .window {
                    for x in [CGFloat(6),10,14] {
                        context.fill(Path(ellipseIn: CGRect(x: x,y: 7,width: 1.6,height: 1.6)),with: .color(.primary.opacity(0.72)))
                    }
                }
            }.frame(width: 29,height: 28)
        } else {
            Image(systemName: mode == .activeWindow ? "macwindow.on.rectangle" : "arrow.counterclockwise")
                .font(.system(size: 21,weight: .regular)).foregroundStyle(.primary.opacity(0.72))
        }
    }
}
