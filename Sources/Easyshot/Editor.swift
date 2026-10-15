import AppKit
import SwiftUI
import EasyshotCore

enum MarkTool: String,CaseIterable,Identifiable,Codable {
    case arrow,rectangle,ellipse,line,pen,highlight,text,step,redact,pixelate,blur,spotlight,crop
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .ellipse: return "circle"
        case .line: return "line.diagonal"; case .pen: return "pencil.tip"; case .highlight: return "highlighter"
        case .text: return "textformat"; case .step: return "1.circle"; case .redact: return "rectangle.fill"
        case .pixelate: return "square.grid.3x3.fill"; case .blur: return "drop.halffull"
        case .spotlight: return "flashlight.on.fill"; case .crop: return "crop"
        }
    }
}

enum TextPreset: String,CaseIterable,Codable {
    case plain,outlined,pill,callout,mono,title
    var title: String { switch self { case .plain: "Plain"; case .outlined: "Outlined"; case .pill: "Pill"; case .callout: "Callout"; case .mono: "Code"; case .title: "Title" } }
}

struct Mark: Codable {
    var tool: MarkTool
    var points: [CGPoint]
    var color: [Double]
    var width: Double
    var text: String = ""
    // Optional so projects saved by earlier versions still decode.
    var arrow: ArrowStyle? = nil
    var bend: CGPoint? = nil
    var preset: TextPreset? = nil
    var seed: UInt64? = nil
    var rect: CGRect { CaptureGeometry.rectangle(from: points.first ?? .zero,to: points.last ?? .zero) }
    var nsColor: NSColor { NSColor(srgbRed: color[0],green: color[1],blue: color[2],alpha: color[3]) }
    var hasBend: Bool { tool == .arrow && (arrow == .curved || arrow == .tapered) }
}

/// Editable project file: the original pixels plus markup and background settings.
struct EditorProject: Codable {
    var png: Data; var marks: [Mark]; var padding: Double; var background: [Double]; var shadow: Bool
    var backdrop: StudioBackground? = nil; var corner: Double? = nil
    var aspect: BackdropAspect? = nil; var alignment: BackdropAlignment? = nil; var autoBalance: Bool? = nil
}

@MainActor final class EditorModel: ObservableObject {
    @Published var image: CGImage { didSet { analysis = nil; visible = nil; proposals = [] } }
    @Published var marks: [Mark] = []
    @Published var tool: MarkTool = .arrow { didSet { if [.highlight,.crop].contains(tool) { analyze() } } }
    @Published var color = Color(red: 1,green: 0.32,blue: 0.35)
    @Published var stroke: Double = 6
    @Published var text = "Your text"
    @Published var preset: TextPreset = .plain
    @Published var arrowStyle: ArrowStyle = .straight
    @Published var cropAspect: CropAspect = .free
    @Published var backdrop: StudioBackground = .color(0.28,0.19,0.57)
    @Published var padding: Double = 0
    @Published var corner: Double = 0
    @Published var shadow = true
    @Published var aspect: BackdropAspect = .auto
    @Published var alignment: BackdropAlignment = .center
    @Published var autoBalance = false
    @Published var resizeWidth = ""
    @Published var notice = ""
    /// Secrets found by "Find secrets", awaiting review. Bottom-left image pixels.
    @Published var proposals: [TextAnalysis.Secret] = []
    @Published var scanning = false
    private(set) var analysis: TextAnalysis?
    private var analyzing: Task<TextAnalysis?,Never>?
    private var visible: CGRect?
    private var markOrigin = CGPoint.zero
    let original: Clip
    let store: ClipStore
    private var undos: [(CGImage,[Mark])] = []
    private var redos: [(CGImage,[Mark])] = []
    init(image: CGImage,clip: Clip,store: ClipStore) { self.image = image; original = clip; self.store = store; resizeWidth = String(image.width) }
    func checkpoint() { undos.append((image,marks)); if undos.count > 40 { undos.removeFirst() }; redos.removeAll() }
    func undo() { guard let state = undos.popLast() else { return }; redos.append((image,marks)); image = state.0; marks = state.1 }
    func redo() { guard let state = redos.popLast() else { return }; undos.append((image,marks)); image = state.0; marks = state.1 }
    var backgroundColor: Color {
        get { if case .color(let r,let g,let b) = backdrop { return Color(.sRGB,red: r,green: g,blue: b) }; return Color(red: 0.28,green: 0.19,blue: 0.57) }
        set { let c = newValue.rgba; backdrop = .color(c[0],c[1],c[2]) }
    }

    // MARK: Text analysis
    /// OCR once per image; shared by highlighter snapping, crop snapping and secret detection.
    @discardableResult func analyze() -> Task<TextAnalysis?,Never> {
        if let analyzing { return analyzing }
        let image = self.image,scanner = Preferences.shared.secretScanner
        let task = Task { () -> TextAnalysis? in
            let result = try? await TextAnalysis.analyze(image,scanner: scanner)
            if self.image === image { self.analysis = result }
            return result
        }
        analyzing = task
        Task { _ = await task.value; if self.analyzing == task { self.analyzing = nil } }
        return task
    }
    func findSecrets() {
        scanning = true; notice = "Looking for secrets…"
        let task = analyze()
        Task {
            let result = await task.value
            scanning = false
            proposals = result?.secrets ?? []
            notice = proposals.isEmpty ? "No secrets found" : "Found \(Redaction.summary(proposals)). Click a box to keep it visible."
        }
    }
    func redactProposals() {
        guard !proposals.isEmpty else { return }
        checkpoint()
        let c = [0.0,0,0,1]
        marks += proposals.map { Mark(tool: .redact,points: [$0.rect.origin,CGPoint(x: $0.rect.maxX,y: $0.rect.maxY)],color: c,width: 1) }
        notice = "Redacted \(proposals.count) item\(proposals.count == 1 ? "" : "s")"; proposals = []
    }

    // MARK: Editing
    func add(_ mark: Mark) {
        var mark = mark
        switch mark.tool {
        case .pen: mark.points = StrokeSmoother.smooth(mark.points,spacing: max(1.5,mark.width*0.35),window: max(8,mark.width*2.5))
        case .highlight:
            if let lines = analysis?.lines {
                let r = HighlightSnap.snap(mark.rect,lines: lines)
                mark.points = [r.origin,CGPoint(x: r.maxX,y: r.maxY)]
            }
        case .arrow:
            guard let a = mark.points.first,let b = mark.points.last,hypot(b.x-a.x,b.y-a.y) > 3 else { return }
            if mark.arrow == .curved,mark.bend == nil { mark.bend = ArrowGeometry.defaultBend(from: a,to: b) }
            if mark.arrow == .tapered,mark.bend == nil { mark.bend = CGPoint(x: (a.x+b.x)/2,y: (a.y+b.y)/2) }
        case .pixelate: if mark.seed == nil { mark.seed = UInt64.random(in: 1...UInt64.max) }
        default: break
        }
        checkpoint()
        if mark.tool == .crop {
            let r = mark.rect.intersection(CGRect(x: 0,y: 0,width: image.width,height: image.height)).integral
            if r.width >= 2,r.height >= 2,let cropped = render(includeBackground: false)?.cropping(to: CGRect(x: r.minX,y: CGFloat(image.height)-r.maxY,width: r.width,height: r.height)) {
                image = cropped; marks.removeAll(); resizeWidth = String(image.width)
            }
        } else { marks.append(mark) }
    }
    /// Index of the curved arrow whose bend handle is within `tolerance` of `p`.
    func bendHandle(near p: CGPoint,tolerance: CGFloat) -> Int? {
        marks.indices.last { marks[$0].hasBend && marks[$0].bend.map { hypot($0.x-p.x,$0.y-p.y) <= tolerance } == true }
    }
    /// The dragged crop corner: snapped to image and object edges, then held to the chosen aspect.
    func cropCorner(anchor: CGPoint,point: CGPoint,tolerance: CGFloat) -> CGPoint {
        let bounds = CGRect(x: 0,y: 0,width: image.width,height: image.height)
        let guides = CropMath.guides(bounds: bounds,objects: (analysis?.lines ?? [])+marks.filter { $0.tool != .pen }.map(\.rect))
        let snapped = CropMath.snapPoint(point,xGuides: guides.x,yGuides: guides.y,tolerance: tolerance)
        let r = CropMath.constrain(anchor: anchor,point: snapped,ratio: cropAspect.ratio,bounds: bounds)
        return CGPoint(x: abs(r.minX-anchor.x) < 0.5 ? r.maxX : r.minX,y: abs(r.minY-anchor.y) < 0.5 ? r.maxY : r.minY)
    }
    func resize() {
        guard let w = Int(resizeWidth),w >= 16,w <= 16000,let rendered = render(includeBackground: false) else { notice = "Enter a width between 16 and 16,000 pixels."; return }
        let h = Int(Double(rendered.height)*Double(w)/Double(rendered.width))
        guard let ctx = Self.context(width: w,height: h) else { return }
        ctx.interpolationQuality = .high; ctx.draw(rendered,in: CGRect(x: 0,y: 0,width: w,height: h))
        guard let result = ctx.makeImage() else { return }; checkpoint(); image = result; marks = []
    }
    func transform(rotate: Bool) {
        guard let rendered = render(includeBackground: false) else { return }
        let w = rotate ? rendered.height : rendered.width; let h = rotate ? rendered.width : rendered.height
        guard let ctx = Self.context(width: w,height: h) else { return }
        if rotate { ctx.translateBy(x: CGFloat(w),y: 0); ctx.rotate(by: .pi/2) }
        else { ctx.translateBy(x: CGFloat(w),y: 0); ctx.scaleBy(x: -1,y: 1) }
        ctx.draw(rendered,in: CGRect(x: 0,y: 0,width: rendered.width,height: rendered.height))
        if let result = ctx.makeImage() { checkpoint(); image = result; marks = []; resizeWidth = String(w) }
    }
    nonisolated static func context(width: Int,height: Int) -> CGContext? {
        guard width > 0,height > 0,width <= 20000,height <= 30000,width*height <= 150_000_000 else { return nil }
        return CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: Rendering
    /// Opaque part of the image (top-left origin), so transparent window-shadow margins don't skew the padding.
    func visibleBounds() -> CGRect {
        if let visible { return visible }
        let full = CGRect(x: 0,y: 0,width: image.width,height: image.height)
        var result = full
        if ![.none,.noneSkipLast,.noneSkipFirst].contains(image.alphaInfo),
           let ctx = Self.context(width: image.width,height: image.height),let data = ctx.data {
            ctx.draw(image,in: full)
            let bytes = data.assumingMemoryBound(to: UInt8.self),stride = ctx.bytesPerRow
            result = BackdropLayout.opaqueBounds(alpha: { x,y in bytes[y*stride+x*4+3] },width: image.width,height: image.height) ?? full
        }
        visible = result
        return result
    }
    var decorated: Bool { padding > 0 || aspect != .auto }
    func render(includeBackground: Bool = true,extra: Mark? = nil) -> CGImage? {
        let decorate = includeBackground && decorated
        let size = CGSize(width: image.width,height: image.height)
        var canvas = size,origin = CGPoint.zero
        if decorate {
            let layout = BackdropLayout.layout(content: size,visible: autoBalance ? visibleBounds() : nil,padding: CGFloat(padding),aspect: aspect,alignment: alignment,autoBalance: autoBalance)
            canvas = layout.canvas; origin = layout.origin
        }
        guard let ctx = Self.context(width: Int(canvas.width),height: Int(canvas.height)) else { return nil }
        let frame = CGRect(x: origin.x,y: canvas.height-origin.y-size.height,width: size.width,height: size.height)
        if decorate {
            Self.drawBackground(backdrop,in: ctx,rect: CGRect(origin: .zero,size: canvas))
            ctx.saveGState()
            if shadow { ctx.setShadow(offset: CGSize(width: 0,height: -8),blur: max(14,CGFloat(padding)*0.5),color: NSColor.black.withAlphaComponent(0.4).cgColor) }
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            if corner > 0 { ctx.addPath(CGPath(roundedRect: frame,cornerWidth: corner,cornerHeight: corner,transform: nil)); ctx.clip() }
            ctx.draw(image,in: frame)
            ctx.endTransparencyLayer(); ctx.restoreGState()
        } else { ctx.draw(image,in: frame) }
        markOrigin = frame.origin
        ctx.translateBy(x: frame.minX,y: frame.minY)
        for mark in marks+(extra.map { [$0] } ?? []) { drawMark(mark,in: ctx) }
        return ctx.makeImage()
    }
    nonisolated static func drawBackground(_ background: StudioBackground,in ctx: CGContext,rect: CGRect) {
        switch background {
        case .none: break
        case .color(let r,let g,let b): ctx.setFillColor(CGColor(srgbRed: r,green: g,blue: b,alpha: 1)); ctx.fill(rect)
        case .gradient(let index): Backdrops.draw(index,in: ctx,rect: rect)
        case .image(let path):
            guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil,context: nil,hints: nil) else { Backdrops.draw(0,in: ctx,rect: rect); return }
            let fill = max(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height))
            let w = CGFloat(image.width)*fill,h = CGFloat(image.height)*fill
            ctx.saveGState(); ctx.clip(to: rect); ctx.interpolationQuality = .high
            ctx.draw(image,in: CGRect(x: rect.midX-w/2,y: rect.midY-h/2,width: w,height: h)); ctx.restoreGState()
        }
    }
    private func drawMark(_ mark: Mark,in ctx: CGContext) {
        guard let a = mark.points.first,let b = mark.points.last else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setLineWidth(mark.width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(mark.nsColor.cgColor); ctx.setFillColor(mark.nsColor.cgColor)
        switch mark.tool {
        case .arrow: drawArrow(mark,a,b,in: ctx)
        case .line: ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        case .rectangle: ctx.stroke(mark.rect)
        case .ellipse: ctx.strokeEllipse(in: mark.rect)
        case .pen: ctx.addLines(between: mark.points); ctx.strokePath()
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(mark.nsColor.withAlphaComponent(0.4).cgColor); ctx.fill(mark.rect)
        case .redact: ctx.setFillColor(NSColor.black.cgColor); ctx.fill(mark.rect)
        case .pixelate,.blur:
            let rect = mark.rect.intersection(CGRect(x: 0,y: 0,width: image.width,height: image.height)).integral
            guard rect.width > 0,rect.height > 0,let base = ctx.makeImage() else { return }
            // Include all prior markup; filter only the selected pixels.
            guard let crop = base.cropping(to: CGRect(x: rect.minX+markOrigin.x,y: CGFloat(base.height)-markOrigin.y-rect.maxY,width: rect.width,height: rect.height)) else { return }
            if mark.tool == .pixelate {
                if let mosaic = Self.scrambledMosaic(crop,seed: mark.seed ?? UInt64(abs(Int(rect.minX*7919+rect.minY*104729+rect.width)))) { ctx.interpolationQuality = .none; ctx.draw(mosaic,in: rect) }
            } else {
                let input = CIImage(cgImage: crop)
                let output = input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters: ["inputRadius": 18]).cropped(to: input.extent)
                if let blurred = StudioRenderer.context.createCGImage(output,from: input.extent) { ctx.draw(blurred,in: rect) }
            }
        case .spotlight:
            let path = CGMutablePath(); path.addRect(CGRect(x: 0,y: 0,width: image.width,height: image.height)); path.addRoundedRect(in: mark.rect,cornerWidth: 12,cornerHeight: 12)
            ctx.addPath(path); ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.drawPath(using: .eoFill)
        case .text: drawText(mark,at: a,in: ctx)
        case .step:
            let size = max(22,mark.width*5)
            ctx.fillEllipse(in: CGRect(x: a.x-size*0.7,y: a.y-size*0.7,width: size*1.4,height: size*1.4))
            let text = NSAttributedString(string: mark.text,attributes: [.font: NSFont.systemFont(ofSize: size,weight: .bold),.foregroundColor: NSColor.white])
            Self.draw(text,at: CGPoint(x: a.x-text.size().width/2,y: a.y-text.size().height/2),in: ctx)
        case .crop: ctx.stroke(mark.rect)
        }
    }
    private func drawArrow(_ mark: Mark,_ a: CGPoint,_ b: CGPoint,in ctx: CGContext) {
        let style = mark.arrow ?? .straight
        let mid = CGPoint(x: (a.x+b.x)/2,y: (a.y+b.y)/2)
        let c = mark.hasBend ? ArrowGeometry.control(from: a,to: b,through: mark.bend ?? mid) : mid
        let head = max(16,mark.width*3.4)
        let endAngle = ArrowGeometry.tangentAngle(a,c,b,atEnd: true),startAngle = ArrowGeometry.tangentAngle(a,c,b,atEnd: false)
        // Stop the body inside the head so its round cap never pokes through the tip.
        let end = CGPoint(x: b.x-head*0.6*cos(endAngle),y: b.y-head*0.6*sin(endAngle))
        let start = style == .double ? CGPoint(x: a.x-head*0.6*cos(startAngle),y: a.y-head*0.6*sin(startAngle)) : a
        if style == .tapered {
            ctx.addLines(between: ArrowGeometry.taperedOutline(start,c,end,start: mark.width*0.35,end: mark.width*1.5)); ctx.closePath(); ctx.fillPath()
        } else {
            ctx.move(to: start); ctx.addQuadCurve(to: end,control: c); ctx.strokePath()
        }
        let length = style == .tapered ? head*1.15 : head
        ctx.addLines(between: ArrowGeometry.head(tip: b,angle: endAngle,length: length,spread: .pi/7)); ctx.closePath(); ctx.fillPath()
        if style == .double { ctx.addLines(between: ArrowGeometry.head(tip: a,angle: startAngle,length: head,spread: .pi/7)); ctx.closePath(); ctx.fillPath() }
    }
    private func drawText(_ mark: Mark,at a: CGPoint,in ctx: CGContext) {
        let preset = mark.preset ?? .plain
        let size = max(22,mark.width*5)*(preset == .title ? 1.7 : preset == .mono ? 0.8 : 1)
        let color = mark.nsColor
        let light = (color.usingColorSpace(.sRGB).map { 0.299*$0.redComponent+0.587*$0.greenComponent+0.114*$0.blueComponent } ?? 0) > 0.7
        var attributes: [NSAttributedString.Key: Any] = [.font: preset == .mono ? NSFont.monospacedSystemFont(ofSize: size,weight: .medium) : NSFont.systemFont(ofSize: size,weight: preset == .title ? .heavy : .bold),.foregroundColor: color]
        switch preset {
        case .outlined: attributes[.strokeColor] = light ? NSColor.black : NSColor.white; attributes[.strokeWidth] = -4.0
        case .pill,.callout: attributes[.foregroundColor] = light ? NSColor.black : NSColor.white
        case .mono: attributes[.foregroundColor] = NSColor(white: 0.93,alpha: 1)
        case .title: let shadow = NSShadow(); shadow.shadowBlurRadius = size*0.12; shadow.shadowOffset = CGSize(width: 0,height: -size*0.04); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); attributes[.shadow] = shadow
        case .plain: break
        }
        let text = NSAttributedString(string: mark.text,attributes: attributes)
        let box = CGRect(origin: a,size: text.size())
        let pad = CGSize(width: size*0.45,height: size*0.18)
        switch preset {
        case .pill:
            let r = box.insetBy(dx: -pad.width,dy: -pad.height)
            ctx.addPath(CGPath(roundedRect: r,cornerWidth: r.height/2,cornerHeight: r.height/2,transform: nil)); ctx.fillPath()
        case .callout:
            let r = box.insetBy(dx: -pad.width,dy: -pad.height),radius = size*0.3
            ctx.addPath(CGPath(roundedRect: r,cornerWidth: radius,cornerHeight: radius,transform: nil))
            ctx.move(to: CGPoint(x: r.minX+radius*1.4,y: r.minY+1)); ctx.addLine(to: CGPoint(x: r.minX+radius*0.4,y: r.minY-size*0.55)); ctx.addLine(to: CGPoint(x: r.minX+radius*2.8,y: r.minY+1))
            ctx.fillPath()
        case .mono:
            let r = box.insetBy(dx: -pad.width,dy: -pad.height)
            ctx.setFillColor(NSColor(srgbRed: 0.11,green: 0.11,blue: 0.13,alpha: 0.96).cgColor)
            ctx.addPath(CGPath(roundedRect: r,cornerWidth: size*0.25,cornerHeight: size*0.25,transform: nil)); ctx.fillPath()
            ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: r.minX,y: r.minY+size*0.2,width: max(3,size*0.12),height: r.height-size*0.4))
        default: break
        }
        Self.draw(text,at: a,in: ctx)
    }
    private static func draw(_ text: NSAttributedString,at point: CGPoint,in ctx: CGContext) {
        let old = NSGraphicsContext.current; NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: false)
        text.draw(at: point); NSGraphicsContext.current = old
    }
    /// A 14 px mosaic whose blocks are shuffled and jittered: it reads as pixelation but keeps no layout to reverse.
    nonisolated static func scrambledMosaic(_ crop: CGImage,seed: UInt64) -> CGImage? {
        let w = max(1,crop.width/14),h = max(1,crop.height/14)
        guard let small = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),let data = small.data else { return nil }
        small.interpolationQuality = .medium; small.draw(crop,in: CGRect(x: 0,y: 0,width: w,height: h))
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        var bytes = Array(UnsafeBufferPointer(start: pointer,count: w*h*4))
        PixelScramble.scramble(&bytes,count: w*h,seed: seed)
        bytes.withUnsafeBytes { _ = memcpy(data,$0.baseAddress!,w*h*4) }
        return small.makeImage()
    }

    // MARK: Output
    func save() {
        guard let result = render() else { notice = "Image too large to export."; return }
        do { let clip = try store.write(image: result,kind: "Edited"); notice = "Saved \(clip.url.lastPathComponent)" }
        catch { notice = error.localizedDescription }
    }
    func copy() {
        guard let result = render() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([NSImage(cgImage: result,size: .zero)])
        if let data = NSBitmapImageRep(cgImage: result).representation(using: .png,properties: [:]) { NSPasteboard.general.setData(data,forType: .png) }
        notice = "Copied to clipboard"
    }
    func project() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(original.url.deletingPathExtension().lastPathComponent).easyshot.json"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { return }
        let c = backgroundColor.rgba
        let project = EditorProject(png: data,marks: marks,padding: padding,background: c,shadow: shadow,backdrop: backdrop,corner: corner,aspect: aspect,alignment: alignment,autoBalance: autoBalance)
        do { try JSONEncoder().encode(project).write(to: url,options: .atomic); notice = "Editable project saved" }
        catch { notice = error.localizedDescription }
    }
    func apply(_ project: EditorProject) {
        marks = project.marks; padding = project.padding; shadow = project.shadow
        let b = project.background; backdrop = project.backdrop ?? .color(b[0],b[1],b[2])
        corner = project.corner ?? 0; aspect = project.aspect ?? .auto; alignment = project.alignment ?? .center; autoBalance = project.autoBalance ?? false
    }
    var currentPreset: BackgroundPreset { BackgroundPreset(name: "",background: backdrop,padding: padding,shadow: shadow,corner: corner,aspect: aspect,alignment: alignment,autoBalance: autoBalance) }
    func apply(_ preset: BackgroundPreset) {
        backdrop = preset.background; padding = preset.padding; shadow = preset.shadow; corner = preset.corner
        aspect = preset.aspect; alignment = preset.alignment; autoBalance = preset.autoBalance
    }
    func combine(_ url: URL,horizontal: Bool = Preferences.shared.combineHorizontally) {
        guard let other = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil,context: nil,hints: nil),let current = render(includeBackground: false) else { return }
        let gap = 24
        let w = horizontal ? current.width+other.width+gap : max(current.width,other.width)
        let h = horizontal ? max(current.height,other.height) : current.height+other.height+gap
        guard let ctx = Self.context(width: w,height: h) else { notice = "Combined image would be too large."; return }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0,y: 0,width: w,height: h))
        if horizontal {
            ctx.draw(current,in: CGRect(x: 0,y: h-current.height,width: current.width,height: current.height))
            ctx.draw(other,in: CGRect(x: current.width+gap,y: h-other.height,width: other.width,height: other.height))
        } else {
            ctx.draw(current,in: CGRect(x: 0,y: other.height+gap,width: current.width,height: current.height)); ctx.draw(other,in: CGRect(x: 0,y: 0,width: other.width,height: other.height))
        }
        if let result = ctx.makeImage() { checkpoint(); image = result; marks = []; resizeWidth = String(image.width) }
    }
}

struct AnnotationCanvas: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> DrawingView { DrawingView(model: model) }
    func updateNSView(_ view: DrawingView,context: Context) { view.model = model; view.needsDisplay = true }
    final class DrawingView: NSView {
        var model: EditorModel
        var draft: Mark?
        var editingBend: Int?
        init(model: EditorModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        var imageRect: CGRect {
            let scale = min((bounds.width-60)/CGFloat(model.image.width),(bounds.height-60)/CGFloat(model.image.height))
            let size = CGSize(width: CGFloat(model.image.width)*scale,height: CGFloat(model.image.height)*scale)
            return CGRect(x: (bounds.width-size.width)/2,y: (bounds.height-size.height)/2,width: size.width,height: size.height)
        }
        /// Image pixels per view point; tolerances are given in view points.
        var pixelScale: CGFloat { CGFloat(model.image.width)/max(imageRect.width,1) }
        func point(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow,from: nil); let r = imageRect
            return CGPoint(x: max(0,min(CGFloat(model.image.width),(p.x-r.minX)*CGFloat(model.image.width)/r.width)),y: max(0,min(CGFloat(model.image.height),(p.y-r.minY)*CGFloat(model.image.height)/r.height)))
        }
        func viewRect(_ r: CGRect) -> CGRect {
            let s = 1/pixelScale,o = imageRect.origin
            return CGRect(x: o.x+r.minX*s,y: o.y+r.minY*s,width: r.width*s,height: r.height*s)
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext,let result = model.render(includeBackground: false,extra: draft) else { return }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0,height: -8),blur: 28,color: NSColor.black.withAlphaComponent(0.4).cgColor)
            context.draw(result,in: imageRect)
            context.restoreGState()
            if model.tool == .arrow {
                for mark in model.marks where mark.hasBend {
                    guard let bend = mark.bend else { continue }
                    let p = viewRect(CGRect(origin: bend,size: .zero)).origin
                    context.setFillColor(NSColor.white.cgColor); context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(2)
                    context.fillEllipse(in: CGRect(x: p.x-5,y: p.y-5,width: 10,height: 10)); context.strokeEllipse(in: CGRect(x: p.x-5,y: p.y-5,width: 10,height: 10))
                }
            }
            for secret in model.proposals {
                let r = viewRect(secret.rect)
                context.setStrokeColor(NSColor.systemOrange.cgColor); context.setLineWidth(2); context.setLineDash(phase: 0,lengths: [5,3])
                context.setFillColor(NSColor.systemOrange.withAlphaComponent(0.18).cgColor); context.fill(r); context.stroke(r)
                context.setLineDash(phase: 0,lengths: [])
                let label = NSAttributedString(string: " \(secret.kind.title) ",attributes: [.font: NSFont.systemFont(ofSize: 10,weight: .semibold),.foregroundColor: NSColor.black,.backgroundColor: NSColor.systemOrange])
                label.draw(at: CGPoint(x: r.minX,y: r.maxY+2))
            }
        }
        override func mouseDown(with event: NSEvent) {
            guard imageRect.contains(convert(event.locationInWindow,from: nil)) else { return }
            window?.makeFirstResponder(self)
            let p = point(event)
            if let index = model.proposals.lastIndex(where: { $0.rect.contains(p) }) { model.proposals.remove(at: index); needsDisplay = true; return }
            if model.tool == .arrow,let index = model.bendHandle(near: p,tolerance: 9*pixelScale) { model.checkpoint(); editingBend = index; return }
            let c = NSColor(model.color).usingColorSpace(.sRGB) ?? .red
            let text = model.tool == .step ? String(model.marks.filter { $0.tool == .step }.count+1) : model.text
            draft = Mark(tool: model.tool,points: [p,p],color: [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent],width: model.stroke,text: text,
                         arrow: model.tool == .arrow ? model.arrowStyle : nil,preset: model.tool == .text ? model.preset : nil)
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            let p = point(event)
            if let editingBend { model.marks[editingBend].bend = p; needsDisplay = true; return }
            guard let anchor = draft?.points.first else { return }
            switch model.tool {
            case .pen: draft?.points.append(p)
            case .crop: draft?.points[1] = model.cropCorner(anchor: anchor,point: p,tolerance: 8*pixelScale)
            default: draft?.points[1] = p
            }
            if model.tool == .arrow,model.arrowStyle == .curved,let b = draft?.points.last { draft?.bend = ArrowGeometry.defaultBend(from: anchor,to: b) }
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            if editingBend != nil { editingBend = nil; return }
            guard let mark = draft else { return }; model.add(mark); draft = nil; needsDisplay = true
        }
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command),event.charactersIgnoringModifiers == "z" {
                if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }
            } else if event.keyCode == 53 { draft = nil; needsDisplay = true }
            else { super.keyDown(with: event) }
        }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var preferences = Preferences.shared
    @State private var presetName = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "viewfinder").foregroundStyle(accent)
                Text("Annotate").font(.system(size: 16,weight: .semibold))
                Text("\(model.image.width) × \(model.image.height)").font(.system(size: 11,design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button { model.findSecrets() } label: { Label("Find secrets",systemImage: "eye.slash") }.disabled(model.scanning)
                    .help("Detect API keys, tokens, emails, IP addresses and card numbers on this image")
                if !model.proposals.isEmpty { Button("Redact \(model.proposals.count)") { model.redactProposals() }.buttonStyle(.glassProminent).tint(.orange) }
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo ⌘Z")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                Button("Copy") { model.copy() }.keyboardShortcut("c",modifiers: [.command,.shift])
                Button("Save capture") { model.save() }.keyboardShortcut("s").buttonStyle(.glassProminent).tint(accent)
            }.buttonStyle(.glass).controlSize(.regular).padding(18).glassEffect(.regular,in: RoundedRectangle(cornerRadius: 22)).padding(10)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(MarkTool.allCases) { tool in
                        Button { model.tool = tool } label: {
                            Image(systemName: tool.symbol).font(.system(size: 16)).frame(width: 38,height: 33)
                                .glassEffect(model.tool == tool ? .regular.tint(accent.opacity(0.3)).interactive() : .identity,in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).help(tool.rawValue.capitalized)
                    }
                    Spacer()
                }.padding(10).frame(width: 60).glassEffect(.regular,in: RoundedRectangle(cornerRadius: 22)).padding(8)
                Divider()
                AnnotationCanvas(model: model).frame(maxWidth: .infinity,maxHeight: .infinity)
                    .background(Color(red: 0.12,green: 0.12,blue: 0.15))
                    .onDrop(of: [.fileURL],isTargeted: nil) { providers in
                        providers.first?.loadItem(forTypeIdentifier: "public.file-url",options: nil) { item,_ in
                            guard let data = item as? Data,let url = URL(dataRepresentation: data,relativeTo: nil) else { return }
                            Task { @MainActor in model.combine(url) }
                        }; return true
                    }
                Divider()
                ScrollView { sidebar.padding(18) }.frame(width: 250)
            }
            Divider()
            HStack { Image(systemName: model.tool.symbol); Text(model.tool.rawValue.capitalized); Spacer(); Text(model.notice).lineLimit(1) }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }.background(canvasColor).preferredColorScheme(.dark).frame(minWidth: 960,minHeight: 720)
    }
    var sidebar: some View {
        VStack(alignment: .leading,spacing: 16) {
            heading("STYLE")
            HStack {
                ColorPicker("Color",selection: $model.color,supportsOpacity: false)
                Button { NSColorSampler().show { if let c = $0 { model.color = Color(nsColor: c) } } } label: { Image(systemName: "eyedropper") }.help("Pick a color from the image or screen")
            }
            palette
            VStack(alignment: .leading) { Text("Stroke · \(Int(model.stroke)) px").font(.system(size: 12)); Slider(value: $model.stroke,in: 2...20) }
            toolOptions
            Divider()
            heading("BACKGROUND")
            backgroundOptions
            Divider()
            heading("IMAGE")
            HStack { TextField("Width",text: $model.resizeWidth).frame(width: 65); Text("px").foregroundStyle(.secondary); Button("Resize") { model.resize() } }
            HStack { Button("Rotate") { model.transform(rotate: true) }; Button("Flip") { model.transform(rotate: false) } }
            HStack {
                Button("Add below…") { combine(horizontal: false) }; Button("Add beside…") { combine(horizontal: true) }
            }
            Picker("Dropped images",selection: Binding(get: { preferences.combineHorizontally },set: { preferences.combineHorizontally = $0 })) { Text("Below").tag(false); Text("Beside").tag(true) }.pickerStyle(.segmented)
            Button("Save editable project…") { model.project() }
        }.font(.system(size: 12)).buttonStyle(.glass).controlSize(.small)
    }
    func heading(_ text: String) -> some View { Text(text).font(.system(size: 10,weight: .bold)).foregroundStyle(.secondary) }
    var palette: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(20),spacing: 6),count: 8),alignment: .leading,spacing: 6) {
            ForEach(Array(preferences.colorPalette.enumerated()),id: \.offset) { index,rgba in
                Circle().fill(Color(rgba: rgba)).frame(width: 18,height: 18).overlay(Circle().stroke(.white.opacity(0.3)))
                    .onTapGesture { model.color = Color(rgba: rgba) }
                    .contextMenu { Button("Remove color") { preferences.colorPalette.remove(at: index) } }
            }
            Button { preferences.colorPalette.append(model.color.rgba) } label: { Image(systemName: "plus").font(.system(size: 9,weight: .bold)).frame(width: 18,height: 18) }
                .buttonStyle(.plain).background(Circle().fill(.white.opacity(0.1))).help("Save the current color")
        }
    }
    @ViewBuilder var toolOptions: some View {
        switch model.tool {
        case .arrow:
            Picker("Arrow",selection: $model.arrowStyle) { ForEach(ArrowStyle.allCases,id: \.self) { Text($0.title).tag($0) } }
            if model.arrowStyle == .curved || model.arrowStyle == .tapered { Text("Drag the white handle to bend an arrow.").font(.system(size: 10)).foregroundStyle(.secondary) }
        case .text:
            TextField("Text",text: $model.text).textFieldStyle(.roundedBorder)
            Picker("Style",selection: $model.preset) { ForEach(TextPreset.allCases,id: \.self) { Text($0.title).tag($0) } }
        case .crop:
            Picker("Aspect",selection: $model.cropAspect) { ForEach(CropAspect.allCases,id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text("Edges snap to the image, text and shapes.").font(.system(size: 10)).foregroundStyle(.secondary)
        case .highlight: Text("Highlights snap to the text line underneath.").font(.system(size: 10)).foregroundStyle(.secondary)
        case .pixelate: Text("Mosaic blocks are shuffled, so pixelated text cannot be reconstructed.").font(.system(size: 10)).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
    @ViewBuilder var backgroundOptions: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30),spacing: 6),count: 6),alignment: .leading,spacing: 6) {
            swatch(.none) { RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.4)).overlay(Image(systemName: "nosign").font(.system(size: 11))) }
            swatch(.color(model.backgroundColor.rgba[0],model.backgroundColor.rgba[1],model.backgroundColor.rgba[2])) { RoundedRectangle(cornerRadius: 6).fill(model.backgroundColor) }
            ForEach(0..<Backdrops.count,id: \.self) { i in swatch(.gradient(i)) { Image(nsImage: Backdrops.thumbnail(i)).resizable().clipShape(RoundedRectangle(cornerRadius: 6)) } }
            Button { if let screen = NSScreen.main,let url = NSWorkspace.shared.desktopImageURL(for: screen) { model.backdrop = .image(url.path); ensurePadding() } } label: {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)).overlay(Image(systemName: "photo").font(.system(size: 11)))
            }.buttonStyle(.plain).frame(width: 30,height: 30).help("Desktop wallpaper")
        }
        if case .color = model.backdrop { ColorPicker("Color",selection: $model.backgroundColor,supportsOpacity: false) }
        VStack(alignment: .leading) { Text("Padding · \(Int(model.padding)) px").font(.system(size: 12)); Slider(value: $model.padding,in: 0...240) }
        VStack(alignment: .leading) { Text("Corners · \(Int(model.corner)) px").font(.system(size: 12)); Slider(value: $model.corner,in: 0...40) }
        Picker("Aspect",selection: $model.aspect) { ForEach(BackdropAspect.allCases,id: \.self) { Text($0.title).tag($0) } }
        HStack(alignment: .top,spacing: 14) {
            Grid(horizontalSpacing: 3,verticalSpacing: 3) {
                ForEach(0..<3) { row in GridRow { ForEach(0..<3) { column in
                    let value = BackdropAlignment(rawValue: row*3+column)!
                    Button { model.alignment = value } label: { RoundedRectangle(cornerRadius: 2).fill(model.alignment == value ? accent : .white.opacity(0.18)).frame(width: 12,height: 12) }.buttonStyle(.plain)
                } } }
            }.help("Alignment")
            VStack(alignment: .leading,spacing: 6) {
                Toggle("Shadow",isOn: $model.shadow)
                Toggle("Auto-balance",isOn: $model.autoBalance).help("Pad around the visible window, ignoring transparent shadow margins")
            }
        }
        HStack {
            Menu("Presets") {
                ForEach(preferences.backgroundPresets) { preset in Button(preset.name) { model.apply(preset) } }
                if !preferences.backgroundPresets.isEmpty {
                    Divider()
                    Menu("Delete") { ForEach(preferences.backgroundPresets) { preset in Button(preset.name) { preferences.backgroundPresets.removeAll { $0.id == preset.id } } } }
                }
            }.frame(width: 90)
            TextField("Name",text: $presetName).textFieldStyle(.roundedBorder)
            Button("Save") {
                var preset = model.currentPreset; preset.name = presetName.isEmpty ? "Preset \(preferences.backgroundPresets.count+1)" : presetName
                preferences.backgroundPresets.append(preset); presetName = ""
            }
        }
        Button("Preview background") {
            if let image = model.render() { AppController.shared.pinImage(NSImage(cgImage: image,size: .zero),title: "Background preview") }
        }
    }
    func swatch<L: View>(_ background: StudioBackground,@ViewBuilder label: () -> L) -> some View {
        Button { model.backdrop = background; ensurePadding() } label: { label() }.buttonStyle(.plain).frame(width: 30,height: 30)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(accent,lineWidth: model.backdrop == background ? 2 : 0).padding(-2))
    }
    /// Choosing a background with no padding would show nothing; give it a sensible default.
    func ensurePadding() { if model.padding == 0 && model.aspect == .auto && model.backdrop != .none { model.padding = 64 } }
    func combine(horizontal: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK,let url = panel.url { model.combine(url,horizontal: horizontal) }
    }
}
