import AppKit
import AVFoundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// A serial queue owns the writer and all sample processing.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "easyshot.recording",qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var mic: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var effects: RecordingEffects?
    private var telemetry: CursorTelemetry?
    private var started = false
    private var ending = false
    private var sampleError: Error?
    var didFail: ((Error) -> Void)?

    /// With `telemetry`, frames pass through untouched and the cursor is logged for Studio export.
    func start(filter: SCContentFilter,configuration: SCStreamConfiguration,url: URL,effects: RecordingEffects? = nil,telemetry: CursorTelemetry? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video,outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(35_000_000,max(4_000_000,configuration.width*configuration.height*5))]
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw ShotError.message("Video encoder unavailable at this resolution.") }
        writer.add(video)
        self.effects = effects
        if effects != nil {
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: configuration.width,kCVPixelBufferHeightKey as String: configuration.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        }
        self.writer = writer; self.video = video; self.telemetry = telemetry
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = Preferences.shared.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        if configuration.capturesAudio { audio = audioInput(channels: 2); writer.add(audio!) }
        if #available(macOS 15.0, *),Preferences.shared.microphone {
            configuration.captureMicrophone = true
            mic = audioInput(channels: 1); writer.add(mic!)
        }
        let stream = SCStream(filter: filter,configuration: configuration,delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self,type: .screen,sampleHandlerQueue: queue)
        if configuration.capturesAudio { try stream.addStreamOutput(self,type: .audio,sampleHandlerQueue: queue) }
        if #available(macOS 15.0, *),configuration.captureMicrophone { try stream.addStreamOutput(self,type: .microphone,sampleHandlerQueue: queue) }
        guard writer.startWriting() else { throw writer.error ?? ShotError.message("Could not start video writer.") }
        telemetry?.start(fps: Int(1/max(configuration.minimumFrameInterval.seconds,1/120)),queue: queue)
        do { try await stream.startCapture() }
        catch { telemetry?.cancel(); writer.cancelWriting(); self.stream = nil; throw error }
    }
    private func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio,outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: 48000,AVNumberOfChannelsKey: channels,AVEncoderBitRateKey: 128000
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }
    func stream(_ stream: SCStream,didOutputSampleBuffer sample: CMSampleBuffer,of type: SCStreamOutputType) {
        guard sample.isValid,!ending,let writer,writer.status == .writing else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started { writer.startSession(atSourceTime: sample.presentationTimeStamp); telemetry?.setOrigin(sample.presentationTimeStamp); started = true }
            if video?.isReadyForMoreMediaData == true {
                if let effects,let adaptor,let pool = adaptor.pixelBufferPool,let input = CMSampleBufferGetImageBuffer(sample) {
                    if let output = effects.composite(input,pool: pool),!adaptor.append(output,withPresentationTime: sample.presentationTimeStamp) { sampleError = writer.error }
                } else if video?.append(sample) == false { sampleError = writer.error }
            }
        } else if started {
            let input: AVAssetWriterInput?
            if #available(macOS 15.0, *),type == .microphone { input = mic } else { input = audio }
            if input?.isReadyForMoreMediaData == true,input?.append(sample) == false { sampleError = writer.error }
        }
    }
    func stream(_ stream: SCStream,didStopWithError error: Error) { DispatchQueue.main.async { self.didFail?(error) } }
    func stop() async throws {
        guard let stream,let writer else { return }
        do { try await stream.stopCapture() }
        catch { telemetry?.cancel(); writer.cancelWriting(); self.stream = nil; throw error }
        let hasFrames: Bool = await withCheckedContinuation { continuation in
            queue.async {
                self.ending = true
                self.video?.markAsFinished(); self.audio?.markAsFinished(); self.mic?.markAsFinished()
                continuation.resume(returning: self.started)
            }
        }
        guard hasFrames else { telemetry?.cancel(); writer.cancelWriting(); throw ShotError.message("No video frames were received. Check Screen Recording permission.") }
        await writer.finishWriting()
        self.stream = nil
        if writer.status != .completed { telemetry?.cancel(); throw writer.error ?? sampleError ?? ShotError.message("Recording could not be finalized.") }
        // A missing sidecar only disables Studio editing; the recording itself is intact.
        let output = writer.outputURL
        try? await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in queue.async { c.resume(with: Result { try self.telemetry?.finish(video: output) }) } }
    }
}

enum VideoTools {
    static func mixAudio(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count > 1 else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { i,track in
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(i == 0 ? 0.7 : 1,at: .zero)
            return input
        }
        guard let export = AVAssetExportSession(asset: asset,presetName: AVAssetExportPresetHighestQuality) else { throw ShotError.message("Cannot mix recording audio.") }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".Easyshot-mix-\(UUID().uuidString).mp4")
        export.audioMix = mix
        try await export.export(to: temp,as: .mp4)
        _ = try FileManager.default.replaceItemAt(url,withItemAt: temp)
    }
    static func thumbnail(_ url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 700,height: 450)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: result.0,size: .zero)
    }
    static func gif(_ url: URL,to output: URL,start: Double = 0,end: Double? = nil) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let finish = min(duration,end ?? duration)
        let fps = 10.0
        guard finish > start else { throw ShotError.message("Choose a non-empty video range.") }
        guard finish-start <= 120 else { throw ShotError.message("GIF export is limited to two minutes. Trim the recording first.") }
        let count = Int(ceil((finish-start)*fps))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,UTType.gif.identifier as CFString,count,nil) else { throw ShotError.message("Cannot create GIF.") }
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960,height: 960)
        generator.requestedTimeToleranceBefore = CMTime(value: 1,timescale: 20)
        generator.requestedTimeToleranceAfter = CMTime(value: 1,timescale: 20)
        for i in 0..<count {
            let (image,_) = try await generator.image(at: CMTime(seconds: start+Double(i)/fps,preferredTimescale: 600))
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1/fps]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ShotError.message("Could not finish GIF export.") }
    }
    static func trim(_ url: URL,to output: URL,start: Double,end: Double) async throws {
        guard end > start else { throw ShotError.message("The end must be after the start.") }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset,presetName: AVAssetExportPresetHighestQuality) else { throw ShotError.message("Cannot export this recording.") }
        export.timeRange = CMTimeRange(start: CMTime(seconds: start,preferredTimescale: 600),end: CMTime(seconds: end,preferredTimescale: 600))
        try await export.export(to: output,as: .mp4)
    }
}
