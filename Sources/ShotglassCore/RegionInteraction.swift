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
    public func update(to point: CGPoint,bounds: CGRect,square: Bool = false) -> CGRect {
        switch operation {
        case .move:
            return CaptureGeometry.clamped(original.offsetBy(dx: point.x-anchor.x,dy: point.y-anchor.y),to: bounds)
        case .draw:
            var end = CGPoint(x: max(bounds.minX,min(point.x,bounds.maxX)),y: max(bounds.minY,min(point.y,bounds.maxY)))
            if square {
                let sx: CGFloat = end.x >= anchor.x ? 1 : -1,sy: CGFloat = end.y >= anchor.y ? 1 : -1
                let availableX = sx > 0 ? bounds.maxX-anchor.x : anchor.x-bounds.minX
                let availableY = sy > 0 ? bounds.maxY-anchor.y : anchor.y-bounds.minY
                let side = min(max(abs(end.x-anchor.x),abs(end.y-anchor.y)),availableX,availableY)
                end = CGPoint(x: anchor.x+sx*side,y: anchor.y+sy*side)
            }
            return CaptureGeometry.rectangle(from: anchor,to: end)
        case .resize(let h):
            let p = CGPoint(x: max(bounds.minX,min(point.x,bounds.maxX)),y: max(bounds.minY,min(point.y,bounds.maxY)))
            var x0 = original.minX,x1 = original.maxX,y0 = original.minY,y1 = original.maxY
            if [.bottomLeft,.topLeft,.left].contains(h) { x0 = min(p.x,x1-3) }
            if [.bottomRight,.topRight,.right].contains(h) { x1 = max(p.x,x0+3) }
            if [.bottomLeft,.bottomRight,.bottom].contains(h) { y0 = min(p.y,y1-3) }
            if [.topLeft,.topRight,.top].contains(h) { y1 = max(p.y,y0+3) }
            return CGRect(x: x0,y: y0,width: x1-x0,height: y1-y0)
        }
    }
}

public enum LaunchAction: String, CaseIterable {
    case capture, draw, repeatArea = "repeat", library, settings, fullscreen, window, activeWindow = "active-window"
    /// Capture, upload, and copy a shareable link. `pasteUpload` converts the clipboard image into a link instead.
    case upload, pasteUpload = "paste-upload", cloud
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "shotglass",url.user == nil,url.password == nil,url.port == nil,
              url.path.isEmpty || url.path == "/",url.query == nil,url.fragment == nil,
              let host = url.host,let action = Self(rawValue: host.lowercased()) else { return nil }
        self = action
    }
}
