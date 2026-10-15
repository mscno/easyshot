import AppKit
import EasyshotCore
import AVFoundation
import ScreenCaptureKit

@MainActor enum Diagnostics {
    static func startupBenchmark(controller: AppController) async -> Int32 {
        let selection = Preferences.shared.selection
        defer { Preferences.shared.selection = selection }
        Preferences.shared.selection = CaptureSelection(mode: .area)
        controller.rememberApplication(NSWorkspace.shared.frontmostApplication)
        controller.scheduleLauncher()
        for _ in 0..<2000 {
            if StartupTrace.milestones["selectorVisible"] != nil { break }
            if controller.overlay.onComplete == nil && !controller.launcherPending { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let ready = StartupTrace.milestones["selectorVisible"] != nil
        StartupTrace.report()
        controller.overlay.close()
        for _ in 0..<1000 {
            if controller.pendingExports == 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ready ? 0 : 1
    }
    /// Native window diagnostics; view events are called directly, never posted to the OS.
    static func liveSelectionTest(controller: AppController) async -> Int32 {
        let suite = "Easyshot.TransparentSelectionTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.overlay = CaptureOverlay(engine: controller.engine,preferences: Preferences(defaults: defaults))
        controller.rememberApplication(NSWorkspace.shared.frontmostApplication)
        var checks = 0; var failures = 0
        func check(_ value: Bool,_ name: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL"): \(name)"); fflush(stdout) }
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screen = NSScreen.pointerScreen
        let underlay = NSWindow(contentRect: CGRect(x: screen.frame.midX-180,y: screen.frame.midY-100,width: 360,height: 200),styleMask: .borderless,backing: .buffered,defer: false)
        underlay.isReleasedWhenClosed = false
        underlay.contentView!.wantsLayer = true
        underlay.contentView!.layer!.backgroundColor = NSColor.systemOrange.cgColor
        let moving = CALayer()
        moving.bounds = CGRect(x: 0,y: 0,width: 40,height: 40); moving.position = CGPoint(x: 50,y: 100)
        moving.backgroundColor = NSColor.systemBlue.cgColor
        underlay.contentView!.layer!.addSublayer(moving)
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = 50; animation.toValue = 310; animation.duration = 0.8
        animation.autoreverses = true; animation.repeatCount = .infinity
        moving.add(animation,forKey: "native-motion")
        underlay.orderFrontRegardless()
        defer { controller.overlay.close(); underlay.close() }
        do {
            let overlay = controller.overlay
            overlay.show(mode: .area,purpose: "Screenshot") { _ in }
            check(overlay.toolbar?.isVisible == true && overlay.windows.count == NSScreen.screens.count && controller.sessionActivity.contains(.selection),"bar and all transparent input surfaces appear immediately")
            check(controller.engine.content == nil,"area startup does not request desktop frames or capture metadata")
            check(overlay.windows.allSatisfy { !$0.isOpaque && $0.backgroundColor.alphaComponent == 0 && $0.alphaValue == 1 && !$0.ignoresMouseEvents && $0.contentView?.isOpaque == false },"selector has a clear native backing and independently accepts input")
            check(overlay.windows.contains { $0.isKeyWindow && $0.firstResponder === $0.contentView },"nonactivating selector owns local keyboard focus")
            // Let WindowServer commit ordered windows before querying its input map.
            try await Task.sleep(for: .milliseconds(80))
            check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID,"opening the nonactivating selector keeps the underlying application active")
            var mouseRouting = true
            for mode in CaptureMode.toolbarOrder {
                overlay.state.mode = mode
                for window in overlay.windows {
                    overlay.targetDisplayID = (window.contentView as! SelectionView).displayID
                    let rect = CGRect(x: window.frame.midX-100,y: window.frame.midY-60,width: 200,height: 120)
                    overlay.state.rect = rect; overlay.state.hoveredFrame = rect
                    overlay.redraw(); window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                    let points = [CGPoint(x: rect.midX,y: rect.midY),CGPoint(x: rect.maxX,y: rect.midY),CGPoint(x: window.frame.minX+30,y: window.frame.minY+90)]
                    for point in points {
                        let hit = NSWindow.windowNumber(at: point,belowWindowWithWindowNumber: 0)
                        if hit != window.windowNumber { print("ROUTING mode=\(mode) screen=\(window.frame) point=\(point) expected=\(window.windowNumber) actual=\(hit)") }
                        mouseRouting = mouseRouting && hit == window.windowNumber
                    }
                }
            }
            check(mouseRouting,"WindowServer routes clear interiors, handles and outside clicks to the overlay on every screen in all five modes")
            overlay.state.mode = .area; overlay.state.rect = underlay.frame
            overlay.redraw()
            try await Task.sleep(for: .milliseconds(120))
            let before = moving.presentation()?.position.x
            for step in 0..<12 {
                overlay.state.rect = underlay.frame.offsetBy(dx: CGFloat(step)*4,dy: 0)
                overlay.redraw()
                try await Task.sleep(for: .milliseconds(20))
            }
            let after = moving.presentation()?.position.x
            check(underlay.occlusionState.contains(.visible),"transparent selector leaves the animated underlying window visible to WindowServer")
            check(before != nil && after != nil && abs(before!-after!) > 5,"native underlay animation advances while the selection is moved repeatedly")
            let tips = controller.overlay.tooltips
            tips.hover("Full Screen · 1\nCapture the display under your pointer.",active: true)
            tips.hover("Area · 3\nMove or resize your rectangle.",active: true)
            for _ in 0..<50 { if tips.panel?.isVisible == true { break }; try await Task.sleep(for: .milliseconds(20)) }
            check(tips.panel?.isVisible == true && tips.panel!.level.rawValue > NSWindow.Level.screenSaver.rawValue && tips.panel!.ignoresMouseEvents && tips.panel!.frame.width > 0 && tips.panel!.frame.height > 0,"hover tooltip displays above the selection and never intercepts input")
            tips.hover("Full Screen · 1\nCapture the display under your pointer.",active: false)
            check(tips.panel?.isVisible == true && tips.currentText?.hasPrefix("Area") == true,"late hover exit from a previous button does not dismiss the current tooltip")
            tips.hover("Area · 3\nMove or resize your rectangle.",active: false)
            check(tips.panel == nil && tips.currentText == nil,"leaving a toolbar button dismisses its tooltip immediately")
            guard let bar = overlay.toolbar else { throw ShotError.message("Selector was dismissed during native diagnostics.") }
            overlay.state.mode = .area
            overlay.state.rect = bar.frame.insetBy(dx: -35,dy: -20)
            overlay.redraw()
            try await Task.sleep(for: .milliseconds(250))
            check(overlay.toolbarOccluded && bar.isVisible && bar.alphaValue < 0.01 && bar.ignoresMouseEvents && overlay.state.rect.contains(bar.frame),"overlapping rectangle fades toolbar to zero while preserving the selection and panel")
            let local = CGPoint(x: bar.frame.midX,y: bar.frame.midY)
            guard let inputWindow = overlay.windows.first(where: { $0.frame.contains(local) }) else { throw ShotError.message("Selector was dismissed during native diagnostics.") }
            let view = inputWindow.contentView as! SelectionView
            check(NSWindow.windowNumber(at: local,belowWindowWithWindowNumber: 0) == inputWindow.windowNumber,"faded toolbar routes WindowServer input to selector instead of the underlying app")
            let mouse = NSEvent.mouseEvent(with: .leftMouseDown,location: inputWindow.convertPoint(fromScreen: local),modifierFlags: [],timestamp: 0,windowNumber: inputWindow.windowNumber,context: nil,eventNumber: 0,clickCount: 1,pressure: 1)!
            overlay.clickAnchor = nil; overlay.state.drawingNew = false
            view.mouseDown(with: mouse)
            check(view.interaction.operation == .move && !inputWindow.ignoresMouseEvents,"faded toolbar leaves the transparent selection surface available to move the rectangle")
            overlay.state.rect = CGRect(x: bar.frame.minX,y: bar.frame.maxY+50,width: 100,height: 100)
            overlay.redraw()
            try await Task.sleep(for: .milliseconds(300))
            check(!overlay.toolbarOccluded && bar.alphaValue > 0.99 && !bar.ignoresMouseEvents,"toolbar fades back and accepts clicks once the rectangle clears it")
            overlay.state.rect = bar.frame
            overlay.redraw()
            overlay.state.mode = .window; overlay.redraw()
            try await Task.sleep(for: .milliseconds(300))
            check(!overlay.toolbarOccluded && bar.alphaValue > 0.99 && !bar.ignoresMouseEvents,"rapid overlap and mode changes reverse the fade without leaving invisible controls")

            overlay.close()
            check(overlay.windowRefreshTask == nil && overlay.windows.isEmpty && overlay.toolbar == nil,"closing selector cancels metadata work and removes all surfaces")
            overlay.show(mode: .area,purpose: "Screenshot") { _ in }
            let escape = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: 0,context: nil,characters: "\u{1b}",charactersIgnoringModifiers: "\u{1b}",isARepeat: false,keyCode: 53)!
            check(overlay.interceptEscape(escape) && overlay.toolbar == nil && overlay.onComplete == nil,"Escape immediately cancels the native selector")
            try await Task.sleep(for: .milliseconds(400))
            check(overlay.windows.isEmpty && overlay.windowRefreshTask == nil,"cancelled selector cannot recreate windows or leave background work running")
            print("\(checks-failures)/\(checks) native-transparent selector checks passed.")
            return failures == 0 ? 0 : 1
        } catch { print("TRANSPARENT SELECTOR TEST FAILED: \(error.localizedDescription)"); return 1 }
    }
    static func captureTest(controller: AppController) async -> Int32 {
        let engine = controller.engine
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("easyshot-capture-tests-\(UUID().uuidString)")
        let store = ClipStore(directory: folder.appendingPathComponent("History"))
        var checks = 0; var failures = 0
        func check(_ result: Bool,_ name: String) { checks += 1; if !result { failures += 1 }; print("\(result ? "PASS" : "FAIL"): \(name)") }
        do {
            try await engine.refresh()
            guard let screen = NSScreen.screens.first else { throw ShotError.message("No display.") }
            check(!engine.windows.isEmpty && engine.windows.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 },"window targets retain valid frames for hover selection")
            let full = try await engine.image(.display(screen.displayID))
            check(full.width > 0 && full.height > 0,"full display capture")
            _ = try store.write(image: full,kind: "Screen",destination: folder,copyOverride: false)
            let rect = CGRect(x: screen.frame.minX+50,y: screen.frame.minY+50,width: 301,height: 203)
            let region = try await engine.image(.region(rect))
            check(region.width == Int(301*screen.backingScaleFactor) && region.height == Int(203*screen.backingScaleFactor),"area capture respects native Retina pixel dimensions")
            let clip = try store.write(image: region,kind: "Area",destination: folder,copyOverride: false)
            let repeatImage = try await engine.image(.region(rect))
            check(repeatImage.width == region.width && repeatImage.height == region.height,"repeat same region")
            if let window = engine.windows.first(where: { $0.frame.width > 500 && $0.frame.height > 300 }) {
                let screenshot = try await engine.image(.window(window))
                check(screenshot.width > 0 && screenshot.height > 0,"window capture")
                _ = try store.write(image: screenshot,kind: "Window",destination: folder,copyOverride: false)
                let center = CGPoint(x: window.frame.midX,y: NSScreen.primaryHeight-window.frame.midY)
                check(engine.window(at: center) != nil,"window hit testing")
                if let pid = window.owningApplication?.processID { engine.previousApp = NSRunningApplication(processIdentifier: pid) }
                check(engine.activeWindow()?.owningApplication?.processID == window.owningApplication?.processID,"active-window routing")
            }
            let clipboard = NSPasteboard.general
            let oldItems = clipboard.pasteboardItems?.map { source -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in source.types { if let data = source.data(forType: type) { copy.setData(data,forType: type) } }
                return copy
            } ?? []
            store.copy(clip)
            check(clipboard.data(forType: .png) != nil,"clipboard contains PNG image")
            check(clipboard.readObjects(forClasses: [NSURL.self],options: nil)?.isEmpty == false,"clipboard also contains saved file URL")
            let fastClip = try store.write(image: region,kind: "Clipboard pipeline",destination: folder,copyOverride: true)
            let savedBytes = try Data(contentsOf: fastClip.url)
            check(fastClip.url.pathExtension != "png" || clipboard.data(forType: .png) == savedBytes,"new PNG captures preserve the saved PNG bytes on the clipboard")
            let pasted = NSImage(pasteboard: clipboard)?.cgImage(forProposedRect: nil,context: nil,hints: nil)
            check(pasted?.width == region.width && pasted?.height == region.height,"in-memory capture export pastes at the original native pixel dimensions")
            let fileURLs = clipboard.readObjects(forClasses: [NSURL.self],options: nil) as? [URL] ?? []
            check(fileURLs.contains(fastClip.url),"in-memory capture export keeps the correct saved file URL")
            clipboard.clearContents(); if !oldItems.isEmpty { clipboard.writeObjects(oldItems) }
            let (filter,config) = try engine.configuration(for: .region(rect),recording: true)
            let url = folder.appendingPathComponent("test-recording.mp4")
            let recorder = Recorder()
            let effects = RecordingEffects(source: CaptureGeometry.quartz(rect,primaryHeight: NSScreen.primaryHeight),clicks: true,keys: true)
            effects.addClick(CGPoint(x: rect.midX,y: NSScreen.primaryHeight-rect.midY)); effects.setKey("⌘K")
            try await recorder.start(filter: filter,configuration: config,url: url,effects: effects)
            try await Task.sleep(for: .seconds(2))
            try await recorder.stop()
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            check(duration > 0.5,"ScreenCaptureKit recording with composited effects produces playable MP4")
            let gif = folder.appendingPathComponent("test-recording.gif")
            try await VideoTools.gif(url,to: gif,start: 0,end: min(1,duration))
            check(FileManager.default.fileExists(atPath: gif.path),"GIF export")
            let trimmed = folder.appendingPathComponent("trimmed.mp4")
            try await VideoTools.trim(url,to: trimmed,start: 0,end: min(1,duration))
            check(FileManager.default.fileExists(atPath: trimmed.path),"trimmed video export")
            print("\(checks-failures)/\(checks) capture checks passed. Artifacts: \(folder.path)")
            return failures == 0 ? 0 : 1
        } catch { print("CAPTURE TEST BLOCKED/FAILED: \(error.localizedDescription)"); return 1 }
    }
    static func run() async -> Int32 {
        var failures = 0; var checks = 0
        func check(_ condition: @autoclosure () -> Bool,_ name: String) {
            checks += 1
            if condition() { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 }
        }
        let suiteName = "Easyshot.PreferencesTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fresh = Preferences(defaults: defaults)
        check(fresh.copyToClipboard && fresh.saveToDisk && fresh.format == "png","fresh install saves PNG and copies to clipboard")
        check(fresh.selection == CaptureSelection() && !fresh.showPreview,"fresh install starts in area mode and exits without preview")
        check(!fresh.snapOnDraw,"snap on draw is off by default")
        fresh.snapOnDraw = true
        check(Preferences(defaults: defaults).snapOnDraw,"snap on draw persists across launches")
        fresh.selection = CaptureSelection(mode: .window)
        check(Preferences(defaults: defaults).selection.mode == .window,"preferences remember capture mode after restart")
        fresh.selection = CaptureSelection(mode: .area,drawNew: true)
        check(Preferences(defaults: defaults).selection.drawNew,"preferences remember draw-new mode after restart")
        #if APP_STORE
        check(!fresh.hasCaptureFolderPermission,"Store edition requires a folder grant before external saving")
        defaults.set(Data([0,1,2,3]),forKey: "captureFolderBookmark")
        defaults.set(["/missing-folder": Data([4,5])],forKey: "captureFolderBookmarks")
        check(!Preferences(defaults: defaults).hasCaptureFolderPermission,"invalid current and history bookmarks recover without a prompt or crash")
        defaults.set(true,forKey: "showKeys")
        check(!Preferences(defaults: defaults).showKeys,"Store edition cannot enable global keystroke captions from old preferences")
        defaults.removeObject(forKey: "captureFolderBookmark")
        defaults.removeObject(forKey: "captureFolderBookmarks")
        #endif
        if let screen = NSScreen.screens.first {
            let selector = CaptureOverlay(engine: CaptureEngine(),preferences: fresh)
            let window = selector.makeSelectionWindow(for: screen)
            let view = window.contentView as! SelectionView
            check(!window.isOpaque && window.alphaValue == 1 && !window.ignoresMouseEvents && window.acceptsMouseMovedEvents && window.backgroundColor.alphaComponent == 0 && !view.isOpaque,"transparent window accepts mouse input without painting desktop pixels")
            check(view.acceptsFirstMouse(for: nil) && view.hitTest(CGPoint(x: 150,y: 150)) === view,"selected area accepts first click and remains hit-testable")
            selector.state.mode = .area
            selector.state.rect = CGRect(x: screen.frame.minX+100,y: screen.frame.minY+100,width: 200,height: 120)
            var captures = 0; selector.onComplete = { _ in captures += 1 }
            func event(_ type: NSEvent.EventType,_ x: CGFloat,_ y: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type,location: CGPoint(x: x,y: y),modifierFlags: [],timestamp: 0,windowNumber: window.windowNumber,context: nil,eventNumber: 0,clickCount: 1,pressure: 1)!
            }
            // Direct calls to an offscreen view: no OS event injection or GUI automation.
            view.mouseDown(with: event(.leftMouseDown,150,150))
            view.mouseDragged(with: event(.leftMouseDragged,185,174))
            view.mouseUp(with: event(.leftMouseUp,190,180))
            check(selector.state.rect == CGRect(x: screen.frame.minX+140,y: screen.frame.minY+130,width: 200,height: 120),"view event handling moves the rectangle using event coordinates, including final mouse-up")
            check(captures == 0 && selector.onComplete != nil,"moving a rectangle never captures or dismisses selection")
            view.mouseDown(with: event(.leftMouseDown,340,190))
            view.mouseDragged(with: event(.leftMouseDragged,380,190))
            view.mouseUp(with: event(.leftMouseUp,385,190))
            check(selector.state.rect == CGRect(x: screen.frame.minX+140,y: screen.frame.minY+130,width: 245,height: 120) && captures == 0,"view events resize the right handle without capturing or dismissing selection")
            if let drawing = EditorModel.context(width: Int(view.bounds.width),height: Int(view.bounds.height)) {
                func pixels() -> NSBitmapImageRep {
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: drawing,flipped: false)
                    view.draw(view.bounds); NSGraphicsContext.current = nil
                    return NSBitmapImageRep(cgImage: drawing.makeImage()!)
                }
                _ = pixels(); let rendered = pixels()
                let center = CGPoint(x: 200,y: CGFloat(drawing.height)-180)
                check(rendered.colorAt(x: Int(center.x),y: Int(center.y))?.alphaComponent == 0,"selected interior is fully transparent after repeated redraws")
                let outsideAlpha = rendered.colorAt(x: 50,y: 50)?.alphaComponent ?? 1
                check(abs(outsideAlpha-0.24) < 0.02,"outside dimming remains translucent and does not accumulate across redraws")
                var transparentModes = true
                for mode in CaptureMode.toolbarOrder {
                    selector.state.mode = mode; selector.state.hoveredFrame = selector.state.rect
                    selector.targetDisplayID = screen.displayID
                    let alpha = pixels().colorAt(x: Int(center.x),y: Int(center.y))?.alphaComponent ?? 1
                    transparentModes = transparentModes && abs(alpha - ((mode == .window || mode == .activeWindow) ? 0.13 : 0)) < 0.02
                }
                check(transparentModes,"all five modes preserve native transparency with only a translucent window tint")
                selector.state.mode = .window; selector.state.hoveredWindow = nil; selector.state.hoveredFrame = .zero
                let emptyAlpha = pixels().colorAt(x: Int(center.x),y: Int(center.y))?.alphaComponent ?? 1
                check(abs(emptyAlpha-0.38) < 0.02,"empty window hover clears the previous highlight")
                selector.state.mode = .fullscreen; selector.targetDisplayID = screen.displayID
                let width = Int(screen.frame.width*screen.backingScaleFactor),height = Int(screen.frame.height*screen.backingScaleFactor)
                check(view.fullscreenCaption.contains(screen.localizedName) && view.fullscreenCaption.contains("\(width) × \(height) px"),"full-screen caption identifies native display name and pixel resolution without a screenshot")
                check((pixels().colorAt(x: 2,y: drawing.height/2)?.alphaComponent ?? 0) > 0.4,"full-screen border is visibly drawn inside display edges")
                var routed = true
                for display in NSScreen.screens {
                    selector.updatePointer(at: CGPoint(x: display.frame.midX,y: display.frame.midY))
                    routed = routed && selector.targetDisplayID == display.displayID
                }
                check(routed,"full-screen capture target follows the pointer across every connected display")
                selector.state.mode = .area
                selector.state.rect = selector.state.rect.offsetBy(dx: 300,dy: 0)
                let moved = pixels()
                let oldAlpha = moved.colorAt(x: Int(center.x),y: Int(center.y))?.alphaComponent ?? 1
                check(abs(oldAlpha-0.24) < 0.02 && moved.colorAt(x: 500,y: Int(center.y))?.alphaComponent == 0,"moving selection clears its old hole and reveals the new one without desktop pixels")
            }
            let bar = CaptureToolbarPanel(contentRect: CGRect(x: 0,y: 0,width: 560,height: 62),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            bar.overlay = selector
            var keysMatch = true
            for mode in CaptureMode.toolbarOrder {
                let key = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: bar.windowNumber,context: nil,characters: mode.key,charactersIgnoringModifiers: mode.key,isARepeat: false,keyCode: 0)!
                keysMatch = bar.performKeyEquivalent(with: key) && selector.state.mode == mode && keysMatch
            }
            check(keysMatch,"toolbar routes keys 1–5 in the same left-to-right order as its icons")
            // Exercise capture-on-draw callbacks offscreen; never save a screenshot or post OS input.
            var drawnRegion: CGRect?
            func armDraw() {
                selector.state.mode = .area; selector.state.fastDraw = false; selector.state.drawingNew = false
                selector.clickAnchor = nil
                selector.state.rect = CGRect(x: screen.frame.minX+100,y: screen.frame.minY+100,width: 200,height: 120)
                selector.onComplete = { target in captures += 1; if case .region(let rect) = target { drawnRegion = rect } }
            }
            fresh.snapOnDraw = false; armDraw()
            view.mouseDown(with: event(.leftMouseDown,500,400))
            view.mouseDragged(with: event(.leftMouseDragged,550,450))
            view.mouseUp(with: event(.leftMouseUp,560,470))
            check(captures == 0 && selector.onComplete != nil && drawnRegion == nil,"snap off leaves a newly drawn rectangle ready for manual Capture")
            fresh.snapOnDraw = true; armDraw()
            view.mouseDown(with: event(.leftMouseDown,500,400))
            view.mouseDragged(with: event(.leftMouseDragged,550,450))
            view.mouseUp(with: event(.leftMouseUp,560,470))
            check(captures == 1 && selector.onComplete == nil && drawnRegion == CGRect(x: screen.frame.minX+500,y: screen.frame.minY+400,width: 60,height: 70),"snap on captures exactly once with final mouse-up coordinates and closes the selector")
            armDraw(); selector.drawNew()
            view.mouseDown(with: event(.leftMouseDown,150,150))
            view.mouseDragged(with: event(.leftMouseDragged,230,220))
            view.mouseUp(with: event(.leftMouseUp,230,220))
            check(captures == 2 && selector.onComplete == nil,"Draw New respects snap on even inside the previous rectangle")
            armDraw(); selector.drawNew()
            view.mouseDown(with: event(.leftMouseDown,100,100)); view.mouseUp(with: event(.leftMouseUp,100,100))
            check(captures == 2 && selector.onComplete != nil && selector.clickAnchor != nil,"first corner click waits for the second corner instead of snapping an empty rectangle")
            view.mouseDown(with: event(.leftMouseDown,160,180)); view.mouseUp(with: event(.leftMouseUp,160,180))
            check(captures == 3 && selector.onComplete == nil && drawnRegion?.size == CGSize(width: 60,height: 80),"second corner click captures exactly once and closes with snap on")
            armDraw(); selector.drawNew()
            view.mouseDown(with: event(.leftMouseDown,100,100))
            view.mouseDragged(with: event(.leftMouseDragged,102,102)); view.mouseUp(with: event(.leftMouseUp,102,102))
            check(captures == 3 && selector.onComplete != nil,"tiny invalid rectangles never snap or dismiss the selector")
            selector.state.mode = .fullscreen; selector.changeMode()
            selector.state.mode = .area; selector.changeMode()
            check(selector.captureOnDraw,"changing modes preserves the snap-on-draw preference")
            // Stop tests touching AppController's normal preferences or visible windows.
            selector.onComplete = nil; window.orderOut(nil)
        } else { check(false,"display geometry available for offscreen selection tests") }
        let tips = CaptureTooltips()
        tips.hover("Area",active: true); tips.hover("Full Screen",active: true); tips.hover("Area",active: false)
        check(tips.currentText == "Full Screen","moving between toolbar controls keeps the newest tooltip request")
        tips.dismiss()
        try? await Task.sleep(for: .milliseconds(500))
        check(tips.panel == nil && tips.currentText == nil,"cancelled hover delay never creates a late tooltip window")
        let app = AppController.shared
        app.launcherPending = true; check(!app.sessionActivity.shouldExit,"pending reopen prevents exit before launcher routing")
        app.launcherPending = false; app.busy = true
        app.capture(.fullscreen); app.capture(.window); app.capture(.area)
        check(app.pendingCapture?.mode == .area && app.sessionActivity.contains(.processing),"rapid capture requests keep the newest mode while processing finishes")
        app.pendingCapture = nil; app.busy = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("easyshot-tests-\(UUID().uuidString)")
        let store = ClipStore(directory: folder.appendingPathComponent("History"))
        guard let context = EditorModel.context(width: 500,height: 320) else { return 1 }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0,y: 0,width: 500,height: 320))
        let graphics = NSGraphicsContext(cgContext: context,flipped: false)
        NSGraphicsContext.current = graphics
        ("Easyshot 2026" as NSString).draw(at: CGPoint(x: 45,y: 170),withAttributes: [.font: NSFont.systemFont(ofSize: 45,weight: .semibold),.foregroundColor: NSColor.black])
        NSGraphicsContext.current = nil
        let image = context.makeImage()!
        let original = Clip(path: folder.appendingPathComponent("original.png").path,kind: "Test",width: 500,height: 320)
        let editor = EditorModel(image: image,clip: original,store: store)
        editor.add(Mark(tool: .redact,points: [CGPoint(x: 30,y: 30),CGPoint(x: 130,y: 80)],color: [1,0,0,1],width: 6))
        let rendered = editor.render()!
        let rep = NSBitmapImageRep(cgImage: rendered)
        let black = rep.colorAt(x: 60,y: 260)?.usingColorSpace(.sRGB)
        check((black?.redComponent ?? 1) < 0.01 && (black?.greenComponent ?? 1) < 0.01,"solid redaction changes exported pixels")
        editor.undo(); check(editor.marks.isEmpty,"annotation undo")
        editor.redo(); check(editor.marks.count == 1,"annotation redo")
        for tool in MarkTool.allCases.filter({ $0 != .crop }) {
            editor.add(Mark(tool: tool,points: [CGPoint(x: 150,y: 30),CGPoint(x: 300,y: 90)],color: [1,0,0,1],width: 4,text: "2"))
            check(editor.render() != nil,"render \(tool.rawValue)")
        }
        editor.padding = 40
        let padded = editor.render()!
        check(padded.width == 580 && padded.height == 400,"background export dimensions")
        editor.add(Mark(tool: .crop,points: [CGPoint(x: 20,y: 20),CGPoint(x: 420,y: 220)],color: [1,0,0,1],width: 2))
        check(editor.image.width == 400 && editor.image.height == 200 && editor.marks.isEmpty,"crop flattens annotations and preserves size")
        editor.resizeWidth = "200"; editor.resize()
        check(editor.image.width == 200 && editor.image.height == 100,"resize preserves aspect ratio")
        editor.transform(rotate: true)
        check(editor.image.width == 100 && editor.image.height == 200,"rotation swaps dimensions")
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: 320,kCVPixelBufferHeightKey as String: 200,kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&pool)
        if let pool {
            var input: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil,pool,&input)
            if let input {
                CVPixelBufferLockBaseAddress(input,[])
                memset(CVPixelBufferGetBaseAddress(input),255,CVPixelBufferGetBytesPerRow(input)*200)
                CVPixelBufferUnlockBaseAddress(input,[])
                let effects = RecordingEffects(source: CGRect(x: 0,y: 0,width: 320,height: 200),clicks: true,keys: true)
                effects.addClick(CGPoint(x: 150,y: 70)); effects.setKey("⌘K")
                if let output = effects.composite(input,pool: pool) {
                    CVPixelBufferLockBaseAddress(output,.readOnly)
                    let pointer = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
                    let bytes = UnsafeBufferPointer(start: pointer,count: CVPixelBufferGetBytesPerRow(output)*200)
                    check(bytes.filter { $0 < 100 }.count > 100,"click and command-key effects change output pixels")
                    check(bytes[0] == 255 && bytes[1] == 255 && bytes[2] == 255,"effects preserve untouched video pixels")
                    CVPixelBufferUnlockBaseAddress(output,.readOnly)
                } else { check(false,"recording effect composition") }
            }
        }
        do {
            let a = try store.write(image: image,kind: "Test",destination: folder,copyOverride: false)
            let b = try store.write(image: image,kind: "Test",destination: folder,copyOverride: false)
            check(a.path != b.path && FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path),"atomic image save with unique filenames")
            let restored = ClipStore(directory: store.support)
            check(restored.clips.count == 2,"history survives reload")
            restored.removeFromHistory(a)
            check(FileManager.default.fileExists(atPath: a.path),"history removal preserves file")
            let text = try await CaptureEngine.recognize(image)
            check(text.contains("Easyshot") && text.contains("2026"),"on-device OCR recognizes exported text")
        } catch { check(false,"save/history/OCR: \(error.localizedDescription)") }
        let pattern = patternImage(width: 120,height: 450)
        let a = pattern.cropping(to: CGRect(x: 0,y: 0,width: 120,height: 220))!
        let b = pattern.cropping(to: CGRect(x: 0,y: 100,width: 120,height: 220))!
        check(ScrollStitcher.overlap(a,b) == 120,"scroll overlap detects exact 120-pixel overlap")
        check(ScrollStitcher.overlap(a,a) == 220,"scroll duplicate detection")
        do {
            let stitched = try ScrollStitcher.stitch([a,b])
            check(stitched.width == 120 && stitched.height == 320,"scroll stitched dimensions")
            let expected = pattern.cropping(to: CGRect(x: 0,y: 0,width: 120,height: 320))!
            let actualRep = NSBitmapImageRep(cgImage: stitched)
            let expectedRep = NSBitmapImageRep(cgImage: expected)
            let actual = actualRep.representation(using: .png,properties: [:])
            let wanted = expectedRep.representation(using: .png,properties: [:])
            check(actual == wanted,"scroll stitching preserves every original pixel")
        } catch { check(false,"scroll stitching: \(error.localizedDescription)") }
        let drawing = editor.render()!
        try? NSBitmapImageRep(cgImage: drawing).representation(using: .png,properties: [:])?.write(to: folder.appendingPathComponent("editor.png"))
        do {
            let url = folder.appendingPathComponent("synthetic.mp4")
            let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: 320,AVVideoHeightKey: 200])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: 320,kCVPixelBufferHeightKey as String: 200])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? ShotError.message("Synthetic video writer failed.") }
            writer.startSession(atSourceTime: .zero)
            for i in 0..<20 {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? ShotError.message("Video writer stopped.") }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else { throw ShotError.message("Video buffer pool unavailable.") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)
                guard let buffer else { throw ShotError.message("Video buffer allocation failed.") }
                CVPixelBufferLockBaseAddress(buffer,[])
                memset(CVPixelBufferGetBaseAddress(buffer),Int32(100+i*5),CVPixelBufferGetBytesPerRow(buffer)*200)
                CVPixelBufferUnlockBaseAddress(buffer,[])
                guard adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(i),timescale: 10)) else { throw writer.error ?? ShotError.message("Synthetic frame append failed.") }
            }
            input.markAsFinished(); await writer.finishWriting()
            check(writer.status == .completed,"offline video encoding")
            let thumbnail = await VideoTools.thumbnail(url)
            check(thumbnail != nil,"modern async video thumbnail")
            let gif = folder.appendingPathComponent("synthetic.gif")
            try await VideoTools.gif(url,to: gif,start: 0,end: 1)
            let source = CGImageSourceCreateWithURL(gif as CFURL,nil)
            check(source.map { CGImageSourceGetCount($0) == 10 } ?? false,"GIF exports all ten animation frames")
            let trimmed = folder.appendingPathComponent("synthetic-trimmed.mp4")
            try await VideoTools.trim(url,to: trimmed,start: 0.2,end: 1.2)
            let duration = try await AVURLAsset(url: trimmed).load(.duration).seconds
            check(abs(duration-1) < 0.15,"modern async trim exports correct duration")
        } catch { check(false,"offline video pipeline: \(error.localizedDescription)") }
        print("\(checks-failures)/\(checks) checks passed. Artifacts: \(folder.path)")
        return failures == 0 ? 0 : 1
    }
    /// Offline Studio pipeline check: synthetic 1440p60 video plus a fake cursor track,
    /// exported through the GPU renderer. Needs no permissions.
    static func studioTest() async -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("easyshot-studio-tests-\(UUID().uuidString)")
        var checks = 0; var failures = 0
        func check(_ result: Bool,_ name: String) { checks += 1; if !result { failures += 1 }; print("\(result ? "PASS" : "FAIL"): \(name)"); fflush(stdout) }
        do {
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let w = 2560, h = 1440, fps = 60, seconds = 5
            let url = folder.appendingPathComponent("studio-source.mp4")
            let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: w,AVVideoHeightKey: h])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: w,kCVPixelBufferHeightKey as String: h])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? ShotError.message("Synthetic video writer failed.") }
            writer.startSession(atSourceTime: .zero)
            // Left half red, right half blue, so zoom position is measurable in exported pixels.
            var row = [UInt8](repeating: 0,count: w*4)
            for x in 0..<w { let red = x < w/2; row[x*4] = red ? 40 : 220; row[x*4+1] = 40; row[x*4+2] = red ? 220 : 40; row[x*4+3] = 255 }
            for i in 0..<fps*seconds {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard let pool = adaptor.pixelBufferPool else { throw ShotError.message("Video buffer pool unavailable.") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)
                guard let buffer else { throw ShotError.message("Video buffer allocation failed.") }
                CVPixelBufferLockBaseAddress(buffer,[])
                let base = CVPixelBufferGetBaseAddress(buffer)!, stride = CVPixelBufferGetBytesPerRow(buffer)
                row.withUnsafeBytes { bytes in for y in 0..<h { memcpy(base+y*stride,bytes.baseAddress!,w*4) } }
                CVPixelBufferUnlockBaseAddress(buffer,[])
                guard adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(i),timescale: CMTimeScale(fps))) else { throw writer.error ?? ShotError.message("Synthetic frame append failed.") }
            }
            input.markAsFinished(); await writer.finishWriting()
            check(writer.status == .completed,"synthetic 1440p60 source")

            var track = CursorTrack(width: Double(w),height: Double(h),scale: 2)
            for i in 0...(seconds*30) { let t = Double(i)/30; track.samples.append(.init(t: t,x: Double(w)*(0.15+0.7*t/Double(seconds)),y: Double(h)*0.5)) }
            track.clicks = [.init(t: 1.0,x: Double(w)*0.2,y: Double(h)*0.5),.init(t: 4.2,x: Double(w)*0.8,y: Double(h)*0.5)]
            let arrow = NSCursor.arrow
            if let image = arrow.image.cgImage(forProposedRect: nil,context: nil,hints: nil),let png = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) {
                track.shapes = [.init(png: png,w: arrow.image.size.width,h: arrow.image.size.height,hx: arrow.hotSpot.x,hy: arrow.hotSpot.y)]
                track.shapeChanges = [.init(t: 0,i: 0)]
            }
            let encoded = try JSONEncoder().encode(track)
            check(try JSONDecoder().decode(CursorTrack.self,from: encoded) == track,"cursor sidecar round-trips")
            var plan = StudioPlan()
            plan.segments = StudioPlanner.segments(for: track,duration: Double(seconds),zoom: 1.8)
            check(plan.segments.count == 2,"two distant clicks produce two zoom segments")
            plan.output = .p1080
            let out = folder.appendingPathComponent("studio-1080.mp4")
            var began = Date()
            try await StudioExporter.export(video: url,track: track,plan: plan,to: out)
            let elapsed = Date().timeIntervalSince(began)
            let asset = AVURLAsset(url: out)
            let duration = try await asset.load(.duration).seconds
            let size = try await StudioExporter.videoSize(asset)
            check(abs(duration-Double(seconds)) < 0.1,"Studio export keeps duration (\(String(format: "%.2f",duration))s)")
            check(size == CGSize(width: 1920,height: 1080),"1080p preset output is 1920×1080")
            print(String(format: "INFO: 1440p60 → 1080p H.264 Studio export, cold: %.2fs for %ds (%.0f fps, %.1f× realtime)",elapsed,seconds,Double(fps*seconds)/elapsed,Double(seconds)/elapsed))
            began = Date()
            try await StudioExporter.export(video: url,track: track,plan: plan,to: folder.appendingPathComponent("studio-1080-warm.mp4"))
            let warm = Date().timeIntervalSince(began)
            print(String(format: "INFO: same export, warm: %.2fs (%.0f fps, %.1f× realtime)",warm,Double(fps*seconds)/warm,Double(seconds)/warm))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            func pixel(_ t: Double,_ fx: Double,_ fy: Double) async throws -> (r: Int,g: Int,b: Int) {
                let (image,_) = try await generator.image(at: CMTime(seconds: t,preferredTimescale: 600))
                let rep = NSBitmapImageRep(cgImage: image)
                let color = rep.colorAt(x: Int(Double(image.width)*fx),y: Int(Double(image.height)*fy))!.usingColorSpace(.sRGB)!
                return (Int(color.redComponent*255),Int(color.greenComponent*255),Int(color.blueComponent*255))
            }
            let unzoomed = try await pixel(0.05,0.7,0.5)
            check(unzoomed.b > unzoomed.r+80,"before zoom, the right of the canvas shows the right (blue) half")
            let zoomed = try await pixel(1.5,0.7,0.5)
            check(zoomed.r > zoomed.b+80,"during the first zoom, the left (red) half fills the canvas")
            let corner = try await pixel(1.5,0.01,0.01)
            check(abs(corner.r-corner.b) < 200 && corner != zoomed,"padding shows the background, not video")
            plan.output = .source; plan.hevc = true; plan.motionBlur = true; plan.background = .none
            let hevc = folder.appendingPathComponent("studio-source-hevc.mp4")
            began = Date()
            try await StudioExporter.export(video: url,track: track,plan: plan,to: hevc,range: 1...3)
            let hevcElapsed = Date().timeIntervalSince(began)
            let hevcAsset = AVURLAsset(url: hevc)
            let hevcDuration = try await hevcAsset.load(.duration).seconds
            check(abs(hevcDuration-2) < 0.1,"trimmed HEVC export with motion blur keeps the 2s range")
            check(try await StudioExporter.videoSize(hevcAsset) == CGSize(width: w,height: h),"source preset keeps native size")
            print(String(format: "INFO: 1440p60 source HEVC + motion blur, 2s range: %.2fs (%.1f× realtime)",hevcElapsed,2/hevcElapsed))
        } catch { check(false,"Studio pipeline: \(error.localizedDescription)") }
        print("\(checks-failures)/\(checks) Studio checks passed. Artifacts: \(folder.path)")
        return failures == 0 ? 0 : 1
    }
    static func patternImage(width: Int,height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255,count: width*height*4)
        var seed: UInt32 = 173
        for i in 0..<width*height {
            for c in 0..<3 { seed = seed &* 1664525 &+ 1013904223; bytes[i*4+c] = UInt8((seed >> 16) & 255) }
        }
        return CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    }
}
