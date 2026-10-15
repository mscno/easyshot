#if !APP_STORE
import AppKit
import Combine
import Sparkle
import EasyshotCore

@MainActor final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = true
    @Published private(set) var holdsSession = false
    @Published var automaticChecks = true { didSet { if started && !syncingPreferences { controller.updater.automaticallyChecksForUpdates = automaticChecks } } }
    @Published var automaticInstall = false { didSet { if started && !syncingPreferences { controller.updater.automaticallyDownloadsUpdates = automaticInstall } } }
    var isCapturing: () -> Bool = { false }
    var sessionFinished: () -> Void = {}
    private var started = false
    private var syncingPreferences = false
    private var attemptedBackgroundCheck = false
    private var observers: [NSKeyValueObservation] = []
    private var pendingInstall: (() -> Void)?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    private var enabled: Bool {
        !ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("-test") || $0 == "--ui-testing" || $0 == "--startup-benchmark" }) &&
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }
    func start() {
        guard enabled, !started else { return }
        started = true
        controller.startUpdater()
        let updater = controller.updater
        syncingPreferences = true
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticInstall = updater.automaticallyDownloadsUpdates
        canCheck = updater.canCheckForUpdates
        syncingPreferences = false
        observers = [updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in self?.canCheck = value }
        }, updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.automaticallyChecksForUpdates
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncingPreferences = true
                self.automaticChecks = value
                self.syncingPreferences = false
            }
        }, updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.automaticallyDownloadsUpdates
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncingPreferences = true
                self.automaticInstall = value
                self.syncingPreferences = false
            }
        }]
    }
    /// Sparkle keeps the last-check date and preferences. Short-lived capture
    /// sessions perform a due check at their first safe idle point before quitting.
    @discardableResult func checkBackgroundIfDue() -> Bool {
        guard enabled else { return false }
        let updater = controller.updater
        guard BackgroundUpdatePolicy().shouldCheck(automaticChecks: updater.automaticallyChecksForUpdates,
            attempted: attemptedBackgroundCheck, sessionActive: holdsSession,
            captureActive: isCapturing(), lastCheck: updater.lastUpdateCheckDate) else { return false }
        attemptedBackgroundCheck = true
        holdsSession = true
        start()
        updater.checkForUpdatesInBackground()
        return true
    }
    func checkNow() {
        guard enabled, !isCapturing() else { return }
        start()
        guard controller.updater.canCheckForUpdates else { return }
        holdsSession = true
        controller.checkForUpdates(nil)
    }
    func resumeInstallationIfReady() {
        guard !isCapturing(), let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isCapturing() { throw NSError(domain: "AppUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish the capture or export before updating."]) }
        if updateCheck == .updatesInBackground { attemptedBackgroundCheck = true }
        holdsSession = true
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isCapturing() else { return false }
        pendingInstall = installHandler
        return true
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil { pendingInstall = nil }
        holdsSession = false
        sessionFinished()
    }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverWillFinishUpdateSession() {
        holdsSession = false
        sessionFinished()
    }
}
#endif
