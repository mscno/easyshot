import AppKit

// Agents spawn `Shotglass --mcp` as a headless stdio server; it never reaches NSApplication.
MCPMode.runIfRequested()

MainActor.assumeIsolated {
    _ = StartupTrace.started
    let app = NSApplication.shared
    StartupTrace.mark("applicationCreated")
    let delegate = AppController.shared
    StartupTrace.mark("controllerCreated")
    app.delegate = delegate
    app.run()
}
