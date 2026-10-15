import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

/// Still-image operations use pixels, never a view's logical size or a preview.
public enum ScreenshotPixels {
    public static func capture(_ filter: SCContentFilter, cursor: Bool, shadow: Bool) async throws -> CGImage {
        let config = SCScreenshotConfiguration()
        config.showsCursor = cursor
        config.ignoreShadows = !shadow
        config.displayIntent = .local
        config.dynamicRange = .sdr
        // Default dimensions describe the captured content in native pixels,
        // including shadow bounds. Do not supply a smaller streaming surface.
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard let image = output.sdrImage else { throw EncodingError.failed }
        return image
    }

    public static func cropRect(_ region: CGRect, display: CGRect, width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0, display.width > 0, display.height > 0,
              [region.minX, region.minY, region.width, region.height,
               display.minX, display.minY, display.width, display.height].allSatisfy({ $0.isFinite }) else { return nil }
        let clipped = region.intersection(display)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let sx = CGFloat(width) / display.width
        let sy = CGFloat(height) / display.height
        let x = floor((clipped.minX - display.minX) * sx)
        let y = floor((clipped.minY - display.minY) * sy)
        let endX = ceil((clipped.maxX - display.minX) * sx)
        let endY = ceil((clipped.maxY - display.minY) * sy)
        return CGRect(x: x, y: y, width: endX - x, height: endY - y)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw EncodingError.failed
        }
        // PNG has no lossy quality setting. Encode the original CGImage directly,
        // including its color profile, without an NSImage draw or resize.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodingError.failed }
        return data as Data
    }

    public enum EncodingError: Error { case failed }
}
