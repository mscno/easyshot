import AppKit
import SwiftUI
import AVKit
import EasyshotCore

/// A brief, nonactivating thumbnail. Editing is an explicit action that keeps the session open.
struct QuickPreviewThumbnail: View {
    let clip: Clip
    @ObservedObject var controller: AppController
    @State private var thumbnail: NSImage?
    var body: some View {
        VStack(spacing: 7) {
            Button { controller.editor(clip) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.06))
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                    if clip.isVideo { Image(systemName: "play.circle.fill").font(.system(size: 28)) }
                }.frame(height: 126).clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).help("Click to edit capture").accessibilityLabel("Edit latest capture")
            HStack {
                Text("\(Preferences.shared.saveToDisk ? "Saved" : "In history")\(Preferences.shared.copyToClipboard ? " & copied" : "")")
                    .font(.system(size: 10,weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.dismissPreview() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).help("Dismiss thumbnail").accessibilityLabel("Dismiss thumbnail")
            }
        }.padding(10).glassEffect(.regular,in: RoundedRectangle(cornerRadius: 12))
            .task { thumbnail = clip.isVideo ? await VideoTools.thumbnail(clip.url) : clip.image }
    }
}

struct PinnedImage: View {
    let image: NSImage
    weak var panel: NSPanel?
    @State var opacity = 1.0
    @State var locked = false
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity,maxHeight: .infinity)
            HStack {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: $opacity,in: 0.2...1).onChange(of: opacity) { _,value in panel?.alphaValue = value }
                Button { locked.toggle(); panel?.ignoresMouseEvents = locked } label: { Image(systemName: locked ? "lock.fill" : "lock.open") }.help("Click-through mode. Use Window → Show / unlock pinned images to unlock.")
            }.font(.system(size: 11)).padding(10).frame(height: 40)
        }.glassEffect(.regular,in: RoundedRectangle(cornerRadius: 18)).preferredColorScheme(.dark)
    }
}

struct RecordingControls: View {
    @ObservedObject var controller: AppController
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 7,height: 7)
            Text(controller.timeString).font(.system(size: 14,weight: .medium,design: .monospaced))
            Spacer()
            Button { Task { await controller.stopRecording() } } label: { Label("Stop",systemImage: "stop.fill").font(.system(size: 12,weight: .semibold)) }.buttonStyle(.glassProminent).tint(.red)
        }.padding(14).glassEffect(.regular,in: Capsule()).preferredColorScheme(.dark)
    }
}

struct ScrollingControls: View {
    @ObservedObject var controller: AppController
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "scroll").foregroundStyle(accent)
                Text("\(controller.scrollFrames) frames").font(.system(size: 12,weight: .medium))
                Picker("Direction",selection: $controller.scrollAxis) {
                    Image(systemName: "arrow.up.and.down").tag(ScrollStitcher.Axis.vertical).help("Vertical")
                    Image(systemName: "arrow.left.and.right").tag(ScrollStitcher.Axis.horizontal).help("Horizontal")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 76).disabled(controller.scrollFrames > 1)
                    .help("Scroll direction · fixed after the second frame")
                Spacer()
                #if !APP_STORE
                Button(controller.autoScrolling ? "Stop auto" : "Auto scroll") { controller.toggleAutoScroll() }.disabled(controller.busy && !controller.autoScrolling)
                #endif
                Button("Add frame") { controller.addScrollFrame() }.disabled(controller.busy)
                Button("Finish") { controller.finishScroll() }.buttonStyle(.glassProminent).tint(accent).disabled(controller.busy)
                Button { controller.cancelScroll() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            Text(controller.scrollNotice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }.padding(14).glassEffect(.regular,in: RoundedRectangle(cornerRadius: 24)).buttonStyle(.glass).preferredColorScheme(.dark)
    }
}

struct VideoEditorView: View {
    let clip: Clip
    @ObservedObject var controller: AppController
    @State var player: AVPlayer?
    @State var duration = 0.0
    @State var start = 0.0
    @State var end = 0.0
    @State var exporting = false
    @State var notice = ""
    @StateObject private var studio: StudioBox
    @State private var playhead = 0.0
    @State private var observer: Any?
    init(clip: Clip,controller: AppController) {
        self.clip = clip; self.controller = controller
        _studio = StateObject(wrappedValue: StudioBox(model: StudioModel(clip: clip)))
    }
    var body: some View {
        HStack(spacing: 16) {
            editor
            if let model = studio.model { StudioSidebar(model: model) { exportStudio(model) } }
        }.padding(24).background(canvasColor).preferredColorScheme(.dark).frame(minWidth: studio.model == nil ? 700 : 960,minHeight: 500)
            .task {
                do {
                    if let model = studio.model { player = try await model.makePlayer() } else { player = AVPlayer(url: clip.url) }
                    duration = try await AVURLAsset(url: clip.url).load(.duration).seconds; end = duration
                    observer = player?.addPeriodicTimeObserver(forInterval: CMTime(value: 1,timescale: 15),queue: .main) { time in MainActor.assumeIsolated { playhead = time.seconds } }
                } catch { notice = error.localizedDescription }
            }.onDisappear { player?.pause(); if let observer { player?.removeTimeObserver(observer) } }
    }
    var editor: some View {
        VStack(spacing: 20) {
            HStack { Image(systemName: "video").foregroundStyle(accent); Text("Recording").font(.system(size: 18,weight: .semibold)); Spacer(); Text(clip.url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary) }
            VideoPlayer(player: player).frame(maxWidth: .infinity,maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
            if let model = studio.model {
                StudioTimelineStrip(model: model,playhead: playhead) { player?.seek(to: CMTime(seconds: $0,preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero) }
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading) { Text("Start · \(start,specifier: "%.1f")s"); Slider(value: $start,in: 0...max(0.1,duration)).onChange(of: start) { _,value in player?.seek(to: CMTime(seconds: value,preferredTimescale: 600)) } }
                VStack(alignment: .leading) { Text("End · \(end,specifier: "%.1f")s"); Slider(value: $end,in: 0...max(0.1,duration)) }
            }.font(.system(size: 12))
            HStack {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if exporting { ProgressView().controlSize(.small) }
                ShareLink(item: clip.url) { Label("Share",systemImage: "square.and.arrow.up") }
                Button("Copy file") { controller.store.copy(clip) }
                Button("Export GIF") { export(gif: true) }.disabled(exporting || end <= start)
                if studio.model == nil { Button("Save trimmed MP4") { export(gif: false) }.buttonStyle(.glassProminent).tint(accent).disabled(exporting || end <= start) }
                else { Button("Save original MP4") { export(gif: false) }.disabled(exporting || end <= start) }
            }
        }
    }
    func exportStudio(_ model: StudioModel) {
        guard end > start else { notice = "Choose a non-empty range."; return }
        notice = "Exporting Studio video…"; let range = start...end
        Task {
            do {
                let began = Date()
                let saved = try await model.export(range: range,controller: controller)
                controller.store.add(saved); if Preferences.shared.copyToClipboard { controller.store.copy(saved) }
                notice = String(format: "Studio export saved in %.1fs",Date().timeIntervalSince(began)); controller.showPreview(saved)
            } catch { notice = error.localizedDescription }
        }
    }
    func export(gif: Bool) {
        exporting = true; notice = "Exporting…"; controller.pendingExports += 1
        let start = self.start; let end = self.end
        Task {
            defer { controller.pendingExports -= 1; controller.finishIfIdle() }
            do {
                let folder = try Preferences.shared.saveToDisk ? Preferences.shared.captureFolder() : controller.store.support.appendingPathComponent("Captures")
                try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(CaptureFiles.filename(extension: gif ? "gif" : "mp4"))
                if gif { try await VideoTools.gif(clip.url,to: url,start: start,end: end) }
                else { try await VideoTools.trim(clip.url,to: url,start: start,end: end) }
                let saved = Clip(path: url.path,kind: gif ? "GIF" : "Recording",width: clip.width,height: clip.height)
                controller.store.add(saved); if Preferences.shared.copyToClipboard { controller.store.copy(saved) }
                notice = "Export saved"; controller.showPreview(saved)
            } catch { notice = error.localizedDescription }
            exporting = false
        }
    }
}

/// A brief, click-through confirmation for background work such as uploads.
struct ToastView: View {
    let text: String
    let symbol: String
    var detail: String?
    var spinner = false
    var body: some View {
        HStack(spacing: 10) {
            if spinner { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).font(.system(size: 16,weight: .medium)) }
            VStack(alignment: .leading,spacing: 2) {
                Text(text).font(.system(size: 13,weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).frame(maxWidth: 340,alignment: .leading) }
            }
        }.padding(.horizontal,16).padding(.vertical,11).fixedSize()
            .glassEffect(.regular,in: RoundedRectangle(cornerRadius: 16)).padding(8)
            .accessibilityElement(children: .combine)
    }
}

/// Holds the optional Studio model so the editor owns it for its lifetime.
@MainActor final class StudioBox: ObservableObject {
    let model: StudioModel?
    init(model: StudioModel?) { self.model = model }
}

