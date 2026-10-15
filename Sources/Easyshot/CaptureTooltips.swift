import AppKit
import SwiftUI
import EasyshotCore

/// Help tags must sit above the selection windows, and must never intercept clicks or focus.
@MainActor final class CaptureTooltips {
    var toolbarFrame = CGRect.zero
    private(set) var panel: NSPanel?
    private(set) var currentText: String?
    private var pending: Task<Void,Never>?
    private var generation = 0
    func hover(_ text: String,active: Bool) {
        if !active {
            if currentText == text { dismiss() }
            return
        }
        dismiss(); currentText = text
        let token = generation
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self,self.generation == token,self.currentText == text else { return }
            self.show(text)
        }
    }
    func dismiss() {
        generation += 1; pending?.cancel(); pending = nil; currentText = nil
        panel?.close(); panel = nil
    }
    private func show(_ text: String) {
        let host = NSHostingView(rootView: Text(text).font(.system(size: 11)).lineSpacing(3)
            .fixedSize(horizontal: false,vertical: true).frame(width: 280,alignment: .leading)
            .padding(11).glassEffect(.regular,in: RoundedRectangle(cornerRadius: 9)))
        let size = host.fittingSize
        let point = NSEvent.mouseLocation
        let bounds = NSScreen.pointerScreen.visibleFrame
        let frame = CGRect(x: max(bounds.minX+8,min(point.x-size.width/2,bounds.maxX-size.width-8)),
                           y: max(bounds.minY+8,min(max(point.y+20,toolbarFrame.maxY+8),bounds.maxY-size.height-8)),
                           width: size.width,height: size.height)
        let panel = NSPanel(contentRect: frame,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+3)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.ignoresMouseEvents = true; panel.contentView = host
        self.panel = panel; panel.orderFrontRegardless()
    }
}

extension View {
    func captureHelp(_ text: String,using tooltips: CaptureTooltips) -> some View {
        onHover { active in tooltips.hover(text,active: active) }
            .onChange(of: text) { old,new in if tooltips.currentText == old { tooltips.hover(new,active: true) } }
            .accessibilityHint(text)
    }
}

extension CaptureMode {
    var captureTooltip: String {
        switch self {
        case .fullscreen: return "Full Screen · 1 or F/S\nCapture the display under your pointer. Its border, name and resolution show the target."
        case .window: return "Choose Window · 2 or W\nHover to highlight a window, then click it to capture just that window."
        case .area: return "Area · 3 or A\nReuse your rectangle. Drag inside to move, handles to resize, or outside to draw a new area."
        case .activeWindow: return "Active Window · 4 or V\nCapture the window of the app you were using before opening Easyshot."
        case .lastRegion: return "Last Area · 5 or R\nRecall the rectangle from your last screenshot. Adjust it before capturing if needed."
        }
    }
}
