import XCTest
@testable import EasyshotCore

final class CaptureSessionTests: XCTestCase {
    func testLetterKeysChooseAllModes() {
        for (key,mode) in [("a",CaptureMode.area),("f",.fullscreen),("w",.window),("v",.activeWindow),("r",.lastRegion)] {
            XCTAssertEqual(CaptureKeyAction.resolve(key),.mode(mode))
        }
    }
    func testNumbersFollowLeftToRightToolbarOrder() {
        let expected: [CaptureMode] = [.fullscreen,.window,.area,.activeWindow,.lastRegion]
        XCTAssertEqual(CaptureMode.toolbarOrder,expected)
        for (index,mode) in expected.enumerated() {
            XCTAssertEqual(mode.key,String(index+1))
            XCTAssertEqual(CaptureKeyAction.resolve(String(index+1)),.mode(mode))
            XCTAssertNil(CaptureKeyAction.resolve(String(index+1),command: true))
        }
    }
    func testRapidPreviewReplacementRejectsEarlierTimersAndCompletions() {
        var preview = QuickPreviewLifetime()
        let first = preview.replace(),second = preview.replace(),third = preview.replace()
        XCTAssertFalse(preview.dismiss(first)); XCTAssertFalse(preview.dismiss(second))
        XCTAssertTrue(preview.isCurrent(third)); XCTAssertTrue(preview.isActive)
        XCTAssertTrue(preview.dismiss(third)); XCTAssertFalse(preview.isActive)
    }
    func testReopeningCaptureInvalidatesPreviewDismissal() {
        var preview = QuickPreviewLifetime()
        let previous = preview.replace()
        preview.invalidate()
        XCTAssertFalse(preview.dismiss(previous)); XCTAssertFalse(preview.isActive)
        let current = preview.replace()
        XCTAssertFalse(preview.dismiss(previous)); XCTAssertTrue(preview.isCurrent(current))
    }
    func testDismissalIsIdempotent() {
        var preview = QuickPreviewLifetime()
        let token = preview.replace()
        XCTAssertTrue(preview.dismiss(token)); XCTAssertFalse(preview.dismiss(token))
    }
    func testDrawKeysWorkWithEitherCase() {
        for key in ["d","D","n","N"] { XCTAssertEqual(CaptureKeyAction.resolve(key),.drawNew) }
    }
    func testOrdinaryAppShortcutsAreNotHijacked() {
        for key in ["a","d","f","w","v","r"] {
            XCTAssertNil(CaptureKeyAction.resolve(key,command: true))
            XCTAssertNil(CaptureKeyAction.resolve(key,otherModifier: true))
        }
        XCTAssertEqual(CaptureKeyAction.resolve(",",command: true),.settings)
        XCTAssertEqual(CaptureKeyAction.resolve("l",command: true),.library)
    }
    func testUnknownKeysAreIgnored() {
        XCTAssertNil(CaptureKeyAction.resolve("q")); XCTAssertNil(CaptureKeyAction.resolve(""))
    }
    func testFirstLaunchDefaultsToReusableArea() {
        XCTAssertEqual(CaptureSelection(),CaptureSelection(mode: .area,drawNew: false))
    }
    func testEveryModeSurvivesProcessRestart() throws {
        for mode in CaptureMode.allCases {
            let stored = CaptureSelection(mode: mode)
            XCTAssertEqual(try JSONDecoder().decode(CaptureSelection.self,from: JSONEncoder().encode(stored)),stored)
        }
    }
    func testDrawNewIsRememberedIndependentlyOfSavedRectangle() throws {
        let stored = CaptureSelection(mode: .area,drawNew: true)
        XCTAssertEqual(try JSONDecoder().decode(CaptureSelection.self,from: JSONEncoder().encode(stored)),stored)
        XCTAssertFalse(CaptureSelection(mode: .fullscreen,drawNew: true).drawNew)
    }
    func testEmptySessionExits() { XCTAssertTrue(SessionActivity().shouldExit) }
    func testCaptureMustFinishWritingBeforeExit() {
        var state: SessionActivity = [.selection]
        XCTAssertFalse(state.shouldExit)
        state.remove(.selection); state.insert(.processing)
        XCTAssertFalse(state.shouldExit)
        state.remove(.processing)
        XCTAssertTrue(state.shouldExit)
    }
    func testPreviewDismissalEndsSession() {
        var state: SessionActivity = [.preview]
        XCTAssertFalse(state.shouldExit)
        state.remove(.preview)
        XCTAssertTrue(state.shouldExit)
    }
    func testSettingsAndEditorsRemainOpenUntilClosed() {
        var state: SessionActivity = [.toolWindow]
        XCTAssertFalse(state.shouldExit)
        state.remove(.toolWindow)
        XCTAssertTrue(state.shouldExit)
    }
    func testRecordingsAndScrollingNeverExitWhileActive() {
        XCTAssertFalse(SessionActivity.recording.shouldExit)
        XCTAssertFalse(SessionActivity.scrolling.shouldExit)
        XCTAssertFalse(SessionActivity([.processing,.recording]).shouldExit)
    }
    func testResetKeyClearsDrawArea() {
        XCTAssertEqual(CaptureKeyAction.resolve("x"),.resetArea)
        XCTAssertEqual(CaptureKeyAction.resolve("X"),.resetArea)
        XCTAssertNil(CaptureKeyAction.resolve("x",command: true))
    }
    func testUploadKeyIsConfigurableButNeverShadowsBuiltInKeys() {
        XCTAssertEqual(CaptureKeyAction.resolve("u"),.upload)
        XCTAssertEqual(CaptureKeyAction.resolve("g",uploadKey: "g"),.upload)
        XCTAssertNil(CaptureKeyAction.resolve("u",uploadKey: "g"))
        XCTAssertEqual(CaptureKeyAction.resolve("d",uploadKey: "d"),.drawNew)
        XCTAssertEqual(CaptureKeyAction.sanitizedUploadKey("D"),"u")
        XCTAssertEqual(CaptureKeyAction.sanitizedUploadKey(""),"u")
        XCTAssertEqual(CaptureKeyAction.sanitizedUploadKey("G"),"g")
        XCTAssertEqual(CaptureKeyAction.sanitizedUploadKey(" "),"u")
    }
    func testRFC3339ParsesMicrosecondAndPlainTimestamps() {
        XCTAssertNotNil(RFC3339.parse("2026-10-14T12:30:45.123456Z"))
        XCTAssertNotNil(RFC3339.parse("2026-10-14T12:30:45Z"))
        XCTAssertNotNil(RFC3339.parse("2026-10-14T12:30:45.5+02:00"))
        XCTAssertNil(RFC3339.parse("yesterday"))
        XCTAssertEqual(RFC3339.parse("2026-10-14T12:30:45.123456Z")?.timeIntervalSince1970 ?? 0,RFC3339.parse("2026-10-14T12:30:45.123Z")?.timeIntervalSince1970 ?? 1,accuracy: 0.001)
    }
    func testCloudLibraryGroupsByDay() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = RFC3339.parse("2026-10-14T12:00:00Z")!
        let items = ["2026-10-14T09:00:00Z","2026-10-14T01:00:00Z","2026-10-13T23:00:00Z","2026-10-01T10:00:00Z"].map { RFC3339.parse($0)! }
        let sections = CloudLibrary.sections(items,date: { $0 },now: now,calendar: calendar)
        XCTAssertEqual(sections.map(\.title).prefix(2),["Today","Yesterday"])
        XCTAssertEqual(sections.map(\.items.count),[2,1,1])
    }
    func testExpiryText() {
        let now = Date()
        XCTAssertEqual(CloudLibrary.expiryText(now.addingTimeInterval(-5),now: now),"Expired")
        XCTAssertEqual(CloudLibrary.expiryText(now.addingTimeInterval(86_400*12+60),now: now),"Expires in 12 days")
        XCTAssertEqual(CloudLibrary.expiryText(now.addingTimeInterval(86_400+60),now: now),"Expires in 1 day")
        XCTAssertEqual(CloudLibrary.expiryText(now.addingTimeInterval(3 * 3_600),now: now),"Expires in 3 hours")
    }
    func testShareLinksMustBeHTTP() {
        XCTAssertNotNil(ShareLink.validated("https://example.com/s/abc.png"))
        XCTAssertNil(ShareLink.validated("javascript:alert(1)"))
        XCTAssertNil(ShareLink.validated("file:///etc/passwd"))
        XCTAssertNil(ShareLink.validated("not a url"))
    }
}
