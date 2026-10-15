import XCTest
import CoreGraphics
import ImageIO
@testable import EasyshotCore

final class ScreenshotPixelsTests: XCTestCase {
    func testRetinaCropUsesBackingPixels() {
        let display = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        XCTAssertEqual(ScreenshotPixels.cropRect(CGRect(x: -1400, y: 150, width: 301, height: 203), display: display, width: 2880, height: 1800), CGRect(x: 80, y: 100, width: 602, height: 406))
    }

    func testCropUsesActualImageDensityOnScaledDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(ScreenshotPixels.cropRect(CGRect(x: 100, y: 50, width: 300, height: 200), display: display, width: 3840, height: 2160), CGRect(x: 200, y: 100, width: 600, height: 400))
        XCTAssertEqual(ScreenshotPixels.cropRect(CGRect(x: 100, y: 50, width: 300, height: 200), display: display, width: 1920, height: 1080), CGRect(x: 100, y: 50, width: 300, height: 200))
    }

    func testFractionalEdgesExpandToWholePixels() {
        XCTAssertEqual(ScreenshotPixels.cropRect(CGRect(x: 10.25, y: 20.25, width: 30, height: 40), display: CGRect(x: 0, y: 0, width: 100, height: 100), width: 200, height: 200), CGRect(x: 20, y: 40, width: 61, height: 81))
    }

    func testCropClipsEachDisplayAndRejectsInvalidRegions() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(ScreenshotPixels.cropRect(CGRect(x: -20, y: 10, width: 50, height: 40), display: display, width: 200, height: 200), CGRect(x: 0, y: 20, width: 60, height: 80))
        XCTAssertNil(ScreenshotPixels.cropRect(CGRect(x: 200, y: 0, width: 20, height: 20), display: display, width: 200, height: 200))
        XCTAssertNil(ScreenshotPixels.cropRect(.zero, display: display, width: 200, height: 200))
        XCTAssertNil(ScreenshotPixels.cropRect(display, display: .zero, width: 200, height: 200))
        XCTAssertNil(ScreenshotPixels.cropRect(CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20), display: display, width: 200, height: 200))
    }

    func testPNGAndCropPreserveEveryPixelAndDimensions() throws {
        let width = 603, height = 407
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                // Fine detail makes any resampling or JPEG-style loss visible.
                bytes[i] = (x + y) % 2 == 0 ? 0 : 255
                bytes[i+1] = UInt8((x * 17 + y * 31) % 256)
                bytes[i+2] = UInt8((x * 43 + y * 7) % 256)
                bytes[i+3] = 255
            }
        }
        let image = context.makeImage()!
        let data = try ScreenshotPixels.png(image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(raster(decoded, space: space), raster(image, space: space))
        let rect = try XCTUnwrap(ScreenshotPixels.cropRect(CGRect(x: 5.5, y: 6.5, width: 101.5, height: 81.5), display: CGRect(x: 0, y: 0, width: CGFloat(width)/2, height: CGFloat(height)/2), width: width, height: height))
        let cropped = try XCTUnwrap(image.cropping(to: rect))
        XCTAssertEqual(cropped.width, 203)
        XCTAssertEqual(cropped.height, 163)
        let croppedSource = try XCTUnwrap(CGImageSourceCreateWithData(try ScreenshotPixels.png(cropped) as CFData, nil))
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(croppedSource, 0, nil))
        XCTAssertEqual(raster(result, space: space), raster(cropped, space: space))
        // Compare cropped pixels with their original rows, not just a round trip.
        let originalBytes = raster(image, space: space)
        let croppedBytes = raster(result, space: space)
        for row in 0..<cropped.height {
            let start = ((Int(rect.minY) + row) * width + Int(rect.minX)) * 4
            XCTAssertEqual(Array(croppedBytes[row*cropped.width*4..<(row+1)*cropped.width*4]), Array(originalBytes[start..<start+cropped.width*4]))
        }
    }

    func testPNGPreservesWideGamutProfileAndTransparency() throws {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 17, height: 19, bitsPerComponent: 8, bytesPerRow: 17 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0.2, 0.5, 0.5])!)
        context.fill(CGRect(x: 1, y: 1, width: 15, height: 17))
        let image = context.makeImage()!
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try ScreenshotPixels.png(image) as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.colorSpace?.name, space.name)
        XCTAssertEqual(raster(decoded, space: space), raster(image, space: space))
    }

    private func raster(_ image: CGImage, space: CGColorSpace) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width*image.height*4))
    }
}
