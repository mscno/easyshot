import XCTest
import CoreGraphics
@testable import EasyshotCore

final class GeometryTests: XCTestCase {
    func testQuartzRoundTripAcrossDisplays() {
        let rects = [CGRect(x: 20,y: 30,width: 640,height: 480),CGRect(x: -1600,y: 800,width: 900,height: 650),CGRect(x: 200,y: -900,width: 500,height: 500)]
        for rect in rects {
            let quartz = CaptureGeometry.quartz(rect,primaryHeight: 1080)
            XCTAssertEqual(CaptureGeometry.quartz(quartz,primaryHeight: 1080),rect)
            XCTAssertEqual(quartz.maxY,1080-rect.minY)
        }
    }
    func testDrawingInEveryDirection() {
        for point in [CGPoint(x: 30,y: 40),CGPoint(x: -30,y: 40),CGPoint(x: 30,y: -40),CGPoint(x: -30,y: -40)] {
            let result = CaptureGeometry.rectangle(from: .zero,to: point)
            XCTAssertEqual(result.width,30); XCTAssertEqual(result.height,40)
            XCTAssertEqual(result.minX,min(0,point.x)); XCTAssertEqual(result.minY,min(0,point.y))
        }
    }
    func testPresetClampsToSmallerDisplay() {
        let result = CaptureGeometry.clamped(CGRect(x: -3000,y: 2000,width: 2000,height: 1200),to: CGRect(x: -1280,y: 0,width: 1280,height: 720))
        XCTAssertEqual(result,CGRect(x: -1280,y: 0,width: 1280,height: 720))
    }
    func testRegionCoordinatesOnNegativeDisplay() {
        let display = CGRect(x: -1920,y: 0,width: 1920,height: 1080)
        XCTAssertEqual(CaptureGeometry.sourceRect(CGRect(x: -1800,y: 100,width: 500,height: 300),in: display),CGRect(x: 120,y: 100,width: 500,height: 300))
    }
    func testRegionCrossingDisplaysClipsCorrectly() {
        let region = CGRect(x: -100,y: 50,width: 300,height: 200)
        XCTAssertEqual(CaptureGeometry.sourceRect(region,in: CGRect(x: 0,y: 0,width: 1920,height: 1080)),CGRect(x: 0,y: 50,width: 200,height: 200))
        XCTAssertEqual(CaptureGeometry.sourceRect(region,in: CGRect(x: -1920,y: 0,width: 1920,height: 1080)),CGRect(x: 1820,y: 50,width: 100,height: 200))
    }
    func testOffscreenRegionReturnsZero() {
        XCTAssertEqual(CaptureGeometry.sourceRect(CGRect(x: 4000,y: 0,width: 30,height: 30),in: CGRect(x: 0,y: 0,width: 1920,height: 1080)),.zero)
    }
    func testFilenamesAvoidSameMillisecondCollisions() {
        let date = Date(timeIntervalSince1970: 0)
        let a = CaptureFiles.filename(date: date,extension: "png",token: "aaaaaa")
        let b = CaptureFiles.filename(date: date,extension: "png",token: "bbbbbb")
        XCTAssertNotEqual(a,b); XCTAssertTrue(a.hasSuffix("aaaaaa.png")); XCTAssertFalse(a.contains("/"))
    }
    func testModesHaveDistinctKeyboardSelectors() { XCTAssertEqual(Set(CaptureMode.allCases.map(\.key)).count,5) }
}
