import XCTest
import AppKit
import ScreenCaptureKit
@testable import EasyshotCore

final class NativeScreenshotTests: XCTestCase {
    /// Opt-in hardware check: CI still runs the deterministic PNG/pixel tests.
    /// No permission prompt, clipboard changes, user captures or saved settings.
    @MainActor func testNativeScreenshotKeepsOnePixelDetail() async throws {
        guard ProcessInfo.processInfo.environment["EASYSHOT_TEST_SCREEN_CAPTURE"] == "1" else {
            throw XCTSkip("Set EASYSHOT_TEST_SCREEN_CAPTURE=1 for the local display check.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording access is not already granted; no prompt will be shown.")
        }
        guard let screen = NSScreen.main else { throw XCTSkip("No display attached.") }
        let density = screen.backingScaleFactor
        let size = CGSize(width: 160, height: 120)
        let width = Int(size.width*density), height = Int(size.height*density)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let pattern = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = pattern.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y*width+x)*4
                let value: UInt8 = (x+y)%2 == 0 ? 0 : 255
                bytes[i] = value; bytes[i+1] = value; bytes[i+2] = value; bytes[i+3] = 255
            }
        }
        let panel = NSPanel(contentRect: CGRect(x: screen.frame.midX-80, y: screen.frame.midY-60, width: size.width, height: size.height), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.contentView!.wantsLayer = true
        panel.contentView!.layer!.contents = pattern.makeImage()!
        panel.contentView!.layer!.contentsScale = density
        panel.contentView!.layer!.magnificationFilter = .nearest
        panel.contentView!.layer!.minificationFilter = .nearest
        panel.orderFrontRegardless()
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(150))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let window = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) })
        let image = try await ScreenshotPixels.capture(SCContentFilter(desktopIndependentWindow: window), cursor: false, shadow: false)
        XCTAssertEqual(image.width, width, "Native window width must not use logical points.")
        XCTAssertEqual(image.height, height, "Native window height must not use logical points.")
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: image.width/2-16, y: image.height/2-16, width: 32, height: 32)))
        let raster = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        raster.interpolationQuality = .none
        raster.draw(sample, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let pixels = raster.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<32 {
            for x in 0..<32 {
                let value = pixels[(y*32+x)*4]
                XCTAssertTrue(value == 0 || value == 255, "One-pixel detail was resampled to gray.")
                if x > 0 { XCTAssertNotEqual(value, pixels[(y*32+x-1)*4]) }
                if y > 0 { XCTAssertNotEqual(value, pixels[((y-1)*32+x)*4]) }
            }
        }
        let display = try XCTUnwrap(content.displays.first { $0.displayID == screen.displayIDForTest })
        let full = try await ScreenshotPixels.capture(SCContentFilter(display: display, excludingWindows: []), cursor: false, shadow: false)
        XCTAssertEqual(full.width, Int(screen.frame.width*density))
        XCTAssertEqual(full.height, Int(screen.frame.height*density))
    }
}

private extension NSScreen {
    var displayIDForTest: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    }
}
