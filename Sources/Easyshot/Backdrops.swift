import AppKit
import CoreImage

/// Twenty built-in backgrounds, generated with Core Graphics (no bundled image assets).
/// The first six match the original Studio gradients, so saved plans keep their look.
enum Backdrops {
    enum Kind { case linear,radial,mesh }
    struct Spec { var kind: Kind; var colors: [UInt32] }
    static let all: [Spec] = [
        Spec(kind: .linear,colors: [0x6B4FF2,0x268CFA]),Spec(kind: .linear,colors: [0xFA7359,0xD9388C]),
        Spec(kind: .linear,colors: [0x33CCA6,0x1A6BBF]),Spec(kind: .linear,colors: [0xFFC78C,0xED7A9E]),
        Spec(kind: .linear,colors: [0x0D3373,0x1A9ECC]),Spec(kind: .linear,colors: [0x3D404A,0x121217]),
        Spec(kind: .linear,colors: [0xFF9A8B,0xFF6A88,0xFF99AC]),Spec(kind: .linear,colors: [0x0BA360,0x3CBA92,0x30DD8A]),
        Spec(kind: .linear,colors: [0xF6D365,0xFDA085]),Spec(kind: .linear,colors: [0x1E3C72,0x2A5298,0x6DD5ED]),
        Spec(kind: .radial,colors: [0x8E7CFF,0x2B1A6E,0x0E0A24]),Spec(kind: .radial,colors: [0xFFD6A5,0xFF8E72,0x8C2F39]),
        Spec(kind: .radial,colors: [0x7FFFD4,0x1E8C93,0x07303A]),Spec(kind: .radial,colors: [0xE0E7FF,0x9AA5C6,0x3A4150]),
        Spec(kind: .mesh,colors: [0x1B1340,0xFF5E9C,0x5E6BFF,0x00D4C8]),Spec(kind: .mesh,colors: [0xFFF4E0,0xFFB38A,0xFF7AA2,0x9AD0FF]),
        Spec(kind: .mesh,colors: [0x0B1D2E,0x00C2FF,0x7B61FF,0x00FFA3]),Spec(kind: .mesh,colors: [0x2E1A12,0xFF9F43,0xEE5253,0xFECA57]),
        Spec(kind: .mesh,colors: [0xF0F4F8,0xA0C4FF,0xBDB2FF,0xFFC6FF]),Spec(kind: .mesh,colors: [0x101114,0x3A3D46,0x5B6271,0x8A93A6]),
    ]
    static var count: Int { all.count }
    static func cgColor(_ hex: UInt32,alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255)/255,green: CGFloat((hex >> 8) & 255)/255,blue: CGFloat(hex & 255)/255,alpha: alpha)
    }
    /// Draws backdrop `index` filling `rect` of a top-left-agnostic context.
    static func draw(_ index: Int,in ctx: CGContext,rect: CGRect) {
        let spec = all[min(max(index,0),all.count-1)]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func gradient(_ colors: [CGColor]) -> CGGradient {
            CGGradient(colorsSpace: space,colors: colors as CFArray,locations: colors.indices.map { CGFloat($0)/CGFloat(max(colors.count-1,1)) })!
        }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        let topLeft = CGPoint(x: rect.minX,y: rect.maxY),bottomRight = CGPoint(x: rect.maxX,y: rect.minY)
        switch spec.kind {
        case .linear:
            ctx.drawLinearGradient(gradient(spec.colors.map { cgColor($0) }),start: topLeft,end: bottomRight,options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
        case .radial:
            let center = CGPoint(x: rect.minX+rect.width*0.3,y: rect.minY+rect.height*0.75)
            ctx.drawRadialGradient(gradient(spec.colors.map { cgColor($0) }),startCenter: center,startRadius: 0,endCenter: center,endRadius: hypot(rect.width,rect.height)*0.85,options: [.drawsAfterEndLocation])
        case .mesh:
            // A dark/light base with three soft color fields approximates a mesh gradient.
            ctx.setFillColor(cgColor(spec.colors[0])); ctx.fill(rect)
            let fields: [(CGFloat,CGFloat,CGFloat)] = [(0.15,0.85,0.75),(0.85,0.7,0.65),(0.55,0.1,0.8)]
            for (i,field) in fields.enumerated() {
                let c = CGPoint(x: rect.minX+rect.width*field.0,y: rect.minY+rect.height*field.1)
                let hex = spec.colors[1+i % (spec.colors.count-1)]
                ctx.drawRadialGradient(gradient([cgColor(hex,alpha: 0.9),cgColor(hex,alpha: 0)]),startCenter: c,startRadius: 0,endCenter: c,endRadius: max(rect.width,rect.height)*field.2,options: [])
            }
        }
    }
    static func image(_ index: Int,size: CGSize) -> CGImage? {
        guard let ctx = CGContext(data: nil,width: max(1,Int(size.width)),height: max(1,Int(size.height)),bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(index,in: ctx,rect: CGRect(x: 0,y: 0,width: ctx.width,height: ctx.height))
        return ctx.makeImage()
    }
    @MainActor private static var thumbnails: [Int: NSImage] = [:]
    @MainActor static func thumbnail(_ index: Int) -> NSImage {
        if let cached = thumbnails[index] { return cached }
        let image = Self.image(index,size: CGSize(width: 64,height: 64)).map { NSImage(cgImage: $0,size: CGSize(width: 32,height: 32)) } ?? NSImage()
        thumbnails[index] = image
        return image
    }
}
