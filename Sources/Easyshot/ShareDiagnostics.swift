import AppKit
import AVFoundation
import EasyshotCore

/// `--share-test`: synthetic 1440p video and voice through the fragmented writer, uploaded live by the
/// real uploader to an in-process mock Cloud (with an injected storage failure). Needs no permissions.
/// `--record-share-test BASE EMAIL PASSWORD`: records ~10 s of the real screen through the app's own
/// Record & Share path against a running server and checks the watch page serves the video.
enum ShareDiagnostics {
    @MainActor static func launch(_ arguments: [String],controller: AppController) -> Bool {
        if arguments.contains("--share-test") {
            NSApp.setActivationPolicy(.accessory)
            Task { let result = await offline(); fflush(stdout); exit(result) }
            return true
        }
        if let flag = arguments.firstIndex(of: "--transcribe-test"),let path = arguments[safe: flag+1] {
            NSApp.setActivationPolicy(.accessory)
            Task {
                let start = Date()
                do {
                    let vtt = try await Transcriber.webVTT(URL(fileURLWithPath: path))
                    print(vtt ?? "(no speech)"); print(String(format: "INFO: transcribed in %.1f s",Date().timeIntervalSince(start)))
                    check(vtt?.hasPrefix("WEBVTT") == true,"on-device transcript")
                } catch { check(false,"transcription: \(error.localizedDescription)") }
                fflush(stdout); exit(failures == 0 ? 0 : 1)
            }
            return true
        }
        if let flag = arguments.firstIndex(of: "--record-share-test"),arguments.count > flag+3 {
            NSApp.setActivationPolicy(.accessory)
            let seconds = arguments.firstIndex(of: "--seconds").flatMap { Double(arguments[safe: $0+1] ?? "") } ?? 10
            Task { let result = await live(controller: controller,base: arguments[flag+1],email: arguments[flag+2],password: arguments[flag+3],seconds: seconds); fflush(stdout); exit(result) }
            return true
        }
        return false
    }
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool,_ name: String) { if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL"): \(name)"); fflush(stdout) }
    static func note(_ text: String) { print("INFO: \(text)"); fflush(stdout) }

    final class SpoolDelegate: NSObject,AVAssetWriterDelegate {
        let spool: SegmentSpool; var segments = 0; var error: Error?
        init(spool: SegmentSpool) { self.spool = spool }
        func assetWriter(_ writer: AVAssetWriter,didOutputSegmentData segmentData: Data,segmentType: AVAssetSegmentType,segmentReport: AVAssetSegmentReport?) {
            segments += 1
            do { try spool.append(segmentData) } catch { self.error = error }
        }
    }

    @MainActor static func offline() async -> Int32 {
        failures = 0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("easyshot-share-test-\(UUID().uuidString)",isDirectory: true)
        try? FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("share.mp4")
        // Part 2 fails once with 503; part 3's first PUT hangs until the (shortened) idle timeout.
        MockCloud.reset(failFirstPutOf: 2,hangFirstPutOf: 3)
        let previousTimeout = CloudClient.partIdleTimeout; CloudClient.partIdleTimeout = 1.5
        defer { CloudClient.partIdleTimeout = previousTimeout }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockCloud.self]
        let client = CloudClient(baseURL: URL(string: "https://cloud.mock")!,token: "test-token",session: URLSession(configuration: config))
        var linkTime: Double?
        let begin = Date()
        let share: ShareRecording
        do {
            share = try ShareRecording(client: client,url: url,title: "Share test") { _ in }
            // In the app the link arrives while frames are already flowing; here, wait for it explicitly.
            _ = try await share.waitForVideo(); linkTime = Date().timeIntervalSince(begin)
        } catch { check(false,"link created: \(error)"); return 1 }
        let width = 2560,height = 1440,fps = 30,seconds = 12
        do {
            let writer = try Recorder.makeWriter(url: url,spool: share.spool)
            let delegate = SpoolDelegate(spool: share.spool); writer.delegate = delegate
            let video = Recorder.videoInput(width: width,height: height,fragmented: true); video.expectsMediaDataInRealTime = false
            // System audio (440 Hz, stereo 48 kHz) and a microphone (1 kHz, mono 44.1 kHz, jittered
            // timestamps) through the recorder's live mixer into one stereo track.
            let voice = Recorder.audioInput(channels: 2); voice.expectsMediaDataInRealTime = false
            writer.add(voice); writer.add(video)
            let mixer = AudioMixer(); mixer.origin = .zero
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: width,kCVPixelBufferHeightKey as String: height])
            writer.initialSegmentStartTime = .zero
            guard writer.startWriting() else { throw writer.error ?? ShotError.message("writer did not start") }
            writer.startSession(atSourceTime: .zero)
            var state: UInt64 = 0x9E3779B97F4A7C15
            let noise = (0..<(width*64)).map { _ in state = state &* 6364136223846793005 &+ 1442695040888963407; return 0xFF00_0000 | UInt32(truncatingIfNeeded: state>>40)&0x00FF_FFFF }
            for frame in 0..<(fps*seconds) {
                let time = CMTime(value: CMTimeValue(frame),timescale: CMTimeScale(fps))
                while !video.isReadyForMoreMediaData || !voice.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard let pool = adaptor.pixelBufferPool,let buffer = synthesizedFrame(pool: pool,frame: frame,noise: noise) else { throw ShotError.message("no pixel buffer") }
                guard adaptor.append(buffer,withPresentationTime: time) else { throw writer.error ?? ShotError.message("append failed") }
                if let system = tone(frame: frame,fps: fps,rate: 48000,channels: 2,frequency: 440,amplitude: 0.5) { mixer.add(system.sample,source: AudioMixer.system,at: system.time) }
                if let mic = tone(frame: frame,fps: fps,rate: 44100,channels: 1,frequency: 1000,amplitude: 0.5,jitter: true) { mixer.add(mic.sample,source: AudioMixer.voice,at: mic.time) }
                guard mixer.drain(into: voice,final: false) else { throw writer.error ?? ShotError.message("audio append failed") }
            }
            guard mixer.drain(into: voice,final: true) else { throw writer.error ?? ShotError.message("audio flush failed") }
            note(String(format: "live mixing: %.2f ms CPU per second of audio (%.1f s mixed)",mixer.busySeconds/max(mixer.mixedSeconds,1e-9)*1000,mixer.mixedSeconds))
            video.markAsFinished(); voice.markAsFinished()
            await writer.finishWriting()
            share.spool.close()
            check(writer.status == .completed,"fragmented writer completes (\(writer.error?.localizedDescription ?? "ok"))")
            check(delegate.error == nil && delegate.segments >= seconds,"segments arrive while writing (\(delegate.segments) segments)")
        } catch { check(false,"synthetic recording: \(error.localizedDescription)"); return 1 }
        let stop = Date()
        let size = share.spool.total
        note("spool \(size/1024/1024) MiB, \(PartPlanner.whole(size: size).count) parts; \(MockCloud.storedParts) part(s) stored before stop")
        check(MockCloud.storedParts >= 2,"parts upload while recording, before stop")
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let natural = try? await videoTracks.first?.load(.naturalSize)
        check(abs(duration-Double(seconds)) < 0.25,"local fragmented MP4 is playable: duration \(String(format: "%.2f",duration)) s")
        check(videoTracks.count == 1 && audioTracks.count == 1 && natural == CGSize(width: width,height: height),"one 2560×1440 video track and one audio track")
        if let track = audioTracks.first,let levels = try? await toneLevels(asset: asset,track: track,frequencies: [440,1000,3000],from: 4,seconds: 4) {
            note(String(format: "mixed track levels: 440 Hz %.3f, 1 kHz %.3f, 3 kHz %.4f, peak %.2f",levels.tones[0],levels.tones[1],levels.tones[2],levels.peak))
            check(levels.tones[0] > 0.1 && levels.tones[1] > 0.1,"the single track carries both system audio (440 Hz) and the microphone (1 kHz)")
            check(levels.tones[1] > levels.tones[0],"voice is louder than system audio (1.0 vs 0.7 gain)")
            check(levels.tones[2] < 0.02 && levels.peak < 1,"no clipping or distortion (3 kHz \(String(format: "%.4f",levels.tones[2])), peak \(String(format: "%.2f",levels.peak)))")
        } else { check(false,"mixed audio decodes") }
        let generator = AVAssetImageGenerator(asset: asset)
        check((try? await generator.image(at: CMTime(seconds: Double(seconds)-0.5,preferredTimescale: 600))) != nil,"last second decodes")
        do {
            let ready = try await share.finish(durationMs: Int(duration*1000),width: width,height: height)
            let latency = Date().timeIntervalSince(stop)
            note(String(format: "stop → ready %.0f ms (mock storage, one injected 503 retry)",latency*1000))
            check(ready.status == "ready","complete returns a ready video")
            check(linkTime != nil && linkTime! < 1,"link exists as recording starts (\(String(format: "%.0f",(linkTime ?? 0)*1000)) ms)")
            let uploaded = MockCloud.assembled()
            check(uploaded == (try? Data(contentsOf: url)),"uploaded parts reassemble to the local file byte for byte")
            check(MockCloud.completedParts == PartPlanner.whole(size: size).count && MockCloud.partsSortedWithQuotedETags,"complete lists every part in order with quoted ETags")
            check(MockCloud.retriedPuts >= 1,"a failed part PUT is retried")
            check(MockCloud.retriedPresigns == 1,"a 503 from the presign endpoint is retried, not fatal")
            check(MockCloud.wrongSizePuts == 0,"every part PUT matches the size signed into its URL")
            check(MockCloud.hungPuts == 1,"a hung part PUT times out after the idle timeout and is retried")
            let reports = MockCloud.progress
            note("progress reports: \(reports.map { "\($0.bytes/1024/1024)MiB\($0.recording ? "" : " stopped")" }.joined(separator: ", "))")
            let stopped = reports.firstIndex { !$0.recording }
            check(stopped.map { $0 > 0 && reports[$0...].allSatisfy { !$0.recording } } == true,"progress is reported while recording, then recording: false from stop")
            check(reports.count <= seconds+4 && reports.map(\.bytes) == reports.map(\.bytes).sorted(),"progress is throttled (\(reports.count) reports) and never goes backwards")
            await resumeTest(client: client,url: url,check)
            let unsupported = ProgressReporter(client: client)
            await unsupported.attach("missing"); await unsupported.report(bytes: 1)
            try? await Task.sleep(for: .milliseconds(300))
            check(await unsupported.unsupported,"a server without the progress endpoint (404) turns reporting off")
            check(MockCloud.minNonFinalPart >= PartPlanner.minimumPartSize,"every part but the last is ≥ 5 MiB")
            // Extras: poster JPEG within limits and a WebVTT document.
            let poster = try await ShareExtras.poster(url)
            let jpeg = ShareExtras.jpeg(poster)
            check(jpeg != nil && jpeg!.count <= 2*1024*1024 && max(poster.width,poster.height) <= 1280,"poster frame is a ≤ 1280 px JPEG under 2 MiB")
            let voiceFile = folder.appendingPathComponent("voice.caf")
            check((try? await Transcriber.extractVoice(from: url,to: voiceFile)) == true,"voice track extracts to 16 kHz mono PCM for transcription")
        } catch { check(false,"finish: \(error.localizedDescription)") }
        // Cancel deletes the server video.
        do {
            let cancelled = try ShareRecording(client: client,url: folder.appendingPathComponent("cancel.mp4"),title: nil) { _ in }
            _ = try await cancelled.waitForVideo()
            await cancelled.cancel()
            check(MockCloud.deleted == 1,"cancel deletes the server video")
        } catch { check(false,"cancel: \(error.localizedDescription)") }
        // A write the spool could not make poisons it: later segments must not land at shifted offsets.
        if let spool = try? SegmentSpool(url: folder.appendingPathComponent("broken.mp4")) {
            spool.close()
            let refused = (try? spool.append(Data(count: 16))) == nil
            check(refused && spool.failure != nil && (try? spool.append(Data(count: 16))) == nil && spool.total == 0,"a failed spool write is kept and fails every later append")
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): share test, \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
    /// Moving bars plus per-frame noise so the encoder spends a realistic bitrate.
    static func synthesizedFrame(pool: CVPixelBufferPool,frame: Int,noise: [UInt32]) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess,let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer,[]); defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        let w = CVPixelBufferGetWidth(buffer),h = CVPixelBufferGetHeight(buffer),row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt32.self) else { return nil }
        noise.withUnsafeBufferPointer { random in
            let rows = random.count/w
            for y in 0..<h {
                let line = base.advanced(by: y*row/4)
                if y%3 == 0 { line.update(from: random.baseAddress!.advanced(by: ((y/3+frame*13)%rows)*w),count: w); continue }
                let shade = UInt32((y+frame*7)&0xFF)
                line.update(repeating: 0xFF00_0000 | shade<<16 | UInt32((frame*3)&0xFF)<<8 | UInt32(255-shade),count: w)
            }
        }
        return buffer
    }
    /// One video frame's worth of a sine tone as interleaved float PCM, like a capture callback delivers.
    /// `jitter` offsets the timestamp by up to ±0.4 ms, as device clocks do; the samples stay continuous.
    static func tone(frame: Int,fps: Int,rate: Int,channels: Int,frequency: Double,amplitude: Double,jitter: Bool = false) -> (sample: CMSampleBuffer,time: CMTime)? {
        let start = frame*rate/fps,count = (frame+1)*rate/fps-start
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate),mFormatID: kAudioFormatLinearPCM,mFormatFlags: kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4*channels),mFramesPerPacket: 1,mBytesPerFrame: UInt32(4*channels),mChannelsPerFrame: UInt32(channels),mBitsPerChannel: 32,mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil,asbd: &asbd,layoutSize: 0,layout: nil,magicCookieSize: 0,magicCookie: nil,extensions: nil,formatDescriptionOut: &format) == noErr,let format else { return nil }
        var samples = [Float32](repeating: 0,count: count*channels)
        for i in 0..<count { let v = Float32(amplitude*sin(2*Double.pi*frequency*Double(start+i)/Double(rate))); for c in 0..<channels { samples[i*channels+c] = v } }
        var block: CMBlockBuffer?
        let bytes = samples.count*4
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil,memoryBlock: nil,blockLength: bytes,blockAllocator: nil,customBlockSource: nil,offsetToData: 0,dataLength: bytes,flags: 0,blockBufferOut: &block) == noErr,let block,
              CMBlockBufferReplaceDataBytes(with: &samples,blockBuffer: block,offsetIntoDestination: 0,dataLength: bytes) == noErr else { return nil }
        var time = CMTime(value: CMTimeValue(start),timescale: CMTimeScale(rate))
        if jitter { time = CMTimeAdd(time,CMTime(seconds: 0.0004*sin(Double(frame)*1.7),preferredTimescale: 1_000_000)) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil,dataBuffer: block,formatDescription: format,sampleCount: count,
                                                             presentationTimeStamp: time,packetDescriptions: nil,sampleBufferOut: &sample)
        return sample.map { ($0,time) }
    }
    /// Goertzel amplitudes of `frequencies` and the peak sample over a window of the decoded track's left
    /// channel (a mono downmix would scale the levels by √2).
    static func toneLevels(asset: AVAsset,track: AVAssetTrack,frequencies: [Double],from start: Double,seconds: Double) async throws -> (tones: [Double],peak: Float) {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start,preferredTimescale: 48000),duration: CMTime(seconds: seconds,preferredTimescale: 48000))
        let output = AVAssetReaderTrackOutput(track: track,outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,AVSampleRateKey: 48000,AVNumberOfChannelsKey: 2,
                                                                           AVLinearPCMBitDepthKey: 32,AVLinearPCMIsFloatKey: true,AVLinearPCMIsNonInterleaved: false,AVLinearPCMIsBigEndianKey: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ShotError.message("Cannot read audio.") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(),let block = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0,count: CMBlockBufferGetDataLength(block)/4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset: 0,dataLength: $0.count,destination: $0.baseAddress!) }
            samples += stride(from: 0,to: chunk.count,by: 2).map { chunk[$0] }
        }
        guard samples.count > 4800 else { throw ShotError.message("Too little audio.") }
        let tones = frequencies.map { f -> Double in
            let k = 2*cos(2*Double.pi*f/48000); var s1 = 0.0,s2 = 0.0
            for x in samples { let s0 = Double(x)+k*s1-s2; s2 = s1; s1 = s0 }
            return 2*sqrt(max(0,s1*s1+s2*s2-k*s1*s2))/Double(samples.count)
        }
        return (tones,samples.map(abs).max() ?? 0)
    }
    /// A retry after a failed upload resumes from the journal: only parts it lacks are sent again.
    @MainActor static func resumeTest(client: CloudClient,url: URL,_ check: (Bool,String) -> Void) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let plan = PartPlanner.whole(size: size)
        guard plan.count >= 3 else { check(false,"resume test needs at least three parts"); return }
        // As if every part but the last two were stored before the upload failed.
        var journal = UploadJournal(videoID: "vid1",partSize: PartPlanner.minimumPartSize)
        for part in plan.dropLast(2) { journal.record(part,etag: MockCloud.etag(part.number)) }
        try? JSONEncoder().encode(journal).write(to: UploadJournal.url(for: url))
        MockCloud.prepareRetry(keeping: Set(plan.dropLast(2).map(\.number)))
        do {
            var pending = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: MockCloud.video)) as! [String: Any]
            pending["status"] = "pending"
            let video = try CloudClient.decoder.decode(CloudVideo.self,from: JSONSerialization.data(withJSONObject: pending))
            let retry = try ShareRecording(client: client,file: url,video: video,title: nil)
            let ready = try await retry.finish(durationMs: 1000,width: 2560,height: 1440)
            let reused = await retry.uploader.reusedParts
            check(ready.status == "ready" && MockCloud.puts == 2 && reused == plan.count-2,"retry resumes: \(MockCloud.puts) of \(plan.count) parts re-sent, \(reused) reused from the journal")
            check(MockCloud.assembled() == (try? Data(contentsOf: url)),"the resumed upload reassembles to the local file")
            check(!FileManager.default.fileExists(atPath: UploadJournal.url(for: url).path),"the journal is removed once the upload completes")
        } catch { check(false,"resume: \(error.localizedDescription)") }
    }

    // MARK: Live

    @MainActor static func live(controller: AppController,base: String,email: String,password: String,seconds: Double) async -> Int32 {
        failures = 0
        let p = Preferences.shared
        let previousServer = p.cloudBaseURL
        defer { p.cloudBaseURL = previousServer; CloudSession.shared.serverChanged() }
        p.cloudBaseURL = base; CloudSession.shared.serverChanged()
        if !CloudSession.shared.isSignedIn { await CloudSession.shared.signIn(email: email,password: password,register: false) }
        check(CloudSession.shared.isSignedIn,"signed in to \(base) (\(CloudSession.shared.error ?? "ok"))")
        guard CloudSession.shared.isSignedIn else { return 1 }
        do { try await controller.engine.refresh() } catch { check(false,"screen access: \(error.localizedDescription)"); return 1 }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let rect = CommandLine.arguments.contains("--full") ? screen.frame : CGRect(x: screen.frame.minX+80,y: screen.frame.minY+80,width: 1280,height: 720)
        let target = CaptureTarget.region(CaptureGeometry.quartz(rect,primaryHeight: NSScreen.primaryHeight))
        let start = Date()
        do { try await controller.startRecording(target,share: true) } catch { check(false,"recording starts: \(error.localizedDescription)"); return 1 }
        let recordingAt = Date().timeIntervalSince(start)
        while controller.shareLink == nil,Date().timeIntervalSince(start) < 5 { try? await Task.sleep(for: .milliseconds(10)) }
        check(controller.shareLink != nil,String(format: "link available %.0f ms after it was requested (recording running after %.0f ms): %@",(controller.lastShareLinkLatency ?? -1)*1000,recordingAt*1000,controller.shareLink ?? "none"))
        let link = controller.shareLink ?? ""
        try? await Task.sleep(for: .seconds(seconds))
        if let share = controller.shareRecording {
            let uploaded = await share.uploader.uploadedBytes
            note("before stop: \(share.spool.total/1024) KiB spooled, \(uploaded/1024) KiB already uploaded")
        }
        let stoppedAt = Date()
        await controller.stopRecording()
        let stopCall = Date().timeIntervalSince(stoppedAt)
        // Wait for the background completion.
        var share: CloudShare?
        while Date().timeIntervalSince(stoppedAt) < 120 {
            share = controller.store.clips.first { $0.share?.url == link }?.share
            if share?.status == .ready || share?.status == .failed { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let readyAt = Date().timeIntervalSince(stoppedAt)
        check(share?.status == .ready,String(format: "upload completes: stop → ready %.0f ms (finalizing the writer %.0f ms) %@",readyAt*1000,stopCall*1000,share?.error ?? ""))
        if let ms = controller.lastShareReadyLatency { note(String(format: "upload finish after recorder stop: %.0f ms",ms*1000)) }
        let clip = controller.store.clips.first { $0.share?.url == link }
        let bytes = clip.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        note("recording \(bytes/1024) KiB at \(clip?.width ?? 0)×\(clip?.height ?? 0), \(PartPlanner.whole(size: bytes).count) part(s)")
        if let clip {
            let duration = (try? await AVURLAsset(url: clip.url).load(.duration).seconds) ?? 0
            check(abs(duration-seconds) < 1.5,String(format: "local recording plays: %.1f s",duration))
        }
        // The watch page and a ranged media request (the browser's first request) against the real server.
        if let page = URL(string: link) {
            let html = (try? await URLSession.shared.data(from: page)).flatMap { String(data: $0.0,encoding: .utf8) } ?? ""
            check(html.contains("<video") || html.contains("easyshot-player"),"watch page renders the player")
            var request = URLRequest(url: page.appendingPathComponent("media")); request.setValue("bytes=0-1023",forHTTPHeaderField: "Range")
            let result = try? await URLSession.shared.data(for: request)
            let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
            check(status == 206 && result?.0.count == 1024,"media serves byte ranges (HTTP \(status), \(result?.0.count ?? 0) bytes)")
            let head = result?.0 ?? Data()
            let local = clip.flatMap { try? FileHandle(forReadingFrom: $0.url).read(upToCount: 1024) }
            check(!head.isEmpty && head == local,"served bytes match the local recording")
        }
        // Poster upload runs after ready; give it a moment, then check the unfurl image.
        try? await Task.sleep(for: .seconds(2))
        if let poster = URL(string: ShareLinks.thumbnail(link)) {
            let result = try? await URLSession.shared.data(from: poster)
            let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
            check(status == 200 && (result?.0.count ?? 0) > 1000,"poster served at /thumbnail.jpg (HTTP \(status))")
        }
        // Captions: the same upload the app makes after transcribing, served back by the watch page.
        if let id = controller.store.clips.first(where: { $0.share?.url == link })?.share?.videoID,let client = CloudSession.shared.client,
           let vttURL = URL(string: link)?.appendingPathComponent("transcript.vtt") {
            let vtt = WebVTT.document([WebVTT.Cue(start: 0,end: 2,text: "Record and share test caption")])
            do {
                try await client.uploadAsset(id,kind: "transcript",data: Data(vtt.utf8))
                let served = try? await URLSession.shared.data(from: vttURL)
                check(served.flatMap { String(data: $0.0,encoding: .utf8) }?.contains("Record and share test caption") == true,"captions upload and are served as WebVTT")
            } catch { check(false,"transcript upload: \(error.localizedDescription)") }
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): record & share live test, \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}

extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

/// In-process Easyshot Cloud and object storage for `--share-test`.
final class MockCloud: URLProtocol,@unchecked Sendable {
    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var parts: [Int: Data] = [:]
    nonisolated(unsafe) private static var failNext: Set<Int> = []
    nonisolated(unsafe) private static var hangNext: Set<Int> = []
    nonisolated(unsafe) private static var progressReports: [(bytes: Int,recording: Bool)] = []
    /// Each part's presigned size; a PUT of any other length is refused, as S3 does for a signed Content-Length.
    nonisolated(unsafe) private static var signed: [Int: Int] = [:]
    nonisolated(unsafe) private static var failNextPresign = false
    nonisolated(unsafe) static var retriedPresigns = 0,wrongSizePuts = 0,retriedPuts = 0,hungPuts = 0,puts = 0,completedParts = 0,deleted = 0,partsSortedWithQuotedETags = false,minNonFinalPart = Int.max
    static func reset(failFirstPutOf part: Int,hangFirstPutOf hang: Int) {
        lock.lock(); parts = [:]; failNext = [part]; hangNext = [hang]; progressReports = []; signed = [:]; failNextPresign = true
        retriedPresigns = 0; wrongSizePuts = 0; retriedPuts = 0; hungPuts = 0; puts = 0; completedParts = 0; deleted = 0; partsSortedWithQuotedETags = false; minNonFinalPart = Int.max; lock.unlock()
    }
    /// Keeps only the `keeping` parts in storage, as after an interrupted upload, and resets counters.
    static func prepareRetry(keeping: Set<Int>) {
        lock.lock(); parts = parts.filter { keeping.contains($0.key) }; failNext = []; hangNext = []; puts = 0; lock.unlock()
    }
    static func etag(_ n: Int) -> String { lock.lock(); defer { lock.unlock() }; return "\"etag-\(n)-\(parts[n]?.count ?? 0)\"" }
    static var progress: [(bytes: Int,recording: Bool)] { lock.lock(); defer { lock.unlock() }; return progressReports }
    static var storedParts: Int { lock.lock(); defer { lock.unlock() }; return parts.count }
    static func assembled() -> Data { lock.lock(); defer { lock.unlock() }; return parts.keys.sorted().reduce(into: Data()) { $0.append(parts[$1]!) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".mock") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    private func body() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0,count: 1 << 16)
        while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength: buffer.count); if n <= 0 { break }; data.append(buffer,count: n) }
        return data
    }
    private func reply(_ status: Int,_ json: Any? = nil,headers: [String: String] = [:]) {
        let data = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(url: request.url!,statusCode: status,httpVersion: "HTTP/1.1",headerFields: headers.merging(["Content-Type": "application/json"]) { a,_ in a })!
        client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self,didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    static let video: [String: Any] = ["id": "vid1","slug": "abc123","share_url": "https://cloud.mock/v/abc123","title": "Share test","status": "pending",
                                       "upload": ["min_part_bytes": 5*1024*1024,"max_part_batch": 100,"part_url_ttl_seconds": 900,"max_parts": 10_000]]
    override func startLoading() {
        let url = request.url!,path = url.path,method = request.httpMethod ?? "GET"
        if url.host == "storage.mock",method == "PUT",let n = Int(url.lastPathComponent) {
            let data = body()
            Self.lock.lock()
            if Self.signed[n] != data.count { Self.wrongSizePuts += 1; Self.lock.unlock(); reply(403); return }
            let hang = Self.hangNext.remove(n) != nil
            let fail = !hang && Self.failNext.remove(n) != nil
            if hang { Self.hungPuts += 1 } else if fail { Self.retriedPuts += 1 } else { Self.parts[n] = data; Self.puts += 1 }
            Self.lock.unlock()
            // A hung request never answers; the session's idle timeout cancels it.
            if hang { return }
            if fail { reply(503); return }
            reply(200,headers: ["ETag": "\"etag-\(n)-\(data.count)\""]); return
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" else { reply(401,["error": ["message": "unauthorized"]]); return }
        switch (method,path) {
        case ("POST","/v1/videos"): reply(201,Self.video)
        case ("POST","/v1/videos/vid1/parts"):
            let parts = ((try? JSONSerialization.jsonObject(with: body()) as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            Self.lock.lock()
            let busy = Self.failNextPresign; Self.failNextPresign = false
            if busy { Self.retriedPresigns += 1 }
            for part in parts { if let n = part["part_number"] as? Int,let size = part["size"] as? Int { Self.signed[n] = size } }
            Self.lock.unlock()
            // One transient failure: the uploader must retry presigning like a storage PUT.
            if busy { reply(503,["error": ["code": "UNAVAILABLE","message": "busy"]]); return }
            reply(200,["parts": parts.compactMap { $0["part_number"] as? Int }.map { ["part_number": $0,"url": "https://storage.mock/part/\($0)","headers": ["content-length": String(Self.signed[$0] ?? 0)]] }])
        case ("POST","/v1/videos/vid1/complete"):
            let parts = ((try? JSONSerialization.jsonObject(with: body()) as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            let numbers = parts.compactMap { $0["part_number"] as? Int }
            Self.lock.lock()
            Self.completedParts = parts.count
            Self.partsSortedWithQuotedETags = numbers == numbers.sorted() && numbers == Array(1...max(1,numbers.count)) && parts.allSatisfy { ($0["etag"] as? String)?.hasPrefix("\"") == true }
            for n in numbers.dropLast() { Self.minNonFinalPart = min(Self.minNonFinalPart,Self.parts[n]?.count ?? 0) }
            if numbers.count == 1 { Self.minNonFinalPart = Int.max }
            Self.lock.unlock()
            var ready = Self.video; ready["status"] = "ready"; reply(200,ready)
        case ("POST","/v1/videos/vid1/progress"):
            let json = (try? JSONSerialization.jsonObject(with: body()) as? [String: Any]) ?? [:]
            Self.lock.lock(); Self.progressReports.append((json["uploaded_bytes"] as? Int ?? -1,json["recording"] as? Bool ?? true)); Self.lock.unlock()
            reply(204)
        case ("DELETE","/v1/videos/vid1"): Self.lock.lock(); Self.deleted += 1; Self.lock.unlock(); reply(204)
        default: reply(404,["error": ["message": "not found"]])
        }
    }
}
