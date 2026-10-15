import AppKit
import SwiftUI

struct BasicSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences = Preferences.shared
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Save To") {
                    Toggle("Save screenshot as a file",isOn: $preferences.saveToDisk)
                    HStack {
                        if Distribution.isAppStore {
                            Text(preferences.folderDescription).lineLimit(1).truncationMode(.middle)
                        } else {
                            TextField("Folder",text: $preferences.folder).textFieldStyle(.roundedBorder)
                        }
                        Button("Choose…") {
                            do { try preferences.chooseCaptureFolder() } catch { controller.fail(error) }
                        }
                    }
                    Picker("Image format",selection: $preferences.format) {
                        Text("PNG").tag("png"); Text("JPEG").tag("jpg")
                    }
                    Toggle("Copy screenshot to clipboard",isOn: $preferences.copyToClipboard)
                }
                Section("Options") {
                    Toggle("Include window shadow",isOn: $preferences.windowShadow)
                    Toggle("Include pointer",isOn: $preferences.captureCursor)
                    Picker("Timer",selection: $preferences.delay) {
                        Text("None").tag(0.0); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0)
                    }
                    Toggle("Snap on draw",isOn: $preferences.snapOnDraw)
                    .help("Capture and close when you finish drawing a new rectangle. Moving and resizing wait for Capture.")
                    Picker("After capture",selection: $preferences.postCapture) { ForEach(PostCapture.allCases) { Text($0.title).tag($0) } }
                    if preferences.postCapture == .overlay {
                        Picker("Close cards after",selection: $preferences.quickAccessAutoClose) { Text("Never").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10) }
                    }
                    Text("Quick Access cards stack in the corner of the captured display; hover to keep them, swipe to dismiss. Easyshot quits when the last one closes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Magnifier while selecting · M",isOn: $preferences.magnifier)
                    Toggle("Freeze screen while selecting",isOn: $preferences.freezeScreen)
                    Picker("Window background",selection: $preferences.windowBackground) { ForEach(WindowBackground.allCases) { Text($0.title).tag($0) } }
                }
                #if !APP_STORE
                Section("Updates") { UpdateSettingsView() }
                #endif
                if CloudSession.isAvailable { CloudSettingsSection() }
                Section {
                    Button("Privacy Policy") { controller.openPrivacyPolicy() }
                    Text("Easyshot opens when you launch it and quits when you finish. It remembers your capture mode and area.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Label(controller.permitted ? "Screen access allowed" : "Screen access needed",systemImage: controller.permitted ? "checkmark.circle" : "exclamationmark.circle")
                        Spacer()
                        Button("System Settings…") { controller.requestPermission() }
                    }.font(.callout)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("More Settings…") { controller.settingsWindow?.orderOut(nil); controller.showMain(); DispatchQueue.main.async { NotificationCenter.default.post(name: .showSettings,object: nil) } }
                Spacer()
                Button("Back to Capture") { controller.settingsDone() }.buttonStyle(.glass).keyboardShortcut(.defaultAction)
            }.padding(16)
        }.buttonStyle(.glass)
    }
}

#if !APP_STORE
struct UpdateSettingsView: View {
    @ObservedObject var updates = AppController.shared.updates
    var body: some View {
        Toggle("Check for updates automatically", isOn: $updates.automaticChecks)
        Toggle("Automatically install updates", isOn: $updates.automaticInstall)
            .disabled(!updates.automaticChecks)
        Button("Check for Updates…") { updates.checkNow() }.disabled(!updates.canCheck)
        Text("Updates come from GitHub. Installation waits until capture and export finish.")
            .font(.caption).foregroundStyle(.secondary)
            .onAppear { updates.start() }
    }
}
#endif
