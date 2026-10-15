import Foundation

/// A short-lived capture session may check once, without delaying active work.
public struct BackgroundUpdatePolicy {
    public init() {}
    public func shouldCheck(automaticChecks: Bool, attempted: Bool, sessionActive: Bool,
                            captureActive: Bool, lastCheck: Date?, now: Date = Date()) -> Bool {
        automaticChecks && !attempted && !sessionActive && !captureActive &&
            (lastCheck.map { now.timeIntervalSince($0) >= 86_400 } ?? true)
    }
}
