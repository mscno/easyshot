import AppIntents
import EasyshotCore

/// Shortcuts and Spotlight actions. macOS launches Easyshot to run one and the session ends as usual, so a
/// keyboard shortcut assigned to an action in Shortcuts or System Settings needs no resident Easyshot process.
protocol EasyshotIntent: AppIntent { static var action: LaunchAction { get } }
extension EasyshotIntent {
    static var openAppWhenRun: Bool { false }
    @MainActor func perform() async throws -> some IntentResult { AppController.shared.runIntent(Self.action); return .result() }
}

struct CaptureAreaIntent: EasyshotIntent {
    static let title: LocalizedStringResource = "Capture Area"
    static let description = IntentDescription("Open the Easyshot capture bar in area mode.")
    static let action = LaunchAction.capture
}
struct CaptureWindowIntent: EasyshotIntent {
    static let title: LocalizedStringResource = "Capture Window"
    static let description = IntentDescription("Click a window to capture it.")
    static let action = LaunchAction.window
}
struct CaptureFullScreenIntent: EasyshotIntent {
    static let title: LocalizedStringResource = "Capture Full Screen"
    static let description = IntentDescription("Capture the display under the pointer.")
    static let action = LaunchAction.fullscreen
}
struct CaptureTextIntent: EasyshotIntent {
    static let title: LocalizedStringResource = "Capture Text"
    static let description = IntentDescription("Select an area and copy its text and QR codes, recognized on device.")
    static let action = LaunchAction.captureText
}
struct RepeatAreaIntent: EasyshotIntent {
    static let title: LocalizedStringResource = "Repeat Last Area"
    static let description = IntentDescription("Capture your previous area immediately.")
    static let action = LaunchAction.repeatArea
}
struct RecordScreenIntent: EasyshotIntent {
    static let title: LocalizedStringResource = "Record Screen"
    static let description = IntentDescription("Select an area to record, or stop the current recording.")
    static let action = LaunchAction.record
}
struct OpenLibraryIntent: EasyshotIntent {
    static let title: LocalizedStringResource = "Open Library"
    static let description = IntentDescription("Browse, search and share past captures.")
    static let action = LaunchAction.library
}
struct RestoreLastCaptureIntent: EasyshotIntent {
    static let title: LocalizedStringResource = "Restore Last Quick Access Card"
    static let description = IntentDescription("Bring back the most recently closed capture card.")
    static let action = LaunchAction.restoreOverlay
}

struct EasyshotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureAreaIntent(),phrases: ["Capture area with \(.applicationName)","Take a screenshot with \(.applicationName)"],shortTitle: "Capture Area",systemImageName: "crop")
        AppShortcut(intent: CaptureTextIntent(),phrases: ["Capture text with \(.applicationName)"],shortTitle: "Capture Text",systemImageName: "text.viewfinder")
        AppShortcut(intent: RecordScreenIntent(),phrases: ["Record the screen with \(.applicationName)"],shortTitle: "Record Screen",systemImageName: "record.circle")
        AppShortcut(intent: CaptureWindowIntent(),phrases: ["Capture a window with \(.applicationName)"],shortTitle: "Capture Window",systemImageName: "macwindow")
        AppShortcut(intent: RepeatAreaIntent(),phrases: ["Repeat the last area with \(.applicationName)"],shortTitle: "Repeat Area",systemImageName: "arrow.counterclockwise")
    }
}
