import Foundation
import CoreGraphics

/// Selection behavior independent of AppKit, so drag, move and resize can be verified.
public struct RegionInteraction {
    public enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
        public func point(in r: CGRect) -> CGPoint {
            switch self {
            case .bottomLeft: return CGPoint(x: r.minX,y: r.minY)
            case .bottom: return CGPoint(x: r.midX,y: r.minY)
            case .bottomRight: return CGPoint(x: r.maxX,y: r.minY)
            case .right: return CGPoint(x: r.maxX,y: r.midY)
            case .topRight: return CGPoint(x: r.maxX,y: r.maxY)
            case .top: return CGPoint(x: r.midX,y: r.maxY)
            case .topLeft: return CGPoint(x: r.minX,y: r.maxY)
            case .left: return CGPoint(x: r.minX,y: r.midY)
            }
        }
    }
    public enum Operation: Equatable { case draw, move, resize(Handle) }
    public private(set) var operation: Operation = .draw
    private var anchor = CGPoint.zero
    private var original = CGRect.zero
    public init() {}
    public static let handleHitRadius: CGFloat = 10
    public static func handle(at point: CGPoint,in rect: CGRect) -> Handle? {
        guard rect.width > 2,rect.height > 2 else { return nil }
        return Handle.allCases.first { h in
            let p = h.point(in: rect)
            return abs(p.x-point.x) <= handleHitRadius && abs(p.y-point.y) <= handleHitRadius
        }
    }
    public mutating func begin(at point: CGPoint,rect: CGRect,forceDraw: Bool = false) {
        anchor = point; original = rect
        if forceDraw { operation = .draw }
        else if let handle = Self.handle(at: point,in: rect) { operation = .resize(handle) }
        else if rect.contains(point),rect.width > 2,rect.height > 2 { operation = .move }
        else { operation = .draw }
    }
    /// `square` (Shift) forces 1:1 and overrides `ratio`, an optional width/height aspect lock.
    public func update(to point: CGPoint,bounds: CGRect,square: Bool = false,ratio: CGFloat? = nil) -> CGRect {
        let lock = square ? 1 : ratio
        switch operation {
        case .move:
            return CaptureGeometry.clamped(original.offsetBy(dx: point.x-anchor.x,dy: point.y-anchor.y),to: bounds)
        case .draw:
            var end = CGPoint(x: max(bounds.minX,min(point.x,bounds.maxX)),y: max(bounds.minY,min(point.y,bounds.maxY)))
            if let lock { end = AspectLock.end(from: anchor,to: end,ratio: lock,bounds: bounds) }
            return CaptureGeometry.rectangle(from: anchor,to: end)
        case .resize(let h):
            let p = CGPoint(x: max(bounds.minX,min(point.x,bounds.maxX)),y: max(bounds.minY,min(point.y,bounds.maxY)))
            var x0 = original.minX,x1 = original.maxX,y0 = original.minY,y1 = original.maxY
            if [.bottomLeft,.topLeft,.left].contains(h) { x0 = min(p.x,x1-3) }
            if [.bottomRight,.topRight,.right].contains(h) { x1 = max(p.x,x0+3) }
            if [.bottomLeft,.bottomRight,.bottom].contains(h) { y0 = min(p.y,y1-3) }
            if [.topLeft,.topRight,.top].contains(h) { y1 = max(p.y,y0+3) }
            let raw = CGRect(x: x0,y: y0,width: x1-x0,height: y1-y0)
            guard let lock else { return raw }
            return AspectLock.resized(raw,handle: h,original: original,ratio: lock,bounds: bounds)
        }
    }
}

public enum LaunchAction: String, CaseIterable {
    case capture, draw, repeatArea = "repeat", library, settings, fullscreen, window, activeWindow = "active-window"
    /// Capture, upload, and copy a shareable link. `pasteUpload` converts the clipboard image into a link instead.
    case upload, pasteUpload = "paste-upload", cloud
    /// OCR an area straight to the clipboard; reopen the most recently closed Quick Access card.
    case captureText = "capture-text", restoreOverlay = "restore-overlay"
    /// Start an area recording, or stop the current one.
    case record
    public init?(url: URL) {
        guard ["easyshot","easyshot-dev"].contains(url.scheme?.lowercased() ?? ""),url.user == nil,url.password == nil,url.port == nil,
              url.path.isEmpty || url.path == "/",url.query == nil,url.fragment == nil,
              let host = url.host,let action = Self(rawValue: host.lowercased()) else { return nil }
        self = action
    }
    /// `easyshot://edit?path=/absolute/file` opens a capture, recording or project in the editor.
    public static func editPath(_ url: URL) -> String? {
        guard ["easyshot","easyshot-dev"].contains(url.scheme?.lowercased() ?? ""),url.host?.lowercased() == "edit",url.user == nil,url.password == nil,url.port == nil,
              let items = URLComponents(url: url,resolvingAgainstBaseURL: false)?.queryItems,items.count == 1,items[0].name == "path",
              let path = items[0].value,path.hasPrefix("/") else { return nil }
        return (path as NSString).standardizingPath
    }
    public static func editURL(path: String) -> URL? {
        var components = URLComponents(); components.scheme = "easyshot"; components.host = "edit"
        components.queryItems = [URLQueryItem(name: "path",value: path)]
        return components.url
    }
}
