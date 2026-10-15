import AppKit
import SwiftUI
import EasyshotCore

enum CameraShape: String,CaseIterable,Codable { case circle,rounded,square }
enum CameraSize: String,CaseIterable,Codable {
    case small,medium,large
    var fraction: CGFloat { switch self { case .small: 0.17; case .medium: 0.23; case .large: 0.31 } }
}
enum ScreenCorner: Int,CaseIterable,Codable {
    case bottomRight,bottomLeft,topRight,topLeft
    var title: String { ["Bottom right","Bottom left","Top right","Top left"][rawValue] }
}

/// A reusable background look for screenshots.
struct BackgroundPreset: Codable,Identifiable,Equatable {
    var id = UUID()
    var name: String
    var background: StudioBackground
    var padding: Double
    var shadow: Bool
    var corner: Double
    var aspect: BackdropAspect
    var alignment: BackdropAlignment
    var autoBalance: Bool
}

/// Editor and recording-style preferences, stored directly in defaults. Setters notify observers.
extension Preferences {
    private func value<T>(_ key: String,_ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
    private func store(_ key: String,_ value: Any?) { objectWillChange.send(); defaults.set(value,forKey: key) }
    private func decoded<T: Codable>(_ key: String,_ fallback: T) -> T { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self,from: $0) } ?? fallback }
    private func encode<T: Codable>(_ key: String,_ value: T) { store(key,try? JSONEncoder().encode(value)) }

    static let defaultPalette: [[Double]] = [[1,0.32,0.35,1],[1,0.62,0.2,1],[1,0.84,0.25,1],[0.3,0.82,0.45,1],[0.25,0.6,1,1],[0.64,0.53,1,1],[1,1,1,1],[0.08,0.08,0.1,1]]
    var colorPalette: [[Double]] { get { decoded("colorPalette",Self.defaultPalette) } set { encode("colorPalette",Array(newValue.suffix(16))) } }
    var backgroundPresets: [BackgroundPreset] { get { decoded("backgroundPresets",[]) } set { encode("backgroundPresets",newValue) } }
    var combineHorizontally: Bool { get { value("combineHorizontally",false) } set { store("combineHorizontally",newValue) } }

    var historyRetention: HistoryRetention { get { HistoryRetention(rawValue: value("historyRetention","")) ?? .forever } set { store("historyRetention",newValue.rawValue) } }
    var redactBeforeUpload: Bool { get { value("redactBeforeUpload",true) } set { store("redactBeforeUpload",newValue) } }
    var redactUUIDs: Bool { get { value("redactUUIDs",false) } set { store("redactUUIDs",newValue) } }
    var redactGitSHAs: Bool { get { value("redactGitSHAs",false) } set { store("redactGitSHAs",newValue) } }
    var secretScanner: SecretScanner { SecretScanner(includeUUIDs: redactUUIDs,includeGitSHAs: redactGitSHAs) }

    var clickColor: [Double] { get { value("clickColor",[0.72,0.58,1,1]) } set { store("clickColor",newValue) } }
    var clickSize: Double { get { value("clickSize",1.0) } set { store("clickSize",newValue) } }
    var clickFilled: Bool { get { value("clickFilled",false) } set { store("clickFilled",newValue) } }
    var keysAllKeys: Bool { get { value("keysAllKeys",false) } set { store("keysAllKeys",newValue) } }
    var keysAtTop: Bool { get { value("keysAtTop",false) } set { store("keysAtTop",newValue) } }
    var keysLight: Bool { get { value("keysLight",false) } set { store("keysLight",newValue) } }
    var cameraShape: CameraShape { get { CameraShape(rawValue: value("cameraShape","")) ?? .circle } set { store("cameraShape",newValue.rawValue) } }
    var cameraSize: CameraSize { get { CameraSize(rawValue: value("cameraSize","")) ?? .medium } set { store("cameraSize",newValue.rawValue) } }
    var cameraCorner: ScreenCorner { get { ScreenCorner(rawValue: value("cameraCorner",0)) ?? .bottomRight } set { store("cameraCorner",newValue.rawValue) } }
    var recordAsGIF: Bool { get { value("recordAsGIF",false) } set { store("recordAsGIF",newValue) } }
    var cleanDesktop: Bool { get { value("cleanDesktop",false) } set { store("cleanDesktop",newValue) } }
    var replaceWallpaper: Bool { get { value("replaceWallpaper",false) } set { store("replaceWallpaper",newValue) } }
    var wallpaperColor: [Double] { get { value("wallpaperColor",[0.11,0.12,0.15,1]) } set { store("wallpaperColor",newValue) } }
}

extension Color {
    init(rgba c: [Double]) { self.init(.sRGB,red: c[0],green: c[1],blue: c[2],opacity: c.count > 3 ? c[3] : 1) }
    var rgba: [Double] { let c = NSColor(self).usingColorSpace(.sRGB) ?? .red; return [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent] }
}
