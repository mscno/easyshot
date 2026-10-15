import XCTest
@testable import EasyshotCore

final class BackgroundUpdatePolicyTests: XCTestCase {
    let policy = BackgroundUpdatePolicy()
    let now = Date(timeIntervalSince1970: 100_000)
    func testFirstSafeIdleChecksWhenNoPreviousCheckExists() {
        XCTAssertTrue(policy.shouldCheck(automaticChecks: true, attempted: false,
            sessionActive: false, captureActive: false, lastCheck: nil, now: now))
    }
    func testFailureCannotTriggerRepeatedChecksInSameLaunch() {
        XCTAssertFalse(policy.shouldCheck(automaticChecks: true, attempted: true,
            sessionActive: false, captureActive: false, lastCheck: nil, now: now))
    }
    func testDisabledChecksAndActiveWorkDoNotDelayExitWithNetworkChecks() {
        for (automatic, session, capture) in [(false, false, false), (true, true, false), (true, false, true)] {
            XCTAssertFalse(policy.shouldCheck(automaticChecks: automatic, attempted: false,
                sessionActive: session, captureActive: capture, lastCheck: nil, now: now))
        }
    }
    func testLastCheckPersistsDailyScheduleAcrossLaunches() {
        for elapsed in [0.0, 86_399.0] {
            XCTAssertFalse(policy.shouldCheck(automaticChecks: true, attempted: false,
                sessionActive: false, captureActive: false, lastCheck: now.addingTimeInterval(-elapsed), now: now))
        }
        XCTAssertTrue(policy.shouldCheck(automaticChecks: true, attempted: false,
            sessionActive: false, captureActive: false, lastCheck: now.addingTimeInterval(-86_400), now: now))
    }
}
