import XCTest
@testable import EasyshotCore

final class RecordingClockTests: XCTestCase {
    func testPauseCutsTheGapWithoutAFrozenFrame() {
        var clock = PauseClock(frameDuration: 0.1)
        var video: [Double] = []
        for i in 0..<10 { if let t = clock.map(100+Double(i)*0.1, track: 0) { video.append(t) } }
        clock.pause()
        for i in 10..<30 { XCTAssertNil(clock.map(100+Double(i)*0.1, track: 0)); XCTAssertNil(clock.map(100+Double(i)*0.1, track: 1)) }
        clock.resume()
        XCTAssertNil(clock.map(103.0, track: 1), "audio waits for the first video frame after a resume")
        for i in 30..<40 { if let t = clock.map(100+Double(i)*0.1, track: 0) { video.append(t) } }
        XCTAssertEqual(video.count, 20)
        for (a, b) in zip(video, video.dropFirst()) { XCTAssertEqual(b-a, 0.1, accuracy: 0.0001) }
        XCTAssertEqual(clock.removed, 2.0, accuracy: 0.0001)
        XCTAssertEqual(clock.map(104.05, track: 1)!, 102.05, accuracy: 0.0001)
    }
    func testOutputTimeForSideData() {
        var clock = PauseClock(frameDuration: 0.1)
        _ = clock.map(0, track: 0); _ = clock.map(0.9, track: 0)
        clock.pause(); clock.resume()
        _ = clock.map(3.0, track: 0)
        XCTAssertEqual(clock.cuts, [PauseClock.Cut(start: 1.0, end: 3.0)])
        XCTAssertEqual(clock.outputTime(0.5)!, 0.5, accuracy: 0.0001)
        XCTAssertNil(clock.outputTime(2))
        XCTAssertEqual(clock.outputTime(3.5)!, 1.5, accuracy: 0.0001)
        XCTAssertEqual(clock.clampedOutputTime(2), 1.0, accuracy: 0.0001)
        XCTAssertEqual(clock.clampedOutputTime(3.5), 1.5, accuracy: 0.0001)
    }
    func testTimesNeverGoBackwards() {
        var clock = PauseClock(frameDuration: 1/30)
        XCTAssertNotNil(clock.map(1, track: 1)); XCTAssertNil(clock.map(0.99, track: 1)); XCTAssertNil(clock.map(1, track: 1))
        XCTAssertNotNil(clock.map(0.5, track: 0), "tracks are independent")
    }
    func testShortPauseRemovesNothing() {
        var clock = PauseClock(frameDuration: 0.1)
        _ = clock.map(0, track: 0); clock.pause(); clock.resume()
        XCTAssertEqual(clock.map(0.1, track: 0), 0.1)
        XCTAssertTrue(clock.cuts.isEmpty)
    }
    func testRetention() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertFalse(HistoryRetention.forever.isExpired(now.addingTimeInterval(-1e9), now: now))
        XCTAssertTrue(HistoryRetention.week.isExpired(now.addingTimeInterval(-8*86_400), now: now))
        XCTAssertFalse(HistoryRetention.month.isExpired(now.addingTimeInterval(-8*86_400), now: now))
        XCTAssertTrue(HistoryRetention.mayDeleteFile("/x/Support/Easyshot/Captures/a.png", internalFolder: "/x/Support/Easyshot/Captures"))
        XCTAssertFalse(HistoryRetention.mayDeleteFile("/Users/me/Documents/Screenshots/a.png", internalFolder: "/x/Support/Easyshot/Captures"))
        XCTAssertFalse(HistoryRetention.mayDeleteFile("/x/Support/Easyshot/CapturesOther/a.png", internalFolder: "/x/Support/Easyshot/Captures"))
        XCTAssertFalse(HistoryRetention.mayDeleteFile("/x/Support/Easyshot/Captures/../../b.png", internalFolder: "/x/Support/Easyshot/Captures"))
    }
    func testStudioAspectViewportAndCanvas() {
        let source = CGSize(width: 2560, height: 1440)
        XCTAssertEqual(StudioPlan.viewport(source: source, aspect: .vertical), CGSize(width: 810, height: 1440))
        XCTAssertEqual(StudioPlan.viewport(source: source, aspect: .square), CGSize(width: 1440, height: 1440))
        XCTAssertEqual(StudioPlan.viewport(source: source, aspect: .source), source)
        var plan = StudioPlan(); plan.aspect = .vertical; plan.output = .source
        XCTAssertEqual(plan.canvasSize(for: source), CGSize(width: 810, height: 1440))
        plan.aspect = .landscape
        XCTAssertEqual(plan.canvasSize(for: CGSize(width: 1000, height: 1000)), CGSize(width: 1000, height: 562))
    }
    func testReframedViewportFollowsTheCursor() {
        var track = CursorTrack(width: 1600, height: 900, scale: 1)
        track.samples = [.init(t: 0, x: 100, y: 450), .init(t: 4, x: 1500, y: 450)]
        var plan = StudioPlan(); plan.aspect = .vertical; plan.smoothing = 0
        let timeline = StudioTimeline(track: track, plan: plan, duration: 6)
        let early = timeline.viewport(at: 0.2), late = timeline.viewport(at: 5.5)
        XCTAssertEqual(early.width, 506.25, accuracy: 0.01); XCTAssertEqual(early.height, 900, accuracy: 0.01)
        XCTAssertEqual(early.minX, 0, accuracy: 1)
        XCTAssertEqual(late.maxX, 1600, accuracy: 2)
    }
    func testOlderPlansDecodeWithDefaults() throws {
        let json = #"{"autoZoom":false,"zoom":2,"segments":[],"showCursor":true,"cursorScale":1,"smoothing":0.5,"transition":0.6,"background":{"none":{}},"padding":0.05,"cornerRadius":0.01,"shadow":true,"motionBlur":true,"output":"source","hevc":false}"#
        let plan = try JSONDecoder().decode(StudioPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.zoom, 2); XCTAssertFalse(plan.autoZoom); XCTAssertTrue(plan.motionBlur)
        XCTAssertEqual(plan.aspect, .source); XCTAssertEqual(plan.cursorStyle, .macOS); XCTAssertEqual(plan.motionBlurAmount, 0.5)
        var edited = plan; edited.aspect = .square; edited.cursorStyle = .dot
        XCTAssertEqual(try JSONDecoder().decode(StudioPlan.self, from: JSONEncoder().encode(edited)), edited)
    }
}
