import Foundation
import CoreGraphics

public enum ArrowStyle: String, CaseIterable, Codable, Sendable {
    case straight, curved, double, tapered
    public var title: String { switch self { case .straight: "Straight"; case .curved: "Curved"; case .double: "Double"; case .tapered: "Tapered" } }
}

/// Arrow shapes. A curved arrow passes through its `bend` handle (a point on the curve, not a raw control point).
public enum ArrowGeometry {
    /// Quadratic control point so the curve passes through `bend` at its midpoint.
    public static func control(from a: CGPoint, to b: CGPoint, through bend: CGPoint) -> CGPoint {
        CGPoint(x: 2*bend.x-(a.x+b.x)/2, y: 2*bend.y-(a.y+b.y)/2)
    }
    /// Default bend for a new curved arrow: 18% of its length to the left of the chord.
    public static func defaultBend(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (a.x+b.x)/2, y: (a.y+b.y)/2)
        return CGPoint(x: mid.x-(b.y-a.y)*0.18, y: mid.y+(b.x-a.x)*0.18)
    }
    public static func point(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1-t
        return CGPoint(x: u*u*a.x+2*u*t*c.x+t*t*b.x, y: u*u*a.y+2*u*t*c.y+t*t*b.y)
    }
    /// Direction of travel at the end (`atEnd`) or start of the curve, in radians.
    public static func tangentAngle(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, atEnd: Bool) -> CGFloat {
        let to = atEnd ? b : a
        let d = CGPoint(x: to.x-c.x, y: to.y-c.y)
        if hypot(d.x, d.y) < 0.001 { return atEnd ? atan2(b.y-a.y, b.x-a.x) : atan2(a.y-b.y, a.x-b.x) }
        return atan2(d.y, d.x)
    }
    /// Head triangle tip, left and right corners for a head pointing along `angle`.
    public static func head(tip: CGPoint, angle: CGFloat, length: CGFloat, spread: CGFloat = .pi/6) -> [CGPoint] {
        [tip, CGPoint(x: tip.x-length*cos(angle-spread), y: tip.y-length*sin(angle-spread)),
         CGPoint(x: tip.x-length*cos(angle+spread), y: tip.y-length*sin(angle+spread))]
    }
    /// Closed outline of a hand-drawn arrow body that tapers from `start` width to `end` width.
    public static func taperedOutline(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, start: CGFloat, end: CGFloat, steps: Int = 24) -> [CGPoint] {
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i)/CGFloat(steps)
            let p = point(a, c, b, t)
            let d = CGPoint(x: 2*(1-t)*(c.x-a.x)+2*t*(b.x-c.x), y: 2*(1-t)*(c.y-a.y)+2*t*(b.y-c.y))
            let len = max(hypot(d.x, d.y), 0.0001), w = (start+(end-start)*t)/2
            let n = CGPoint(x: -d.y/len*w, y: d.x/len*w)
            left.append(CGPoint(x: p.x+n.x, y: p.y+n.y)); right.append(CGPoint(x: p.x-n.x, y: p.y-n.y))
        }
        return left+right.reversed()
    }
}

/// Freehand smoothing that depends on distance travelled, not on how fast events arrived:
/// resample at a fixed spacing, then average over a fixed arc-length window.
public enum StrokeSmoother {
    public static func smooth(_ points: [CGPoint], spacing: CGFloat = 2, window: CGFloat = 12) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let resampled = resample(points, spacing: spacing)
        let radius = max(1, Int(window/spacing/2))
        guard resampled.count > 2 else { return resampled }
        var out = resampled
        for i in 1..<resampled.count-1 {
            let lo = max(0, i-radius), hi = min(resampled.count-1, i+radius)
            // Shrink the window near the ends so the stroke keeps its exact endpoints.
            let r = min(i-lo, hi-i)
            var sx: CGFloat = 0, sy: CGFloat = 0
            for j in (i-r)...(i+r) { sx += resampled[j].x; sy += resampled[j].y }
            out[i] = CGPoint(x: sx/CGFloat(2*r+1), y: sy/CGFloat(2*r+1))
        }
        return out
    }
    public static func resample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard var previous = points.first else { return [] }
        var out = [previous], carry: CGFloat = 0
        for p in points.dropFirst() {
            var segment = hypot(p.x-previous.x, p.y-previous.y)
            var start = previous
            while carry+segment >= spacing {
                let f = (spacing-carry)/segment
                let q = CGPoint(x: start.x+(p.x-start.x)*f, y: start.y+(p.y-start.y)*f)
                out.append(q); segment -= spacing-carry; start = q; carry = 0
            }
            carry += segment; previous = p
        }
        if let last = points.last, out.last != last { out.append(last) }
        return out
    }
}

public enum CropAspect: String, CaseIterable, Codable, Sendable {
    case free, square, fourThree, sixteenNine, nineSixteen
    public var title: String { switch self { case .free: "Free"; case .square: "1:1"; case .fourThree: "4:3"; case .sixteenNine: "16:9"; case .nineSixteen: "9:16" } }
    public var ratio: CGFloat? { switch self { case .free: nil; case .square: 1; case .fourThree: 4/3; case .sixteenNine: 16/9; case .nineSixteen: 9/16 } }
}

public enum CropMath {
    /// Rectangle from a fixed `anchor` towards `point`, forced to `ratio` (width/height) and kept inside `bounds`.
    public static func constrain(anchor: CGPoint, point: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        let p = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        guard let ratio, ratio > 0 else { return rect(anchor, p) }
        let sx: CGFloat = p.x >= anchor.x ? 1 : -1, sy: CGFloat = p.y >= anchor.y ? 1 : -1
        var w = abs(p.x-anchor.x), h = abs(p.y-anchor.y)
        if w/max(h, 0.0001) > ratio { h = w/ratio } else { w = h*ratio }
        // Shrink to fit the space available on the dragged side.
        let maxW = sx > 0 ? bounds.maxX-anchor.x : anchor.x-bounds.minX
        let maxH = sy > 0 ? bounds.maxY-anchor.y : anchor.y-bounds.minY
        let k = min(1, maxW/max(w, 0.0001), maxH/max(h, 0.0001))
        w *= k; h *= k
        return rect(anchor, CGPoint(x: anchor.x+sx*w, y: anchor.y+sy*h))
    }
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x-b.x), height: abs(a.y-b.y)) }
    /// Moves `value` onto the nearest guide within `tolerance`.
    public static func snap(_ value: CGFloat, to guides: [CGFloat], tolerance: CGFloat) -> CGFloat {
        guard let nearest = guides.min(by: { abs($0-value) < abs($1-value) }), abs(nearest-value) <= tolerance else { return value }
        return nearest
    }
    /// Snaps the dragged corner of a free-form rectangle to image edges and object edges.
    public static func snapPoint(_ p: CGPoint, xGuides: [CGFloat], yGuides: [CGFloat], tolerance: CGFloat) -> CGPoint {
        CGPoint(x: snap(p.x, to: xGuides, tolerance: tolerance), y: snap(p.y, to: yGuides, tolerance: tolerance))
    }
    /// Guides from the image bounds and from detected objects (text lines, rectangles).
    public static func guides(bounds: CGRect, objects: [CGRect]) -> (x: [CGFloat], y: [CGFloat]) {
        var x = [bounds.minX, bounds.midX, bounds.maxX], y = [bounds.minY, bounds.midY, bounds.maxY]
        for o in objects { x += [o.minX, o.maxX]; y += [o.minY, o.maxY] }
        return (x, y)
    }
}

public enum HighlightSnap {
    /// Fits a highlighter rectangle to the text lines it covers: the vertical extent of every line
    /// it overlaps by at least half the line height. Returns the original rectangle when it covers no text.
    public static func snap(_ rect: CGRect, lines: [CGRect], padding: CGFloat = 2) -> CGRect {
        let hits = lines.filter { line in
            let v = min(rect.maxY, line.maxY)-max(rect.minY, line.minY)
            let h = min(rect.maxX, line.maxX)-max(rect.minX, line.minX)
            return h > 0 && v >= line.height*0.5 || (h > 0 && rect.height < line.height && rect.midY > line.minY && rect.midY < line.maxY)
        }
        guard !hits.isEmpty else { return rect }
        let minY = hits.map(\.minY).min()!-padding, maxY = hits.map(\.maxY).max()!+padding
        return CGRect(x: rect.minX, y: minY, width: rect.width, height: maxY-minY)
    }
}

/// Irreversible pixelation: block colors are shuffled and jittered, so the mosaic carries no
/// recoverable layout of the original pixels. Deterministic for a given seed so redraws match.
public enum PixelScramble {
    public struct Generator: RandomNumberGenerator {
        var state: UInt64
        public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        public mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
    /// Shuffles RGBA pixels of a small block image in place and adds ±`jitter` noise per channel.
    public static func scramble(_ pixels: inout [UInt8], count: Int, seed: UInt64, jitter: Int = 18) {
        var rng = Generator(seed: seed)
        guard count > 1 else { return }
        for i in stride(from: count-1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i+1))
            if i != j { for c in 0..<4 { pixels.swapAt(i*4+c, j*4+c) } }
        }
        for i in 0..<count { for c in 0..<3 {
            let v = Int(pixels[i*4+c])+Int(rng.next() % UInt64(2*jitter+1))-jitter
            pixels[i*4+c] = UInt8(min(max(v, 0), Int(pixels[i*4+3])))
        } }
    }
}

public enum BackdropAlignment: Int, CaseIterable, Codable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    /// Horizontal and vertical position of the content in its free space, 0...1, top-left origin.
    public var factors: (x: CGFloat, y: CGFloat) { (CGFloat(rawValue % 3)/2, CGFloat(rawValue / 3)/2) }
}

public enum BackdropAspect: String, CaseIterable, Codable, Sendable {
    case auto, sixteenNine, square, fourThree, nineSixteen
    public var title: String { switch self { case .auto: "Auto"; case .sixteenNine: "16:9"; case .square: "1:1"; case .fourThree: "4:3"; case .nineSixteen: "9:16" } }
    public var ratio: CGFloat? { switch self { case .auto: nil; case .sixteenNine: 16/9; case .square: 1; case .fourThree: 4/3; case .nineSixteen: 9/16 } }
}

public enum BackdropLayout {
    /// Canvas size and the content's origin (top-left origin) for a screenshot placed on a background.
    /// With auto-balance, `visible` (the opaque part of the content, in content coordinates) is what gets
    /// centered and padded, so transparent window-shadow margins do not make the padding look uneven.
    public static func layout(content: CGSize, visible: CGRect? = nil, padding: CGFloat, aspect: BackdropAspect, alignment: BackdropAlignment, autoBalance: Bool) -> (canvas: CGSize, origin: CGPoint) {
        let v = autoBalance ? (visible ?? CGRect(origin: .zero, size: content)) : CGRect(origin: .zero, size: content)
        var canvas = CGSize(width: v.width+padding*2, height: v.height+padding*2)
        if let ratio = aspect.ratio {
            if canvas.width/canvas.height > ratio { canvas.height = canvas.width/ratio } else { canvas.width = canvas.height*ratio }
        }
        canvas = CGSize(width: canvas.width.rounded(.up), height: canvas.height.rounded(.up))
        let f = alignment.factors
        let free = CGSize(width: canvas.width-padding*2-v.width, height: canvas.height-padding*2-v.height)
        let vx = padding+free.width*f.x, vy = padding+free.height*f.y
        return (canvas, CGPoint(x: (vx-v.minX).rounded(), y: (vy-v.minY).rounded()))
    }
    /// Bounding box of pixels whose alpha exceeds `threshold`, top-left origin; nil when fully transparent.
    public static func opaqueBounds(alpha: (Int, Int) -> UInt8, width: Int, height: Int, threshold: UInt8 = 24) -> CGRect? {
        // Scan inward from each edge; screenshots are mostly opaque, so this touches few pixels.
        func row(_ y: Int) -> Bool { (0..<width).contains { alpha($0, y) > threshold } }
        guard let minY = (0..<height).first(where: row), let maxY = (0..<height).reversed().first(where: row) else { return nil }
        func column(_ x: Int) -> Bool { (minY...maxY).contains { alpha(x, $0) > threshold } }
        let minX = (0..<width).first(where: column)!, maxX = (0..<width).reversed().first(where: column)!
        return CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1)
    }
}
