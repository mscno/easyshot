import SwiftUI
import AppKit
import ImageIO
import ShotglassCore

enum WorkspacePage: String,CaseIterable,Identifiable {
    case capture = "Capture",library = "Library",cloud = "Cloud",presets = "Presets",settings = "Settings"
    var id: String { rawValue }
    var symbol: String { switch self { case .capture: return "viewfinder"; case .library: return "square.stack.3d.up"; case .cloud: return "icloud"; case .presets: return "rectangle.dashed"; case .settings: return "slider.horizontal.3" } }
}

struct WorkspaceView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: ClipStore
    @ObservedObject var preferences = Preferences.shared
    @State var page: WorkspacePage = .library
    @State var query = ""
    @State var filter = "All"
    @State var presetName = ""
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Divider().overlay(.white.opacity(0.04))
                ScrollView {
                    Group {
                        switch page {
                        case .capture: capturePage
                        case .library: libraryPage
                        case .cloud: CloudLibraryPage(controller: controller)
                        case .presets: presetsPage
                        case .settings: SettingsView(controller: controller)
                        }
                    }.padding(32).frame(maxWidth: .infinity,alignment: .leading)
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(controller.permitted ? Color.green : Color.orange).frame(width: 5,height: 5)
                    Text(controller.status).lineLimit(1)
                    Spacer()
                    Text("LOCAL BY DEFAULT").font(.system(size: 9,weight: .semibold,design: .monospaced)).tracking(1)
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal,26).padding(.vertical,13)
            }.background(canvasColor.opacity(0.96))
        }.foregroundStyle(.white.opacity(0.92)).preferredColorScheme(.dark)
            .onReceive(NotificationCenter.default.publisher(for: .showLibrary)) { _ in page = .library }
            .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in page = .settings }
            .onReceive(NotificationCenter.default.publisher(for: .showCloud)) { _ in page = .cloud }
            .alert("Shotglass",isPresented: Binding(get: { store.error != nil },set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
    var sidebar: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [accent,Color(red: 0.38,green: 0.25,blue: 0.75)],startPoint: .topLeading,endPoint: .bottomTrailing)).frame(width: 39,height: 39)
                    Image(systemName: "viewfinder").font(.system(size: 22,weight: .medium)).foregroundStyle(.white)
                }
                VStack(alignment: .leading,spacing: 3) { Text("shotglass").font(.system(size: 21,weight: .bold,design: .rounded)); Text("A clearer way to capture").font(.system(size: 9)).foregroundStyle(.secondary) }
            }.padding(.bottom,38)
            Text("WORKSPACE").font(.system(size: 9,weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.3)).padding(.leading,12).padding(.bottom,12)
            ForEach(WorkspacePage.allCases.filter { $0 != .cloud || CloudSession.isAvailable }) { item in
                Button { page = item } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 18)
                        Text(item.rawValue).font(.system(size: 13,weight: page == item ? .semibold : .regular))
                        Spacer()
                        if item == .library { Text("\(store.clips.count)").font(.system(size: 10,weight: .medium,design: .monospaced)).foregroundStyle(.white.opacity(0.45)) }
                    }.padding(.horizontal,13).padding(.vertical,12)
                        .foregroundStyle(page == item ? accent : .white.opacity(0.5))
                        .glassEffect(page == item ? .regular.tint(accent.opacity(0.22)).interactive() : .identity,in: Capsule())
                }.buttonStyle(.plain).padding(.bottom,5)
            }
            Spacer()
            VStack(alignment: .leading,spacing: 12) {
                HStack { Image(systemName: "command").foregroundStyle(accent); Text("Open. Capture. Done.").font(.system(size: 11,weight: .medium)) }
                HStack { Text("While capture is open").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Text("D · draw").font(.system(size: 11,design: .monospaced)).padding(5).background(.white.opacity(0.07),in: RoundedRectangle(cornerRadius: 5)) }
            }.padding(14).background(.white.opacity(0.035),in: RoundedRectangle(cornerRadius: 12))
            HStack { Text("Shotglass 1.2"); Spacer(); Image(systemName: "lock.shield") }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.25)).padding(.top,20)
        }.padding(.horizontal,20).padding(.top,54).padding(.bottom,22).frame(width: 218)
            .glassEffect(.regular,in: RoundedRectangle(cornerRadius: 26)).padding(10)
    }
    var header: some View {
        HStack(spacing: 12) {
            Text(page.rawValue).font(.system(size: 14,weight: .semibold))
            if page == .library { Text("\(store.clips.count) captures").font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            Button { controller.importFile() } label: { Label("Import",systemImage: "square.and.arrow.down") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            Button { NSWorkspace.shared.open(preferences.folderURL) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("Open screenshots folder").foregroundStyle(.secondary)
            Button { controller.capture(.area,unified: true) } label: { Label("New capture",systemImage: "plus").font(.system(size: 11,weight: .semibold)).padding(.horizontal,12).padding(.vertical,8) }
                .buttonStyle(.glassProminent).tint(accent).disabled(controller.busy || controller.recording)
        }.padding(.horizontal,30).padding(.top,39).padding(.bottom,17)
    }
    var capturePage: some View {
        VStack(alignment: .leading,spacing: 26) {
            if !controller.permitted { permissionBanner }
            HStack(alignment: .top) {
                VStack(alignment: .leading,spacing: 12) {
                    HStack(spacing: 7) { Circle().fill(accent).frame(width: 5,height: 5); Text("QUICK CAPTURE").font(.system(size: 9,weight: .semibold)).tracking(1.8).foregroundStyle(accent) }
                    Text("Capture your screen.").font(.system(size: 32,weight: .semibold)).tracking(-1)
                    Text("Capture a detail, a window, or the whole picture.\nSaved to your folder. Ready on your clipboard.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).lineSpacing(5)
                }
                Spacer()
                Image(systemName: "viewfinder").font(.system(size: 34,weight: .light)).foregroundStyle(accent)
                    .frame(width: 84,height: 84).glassEffect(.regular.tint(accent.opacity(0.12)),in: RoundedRectangle(cornerRadius: 24)).padding(.top,15)
            }.padding(.bottom,4)
            VStack(alignment: .leading,spacing: 12) {
                sectionLabel("SCREENSHOTS",trailing: "Switch modes without leaving the overlay")
                GlassEffectContainer(spacing: 6) { HStack(spacing: 10) { ForEach(CaptureMode.allCases) { mode in modeCard(mode) } } }
            }
            HStack(spacing: 12) {
                actionCard("Screen recording",subtitle: "MP4 video, audio & GIF export",symbol: "record.circle",color: Color(red: 1,green: 0.46,blue: 0.47)) { controller.toggleRecord() }
                actionCard("Scrolling capture",subtitle: "Long pages, one image",symbol: "scroll",color: Color(red: 0.45,green: 0.75,blue: 0.99)) { controller.startScroll() }
                actionCard("Capture text",subtitle: "On-device OCR & QR codes",symbol: "text.viewfinder",color: Color(red: 0.5,green: 0.85,blue: 0.68)) { controller.captureText() }
            }
            HStack {
                HStack(spacing: 7) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green.opacity(0.7)); Text("\(preferences.saveToDisk ? "Auto-save on" : "History only") · \(preferences.copyToClipboard ? "Clipboard on" : "Clipboard off")") }
                Spacer()
                Menu {
                    ForEach([0.0,3,5,10],id: \.self) { delay in Button(delay == 0 ? "No delay" : "\(Int(delay)) seconds") { preferences.delay = delay } }
                } label: { Label(preferences.delay == 0 ? "No delay" : "\(Int(preferences.delay))s delay",systemImage: "timer") }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Configure") { page = .settings }.buttonStyle(.plain).foregroundStyle(accent)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal,4)
            Divider().padding(.top,2)
            HStack { Text("Recent captures").font(.system(size: 15,weight: .semibold)); Spacer(); Button("View library →") { page = .library }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent) }
            if store.clips.isEmpty { emptyState }
            else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 14),count: 3),spacing: 14) {
                    ForEach(Array(store.clips.prefix(6))) { clip in ClipCard(clip: clip,controller: controller,store: store) }
                }
            }
        }
    }
    var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.badge.checkmark").font(.system(size: 21)).foregroundStyle(accent)
            VStack(alignment: .leading,spacing: 4) { Text("Let Shotglass see your screen").font(.system(size: 12,weight: .semibold)); Text("Enable Screen Recording in System Settings to start capturing.").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer()
            Button("Enable access") { controller.requestPermission() }.buttonStyle(.glassProminent).tint(accent).font(.system(size: 11))
        }.padding(16).background(accent.opacity(0.10),in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.15)))
    }
    func sectionLabel(_ title: String,trailing: String = "") -> some View {
        HStack { Text(title).font(.system(size: 9,weight: .semibold)).tracking(1.4).foregroundStyle(.white.opacity(0.4)); Spacer(); Text(trailing).font(.system(size: 9)).foregroundStyle(.white.opacity(0.3)) }
    }
    func modeCard(_ mode: CaptureMode) -> some View {
        Button { controller.capture(mode) } label: {
            VStack(alignment: .leading,spacing: 15) {
                HStack { Image(systemName: mode.symbol).font(.system(size: 21,weight: .light)).foregroundStyle(accent); Spacer(); Text(mode.key).font(.system(size: 10,design: .monospaced)).foregroundStyle(.white.opacity(0.2)) }
                VStack(alignment: .leading,spacing: 5) {
                    Text(mode.title).font(.system(size: 11,weight: .semibold))
                    Text(modeDescription(mode)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                }
            }.frame(maxWidth: .infinity,alignment: .leading).padding(15).glassEffect(.regular.interactive(),in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).disabled(controller.busy || controller.recording)
    }
    func modeDescription(_ mode: CaptureMode) -> String {
        switch mode { case .area: return "Reuse or redraw your area"; case .fullscreen: return "Current display"; case .window: return "Point and click"; case .activeWindow: return "Frontmost app"; case .lastRegion: return "Capture again immediately" }
    }
    func actionCard(_ title: String,subtitle: String,symbol: String,color: Color,action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(color).frame(width: 30)
                VStack(alignment: .leading,spacing: 5) { Text(title).font(.system(size: 11,weight: .semibold)); Text(subtitle).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)) }
                Spacer(minLength: 0)
            }.padding(14).frame(maxWidth: .infinity).background(.white.opacity(0.025),in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06)))
        }.buttonStyle(.plain).disabled(controller.busy)
    }
    var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 27,weight: .ultraLight)).foregroundStyle(.white.opacity(0.22)).padding(.bottom,3)
            Text("Your next capture starts here").font(.system(size: 12,weight: .medium)).foregroundStyle(.white.opacity(0.65))
            Text("Take a screenshot and it will be waiting in your library.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
        }.frame(maxWidth: .infinity).padding(.vertical,30).background(.white.opacity(0.018),in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06),style: StrokeStyle(lineWidth: 1,dash: [5,4])))
    }
    var libraryPage: some View {
        VStack(alignment: .leading,spacing: 24) {
            Text("A home for your captures.").font(.system(size: 28,weight: .semibold)).tracking(-0.8)
            HStack {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search filenames or recognized text",text: $query).textFieldStyle(.plain) }.padding(11).background(.white.opacity(0.05),in: RoundedRectangle(cornerRadius: 8))
                Picker("Type",selection: $filter) { ForEach(["All","Screenshots","Recordings","Text"],id: \.self) { Text($0) } }.labelsHidden().frame(width: 140)
            }
            let clips = store.clips.filter { clip in
                (query.isEmpty || clip.url.lastPathComponent.localizedCaseInsensitiveContains(query) || (clip.text?.localizedCaseInsensitiveContains(query) ?? false)) &&
                (filter == "All" || (filter == "Screenshots" && !clip.isVideo) || (filter == "Recordings" && clip.isVideo) || (filter == "Text" && clip.text != nil))
            }
            if clips.isEmpty { emptyState }
            else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 14),count: 3),spacing: 18) { ForEach(clips) { clip in ClipCard(clip: clip,controller: controller,store: store) } }
            }
        }
    }
    var presetsPage: some View {
        VStack(alignment: .leading,spacing: 24) {
            Text("Same frame. Every time.").font(.system(size: 28,weight: .semibold)).tracking(-0.8)
            Text("Save your last selection as a named preset, or create an exact-size area in the capture toolbar.").font(.system(size: 12)).foregroundStyle(.secondary)
            if let last = preferences.lastRegion {
                HStack {
                    Image(systemName: "rectangle.dashed").foregroundStyle(accent)
                    Text("Last area · \(Int(last.width)) × \(Int(last.height)) pt").font(.system(size: 12))
                    Spacer(); TextField("Preset name",text: $presetName).textFieldStyle(.roundedBorder).frame(width: 190)
                    Button("Save preset") { controller.savePreset(name: presetName); presetName = "" }.tint(accent)
                }.padding(18).background(.white.opacity(0.04),in: RoundedRectangle(cornerRadius: 12))
            } else { Text("Draw an area first to save a preset.").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(preferences.presets) { preset in
                HStack {
                    Image(systemName: "crop").foregroundStyle(accent).frame(width: 35)
                    VStack(alignment: .leading,spacing: 5) { Text(preset.name).font(.system(size: 13,weight: .semibold)); Text("\(Int(preset.region.width)) × \(Int(preset.region.height)) pt").font(.system(size: 10,design: .monospaced)).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Position…") { preferences.lastRegion = preset.region; controller.capture(.lastRegion,unified: true) }
                    Button("Capture") { preferences.lastRegion = preset.region; controller.capture(.lastRegion) }.tint(accent)
                    Button { preferences.presets.removeAll { $0.id == preset.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(18).background(.white.opacity(0.03),in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

struct CaptureIllustration: View {
    var body: some View {
        ZStack {
            Ellipse().fill(accent.opacity(0.12)).frame(width: 210,height: 150).blur(radius: 35)
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.18,green: 0.17,blue: 0.23)).frame(width: 214,height: 132).rotationEffect(.degrees(-9)).offset(x: -13,y: -2)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)).frame(width: 214,height: 132).rotationEffect(.degrees(-9)).offset(x: -13,y: -2))
            VStack(alignment: .leading,spacing: 14) {
                HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.25)).frame(width: 4,height: 4) }; Spacer(); Image(systemName: "sparkle").foregroundStyle(accent).font(.system(size: 13)) }
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [accent.opacity(0.8),Color(red: 0.3,green: 0.5,blue: 0.85)],startPoint: .topLeading,endPoint: .bottomTrailing)).frame(width: 65,height: 63)
                    VStack(alignment: .leading,spacing: 9) { Capsule().fill(.white.opacity(0.6)).frame(width: 72,height: 5); Capsule().fill(.white.opacity(0.2)).frame(width: 82,height: 4); Capsule().fill(.white.opacity(0.2)).frame(width: 55,height: 4) }
                }
            }.padding(18).frame(width: 210,height: 132).background(Color(red: 0.14,green: 0.14,blue: 0.19),in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.4))).rotationEffect(.degrees(4)).offset(x: 9,y: 12)
            Image(systemName: "cursorarrow").font(.system(size: 27,weight: .medium)).foregroundStyle(.white).shadow(color: .black.opacity(0.3),radius: 6).rotationEffect(.degrees(-8)).offset(x: 81,y: 78)
            HStack(spacing: 5) { Image(systemName: "checkmark"); Text("Captured.") }.font(.system(size: 9,weight: .semibold)).foregroundStyle(.white).padding(.horizontal,10).padding(.vertical,7).background(accent,in: Capsule()).offset(x: 48,y: -69)
        }.accessibilityHidden(true)
    }
}

struct ClipCard: View {
    let clip: Clip
    @ObservedObject var controller: AppController
    @ObservedObject var store: ClipStore
    @State var thumbnail: NSImage?
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            ZStack {
                Color.white.opacity(0.035)
                if let image = thumbnail { Image(nsImage: image).resizable().scaledToFit().padding(12) }
                else { Image(systemName: clip.isVideo ? "video" : "photo").foregroundStyle(.secondary) }
                if clip.isVideo { Image(systemName: "play.circle.fill").font(.system(size: 30)).shadow(radius: 8) }
            }.frame(height: 135).clipped().contentShape(Rectangle()).onTapGesture { controller.editor(clip) }
            HStack {
                VStack(alignment: .leading,spacing: 5) {
                    Text(clip.kind).font(.system(size: 11,weight: .medium))
                    Text(clip.date,format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.copy(clip); controller.status = "Copied to clipboard" } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }.buttonStyle(.plain).help("Copy capture")
                Menu {
                    Button("Open editor") { controller.editor(clip) }
                    Button("Copy") { store.copy(clip) }
                    Button("Pin on screen") { controller.pin(clip) }.disabled(clip.isVideo)
                    Button("Copy text / QR") { controller.recognize(clip) }.disabled(clip.isVideo)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
                    Button("Open with default app") { NSWorkspace.shared.open(clip.url) }
                    Divider()
                    if CloudSession.isAvailable {
                        Button("Upload & copy link") { Task { await controller.uploadClip(clip) } }.disabled(clip.isVideo)
                        Divider()
                    }
                    Button("Remove from history") { store.removeFromHistory(clip) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize()
            }.padding(12)
        }.background(.white.opacity(0.025),in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06)))
            .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }
            .task(id: clip.path) { thumbnail = clip.isVideo ? await VideoTools.thumbnail(clip.url) : await ThumbnailLoader.load(clip.url,maxPixel: 560) }
    }
}

/// Decodes a downsampled thumbnail off the main thread. Library grids otherwise decode every full-size
/// Retina PNG on the main actor each time a card appears.
enum ThumbnailLoader {
    private static let cache: NSCache<NSString,NSImage> = { let c = NSCache<NSString,NSImage>(); c.countLimit = 120; return c }()
    static func load(_ url: URL,maxPixel: Int) async -> NSImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: NSImage? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg,size: .zero)
        }.value
        if let image { cache.setObject(image,forKey: key) }
        return image
    }
}
