import Foundation
import CoreGraphics

/// Area-mode aspect constraint. Holding Shift (square) overrides it.
public enum AspectLock: String, CaseIterable, Codable, Identifiable {
    case free, wide = "16:9", standard = "4:3", square = "1:1", portrait = "9:16"
    public var id: String { rawValue }
    public var title: String { self == .free ? "Free" : rawValue }
    public var ratio: CGFloat? {
        switch self { case .free: return nil; case .wide: return 16.0/9; case .standard: return 4.0/3; case .square: return 1; case .portrait: return 9.0/16 }
    }
    /// The end point of a ratio-locked drag from `anchor`, following the dominant axis and kept inside `bounds`.
    public static func end(from anchor: CGPoint,to point: CGPoint,ratio r: CGFloat,bounds: CGRect) -> CGPoint {
        let sx: CGFloat = point.x >= anchor.x ? 1 : -1,sy: CGFloat = point.y >= anchor.y ? 1 : -1
        let availableW = sx > 0 ? bounds.maxX-anchor.x : anchor.x-bounds.minX
        let availableH = sy > 0 ? bounds.maxY-anchor.y : anchor.y-bounds.minY
        var w = abs(point.x-anchor.x),h = abs(point.y-anchor.y)
        if w >= h*r { h = w/r } else { w = h*r }
        let k = min(1,availableW/max(w,.ulpOfOne),availableH/max(h,.ulpOfOne))
        return CGPoint(x: anchor.x+sx*w*k,y: anchor.y+sy*h*k)
    }
    /// `rect` reshaped to the ratio around its centre, keeping its width where possible, inside `bounds`.
    public func applied(to rect: CGRect,in bounds: CGRect) -> CGRect {
        guard let r = ratio,rect.width > 2,rect.height > 2 else { return rect }
        var w = rect.width,h = w/r
        let k = min(1,bounds.width/w,bounds.height/h); w *= k; h *= k
        return CaptureGeometry.clamped(CGRect(x: rect.midX-w/2,y: rect.midY-h/2,width: w,height: h),to: bounds)
    }
    /// A resize result constrained to ratio `r`. Corners keep the opposite corner fixed; edges keep the opposite edge
    /// fixed and grow the other axis symmetrically about the original centre.
    public static func resized(_ raw: CGRect,handle: RegionInteraction.Handle,original: CGRect,ratio r: CGFloat,bounds: CGRect) -> CGRect {
        switch handle {
        case .bottomLeft,.bottomRight,.topLeft,.topRight:
            let anchor = CGPoint(x: [.bottomLeft,.topLeft].contains(handle) ? original.maxX : original.minX,
                                 y: [.bottomLeft,.bottomRight].contains(handle) ? original.maxY : original.minY)
            let corner = CGPoint(x: anchor.x == original.maxX ? raw.minX : raw.maxX,y: anchor.y == original.maxY ? raw.minY : raw.maxY)
            return CaptureGeometry.rectangle(from: anchor,to: end(from: anchor,to: corner,ratio: r,bounds: bounds))
        case .left,.right:
            var w = raw.width,h = w/r
            let k = min(1,bounds.height/h); w *= k; h *= k
            let x = handle == .left ? original.maxX-w : original.minX
            let y = min(max(bounds.minY,original.midY-h/2),bounds.maxY-h)
            return CGRect(x: x,y: y,width: w,height: h)
        case .top,.bottom:
            var h = raw.height,w = h*r
            let k = min(1,bounds.width/w); w *= k; h *= k
            let y = handle == .bottom ? original.maxY-h : original.minY
            let x = min(max(bounds.minX,original.midX-w/2),bounds.maxX-w)
            return CGRect(x: x,y: y,width: w,height: h)
        }
    }
}

/// Stacking, auto-close and restore state for post-capture Quick Access cards. Times are seconds on any monotonic clock.
public struct QuickAccessStack<ID: Hashable> {
    public static var maxVisible: Int { 5 }
    /// Oldest first; the newest card sits nearest the screen corner.
    public private(set) var cards: [ID] = []
    public private(set) var recentlyClosed: [ID] = []
    public private(set) var hovered = false
    public var autoClose: TimeInterval?
    private var deadlines: [ID: TimeInterval] = [:]
    public init(autoClose: TimeInterval? = nil) { self.autoClose = autoClose }
    public var isEmpty: Bool { cards.isEmpty }
    /// Adds a card and returns the ones evicted to respect `maxVisible`.
    @discardableResult public mutating func add(_ id: ID,now: TimeInterval) -> [ID] {
        cards.removeAll { $0 == id }; cards.append(id); recentlyClosed.removeAll { $0 == id }
        deadlines[id] = autoClose.map { now+$0 }
        var evicted: [ID] = []
        while cards.count > Self.maxVisible { let old = cards[0]; close(old); evicted.append(old) }
        return evicted
    }
    public mutating func close(_ id: ID) {
        guard let i = cards.firstIndex(of: id) else { return }
        cards.remove(at: i); deadlines[id] = nil
        recentlyClosed.removeAll { $0 == id }; recentlyClosed.append(id)
        if recentlyClosed.count > 10 { recentlyClosed.removeFirst() }
    }
    /// Reopens the most recently closed card that is not already showing.
    public mutating func restore(now: TimeInterval) -> ID? {
        guard let id = recentlyClosed.last else { return nil }
        add(id,now: now); return id
    }
    /// Hovering any card pauses every timer; leaving restarts each with the full duration.
    public mutating func setHovered(_ value: Bool,now: TimeInterval) {
        hovered = value
        if !value { for id in cards { deadlines[id] = autoClose.map { now+$0 } } }
    }
    public mutating func setAutoClose(_ value: TimeInterval?,now: TimeInterval) {
        autoClose = value; for id in cards { deadlines[id] = value.map { now+$0 } }
    }
    public func expired(now: TimeInterval) -> [ID] {
        guard !hovered else { return [] }
        return cards.filter { deadlines[$0].map { $0 <= now } ?? false }
    }
    public var nextDeadline: TimeInterval? { hovered ? nil : cards.compactMap { deadlines[$0] }.min() }
    /// Card frames for `count` cards stacked upward from the bottom-right of `visible`; index 0 is the newest.
    public static func frames(count: Int,size: CGSize,in visible: CGRect,margin: CGFloat = 20,spacing: CGFloat = 12) -> [CGRect] {
        (0..<count).map { i in
            CGRect(x: visible.maxX-size.width-margin,y: visible.minY+margin+CGFloat(i)*(size.height+spacing),width: size.width,height: size.height)
        }
    }
}

/// Reading-order assembly of on-device OCR output.
public enum RecognizedText {
    /// `box` uses Vision's normalized, bottom-left-origin coordinates.
    public struct Line: Equatable {
        public var text: String; public var box: CGRect
        public init(text: String,box: CGRect) { self.text = text; self.box = box }
    }
    /// Top-to-bottom rows, left-to-right within a row. Lines whose vertical centres differ by less than half the
    /// median line height share a row, so multi-column screenshots read like the screen.
    public static func ordered(_ lines: [Line]) -> [Line] {
        guard lines.count > 1 else { return lines }
        let heights = lines.map(\.box.height).sorted()
        let tolerance = max(heights[heights.count/2]/2,0.001)
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.first,abs(last.box.midY-line.box.midY) < tolerance { rows[rows.count-1].append(line) }
            else { rows.append([line]) }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }
    /// Text rows joined by newlines; same-row fragments joined by a tab. QR/barcode payloads not already present follow.
    public static func assemble(lines: [Line],codes: [String]) -> String {
        let sorted = ordered(lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        var output: [String] = []
        var rowMid: CGFloat?
        let heights = sorted.map(\.box.height).sorted()
        let tolerance = heights.isEmpty ? 0 : max(heights[heights.count/2]/2,0.001)
        for line in sorted {
            if let mid = rowMid,abs(mid-line.box.midY) < tolerance,!output.isEmpty { output[output.count-1] += "\t"+line.text }
            else { output.append(line.text); rowMid = line.box.midY }
        }
        let body = output.joined(separator: "\n")
        var seen = Set<String>()
        let extra = codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !body.contains($0) && seen.insert($0).inserted }
        return (output+extra).joined(separator: "\n")
    }
}

/// Geometry and formatting for the selection magnifier.
public enum PixelLoupe {
    /// Odd, so one pixel sits exactly under the crosshair.
    public static let samplePixels = 21
    public static func hex(red: UInt8,green: UInt8,blue: UInt8) -> String { String(format: "#%02X%02X%02X",red,green,blue) }
    /// The global point rectangle covering `samplePixels` native pixels centred on the pixel under `point`.
    public static func sampleRect(around point: CGPoint,scale: CGFloat,pixels: Int = samplePixels) -> CGRect {
        let s = max(scale,1)
        let px = (point.x*s).rounded(.down),py = (point.y*s).rounded(.down)
        let half = CGFloat(pixels/2)
        return CGRect(x: (px-half)/s,y: (py-half)/s,width: CGFloat(pixels)/s,height: CGFloat(pixels)/s)
    }
    /// The loupe goes below-right of the pointer and flips to stay inside `bounds`.
    public static func placement(pointer: CGPoint,size: CGSize,in bounds: CGRect,offset: CGFloat = 26) -> CGRect {
        var x = pointer.x+offset,y = pointer.y-offset-size.height
        if x+size.width > bounds.maxX { x = pointer.x-offset-size.width }
        if y < bounds.minY { y = pointer.y+offset }
        return CGRect(x: max(bounds.minX,min(x,bounds.maxX-size.width)),y: max(bounds.minY,min(y,bounds.maxY-size.height)),width: size.width,height: size.height)
    }
}

/// Wraps a window capture in padding over a background, at the capture's native pixels.
public enum WindowBackdrop {
    public enum Fill { case clear, solid(CGColor), gradient(CGColor,CGColor), image(CGImage) }
    public static func compose(_ window: CGImage,fill: Fill,padding: Int) -> CGImage? {
        let pad = max(0,padding)
        let w = window.width+pad*2,h = window.height+pad*2
        let space = window.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard w <= 20000,h <= 20000,let ctx = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: 0,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0,y: 0,width: w,height: h)
        switch fill {
        case .clear: break
        case .solid(let color): ctx.setFillColor(color); ctx.fill(full)
        case .gradient(let a,let b):
            if let gradient = CGGradient(colorsSpace: space,colors: [a,b] as CFArray,locations: [0,1]) {
                ctx.drawLinearGradient(gradient,start: CGPoint(x: 0,y: CGFloat(h)),end: CGPoint(x: CGFloat(w),y: 0),options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
            }
        case .image(let image):
            // Aspect-fill, centred, like a desktop picture.
            let k = max(CGFloat(w)/CGFloat(image.width),CGFloat(h)/CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width)*k,height: CGFloat(image.height)*k)
            ctx.interpolationQuality = .high
            ctx.draw(image,in: CGRect(x: (CGFloat(w)-size.width)/2,y: (CGFloat(h)-size.height)/2,width: size.width,height: size.height))
        }
        ctx.interpolationQuality = .none
        ctx.draw(window,in: CGRect(x: pad,y: pad,width: window.width,height: window.height))
        return ctx.makeImage()
    }
}
