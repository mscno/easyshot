import AppKit
import AVFoundation
import EasyshotCore

/// Live upload state for Quick Access cards, which hold a fixed clip; history keeps the persisted copy.
@MainActor final class ShareCenter: ObservableObject {
    static let shared = ShareCenter()
    @Published var states: [UUID: CloudShare] = [:]
    func state(_ clip: Clip) -> CloudShare? { states[clip.id] ?? clip.share }
}

/// Record & Share: a recording whose link exists the moment it starts. The writer emits fragmented MP4,
/// parts upload while recording, and stopping only sends the last part and `complete`.
extension AppController {
    static let recordSharePurpose = "Record & Share"
    func recordShare() {
        if recording { Task { await stopRecording() }; return }
        guard CloudSession.shared.isSignedIn else { requireSignIn(); return }
        capture(.area,unified: true,purpose: Self.recordSharePurpose,drawNewArea: Preferences.shared.selection.drawNew)
    }
    static func shareTitle(_ date: Date = Date()) -> String { "Recording · \(date.formatted(date: .abbreviated,time: .shortened))" }
    func beginShare(url: URL) throws -> ShareRecording {
        guard let client = CloudSession.shared.client else { throw CloudError.notSignedIn }
        let share = try ShareRecording(client: client,url: url,title: Self.shareTitle()) { [weak self] video in
            guard let self else { return }
            self.shareLink = video.shareUrl
            if Preferences.shared.shareCopyLinkAtStart,self.copyLink(video.shareUrl) { self.showToast("Link copied · recording",symbol: "link",detail: video.shareUrl,hideAfter: 2.5) }
        }
        shareRecording = share
        Task { [weak self] in
            // A failed creation keeps the recording local; it can be retried from Quick Access or the Library.
            do { _ = try await share.waitForVideo() }
            catch CloudError.notSignedIn { CloudSession.shared.sessionExpired(); self?.showToast("Not signed in · recording locally",symbol: "exclamationmark.triangle.fill",hideAfter: 3) }
            catch { self?.showToast("Couldn't create the link · recording locally",symbol: "exclamationmark.triangle.fill",detail: error.localizedDescription,hideAfter: 3) }
        }
        return share
    }
    /// Completes the upload in the background, keeping the session alive, then adds poster and captions.
    func finishShare(_ share: ShareRecording,clip: Clip,voice: Bool) {
        pendingExports += 1
        let started = Date()
        Task { @MainActor in
            defer { pendingExports -= 1; finishIfIdle() }
            let file = clip.url
            let duration = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? Double(recordingSeconds)
            do {
                let video = try await share.finish(durationMs: Int((duration.isFinite ? duration : 0)*1000),width: clip.width,height: clip.height)
                setShare(clip,CloudShare(video: video,title: nil,status: .ready))
                lastShareReadyLatency = Date().timeIntervalSince(started)
                showToast("Link ready",symbol: "link",detail: video.shareUrl,hideAfter: 2.5)
                await publishExtras(client: share.client,video: video.id,file: file,voice: voice)
            } catch is CancellationError {
            } catch {
                setShare(clip,CloudShare(video: share.video,title: nil,status: .failed,error: error.localizedDescription))
                showToast("Upload failed · Retry from Quick Access or Library",symbol: "exclamationmark.triangle.fill",detail: error.localizedDescription,hideAfter: 4)
            }
        }
    }
    /// Poster first (it makes the link unfurl), then captions. Neither delays or fails the link.
    func publishExtras(client: CloudClient,video: String,file: URL,voice: Bool) async {
        do {
            if let warning = try await ShareExtras.uploadPoster(client: client,video: video,file: file) {
                showToast("Possible secrets on screen",symbol: "exclamationmark.shield.fill",detail: warning,hideAfter: 6)
            }
        } catch { store.error = "Poster upload failed: \(error.localizedDescription)" }
        guard voice,Preferences.shared.shareTranscribe else { return }
        do { _ = try await ShareExtras.uploadTranscript(client: client,video: video,file: file) }
        catch { store.error = "Transcript failed: \(error.localizedDescription)" }
    }
    func setShare(_ clip: Clip,_ share: CloudShare?) {
        var updated = store.clips.first { $0.id == clip.id } ?? clip
        updated.share = share; store.update(updated)
        ShareCenter.shared.states[clip.id] = share
    }
    /// Stops the recording without keeping anything: local file and server video are deleted.
    func cancelShareRecording() {
        guard recording,let recorder,let share = shareRecording,let url = recordURL else { return }
        recording = false; recordingPaused = false; busy = true; recordTimer?.invalidate(); recordPanel?.orderOut(nil)
        Task {
            try? await recorder.stop(); recordingEffects?.stop()
            await share.cancel()
            for file in [url,CursorTrack.sidecarURL(for: url),CursorTrack.planURL(for: url)] { try? FileManager.default.removeItem(at: file) }
            self.recorder = nil; recordingEffects = nil; recordURL = nil; shareRecording = nil; shareLink = nil; busy = false
            status = "Recording cancelled"; showToast("Recording discarded",symbol: "trash",hideAfter: 1.6); finishIfIdle()
        }
    }
    /// Re-uploads a recording whose upload failed, to the same link when the server video exists.
    func retryShare(_ clip: Clip) {
        guard let client = CloudSession.shared.client,CloudSession.shared.isSignedIn else { requireSignIn(); return }
        let current = ShareCenter.shared.state(clip)
        Task {
            var existing: CloudVideo?
            if let id = current?.videoID { existing = try? await client.video(id) }
            do {
                let share = try ShareRecording(client: client,file: clip.url,video: existing,title: current?.title ?? Self.shareTitle(clip.date))
                setShare(clip,CloudShare(video: existing,title: current?.title,status: .uploading))
                finishShare(share,clip: clip,voice: true)
            } catch { fail(error) }
        }
    }
    func copyShareLink(_ clip: Clip) {
        guard let url = ShareCenter.shared.state(clip)?.url,copyLink(url) else { return }
        showToast("Link copied",symbol: "link",detail: url,hideAfter: 1.6)
    }
    func copyShareMarkdown(_ clip: Clip) {
        guard let markdown = ShareCenter.shared.state(clip)?.markdown else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(markdown,forType: .string)
        showToast("Markdown copied for GitHub",symbol: "chevron.left.forwardslash.chevron.right",hideAfter: 1.6)
    }
    func openShare(_ clip: Clip) {
        guard let link = ShareCenter.shared.state(clip)?.url,let url = ShareLink.validated(link) else { return }
        NSWorkspace.shared.open(url)
    }
    func renameShare(_ clip: Clip) {
        guard let share = ShareCenter.shared.state(clip),let id = share.videoID,let client = CloudSession.shared.client else { return }
        let alert = NSAlert(); alert.messageText = "Rename shared recording"
        let field = NSTextField(string: share.title ?? ""); field.frame = CGRect(x: 0,y: 0,width: 280,height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            do { let video = try await client.updateVideo(id,title: title); var updated = share; updated.title = video.title ?? title; setShare(clip,updated) }
            catch { fail(error) }
        }
    }
    func deleteShare(_ clip: Clip) {
        guard let share = ShareCenter.shared.state(clip),let client = CloudSession.shared.client else { return }
        let alert = NSAlert(); alert.messageText = "Delete the shared copy?"
        alert.informativeText = "The link stops working for everyone. The recording stays on this Mac."
        alert.addButton(withTitle: "Delete Link"); alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { if let id = share.videoID { try await client.deleteVideo(id) }; setShare(clip,nil); showToast("Link deleted",symbol: "trash",hideAfter: 1.6) }
            catch { fail(error) }
        }
    }
}

extension ShareRecording {
    /// Waits for the server video (and with it the share link).
    func waitForVideo() async throws -> CloudVideo {
        if let video { return video }
        return try await creationValue()
    }
}
