import SwiftUI
import EasyshotCore

/// Recording overlays, GIF output and desktop cleanup.
struct RecordingStyleSettings: View {
    @ObservedObject var p = Preferences.shared
    func bind<T>(_ key: ReferenceWritableKeyPath<Preferences,T>) -> Binding<T> { Binding(get: { p[keyPath: key] },set: { p[keyPath: key] = $0 }) }
    var body: some View {
        Toggle("Record as GIF",isOn: bind(\.recordAsGIF)).help("Records an MP4 internally, then saves and copies a GIF (10 fps, up to 960 px, two minutes)")
        Toggle("Clean desktop in display and area recordings",isOn: bind(\.cleanDesktop)).help("Hides desktop icons. Finder windows and the Dock stay visible.")
        if p.cleanDesktop {
            HStack {
                Toggle("Replace wallpaper with a solid color",isOn: bind(\.replaceWallpaper))
                if p.replaceWallpaper { ColorPicker("",selection: Binding(get: { Color(rgba: p.wallpaperColor) },set: { p.wallpaperColor = $0.rgba }),supportsOpacity: false).labelsHidden() }
            }
        }
        HStack(spacing: 14) {
            Text("Clicks")
            ColorPicker("",selection: Binding(get: { Color(rgba: p.clickColor) },set: { p.clickColor = $0.rgba }),supportsOpacity: false).labelsHidden()
            Picker("",selection: bind(\.clickSize)) { Text("Small").tag(0.75); Text("Medium").tag(1.0); Text("Large").tag(1.4) }.labelsHidden().frame(width: 100)
            Toggle("Filled",isOn: bind(\.clickFilled))
        }
        #if !APP_STORE
        HStack(spacing: 14) {
            Text("Keystrokes")
            Picker("",selection: bind(\.keysAllKeys)) { Text("Shortcuts only").tag(false); Text("All keys").tag(true) }.labelsHidden().frame(width: 130)
            Picker("",selection: bind(\.keysAtTop)) { Text("Bottom").tag(false); Text("Top").tag(true) }.labelsHidden().frame(width: 90)
            Picker("",selection: bind(\.keysLight)) { Text("Dark").tag(false); Text("Light").tag(true) }.labelsHidden().frame(width: 80)
        }
        #endif
        HStack(spacing: 14) {
            Text("Camera")
            Picker("",selection: bind(\.cameraShape)) { Text("Circle").tag(CameraShape.circle); Text("Rounded").tag(CameraShape.rounded); Text("Square").tag(CameraShape.square) }.labelsHidden().frame(width: 100)
            Picker("",selection: bind(\.cameraSize)) { Text("Small").tag(CameraSize.small); Text("Medium").tag(CameraSize.medium); Text("Large").tag(CameraSize.large) }.labelsHidden().frame(width: 95)
            Picker("",selection: bind(\.cameraCorner)) { ForEach(ScreenCorner.allCases,id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 120)
        }
    }
}

/// History retention and the pre-upload secret check.
struct HistoryPrivacySettings: View {
    @ObservedObject var p = Preferences.shared
    func bind<T>(_ key: ReferenceWritableKeyPath<Preferences,T>) -> Binding<T> { Binding(get: { p[keyPath: key] },set: { p[keyPath: key] = $0 }) }
    var body: some View {
        Picker("Keep history",selection: bind(\.historyRetention)) { ForEach(HistoryRetention.allCases,id: \.self) { Text($0.title).tag($0) } }.frame(maxWidth: 310,alignment: .leading)
        Text("Older entries leave history when it next loads. Files in your screenshots folder are never deleted; only copies kept inside Easyshot's own history folder are.").font(.system(size: 10)).foregroundStyle(.secondary)
        if CloudSession.isAvailable { Toggle("Check for secrets before uploading",isOn: bind(\.redactBeforeUpload)) }
        HStack(spacing: 18) {
            Toggle("Treat UUIDs as secrets",isOn: bind(\.redactUUIDs))
            Toggle("Treat git SHAs as secrets",isOn: bind(\.redactGitSHAs))
        }
        Text("Text recognition runs on this Mac. It finds API keys and tokens, JWTs, private keys, emails, IP addresses, card numbers and password values, and proposes redactions you can review.").font(.system(size: 10)).foregroundStyle(.secondary)
    }
}
