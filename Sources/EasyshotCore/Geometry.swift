import Foundation
import CoreGraphics

public enum CaptureMode: String, CaseIterable, Codable, Identifiable {
    case area, fullscreen, window, activeWindow, lastRegion
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .area: return "Area"
        case .fullscreen: return "Full screen"
        case .window: return "Choose window"
        case .activeWindow: return "Active window"
        case .lastRegion: return "Repeat last area"
        }
    }
    public var symbol: String {
        switch self {
        case .area: return "crop"
        case .fullscreen: return "rectangle.inset.filled"
        case .window: return "macwindow"
        case .activeWindow: return "macwindow.on.rectangle"
        case .lastRegion: return "arrow.counterclockwise"
        }
    }
    /// Shared by the toolbar, numeric shortcuts, and Tab navigation.
    public static let toolbarOrder: [Self] = [.fullscreen,.window,.area,.activeWindow,.lastRegion]
    public var key: String { String(Self.toolbarOrder.firstIndex(of: self)! + 1) }

}

public enum CaptureGeometry {
    /// Quartz has a top-left origin; AppKit has a bottom-left origin, based on the primary screen.
    public static func quartz(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    public static func rectangle(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }
    public static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let size = CGSize(width: min(rect.width,bounds.width),height: min(rect.height,bounds.height))
        return CGRect(x: max(bounds.minX,min(rect.minX,bounds.maxX-size.width)),
                      y: max(bounds.minY,min(rect.minY,bounds.maxY-size.height)),width: size.width,height: size.height)
    }
    public static func sourceRect(_ global: CGRect, in display: CGRect) -> CGRect {
        let clipped = global.intersection(display)
        guard !clipped.isNull else { return .zero }
        return clipped.offsetBy(dx: -display.minX, dy: -display.minY)
    }
}

public enum CaptureFiles {
    // DateFormatter is documented thread-safe; building one per capture was needless work.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return formatter
    }()
    public static func filename(date: Date = Date(), extension ext: String, token: String = String(UUID().uuidString.prefix(6))) -> String {
        return "Easyshot \(formatter.string(from: date)) \(token).\(ext)"
    }
}
