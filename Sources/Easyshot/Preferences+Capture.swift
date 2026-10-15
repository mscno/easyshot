import AppKit
import EasyshotCore

/// What appears after a capture finishes.
enum PostCapture: String, CaseIterable, Identifiable {
    case overlay, thumbnail, none
    var id: String { rawValue }
    var title: String { switch self { case .overlay: return "Quick Access overlay"; case .thumbnail: return "Thumbnail · 3 seconds"; case .none: return "Nothing" } }
}

/// Backdrop for window captures. `none` keeps the plain window (with or without its shadow).
enum WindowBackground: String, CaseIterable, Identifiable {
    case none, wallpaper, gradient, solid, transparent
    var id: String { rawValue }
    var title: String { switch self { case .none: return "None"; case .wallpaper: return "Desktop wallpaper"; case .gradient: return "Gradient"; case .solid: return "Solid color"; case .transparent: return "Transparent padding" } }
}

/// Capture-side preferences. Computed over the same defaults store so new keys need no stored-property migration.
extension Preferences {
    private func put(_ value: Any,_ key: String) { objectWillChange.send(); defaults.set(value,forKey: key) }
    var postCapture: PostCapture {
        get { defaults.string(forKey: "postCapture").flatMap(PostCapture.init) ?? .overlay }
        set { put(newValue.rawValue,"postCapture") }
    }
    /// Seconds before an untouched Quick Access card closes; 0 keeps cards until dismissed.
    var quickAccessAutoClose: Int {
        get { (defaults.object(forKey: "quickAccessAutoClose") as? Int).flatMap { [0,3,5,10].contains($0) ? $0 : nil } ?? 5 }
        set { put(newValue,"quickAccessAutoClose") }
    }
    var magnifier: Bool { get { defaults.bool(forKey: "magnifier") } set { put(newValue,"magnifier") } }
    var freezeScreen: Bool { get { defaults.bool(forKey: "freezeScreen") } set { put(newValue,"freezeScreen") } }
    /// Capture Text normally leaves only text on the clipboard; this also keeps the screenshot in history.
    var saveCapturedText: Bool { get { defaults.bool(forKey: "saveCapturedText") } set { put(newValue,"saveCapturedText") } }
    var aspectLock: AspectLock {
        get { defaults.string(forKey: "aspectLock").flatMap(AspectLock.init) ?? .free }
        set { put(newValue.rawValue,"aspectLock") }
    }
    var windowBackground: WindowBackground {
        get { defaults.string(forKey: "windowBackground").flatMap(WindowBackground.init) ?? .none }
        set { put(newValue.rawValue,"windowBackground") }
    }
    /// Padding around window captures in points; scaled to the capture's native pixels.
    var windowPadding: Double {
        get { defaults.object(forKey: "windowPadding") as? Double ?? 64 }
        set { put(min(240,max(8,newValue)),"windowPadding") }
    }
    var windowBackgroundColor: NSColor {
        get { (defaults.array(forKey: "windowBackgroundColor") as? [Double]).flatMap { $0.count == 4 ? NSColor(srgbRed: $0[0],green: $0[1],blue: $0[2],alpha: $0[3]) : nil } ?? NSColor(srgbRed: 0.36,green: 0.25,blue: 0.85,alpha: 1) }
        set { let c = newValue.usingColorSpace(.sRGB) ?? .systemPurple; put([c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent].map(Double.init),"windowBackgroundColor") }
    }
}
