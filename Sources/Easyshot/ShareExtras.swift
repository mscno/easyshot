import AppKit
import AVFoundation
import ImageIO
import Speech
import UniformTypeIdentifiers
import EasyshotCore

/// What history remembers about a recording's Cloud copy.
struct CloudShare: Codable,Equatable {
    enum Status: String,Codable { case uploading,ready,failed }
    var videoID: String?; var slug: String?; var url: String?; var title: String?; var status: Status
    var error: String?
    init(video: CloudVideo?,title: String?,status: Status,error: String? = nil) {
        videoID = video?.id; slug = video?.slug; url = video?.shareUrl; self.title = video?.title ?? title; self.status = status; self.error = error
    }
    var markdown: String? { url.map { ShareLinks.githubMarkdown(title: title ?? "Recording",shareURL: $0) } }
}

/// Poster and captions for a shared recording. Both are uploaded after the link is ready, never before it.
enum ShareExtras {
    /// A poster frame a second in (past any initial black frame), at most 1280 px, as JPEG under the 2 MiB limit.
    static func poster(_ url: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280,height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(value: 1,timescale: 2); generator.requestedTimeToleranceAfter = CMTime(value: 1,timescale: 2)
        return try await generator.image(at: CMTime(seconds: duration.isFinite ? min(1,duration/2) : 0,preferredTimescale: 600)).image
    }
    static func jpeg(_ image: CGImage) -> Data? {
        for quality in [0.82,0.65,0.45] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { return nil }
            CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= 2*1024*1024 { return data as Data }
        }
        return nil
    }
    /// Uploads the poster, with detected secrets blacked out when the secret check is on. A video can't be
    /// redacted after the fact, so findings come back as a warning instead of blocking the share.
    @MainActor static func uploadPoster(client: CloudClient,video: String,file: URL) async throws -> String? {
        var image = try await poster(file)
        var warning: String?
        if Preferences.shared.redactBeforeUpload {
            let secrets = try await TextAnalysis.analyze(image,scanner: Preferences.shared.secretScanner).secrets
            if !secrets.isEmpty {
                if let redacted = Redaction.apply(image,boxes: secrets.map(\.rect)) { image = redacted }
                warning = "The recording may show secrets (\(Redaction.summary(secrets))). They are hidden in the poster but visible in the video."
            }
        }
        guard let data = jpeg(image) else { throw ShotError.message("Could not encode the poster frame.") }
        try await client.uploadAsset(video,kind: "thumbnail",data: data)
        return warning
    }
    static func uploadTranscript(client: CloudClient,video: String,file: URL) async throws -> Bool {
        guard let vtt = try await Transcriber.webVTT(file) else { return false }
        try await client.uploadAsset(video,kind: "transcript",data: Data(vtt.utf8))
        return true
    }
}

/// On-device speech-to-text for the recording's voice track: SpeechAnalyzer on macOS 26, otherwise
/// SFSpeechRecognizer restricted to on-device recognition. Audio never leaves the Mac for this.
enum Transcriber {
    static func webVTT(_ movie: URL) async throws -> String? {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("easyshot-voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: audio) }
        guard try await extractVoice(from: movie,to: audio) else { return nil }
        var phrases: [WebVTT.Cue]
        do { phrases = try await analyze(audio) } catch { phrases = try await recognize(audio) }
        let cues = WebVTT.cues(phrases)
        return cues.isEmpty ? nil : WebVTT.document(cues)
    }
    /// The mono microphone track (the voice is written first in shared recordings), as 16 kHz mono float PCM.
    static func extractVoice(from movie: URL,to output: URL) async throws -> Bool {
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var voice: AVAssetTrack?
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            if formats.contains(where: { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame == 1 }) { voice = track; break }
        }
        guard let track = voice ?? tracks.first else { return false }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 16000,channels: 1,interleaved: false)!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track,outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,AVSampleRateKey: 16000,AVNumberOfChannelsKey: 1,
                                                                        AVLinearPCMBitDepthKey: 32,AVLinearPCMIsFloatKey: true,AVLinearPCMIsNonInterleaved: true,AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? ShotError.message("Could not read the recording's audio.") }
        let file = try AVAudioFile(forWriting: output,settings: format.settings,commonFormat: .pcmFormatFloat32,interleaved: false)
        var frames = 0
        while let sample = out.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0,let buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(count)) else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,at: 0,frameCount: Int32(count),into: buffer.mutableAudioBufferList) == noErr else { continue }
            try file.write(from: buffer); frames += count
        }
        if reader.status == .failed { throw reader.error ?? ShotError.message("Could not read the recording's audio.") }
        return frames > 16000/2
    }
    static func analyze(_ audio: URL) async throws -> [WebVTT.Cue] {
        guard SpeechTranscriber.isAvailable else { throw ShotError.message("On-device transcription is unavailable.") }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale,transcriptionOptions: [],reportingOptions: [],attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await install.downloadAndInstall() }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var cues: [WebVTT.Cue] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { cues.append(WebVTT.Cue(start: result.range.start.seconds,end: result.range.end.seconds,text: text)) }
            }
            return cues
        }
        let file = try AVAudioFile(forReading: audio)
        if let end = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: end) }
        else { await analyzer.cancelAndFinishNow() }
        return try await collect.value
    }
    /// Fallback: SFSpeechRecognizer, on device only, grouping words into phrases at pauses.
    static func recognize(_ audio: URL) async throws -> [WebVTT.Cue] {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized,let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else { throw ShotError.message("On-device speech recognition is unavailable.") }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false; request.addsPunctuation = true
        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result,error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: error) }
                else if let result,result.isFinal { done = true; c.resume(returning: result.bestTranscription.segments) }
            }
        }
        var cues: [WebVTT.Cue] = []
        for segment in segments {
            let end = segment.timestamp+segment.duration
            if var last = cues.last,segment.timestamp-last.end < 0.7,end-last.start < 6 { last.text += " "+segment.substring; last.end = end; cues[cues.count-1] = last }
            else { cues.append(WebVTT.Cue(start: segment.timestamp,end: end,text: segment.substring)) }
        }
        return cues
    }
}
