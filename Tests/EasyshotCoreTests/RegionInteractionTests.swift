import XCTest
import CoreGraphics
@testable import EasyshotCore

final class RegionInteractionTests: XCTestCase {
    let bounds = CGRect(x: -1000,y: -500,width: 2400,height: 1600)
    let rect = CGRect(x: 100,y: 200,width: 400,height: 300)
    func testDragInsideMovesWithoutChangingSize() {
        var drag = RegionInteraction()
        drag.begin(at: CGPoint(x: 300,y: 350),rect: rect)
        XCTAssertEqual(drag.operation,.move)
        XCTAssertEqual(drag.update(to: CGPoint(x: -200,y: 650),bounds: bounds),rect.offsetBy(dx: -500,dy: 300))
    }
    func testMovingClampsToDesktopBounds() {
        var drag = RegionInteraction()
        drag.begin(at: CGPoint(x: 300,y: 350),rect: rect)
        XCTAssertEqual(drag.update(to: CGPoint(x: 5000,y: -5000),bounds: bounds),CGRect(x: 1000,y: -500,width: 400,height: 300))
    }
    func testDrawNewOverridesMovingEvenInsideOldArea() {
        var drag = RegionInteraction()
        drag.begin(at: CGPoint(x: 300,y: 350),rect: rect,forceDraw: true)
        XCTAssertEqual(drag.operation,.draw)
        XCTAssertEqual(drag.update(to: CGPoint(x: 450,y: 450),bounds: bounds),CGRect(x: 300,y: 350,width: 150,height: 100))
    }
    func testOutsideDragReplacesSelection() {
        var drag = RegionInteraction()
        drag.begin(at: CGPoint(x: -300,y: 0),rect: rect)
        XCTAssertEqual(drag.operation,.draw)
        XCTAssertEqual(drag.update(to: CGPoint(x: -600,y: -200),bounds: bounds),CGRect(x: -600,y: -200,width: 300,height: 200))
    }
    func testEveryHandleResizesWithOppositeEdgesFixed() {
        for handle in RegionInteraction.Handle.allCases {
            var drag = RegionInteraction()
            let p = handle.point(in: rect)
            drag.begin(at: p,rect: rect)
            XCTAssertEqual(drag.operation,.resize(handle))
            let result = drag.update(to: CGPoint(x: p.x+20,y: p.y+30),bounds: bounds)
            XCTAssertGreaterThan(result.width,0); XCTAssertGreaterThan(result.height,0)
            if [.bottomLeft,.topLeft,.left].contains(handle) { XCTAssertEqual(result.maxX,rect.maxX) }
            if [.bottomRight,.topRight,.right].contains(handle) { XCTAssertEqual(result.minX,rect.minX) }
            if [.bottomLeft,.bottomRight,.bottom].contains(handle) { XCTAssertEqual(result.maxY,rect.maxY) }
            if [.topLeft,.topRight,.top].contains(handle) { XCTAssertEqual(result.minY,rect.minY) }
        }
    }
    func testHandleHitTargetsAreLargerThanVisibleHandle() {
        XCTAssertEqual(RegionInteraction.handle(at: CGPoint(x: 105,y: 205),in: rect),.bottomLeft)
        XCTAssertNil(RegionInteraction.handle(at: CGPoint(x: 300,y: 350),in: rect))
    }
    func testResizeCannotInvertRectangle() {
        var drag = RegionInteraction()
        drag.begin(at: CGPoint(x: 100,y: 350),rect: rect)
        let result = drag.update(to: CGPoint(x: 900,y: 350),bounds: bounds)
        XCTAssertEqual(result.width,3); XCTAssertEqual(result.maxX,rect.maxX)
    }
    func testShiftDrawKeepsSquareAtScreenEdge() {
        var drag = RegionInteraction()
        drag.begin(at: CGPoint(x: 1300,y: 900),rect: .zero)
        let result = drag.update(to: CGPoint(x: 1800,y: 1000),bounds: bounds,square: true)
        XCTAssertEqual(result.width,100); XCTAssertEqual(result.height,100)
        XCTAssertTrue(bounds.contains(result))
    }
    func testDragAcrossMonitorsPreservesNegativeCoordinates() {
        var drag = RegionInteraction()
        drag.begin(at: CGPoint(x: -500,y: 100),rect: .zero)
        XCTAssertEqual(drag.update(to: CGPoint(x: 500,y: 600),bounds: bounds),CGRect(x: -500,y: 100,width: 1000,height: 500))
    }
    func testAllLauncherRoutes() {
        for action in LaunchAction.allCases {
            XCTAssertEqual(LaunchAction(url: URL(string: "easyshot://\(action.rawValue)")!),action)
            XCTAssertEqual(LaunchAction(url: URL(string: "easyshot-dev://\(action.rawValue)")!),action)
        }
    }
    func testInvalidURLsCannotRouteActions() {
        for value in ["https://capture","easyshot://unknown","easyshot://capture/path","easyshot://capture?file=secret","easyshot://user@draw","easyshot://capture:80","easyshot://capture#foo"] {
            XCTAssertNil(LaunchAction(url: URL(string: value)!))
        }
    }
}
