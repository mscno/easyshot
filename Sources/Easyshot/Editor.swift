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

struct Mark: Codable {
    var tool: MarkTool
    var points: [CGPoint]
    var color: [Double]
    var width: Double
    var text: String = ""
    var rect: CGRect { CaptureGeometry.rectangle(from: points.first ?? .zero,to: points.last ?? .zero) }
    var nsColor: NSColor { NSColor(srgbRed: color[0],green: color[1],blue: color[2],alpha: color[3]) }
}

@MainActor final class EditorModel: ObservableObject {
    @Published var image: CGImage
    @Published var marks: [Mark] = []
    @Published var tool: MarkTool = .arrow
    @Published var color = Color(red: 1,green: 0.32,blue: 0.35)
    @Published var stroke: Double = 6
    @Published var text = "Your text"
    @Published var padding: Double = 0
    @Published var background = Color(red: 0.28,green: 0.19,blue: 0.57)
    @Published var shadow = true
    @Published var resizeWidth = ""
    @Published var notice = ""
    let original: Clip
    let store: ClipStore
    private var undos: [(CGImage,[Mark])] = []
    private var redos: [(CGImage,[Mark])] = []
    init(image: CGImage,clip: Clip,store: ClipStore) { self.image = image; original = clip; self.store = store; resizeWidth = String(image.width) }
    func checkpoint() { undos.append((image,marks)); if undos.count > 40 { undos.removeFirst() }; redos.removeAll() }
    func undo() { guard let state = undos.popLast() else { return }; redos.append((image,marks)); image = state.0; marks = state.1 }
    func redo() { guard let state = redos.popLast() else { return }; undos.append((image,marks)); image = state.0; marks = state.1 }
    func add(_ mark: Mark) {
        checkpoint()
        if mark.tool == .crop {
            let r = mark.rect.intersection(CGRect(x: 0,y: 0,width: image.width,height: image.height)).integral
            if r.width >= 2,r.height >= 2,let cropped = render(includeBackground: false)?.cropping(to: CGRect(x: r.minX,y: CGFloat(image.height)-r.maxY,width: r.width,height: r.height)) {
                image = cropped; marks.removeAll(); resizeWidth = String(image.width)
            }
        } else { marks.append(mark) }
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
    func render(includeBackground: Bool = true,extra: Mark? = nil) -> CGImage? {
        let pad = includeBackground ? Int(padding) : 0
        guard let ctx = Self.context(width: image.width+pad*2,height: image.height+pad*2) else { return nil }
        if pad > 0 {
            ctx.setFillColor(NSColor(background).cgColor); ctx.fill(CGRect(x: 0,y: 0,width: ctx.width,height: ctx.height))
            if shadow { ctx.setShadow(offset: CGSize(width: 0,height: -8),blur: CGFloat(pad)*0.5,color: NSColor.black.withAlphaComponent(0.4).cgColor) }
        }
        ctx.draw(image,in: CGRect(x: pad,y: pad,width: image.width,height: image.height))
        ctx.setShadow(offset: .zero,blur: 0,color: nil)
        ctx.translateBy(x: CGFloat(pad),y: CGFloat(pad))
        for mark in marks+(extra.map { [$0] } ?? []) { drawMark(mark,in: ctx) }
        return ctx.makeImage()
    }
    private func drawMark(_ mark: Mark,in ctx: CGContext) {
        guard let a = mark.points.first,let b = mark.points.last else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setLineWidth(mark.width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(mark.nsColor.cgColor); ctx.setFillColor(mark.nsColor.cgColor)
        switch mark.tool {
        case .arrow,.line:
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            if mark.tool == .arrow {
                let angle = atan2(b.y-a.y,b.x-a.x); let length = max(18,mark.width*4)
                ctx.move(to: CGPoint(x: b.x-length*cos(angle - .pi/6),y: b.y-length*sin(angle - .pi/6)))
                ctx.addLine(to: b); ctx.addLine(to: CGPoint(x: b.x-length*cos(angle + .pi/6),y: b.y-length*sin(angle + .pi/6))); ctx.strokePath()
            }
        case .rectangle: ctx.stroke(mark.rect)
        case .ellipse: ctx.strokeEllipse(in: mark.rect)
        case .pen:
            ctx.addLines(between: mark.points); ctx.strokePath()
        case .highlight:
            ctx.setFillColor(mark.nsColor.withAlphaComponent(0.32).cgColor); ctx.fill(mark.rect)
        case .redact: ctx.setFillColor(NSColor.black.cgColor); ctx.fill(mark.rect)
        case .pixelate,.blur:
            let rect = mark.rect.intersection(CGRect(x: 0,y: 0,width: image.width,height: image.height)).integral
            guard rect.width > 0,rect.height > 0,let base = ctx.makeImage() else { return }
            // Include all prior markup; filter only the selected pixels.
            let padX = CGFloat(ctx.width-image.width)/2; let padY = CGFloat(ctx.height-image.height)/2
            guard let crop = base.cropping(to: CGRect(x: rect.minX+padX,y: CGFloat(base.height)-padY-rect.maxY,width: rect.width,height: rect.height)) else { return }
            if mark.tool == .pixelate {
                guard let small = Self.context(width: max(1,Int(rect.width/14)),height: max(1,Int(rect.height/14))) else { return }
                small.interpolationQuality = .low; small.draw(crop,in: CGRect(x: 0,y: 0,width: small.width,height: small.height))
                if let pixelated = small.makeImage() { ctx.interpolationQuality = .none; ctx.draw(pixelated,in: rect) }
            } else {
                let input = CIImage(cgImage: crop)
                let output = input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters: ["inputRadius": 18]).cropped(to: input.extent)
                if let blurred = CIContext().createCGImage(output,from: input.extent) { ctx.draw(blurred,in: rect) }
            }
        case .spotlight:
            let path = CGMutablePath(); path.addRect(CGRect(x: 0,y: 0,width: image.width,height: image.height)); path.addRoundedRect(in: mark.rect,cornerWidth: 12,cornerHeight: 12)
            ctx.addPath(path); ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.drawPath(using: .eoFill)
        case .text,.step:
            let size = max(22,mark.width*5)
            if mark.tool == .step {
                ctx.fillEllipse(in: CGRect(x: a.x-size*0.7,y: a.y-size*0.7,width: size*1.4,height: size*1.4))
            }
            let text = NSAttributedString(string: mark.text,attributes: [.font: NSFont.systemFont(ofSize: size,weight: .bold),.foregroundColor: mark.tool == .step ? NSColor.white : mark.nsColor])
            let old = NSGraphicsContext.current; NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: false)
            let point = mark.tool == .step ? CGPoint(x: a.x-text.size().width/2,y: a.y-text.size().height/2) : a
            text.draw(at: point); NSGraphicsContext.current = old
        case .crop: ctx.stroke(mark.rect)
        }
    }
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
        struct Project: Codable { var png: Data; var marks: [Mark]; var padding: Double; var background: [Double]; var shadow: Bool }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { return }
        let c = NSColor(background).usingColorSpace(.sRGB) ?? .purple
        do { try JSONEncoder().encode(Project(png: data,marks: marks,padding: padding,background: [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent],shadow: shadow)).write(to: url,options: .atomic); notice = "Editable project saved" }
        catch { notice = error.localizedDescription }
    }
    func combine(_ url: URL) {
        guard let other = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil,context: nil,hints: nil),let current = render(includeBackground: false),let ctx = Self.context(width: max(current.width,other.width),height: current.height+other.height+24) else { return }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0,y: 0,width: ctx.width,height: ctx.height))
        ctx.draw(current,in: CGRect(x: 0,y: other.height+24,width: current.width,height: current.height)); ctx.draw(other,in: CGRect(x: 0,y: 0,width: other.width,height: other.height))
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
        init(model: EditorModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        var imageRect: CGRect {
            let scale = min((bounds.width-60)/CGFloat(model.image.width),(bounds.height-60)/CGFloat(model.image.height))
            let size = CGSize(width: CGFloat(model.image.width)*scale,height: CGFloat(model.image.height)*scale)
            return CGRect(x: (bounds.width-size.width)/2,y: (bounds.height-size.height)/2,width: size.width,height: size.height)
        }
        func point(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow,from: nil); let r = imageRect
            return CGPoint(x: max(0,min(CGFloat(model.image.width),(p.x-r.minX)*CGFloat(model.image.width)/r.width)),y: max(0,min(CGFloat(model.image.height),(p.y-r.minY)*CGFloat(model.image.height)/r.height)))
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext,let result = model.render(includeBackground: false,extra: draft) else { return }
            context.setShadow(offset: CGSize(width: 0,height: -8),blur: 28,color: NSColor.black.withAlphaComponent(0.4).cgColor)
            context.draw(result,in: imageRect)
        }
        override func mouseDown(with event: NSEvent) {
            guard imageRect.contains(convert(event.locationInWindow,from: nil)) else { return }
            window?.makeFirstResponder(self)
            let c = NSColor(model.color).usingColorSpace(.sRGB) ?? .red
            let p = point(event)
            let text = model.tool == .step ? String(model.marks.filter { $0.tool == .step }.count+1) : model.text
            draft = Mark(tool: model.tool,points: [p,p],color: [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent],width: model.stroke,text: text)
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            guard draft != nil else { return }
            if model.tool == .pen { draft?.points.append(point(event)) } else { draft?.points[1] = point(event) }
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
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
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "viewfinder").foregroundStyle(accent)
                Text("Annotate").font(.system(size: 16,weight: .semibold))
                Text("\(model.image.width) × \(model.image.height)").font(.system(size: 11,design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
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
                VStack(alignment: .leading,spacing: 18) {
                    Text("STYLE").font(.system(size: 10,weight: .bold)).foregroundStyle(.secondary)
                    ColorPicker("Color",selection: $model.color,supportsOpacity: false)
                    VStack(alignment: .leading) { Text("Stroke · \(Int(model.stroke)) px").font(.system(size: 12)); Slider(value: $model.stroke,in: 2...20) }
                    if model.tool == .text { TextField("Text",text: $model.text).textFieldStyle(.roundedBorder) }
                    Divider()
                    Text("BACKGROUND").font(.system(size: 10,weight: .bold)).foregroundStyle(.secondary)
                    ColorPicker("Background",selection: $model.background,supportsOpacity: false)
                    VStack(alignment: .leading) { Text("Padding · \(Int(model.padding)) px").font(.system(size: 12)); Slider(value: $model.padding,in: 0...200) }
                    Toggle("Shadow",isOn: $model.shadow)
                    Button("Preview background") {
                        if let image = model.render() { AppController.shared.pinImage(NSImage(cgImage: image,size: .zero),title: "Background preview") }
                    }
                    Divider()
                    Text("IMAGE").font(.system(size: 10,weight: .bold)).foregroundStyle(.secondary)
                    HStack { TextField("Width",text: $model.resizeWidth).frame(width: 65); Text("px").foregroundStyle(.secondary); Button("Resize") { model.resize() } }
                    HStack { Button("Rotate") { model.transform(rotate: true) }; Button("Flip") { model.transform(rotate: false) } }
                    Button("Combine image…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK,let url = panel.url { model.combine(url) }
                    }
                    Button("Save editable project…") { model.project() }
                    Spacer()
                    Text("Drag another image onto the canvas to combine.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).buttonStyle(.glass).controlSize(.small).padding(18).frame(width: 235)
            }
            Divider()
            HStack { Image(systemName: model.tool.symbol); Text(model.tool.rawValue.capitalized); Spacer(); Text(model.notice).lineLimit(1) }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }.background(canvasColor).preferredColorScheme(.dark).frame(minWidth: 900,minHeight: 700)
    }
}
