import XCTest
import CoreGraphics
@testable import ShotglassCore

final class StudioTests: XCTestCase {
    func track(_ clicks: [(Double, Double, Double)], width: Double = 2000, height: Double = 1000) -> CursorTrack {
        var track = CursorTrack(width: width, height: height, scale: 2)
        track.samples = [.init(t: 0, x: width/2, y: height/2)]
        track.clicks = clicks.map { .init(t: $0.0, x: $0.1, y: $0.2) }
        return track
    }
    func testNearbyClicksClusterIntoOneSegment() {
        let segments = StudioPlanner.segments(for: track([(2, 400, 300), (3.5, 450, 320), (5, 500, 300)]), duration: 20, zoom: 2)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 2-0.6-StudioPlanner.lead, accuracy: 1e-9)
        XCTAssertEqual(segments[0].end, 5+StudioPlanner.hold+0.6, accuracy: 1e-9)
        XCTAssertEqual(segments[0].anchor, CGPoint(x: 400, y: 300))
    }
    func testDistantPausesSplitAndCloseSegmentsMerge() {
        XCTAssertEqual(StudioPlanner.segments(for: track([(2, 400, 300), (10, 400, 300)]), duration: 20, zoom: 2).count, 2)
        // 2.9 s apart: separate clusters, but their ramps nearly touch, so they merge.
        let merged = StudioPlanner.segments(for: track([(2, 400, 300), (4.9, 420, 300)]), duration: 20, zoom: 2)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].anchor, CGPoint(x: 400, y: 300))
    }
    func testFarJumpStartsNewCluster() {
        let segments = StudioPlanner.segments(for: track([(2, 100, 100), (3.5, 1900, 900)]), duration: 30, zoom: 2)
        XCTAssertEqual(segments.count, 1, "close in time, so ramps still merge")
        let apart = StudioPlanner.segments(for: track([(2, 100, 100), (4.4, 1900, 900), (12, 100, 100)]), duration: 30, zoom: 2)
        XCTAssertEqual(apart.count, 2)
    }
    func testTypingExtendsTheLastClickSegment() {
        var t = track([(2, 400, 300)])
        t.keys = stride(from: 3.0, through: 8.0, by: 0.2).map { $0 }
        let segments = StudioPlanner.segments(for: t, duration: 30, zoom: 2)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].end, 8+StudioPlanner.hold+0.6, accuracy: 1e-6)
    }
    func testSegmentsClampToDuration() {
        let segments = StudioPlanner.segments(for: track([(0.1, 400, 300), (9.9, 400, 300)]), duration: 10, zoom: 2)
        XCTAssertTrue(segments.allSatisfy { $0.start >= 0 && $0.end <= 10 })
    }
    func testZoomEasesAndViewportStaysInsideFrame() {
        var plan = StudioPlan()
        plan.segments = [ZoomSegment(start: 1, end: 5, scale: 2, anchor: CGPoint(x: 10, y: 10))]
        var t = track([])
        t.samples = [.init(t: 0, x: 10, y: 10), .init(t: 6, x: 1990, y: 990)]
        let timeline = StudioTimeline(track: t, plan: plan, duration: 6)
        XCTAssertEqual(timeline.zoom(at: 0.5), 1)
        XCTAssertEqual(timeline.zoom(at: 1.3), 1.5, accuracy: 1e-9, "halfway through the ramp")
        XCTAssertEqual(timeline.zoom(at: 3), 2)
        let frame = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        for i in 0...600 {
            let v = timeline.viewport(at: Double(i)/100)
            XCTAssertTrue(frame.insetBy(dx: -0.001, dy: -0.001).contains(v), "viewport \(v) at \(Double(i)/100)")
        }
        XCTAssertEqual(timeline.viewport(at: 3).size, CGSize(width: 1000, height: 500))
        XCTAssertEqual(timeline.viewport(at: 0.2), frame)
    }
    func testSmoothingIsTimeBasedAndConverges() {
        var plan = StudioPlan(); plan.smoothing = 0.6
        func smoothed(rate: Double) -> CGPoint {
            var t = track([])
            t.samples = stride(from: 0.0, through: 1.0, by: 1/rate).map { .init(t: $0, x: $0 < 0.5 ? 0 : 1000, y: 0) } + [.init(t: 3, x: 1000, y: 0)]
            return StudioTimeline(track: t, plan: plan, duration: 3).cursor(at: 0.6)
        }
        // The same motion sampled at 30 and 60 Hz must glide identically.
        XCTAssertEqual(smoothed(rate: 30).x, smoothed(rate: 60).x, accuracy: 40)
        var t = track([])
        t.samples = [.init(t: 0, x: 0, y: 0), .init(t: 0.5, x: 0, y: 0), .init(t: 0.51, x: 1000, y: 500), .init(t: 3, x: 1000, y: 500)]
        let timeline = StudioTimeline(track: t, plan: plan, duration: 3)
        let early = timeline.cursor(at: 0.55)
        XCTAssertGreaterThan(early.x, 0); XCTAssertLessThan(early.x, 900, "a jump glides instead of teleporting")
        XCTAssertEqual(timeline.cursor(at: 2.5).x, 1000, accuracy: 1)
        plan.smoothing = 0
        XCTAssertEqual(StudioTimeline(track: t, plan: plan, duration: 3).cursor(at: 0.55).x, 1000, accuracy: 0.5)
    }
    func testPressScaleDipsBriefly() {
        var plan = StudioPlan(); plan.segments = []
        let timeline = StudioTimeline(track: track([(1, 0, 0)]), plan: plan, duration: 3)
        XCTAssertEqual(timeline.pressScale(at: 0.9), 1)
        XCTAssertLessThan(timeline.pressScale(at: 1.15), 0.9)
        XCTAssertEqual(timeline.pressScale(at: 1.5), 1)
    }
    func testOutputSizesStayEvenAndKeepAspect() {
        XCTAssertEqual(StudioOutput.p1080.size(for: CGSize(width: 3024, height: 1964)), CGSize(width: 1662, height: 1080))
        XCTAssertEqual(StudioOutput.p2160.size(for: CGSize(width: 1000, height: 3000)), CGSize(width: 1000, height: 3000), "presets never upscale")
        XCTAssertEqual(StudioOutput.p1080.size(for: CGSize(width: 1800, height: 2880)), CGSize(width: 1080, height: 1728), "portrait fits 1080×1920")
        let size = StudioOutput.source.size(for: CGSize(width: 1513, height: 977))
        XCTAssertEqual(size, CGSize(width: 1514, height: 978))
    }
    func testPlanAndShapeLookupRoundTrip() throws {
        var plan = StudioPlan(); plan.background = .image("/tmp/x.heic"); plan.segments = [ZoomSegment(start: 1, end: 2, scale: 2)]
        XCTAssertEqual(try JSONDecoder().decode(StudioPlan.self, from: JSONEncoder().encode(plan)), plan)
        var t = track([]); t.shapeChanges = [.init(t: 0, i: 0), .init(t: 2, i: 1), .init(t: 4, i: 0)]
        XCTAssertEqual(t.shape(at: 1), 0); XCTAssertEqual(t.shape(at: 2), 1); XCTAssertEqual(t.shape(at: 9), 0)
        XCTAssertEqual(CursorTrack.sidecarURL(for: URL(fileURLWithPath: "/a/b/Shot 1.mp4")).path, "/a/b/.Shot 1.mp4.shotglass-cursor.json")
    }
}
