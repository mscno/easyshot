import AppKit
import AVFoundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import EasyshotCore

/// A serial queue owns the writer and all sample processing.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "easyshot.recording",qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var mic: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// With both system audio and the microphone on, one mixed track replaces the two separate ones.
    private var mixer: AudioMixer?
    /// Mixing cost from the last recording: CPU seconds spent and seconds of audio produced.
    private(set) var mixStats: (busy: Double,audio: Double)?
    private var effects: RecordingEffects?
    private var telemetry: CursorTelemetry?
    /// Record & Share: the writer emits fragmented-MP4 segments into this spool, which is both the local
    /// recording and the source of upload parts. The writer starts at the first frame, because a segmented
    /// writer needs its initial segment time before `startWriting`.
    private var spool: SegmentSpool?
    private var outputURL: URL?
    private var started = false
    private var ending = false
    private var sampleError: Error?
    /// Cuts paused time out of every track; owned by `queue`.
    private var clock = PauseClock(frameDuration: 1/30)
    var didFail: ((Error) -> Void)?

    /// Paused frames and audio are dropped; on resume, the output continues one frame after the pause.
    func setPaused(_ paused: Bool) { queue.async { if paused { self.clock.pause() } else { self.clock.resume() } } }
    /// Moves every timing entry of `sample` earlier by `delta` (audio buffers carry several).
    static func retimed(_ sample: CMSampleBuffer,by delta: CMTime) -> CMSampleBuffer? {
        guard delta != .zero else { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample,entryCount: 0,arrayToFill: nil,entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(),count: max(count,1))
        guard CMSampleBufferGetSampleTimingInfoArray(sample,entryCount: count,arrayToFill: &timing,entriesNeededOut: &count) == noErr else { return nil }
        for i in 0..<count {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp,delta)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp,delta) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil,sampleBuffer: sample,sampleTimingEntryCount: count,sampleTimingArray: &timing,sampleBufferOut: &out)
        return out
    }
    private func map(_ pts: CMTime,track: Int) -> (time: CMTime,delta: CMTime)? { Self.map(pts,track: track,clock: &clock) }
    /// Output time for a capture timestamp and how far it moved, or nil when the sample falls in a pause.
    static func map(_ pts: CMTime,track: Int,clock: inout PauseClock) -> (time: CMTime,delta: CMTime)? {
        guard let out = clock.map(pts.seconds,track: track) else { return nil }
        let removed = pts.seconds-out
        guard removed > 1e-9 else { return (pts,.zero) }
        let delta = CMTime(seconds: removed,preferredTimescale: 1_000_000_000)
        return (CMTimeSubtract(pts,delta),delta)
    }

    /// With `telemetry`, frames pass through untouched and the cursor is logged for Studio export.
    func start(filter: SCContentFilter,configuration: SCStreamConfiguration,url: URL,effects: RecordingEffects? = nil,telemetry: CursorTelemetry? = nil,spool: SegmentSpool? = nil) async throws {
        let writer = try Self.makeWriter(url: url,spool: spool)
        // A delegate switches the writer to segment delivery; a plain file writer must not have one.
        if spool != nil { writer.delegate = self }
        let video = Self.videoInput(width: configuration.width,height: configuration.height,fragmented: spool != nil)
        guard writer.canAdd(video) else { throw ShotError.message("Video encoder unavailable at this resolution.") }
        writer.add(video)
        self.spool = spool; outputURL = url
        self.effects = effects
        if effects != nil {
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: configuration.width,kCVPixelBufferHeightKey as String: configuration.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        }
        self.writer = writer; self.video = video; self.telemetry = telemetry
        clock = PauseClock(frameDuration: configuration.minimumFrameInterval.seconds > 0 ? configuration.minimumFrameInterval.seconds : 1/30)
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = Preferences.shared.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        // One audio track either way: a single source passes through, two are mixed while recording.
        if #available(macOS 15.0, *),Preferences.shared.microphone {
            configuration.captureMicrophone = true
            if configuration.capturesAudio { mixer = AudioMixer() } else { mic = Self.audioInput(channels: 1); writer.add(mic!) }
        }
        if configuration.capturesAudio { audio = Self.audioInput(channels: 2); writer.add(audio!) }
        let stream = SCStream(filter: filter,configuration: configuration,delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self,type: .screen,sampleHandlerQueue: queue)
        if configuration.capturesAudio { try stream.addStreamOutput(self,type: .audio,sampleHandlerQueue: queue) }
        if #available(macOS 15.0, *),configuration.captureMicrophone { try stream.addStreamOutput(self,type: .microphone,sampleHandlerQueue: queue) }
        if spool == nil { guard writer.startWriting() else { throw writer.error ?? ShotError.message("Could not start video writer.") } }
        telemetry?.start(fps: Int(1/max(configuration.minimumFrameInterval.seconds,1/120)),queue: queue)
        do { try await stream.startCapture() }
        catch { telemetry?.cancel(); if writer.status == .writing { writer.cancelWriting() }; self.stream = nil; throw error }
    }
    /// A plain MP4 file, or with `spool` a fragmented MP4 delivered segment by segment (init segment first).
    static func makeWriter(url: URL,spool: SegmentSpool?) throws -> AVAssetWriter {
        guard spool != nil else { return try AVAssetWriter(outputURL: url,fileType: .mp4) }
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1,preferredTimescale: 600)
        return writer
    }
    static func videoInput(width: Int,height: Int,fragmented: Bool) -> AVAssetWriterInput {
        var compression: [String: Any] = [AVVideoAverageBitRateKey: min(35_000_000,max(4_000_000,width*height*5))]
        // Segments split at sync samples; a keyframe each second keeps parts flowing during a recording.
        if fragmented { compression[AVVideoMaxKeyFrameIntervalDurationKey] = 1.0 }
        let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: width,AVVideoHeightKey: height,AVVideoCompressionPropertiesKey: compression])
        input.expectsMediaDataInRealTime = true
        return input
    }
    static func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio,outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: 48000,AVNumberOfChannelsKey: channels,AVEncoderBitRateKey: 128000
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }
    func stream(_ stream: SCStream,didOutputSampleBuffer sample: CMSampleBuffer,of type: SCStreamOutputType) {
        guard sample.isValid,!ending,let writer,writer.status == .writing || (spool != nil && !started && writer.status == .unknown) else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,SCFrameStatus(rawValue: raw) == .complete else { return }
            guard let (time,delta) = map(sample.presentationTimeStamp,track: 0) else { return }
            if !started {
                if spool != nil {
                    writer.initialSegmentStartTime = time
                    guard writer.startWriting() else { sampleError = writer.error; return }
                }
                writer.startSession(atSourceTime: time); telemetry?.setOrigin(time); mixer?.origin = time; started = true
            }
            if video?.isReadyForMoreMediaData == true {
                if let effects,let adaptor,let pool = adaptor.pixelBufferPool,let input = CMSampleBufferGetImageBuffer(sample) {
                    if let output = effects.composite(input,pool: pool),!adaptor.append(output,withPresentationTime: time) { sampleError = writer.error }
                } else if let retimed = Self.retimed(sample,by: delta),video?.append(retimed) == false { sampleError = writer.error }
            }
        } else if started {
            let input: AVAssetWriterInput?,track: Int
            if #available(macOS 15.0, *),type == .microphone { input = mic; track = 2 } else { input = audio; track = 1 }
            guard let (time,delta) = map(sample.presentationTimeStamp,track: track) else { return }
            if let mixer,let audio {
                mixer.add(sample,source: track == 2 ? AudioMixer.voice : AudioMixer.system,at: time)
                if !mixer.drain(into: audio,final: false) { sampleError = writer.error }
                return
            }
            if input?.isReadyForMoreMediaData == true,let retimed = Self.retimed(sample,by: delta),input?.append(retimed) == false { sampleError = writer.error }
        }
    }
    func stream(_ stream: SCStream,didStopWithError error: Error) { DispatchQueue.main.async { self.didFail?(error) } }
    func stop() async throws {
        guard let stream,let writer else { return }
        do { try await stream.stopCapture() }
        catch { telemetry?.cancel(); if writer.status == .writing { writer.cancelWriting() }; spool?.close(); self.stream = nil; throw error }
        let hasFrames: Bool = await withCheckedContinuation { continuation in
            queue.async {
                self.ending = true
                if let mixer = self.mixer,let audio = self.audio {
                    if self.started,!mixer.drain(into: audio,final: true) { self.sampleError = self.writer?.error }
                    self.mixStats = (mixer.busySeconds,mixer.mixedSeconds)
                }
                self.video?.markAsFinished(); self.audio?.markAsFinished(); self.mic?.markAsFinished()
                continuation.resume(returning: self.started)
            }
        }
        guard hasFrames else { telemetry?.cancel(); if writer.status == .writing { writer.cancelWriting() }; spool?.close(); throw ShotError.message("No video frames were received. Check Screen Recording permission.") }
        await writer.finishWriting()
        // Every segment, including the last, has been delivered once finishWriting returns.
        spool?.close()
        self.stream = nil
        if writer.status != .completed { telemetry?.cancel(); throw writer.error ?? sampleError ?? ShotError.message("Recording could not be finalized.") }
        // A missing sidecar only disables Studio editing; the recording itself is intact.
        let output = outputURL ?? writer.outputURL
        try? await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in
            queue.async { let clock = self.clock; c.resume(with: Result { try self.telemetry?.finish(video: output,retime: { clock.outputTime($0) },clamp: { clock.clampedOutputTime($0) }) }) }
        }
    }
}

extension Recorder: AVAssetWriterDelegate {
    func assetWriter(_ writer: AVAssetWriter,didOutputSegmentData segmentData: Data,segmentType: AVAssetSegmentType,segmentReport: AVAssetSegmentReport?) {
        do { try spool?.append(segmentData) } catch { queue.async { self.sampleError = error } }
    }
}

enum VideoTools {
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
