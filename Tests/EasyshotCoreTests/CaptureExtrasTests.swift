import XCTest
import CoreGraphics
@testable import EasyshotCore

final class CaptureExtrasTests: XCTestCase {
    let bounds = CGRect(x: 0,y: 0,width: 1000,height: 800)

    func testAspectLockDrawFollowsDominantAxisAndStaysInBounds() {
        let end = AspectLock.end(from: CGPoint(x: 100,y: 100),to: CGPoint(x: 260,y: 120),ratio: 16.0/9,bounds: bounds)
        XCTAssertEqual(end.x,260,accuracy: 0.001); XCTAssertEqual(end.y,190,accuracy: 0.001)
        // Dragging mostly vertically drives the height instead.
        let tall = AspectLock.end(from: CGPoint(x: 100,y: 100),to: CGPoint(x: 110,y: 280),ratio: 1,bounds: bounds)
        XCTAssertEqual(tall,CGPoint(x: 280,y: 280))
        // Near an edge the rectangle shrinks while keeping its ratio.
        let edge = AspectLock.end(from: CGPoint(x: 900,y: 700),to: CGPoint(x: 1000,y: 800),ratio: 4.0/3,bounds: bounds)
        XCTAssertEqual((edge.x-900)/(edge.y-700),4.0/3,accuracy: 0.001)
        XCTAssertLessThanOrEqual(edge.x,1000); XCTAssertLessThanOrEqual(edge.y,800)
        // Leftward/downward drags mirror correctly.
        let mirrored = AspectLock.end(from: CGPoint(x: 500,y: 500),to: CGPoint(x: 340,y: 480),ratio: 16.0/9,bounds: bounds)
        XCTAssertEqual(mirrored.x,340,accuracy: 0.001); XCTAssertEqual(mirrored.y,410,accuracy: 0.001)
    }

    func testInteractionDrawUsesRatioAndShiftOverridesIt() {
        var interaction = RegionInteraction()
        interaction.begin(at: CGPoint(x: 100,y: 100),rect: .zero)
        let wide = interaction.update(to: CGPoint(x: 420,y: 150),bounds: bounds,ratio: 16.0/9)
        XCTAssertEqual(wide.width/wide.height,16.0/9,accuracy: 0.001)
        let square = interaction.update(to: CGPoint(x: 420,y: 150),bounds: bounds,square: true,ratio: 16.0/9)
        XCTAssertEqual(square.width,square.height,accuracy: 0.001)
        XCTAssertEqual(interaction.update(to: CGPoint(x: 420,y: 150),bounds: bounds),CGRect(x: 100,y: 100,width: 320,height: 50))
    }

    func testRatioLockedResizeKeepsOppositeCornerAndEdge() {
        let original = CGRect(x: 100,y: 100,width: 320,height: 180)
        var interaction = RegionInteraction()
        interaction.begin(at: CGPoint(x: 420,y: 280),rect: original)
        XCTAssertEqual(interaction.operation,.resize(.topRight))
        let corner = interaction.update(to: CGPoint(x: 580,y: 290),bounds: bounds,ratio: 16.0/9)
        XCTAssertEqual(corner.origin,original.origin)
        XCTAssertEqual(corner.width/corner.height,16.0/9,accuracy: 0.001)
        XCTAssertEqual(corner.width,480,accuracy: 0.001)
        interaction.begin(at: CGPoint(x: 100,y: 190),rect: original)
        XCTAssertEqual(interaction.operation,.resize(.left))
        let edge = interaction.update(to: CGPoint(x: 20,y: 190),bounds: bounds,ratio: 16.0/9)
        XCTAssertEqual(edge.maxX,original.maxX,accuracy: 0.001)
        XCTAssertEqual(edge.midY,original.midY,accuracy: 0.001)
        XCTAssertEqual(edge.width/edge.height,16.0/9,accuracy: 0.001)
    }

    func testApplyingLockToExistingRectKeepsCentreAndBounds() {
        let rect = AspectLock.portrait.applied(to: CGRect(x: 400,y: 300,width: 300,height: 100),in: bounds)
        XCTAssertEqual(rect.width/rect.height,9.0/16,accuracy: 0.001)
        XCTAssertTrue(bounds.contains(rect))
        XCTAssertEqual(AspectLock.free.applied(to: CGRect(x: 1,y: 2,width: 30,height: 40),in: bounds),CGRect(x: 1,y: 2,width: 30,height: 40))
        XCTAssertEqual(AspectLock.allCases.map(\.title),["Free","16:9","4:3","1:1","9:16"])
    }

    func testQuickAccessStackEvictsPausesExpiresAndRestores() {
        var stack = QuickAccessStack<Int>(autoClose: 5)
        for i in 1...6 { stack.add(i,now: 0) }
        XCTAssertEqual(stack.cards,[2,3,4,5,6],"the oldest card is evicted beyond five")
        XCTAssertEqual(stack.recentlyClosed,[1])
        XCTAssertEqual(stack.nextDeadline,5)
        XCTAssertTrue(stack.expired(now: 4.9).isEmpty)
        stack.setHovered(true,now: 4)
        XCTAssertTrue(stack.expired(now: 100).isEmpty,"hover pauses every timer")
        XCTAssertNil(stack.nextDeadline)
        stack.setHovered(false,now: 100)
        XCTAssertEqual(stack.expired(now: 105),[2,3,4,5,6],"leaving restarts the full duration")
        stack.close(6); stack.close(5)
        XCTAssertEqual(stack.restore(now: 200),5)
        XCTAssertEqual(stack.cards.last,5)
        XCTAssertFalse(stack.recentlyClosed.contains(5),"a restored card is not restored twice")
        stack.setAutoClose(nil,now: 200)
        XCTAssertNil(stack.nextDeadline,"auto-close off keeps cards until dismissed")
    }

    func testQuickAccessFramesStackUpFromTheCorner() {
        let frames = QuickAccessStack<Int>.frames(count: 3,size: CGSize(width: 200,height: 100),in: CGRect(x: 1000,y: 50,width: 1440,height: 850))
        XCTAssertEqual(frames[0],CGRect(x: 2220,y: 70,width: 200,height: 100))
        XCTAssertEqual(frames[1].minY,frames[0].maxY+12)
        XCTAssertTrue(frames.allSatisfy { $0.maxX == 2420 })
    }

    func testRecognizedTextReadsRowsLeftToRightAndDedupesCodes() {
        let lines = [
            RecognizedText.Line(text: "World",box: CGRect(x: 0.5,y: 0.8,width: 0.2,height: 0.05)),
            RecognizedText.Line(text: "Hello",box: CGRect(x: 0.1,y: 0.81,width: 0.2,height: 0.05)),
            RecognizedText.Line(text: "Second line",box: CGRect(x: 0.1,y: 0.6,width: 0.4,height: 0.05)),
            RecognizedText.Line(text: "  ",box: CGRect(x: 0.1,y: 0.3,width: 0.4,height: 0.05)),
        ]
        XCTAssertEqual(RecognizedText.ordered(lines).map(\.text).prefix(3),["Hello","World","Second line"])
        let text = RecognizedText.assemble(lines: lines,codes: ["https://easyshot.app","World","https://easyshot.app"])
        XCTAssertEqual(text,"Hello\tWorld\nSecond line\nhttps://easyshot.app")
        XCTAssertEqual(RecognizedText.assemble(lines: [],codes: []),"")
        XCTAssertEqual(RecognizedText.assemble(lines: [],codes: ["QR"]),"QR")
    }

    func testLoupeSamplingGeometryAndHex() {
        XCTAssertEqual(PixelLoupe.hex(red: 255,green: 8,blue: 171),"#FF08AB")
        let rect = PixelLoupe.sampleRect(around: CGPoint(x: 100.7,y: 50.2),scale: 2)
        XCTAssertEqual(rect.width*2,CGFloat(PixelLoupe.samplePixels),accuracy: 0.001)
        XCTAssertEqual(rect.midX*2,201.5,accuracy: 0.001,"the centre pixel is the one under the pointer")
        XCTAssertEqual(rect.midY*2,100.5,accuracy: 0.001)
        let size = CGSize(width: 160,height: 200)
        let normal = PixelLoupe.placement(pointer: CGPoint(x: 300,y: 500),size: size,in: bounds)
        XCTAssertEqual(normal.minX,326); XCTAssertEqual(normal.maxY,474)
        let flipped = PixelLoupe.placement(pointer: CGPoint(x: 990,y: 20),size: size,in: bounds)
        XCTAssertLessThan(flipped.maxX,990); XCTAssertGreaterThan(flipped.minY,20)
        XCTAssertTrue(bounds.contains(flipped))
    }

    func testWindowBackdropPadsAtNativePixelsAndKeepsTheWindowExact() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil,width: 40,height: 30,bitsPerComponent: 8,bytesPerRow: 0,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0,green: 1,blue: 0,alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: 40,height: 30))
        let window = try XCTUnwrap(ctx.makeImage())
        let red = CGColor(srgbRed: 1,green: 0,blue: 0,alpha: 1)
        let solid = try XCTUnwrap(WindowBackdrop.compose(window,fill: .solid(red),padding: 10))
        XCTAssertEqual(solid.width,60); XCTAssertEqual(solid.height,50)
        XCTAssertEqual(pixel(solid,x: 2,y: 2),[255,0,0,255])
        XCTAssertEqual(pixel(solid,x: 30,y: 25),[0,255,0,255])
        let clear = try XCTUnwrap(WindowBackdrop.compose(window,fill: .clear,padding: 6))
        XCTAssertEqual(pixel(clear,x: 1,y: 1)[3],0,"transparent padding stays transparent")
        let gradient = try XCTUnwrap(WindowBackdrop.compose(window,fill: .gradient(red,CGColor(srgbRed: 0,green: 0,blue: 1,alpha: 1)),padding: 10))
        XCTAssertNotEqual(pixel(gradient,x: 1,y: 1),pixel(gradient,x: 58,y: 48))
        let photo = try XCTUnwrap(WindowBackdrop.compose(window,fill: .image(window),padding: 10))
        XCTAssertEqual(pixel(photo,x: 1,y: 1),[0,255,0,255],"image fill covers the whole canvas")
    }

    func testNewCaptureKeysAndLaunchActions() {
        XCTAssertEqual(CaptureKeyAction.resolve("t"),.captureText)
        XCTAssertEqual(CaptureKeyAction.resolve("M"),.magnifier)
        XCTAssertEqual(CaptureKeyAction.resolve("c"),.copyColor)
        XCTAssertNil(CaptureKeyAction.resolve("c",command: true),"⌘C is never swallowed by the capture bar")
        XCTAssertEqual(CaptureKeyAction.sanitizedUploadKey("t"),"u","the upload key may not shadow fixed keys")
        XCTAssertEqual(LaunchAction(url: URL(string: "easyshot://capture-text")!),.captureText)
        XCTAssertEqual(LaunchAction(url: URL(string: "easyshot://restore-overlay")!),.restoreOverlay)
    }

    private func pixel(_ image: CGImage,x: Int,y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0,count: 4)
        data.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress,width: 1,height: 1,bitsPerComponent: 8,bytesPerRow: 4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // CGImage rows start at the top; draw so pixel (x, y from top) lands on the single output pixel.
            ctx.draw(image,in: CGRect(x: -x,y: -(image.height-1-y),width: image.width,height: image.height))
        }
        return data
    }
}
