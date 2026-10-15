import SwiftUI
import AppKit
import ShotglassCore

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences = Preferences.shared
    @State var message = ""
    var body: some View {
        VStack(alignment: .leading,spacing: 26) {
            Text("Make it your own.").font(.system(size: 28,weight: .semibold)).tracking(-0.8)
            settingsSection("Destination",subtitle: "A file and a clipboard copy, with every capture.") {
                Toggle("Save captures to folder",isOn: $preferences.saveToDisk)
                HStack {
                    Image(systemName: "folder").foregroundStyle(accent)
                    if Distribution.isAppStore {
                        Text(preferences.folderDescription).lineLimit(1).truncationMode(.middle)
                    } else {
                        TextField("Save folder",text: $preferences.folder).textFieldStyle(.roundedBorder)
                    }
                    Button("Choose…") {
                        do { try preferences.chooseCaptureFolder() } catch { controller.fail(error) }
                    }
                }
                Toggle("Copy every capture to the clipboard",isOn: $preferences.copyToClipboard)
                Picker("Image format",selection: $preferences.format) { Text("PNG · lossless").tag("png"); Text("JPEG · smaller files").tag("jpg") }.frame(maxWidth: 310,alignment: .leading)
                Text("With folder saving off, captures are still kept in local history. Removing an item from history leaves its file in place.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            settingsSection("Capture behavior",subtitle: "Fine-tune the details.") {
                Toggle("Include window shadows",isOn: $preferences.windowShadow)
                Toggle("Include cursor in screenshots",isOn: $preferences.captureCursor)
                Toggle("Hide desktop icons in display captures",isOn: $preferences.hideDesktopIcons)
                Toggle("Snap on draw",isOn: $preferences.snapOnDraw)
                    .help("Capture and close when you finish drawing a new rectangle. Moving and resizing wait for Capture.")
                Toggle("Quick Preview · 3 seconds",isOn: $preferences.showPreview)
                Picker("Capture delay",selection: $preferences.delay) { Text("None").tag(0.0); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0) }.frame(maxWidth: 310,alignment: .leading)
            }
            if CloudSession.isAvailable {
                settingsSection("Shotglass Cloud",subtitle: "Upload a screenshot and paste its link anywhere, including over SSH.") {
                    CloudAccountForm()
                    UploadKeyRow()
                }
            }
            settingsSection("Recording",subtitle: "Capture motion and sound.") {
                Toggle("Record system audio",isOn: $preferences.systemAudio)
                Toggle("Record microphone",isOn: $preferences.microphone)
                Toggle("Show cursor",isOn: $preferences.recordCursor)
                Toggle("Highlight mouse clicks",isOn: $preferences.showClicks)
                Toggle("Studio: auto-zoom and smooth cursor",isOn: $preferences.studio)
                #if !APP_STORE
                Toggle("Show command shortcuts (requires Accessibility)",isOn: $preferences.showKeys)
                #endif
                Toggle("Add webcam bubble",isOn: $preferences.recordCamera)
                Picker("Frame rate",selection: $preferences.fps) { Text("24 fps").tag(24); Text("30 fps").tag(30); Text("60 fps").tag(60) }.frame(maxWidth: 310,alignment: .leading)
                Text("Recordings save as MP4. Open a recording to trim it or export a GIF. Studio recordings hide the cursor while recording and log its movement, so the editor can add automatic zooms, a smoothed cursor and a background. With microphone enabled, voice and system audio are mixed for playback.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            settingsSection("Capture shortcuts",subtitle: "Active only while the capture bar is open.") {
                Text("A · area     D / N · draw new     F · full screen\nW · window     V · active window     R · last area\nReturn · capture     Esc · close     Space · area/window\n⌘, · basic settings     ⌘L · library")
                    .font(.system(size: 12,design: .monospaced)).lineSpacing(8)
                Text("Launch Shotglass from Applications, Spotlight, or Raycast. It remembers the last mode and quits when the session ends.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            #if !APP_STORE
            settingsSection("Updates",subtitle: "Keep Shotglass up to date.") { UpdateSettingsView() }
            #endif
            settingsSection("Screen access",subtitle: "Allow screenshots through macOS privacy settings.") {
                Button("Privacy Policy") { controller.openPrivacyPolicy() }
                HStack { Label(controller.permitted ? "Screen Recording allowed" : "Screen Recording access needed",systemImage: controller.permitted ? "checkmark.circle" : "exclamationmark.circle"); Spacer(); Button("System Settings") { controller.openPrivacy() } }
                if !message.isEmpty { Text(message).font(.system(size: 10)).foregroundStyle(.orange) }
            }
        }.font(.system(size: 12)).buttonStyle(.glass)
    }
    func settingsSection<C: View>(_ title: String,subtitle: String,@ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading,spacing: 16) {
            VStack(alignment: .leading,spacing: 5) { Text(title).font(.system(size: 14,weight: .semibold)); Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            Divider()
            content()
        }.padding(22).frame(maxWidth: .infinity,alignment: .leading).background(.white.opacity(0.025),in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.06)))
    }
}
