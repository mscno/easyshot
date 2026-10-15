import AppKit
import ImageIO
import EasyshotCore

/// Applies the window-capture background preference. Screen and preference lookups happen on the main actor;
/// wallpaper decoding and composition run detached so a Retina window never stalls the UI.
enum WindowBackdropRenderer {
    struct Plan: @unchecked Sendable { var fill: WindowBackdrop.Fill; var wallpaper: URL?; var padding: Int }
    @MainActor static func plan(windowFrame: CGRect,preferences p: Preferences = .shared) -> Plan? {
        guard p.windowBackground != .none else { return nil }
        let screen = NSScreen.screens.max { a,b in area(a.frame.intersection(windowFrame)) < area(b.frame.intersection(windowFrame)) } ?? .pointerScreen
        let padding = Int((p.windowPadding*screen.backingScaleFactor).rounded())
        switch p.windowBackground {
        case .none,.transparent: return Plan(fill: .clear,padding: padding)
        case .solid: return Plan(fill: .solid(p.windowBackgroundColor.cgColor),padding: padding)
        case .gradient: return Plan(fill: gradient(from: p.windowBackgroundColor),padding: padding)
        case .wallpaper: return Plan(fill: gradient(from: p.windowBackgroundColor),wallpaper: NSWorkspace.shared.desktopImageURL(for: screen),padding: padding)
        }
    }
    static func render(_ image: CGImage,plan: Plan) -> CGImage {
        var fill = plan.fill
        // Decoded straight at the needed size; a 6K wallpaper is never fully decoded for a small window.
        if let url = plan.wallpaper,let source = CGImageSourceCreateWithURL(url as CFURL,nil),
           let wallpaper = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceThumbnailMaxPixelSize: max(image.width,image.height)+plan.padding*2,kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            fill = .image(wallpaper)
        }
        return WindowBackdrop.compose(image,fill: fill,padding: plan.padding) ?? image
    }
    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width*r.height }
    private static func gradient(from color: NSColor) -> WindowBackdrop.Fill {
        let base = color.usingColorSpace(.sRGB) ?? color
        return .gradient((base.blended(withFraction: 0.45,of: .white) ?? base).cgColor,(base.blended(withFraction: 0.35,of: .black) ?? base).cgColor)
    }
}
