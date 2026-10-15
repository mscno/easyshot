import XCTest
@testable import EasyshotCore

final class EditorGeometryTests: XCTestCase {
    func testCurvedArrowPassesThroughItsBend() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 100, y: 0), bend = CGPoint(x: 50, y: 30)
        let c = ArrowGeometry.control(from: a, to: b, through: bend)
        let mid = ArrowGeometry.point(a, c, b, 0.5)
        XCTAssertEqual(mid.x, 50, accuracy: 0.001); XCTAssertEqual(mid.y, 30, accuracy: 0.001)
        // The head follows the curve's direction at the tip, which descends towards b.
        XCTAssertLessThan(ArrowGeometry.tangentAngle(a, c, b, atEnd: true), 0)
        XCTAssertEqual(ArrowGeometry.tangentAngle(a, CGPoint(x: 50, y: 0), b, atEnd: true), 0, accuracy: 0.0001)
    }
    func testDefaultBendIsPerpendicular() {
        let bend = ArrowGeometry.defaultBend(from: .zero, to: CGPoint(x: 100, y: 0))
        XCTAssertEqual(bend.x, 50, accuracy: 0.001); XCTAssertEqual(abs(bend.y), 18, accuracy: 0.001)
    }
    func testTaperedOutlineNarrowsTowardsTheTip() {
        let outline = ArrowGeometry.taperedOutline(.zero, CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0), start: 10, end: 2, steps: 10)
        XCTAssertEqual(outline.count, 22)
        XCTAssertEqual(abs(outline[0].y - outline[21].y), 10, accuracy: 0.001)
        XCTAssertEqual(abs(outline[10].y - outline[11].y), 2, accuracy: 0.001)
    }
    func testSmoothingIsIndependentOfSampleRate() {
        // One zig-zag path delivered as few events or as many events along the same lines.
        let vertices = (0...20).map { CGPoint(x: CGFloat($0)*10, y: $0 % 2 == 0 ? 0 : 6) }
        var dense: [CGPoint] = [vertices[0]]
        for (a, b) in zip(vertices, vertices.dropFirst()) { for k in 1...10 { let f = CGFloat(k)/10; dense.append(CGPoint(x: a.x+(b.x-a.x)*f, y: a.y+(b.y-a.y)*f)) } }
        let s1 = StrokeSmoother.smooth(vertices), s2 = StrokeSmoother.smooth(dense)
        func y(_ points: [CGPoint], at x: CGFloat) -> CGFloat { points.min { abs($0.x-x) < abs($1.x-x) }!.y }
        for x in stride(from: 20.0, through: 180, by: 7) { XCTAssertEqual(y(s1, at: x), y(s2, at: x), accuracy: 0.25) }
        XCTAssertEqual(s1.first, vertices.first); XCTAssertEqual(s1.last, vertices.last)
        let inner = s2.dropFirst(10).dropLast(10).map(\.y)
        XCTAssertLessThan(inner.max()!-inner.min()!, 6, "zig-zag amplitude shrinks")
    }
    func testResampleSpacing() {
        let points = StrokeSmoother.resample([.zero, CGPoint(x: 10, y: 0)], spacing: 2)
        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(points[1].x, 2, accuracy: 0.0001)
    }
    func testCropAspectAndBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let square = CropMath.constrain(anchor: CGPoint(x: 100, y: 100), point: CGPoint(x: 180, y: 140), ratio: 1, bounds: bounds)
        XCTAssertEqual(square, CGRect(x: 100, y: 100, width: 80, height: 80))
        let wide = CropMath.constrain(anchor: CGPoint(x: 300, y: 200), point: CGPoint(x: 0, y: 190), ratio: 16/9, bounds: bounds)
        XCTAssertEqual(wide.width/wide.height, 16/9, accuracy: 0.001)
        XCTAssertEqual(wide.maxX, 300, accuracy: 0.001)
        XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(wide))
        let clipped = CropMath.constrain(anchor: CGPoint(x: 380, y: 280), point: CGPoint(x: 600, y: 600), ratio: 1, bounds: bounds)
        XCTAssertEqual(clipped, CGRect(x: 380, y: 280, width: 20, height: 20))
        XCTAssertEqual(CropMath.constrain(anchor: .zero, point: CGPoint(x: 30, y: 10), ratio: nil, bounds: bounds), CGRect(x: 0, y: 0, width: 30, height: 10))
    }
    func testSnapping() {
        let guides = CropMath.guides(bounds: CGRect(x: 0, y: 0, width: 400, height: 300), objects: [CGRect(x: 50, y: 60, width: 100, height: 20)])
        XCTAssertEqual(CropMath.snapPoint(CGPoint(x: 147, y: 296), xGuides: guides.x, yGuides: guides.y, tolerance: 6), CGPoint(x: 150, y: 300))
        XCTAssertEqual(CropMath.snapPoint(CGPoint(x: 120, y: 120), xGuides: guides.x, yGuides: guides.y, tolerance: 6), CGPoint(x: 120, y: 120))
    }
    func testHighlighterSnapsToTextLines() {
        let lines = [CGRect(x: 10, y: 100, width: 300, height: 18), CGRect(x: 10, y: 124, width: 280, height: 18)]
        let one = HighlightSnap.snap(CGRect(x: 20, y: 103, width: 120, height: 9), lines: lines)
        XCTAssertEqual(one.minY, 98, accuracy: 0.001); XCTAssertEqual(one.height, 22, accuracy: 0.001)
        XCTAssertEqual(one.minX, 20)
        let two = HighlightSnap.snap(CGRect(x: 20, y: 98, width: 120, height: 44), lines: lines)
        XCTAssertEqual(two.minY, 98, accuracy: 0.001); XCTAssertEqual(two.maxY, 144, accuracy: 0.001)
        let none = CGRect(x: 20, y: 200, width: 50, height: 10)
        XCTAssertEqual(HighlightSnap.snap(none, lines: lines), none)
    }
    func testScrambleIsDeterministicAndDestroysLayout() {
        let count = 64
        var original = [UInt8](); for i in 0..<count { original += [UInt8(i*4), UInt8(255-i*4), 128, 255] }
        var a = original, b = original, c = original
        PixelScramble.scramble(&a, count: count, seed: 7)
        PixelScramble.scramble(&b, count: count, seed: 7)
        PixelScramble.scramble(&c, count: count, seed: 8)
        XCTAssertEqual(a, b); XCTAssertNotEqual(a, c)
        let moved = (0..<count).filter { abs(Int(a[$0*4])-Int(original[$0*4])) > 20 }.count
        XCTAssertGreaterThan(moved, count/2, "most blocks leave their position")
        XCTAssertTrue((0..<count).allSatisfy { a[$0*4+3] == 255 })
    }
    func testBackdropLayout() {
        let plain = BackdropLayout.layout(content: CGSize(width: 100, height: 50), padding: 20, aspect: .auto, alignment: .center, autoBalance: false)
        XCTAssertEqual(plain.canvas, CGSize(width: 140, height: 90)); XCTAssertEqual(plain.origin, CGPoint(x: 20, y: 20))
        let square = BackdropLayout.layout(content: CGSize(width: 100, height: 50), padding: 20, aspect: .square, alignment: .bottomRight, autoBalance: false)
        XCTAssertEqual(square.canvas, CGSize(width: 140, height: 140)); XCTAssertEqual(square.origin, CGPoint(x: 20, y: 70))
        let top = BackdropLayout.layout(content: CGSize(width: 100, height: 50), padding: 20, aspect: .square, alignment: .top, autoBalance: false)
        XCTAssertEqual(top.origin, CGPoint(x: 20, y: 20))
        // A window screenshot with a 30 px transparent shadow margin at the bottom only.
        let balanced = BackdropLayout.layout(content: CGSize(width: 100, height: 80), visible: CGRect(x: 0, y: 0, width: 100, height: 50), padding: 20, aspect: .auto, alignment: .center, autoBalance: true)
        XCTAssertEqual(balanced.canvas, CGSize(width: 140, height: 90))
        XCTAssertEqual(balanced.origin, CGPoint(x: 20, y: 20))
    }
    func testOpaqueBounds() {
        let w = 20, h = 10
        let bounds = BackdropLayout.opaqueBounds(alpha: { x, y in (4...15).contains(x) && (2...6).contains(y) ? 255 : 0 }, width: w, height: h)
        XCTAssertEqual(bounds, CGRect(x: 4, y: 2, width: 12, height: 5))
        XCTAssertNil(BackdropLayout.opaqueBounds(alpha: { _, _ in 0 }, width: w, height: h))
    }
    func testAlignmentFactors() {
        XCTAssertEqual(BackdropAlignment.topLeft.factors.x, 0); XCTAssertEqual(BackdropAlignment.bottomRight.factors.y, 1)
        XCTAssertEqual(BackdropAlignment.center.factors.x, 0.5)
    }
}
