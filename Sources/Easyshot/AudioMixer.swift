import AVFoundation
import EasyshotCore

/// Mixes system audio and the microphone into one stereo track while recording. Browsers play only a
/// file's first audio track, and one track also spares the old post-recording re-export.
/// Both sources are converted to 48 kHz interleaved float, placed on a shared timeline by output time
/// (pauses already cut), summed at 0.7 system / 1.0 voice and soft-limited. Owned by the recorder's queue.
final class AudioMixer {
    static let rate = 48000.0
    static let system = 0,voice = 1
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: AudioMixer.rate,channels: 2,interleaved: true)!
    private var timeline = AudioMixTimeline(gains: [0.7,1],maxLag: Int(AudioMixer.rate*0.3))
    private var sources = [Source(),Source()]
    var origin: CMTime?
    /// CPU time spent mixing and the audio it produced, for diagnostics.
    private(set) var busySeconds = 0.0,mixedSeconds = 0.0

    private struct Source {
        var description: CMFormatDescription?
        var input: AVAudioFormat?; var converter: AVAudioConverter?; var output: AVAudioFormat?
        /// Output time where the next contiguous input buffer is expected.
        var expected: CMTime?
    }

    func add(_ sample: CMSampleBuffer,source: Int,at time: CMTime) {
        guard let origin,let description = sample.formatDescription else { return }
        let begin = DispatchTime.now().uptimeNanoseconds
        defer { busySeconds += Double(DispatchTime.now().uptimeNanoseconds-begin)/1e9 }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else { return }
        var state = sources[source]
        if state.description.map({ !CMFormatDescriptionEqual($0,otherFormatDescription: description) }) ?? true {
            let input = AVAudioFormat(cmAudioFormatDescription: description)
            let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: Self.rate,channels: min(2,max(1,input.channelCount)),interleaved: true)!
            state = Source(description: description,input: input,converter: AVAudioConverter(from: input,to: output),output: output)
        }
        guard let input = state.input,let output = state.output,let converter = state.converter,
              let pcm = AVAudioPCMBuffer(pcmFormat: input,frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,at: 0,frameCount: Int32(count),into: pcm.mutableAudioBufferList) == noErr else { return }
        // Within a stream, buffers follow each other exactly; timestamps carry jitter. Only a real break
        // (pause, dropout) places audio by its timestamp, and resets the resampler's history.
        let contiguous = state.expected.map { abs(CMTimeSubtract(time,$0).seconds) < 0.002 } ?? false
        if !contiguous { converter.reset() }
        state.expected = CMTimeAdd(time,CMTime(value: CMTimeValue(count),timescale: CMTimeScale(input.sampleRate)))
        sources[source] = state
        let capacity = AVAudioFrameCount(ceil(Double(count)*Self.rate/input.sampleRate))+64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output,frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted,error: &error) { _,status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return pcm
        }
        let frames = Int(converted.frameLength)
        guard error == nil,frames > 0,let data = converted.floatChannelData?[0] else { return }
        var stereo = [Float](repeating: 0,count: frames*2)
        if output.channelCount == 1 { for i in 0..<frames { stereo[2*i] = data[i]; stereo[2*i+1] = data[i] } }
        else { stereo.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: data,count: frames*2) } }
        // Device clocks drift from the host clock by a few ppm; past 20 ms, follow the timestamp again.
        let stamped = Int((CMTimeSubtract(time,origin).seconds*Self.rate).rounded())
        let start = contiguous ? timeline.end(of: source).flatMap { abs($0-stamped) < Int(Self.rate*0.02) ? $0 : nil } ?? stamped : stamped
        timeline.write(source,start: start,stereo: stereo)
    }

    /// Appends mixed audio to `input` while it accepts data. `final` releases everything, waiting briefly
    /// for the encoder when needed. Returns false when an append fails.
    func drain(into input: AVAssetWriterInput,final: Bool) -> Bool {
        guard let origin else { return true }
        let begin = DispatchTime.now().uptimeNanoseconds
        defer { busySeconds += Double(DispatchTime.now().uptimeNanoseconds-begin)/1e9 }
        let end = timeline.available(final: final)
        var waited = 0
        while timeline.emitted < end {
            if !input.isReadyForMoreMediaData {
                guard final,waited < 500 else { return true }
                usleep(2000); waited += 1; continue
            }
            guard let (start,stereo) = timeline.read(upTo: end,maxFrames: 4800),let sample = makeSample(stereo,at: CMTimeAdd(origin,CMTime(value: CMTimeValue(start),timescale: CMTimeScale(Self.rate)))) else { return false }
            mixedSeconds += Double(stereo.count/2)/Self.rate
            guard input.append(sample) else { return false }
        }
        return true
    }

    private func makeSample(_ stereo: [Float],at time: CMTime) -> CMSampleBuffer? {
        let frames = stereo.count/2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(frames)),let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        stereo.withUnsafeBufferPointer { data.update(from: $0.baseAddress!,count: stereo.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: CMTimeScale(Self.rate)),presentationTimeStamp: time,decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,dataBuffer: nil,dataReady: false,makeDataReadyCallback: nil,refcon: nil,formatDescription: format.formatDescription,
                                   sampleCount: frames,sampleTimingEntryCount: 1,sampleTimingArray: &timing,sampleSizeEntryCount: 0,sampleSizeArray: nil,sampleBufferOut: &sample) == noErr,let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample,blockBufferAllocator: kCFAllocatorDefault,blockBufferMemoryAllocator: kCFAllocatorDefault,flags: 0,bufferList: buffer.audioBufferList) == noErr else { return nil }
        return sample
    }
}
