import Foundation

/// Opt-in measurements use the real launch/capture path; no screen input is synthesized.
@MainActor enum StartupTrace {
    static let started = ProcessInfo.processInfo.systemUptime
    static let enabled = CommandLine.arguments.contains("--startup-benchmark")
    static var milestones: [String: Double] = [:]
    static func mark(_ name: String) {
        guard enabled,milestones[name] == nil else { return }
        milestones[name] = (ProcessInfo.processInfo.systemUptime-started)*1000
    }
    static func report() {
        for (name,ms) in milestones.sorted(by: { $0.value < $1.value }) {
            print(String(format: "STARTUP %@ %.1f ms",name,ms))
        }
        fflush(stdout)
    }
}
