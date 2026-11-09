import AVFoundation

/// Liest eine lokale Audiodatei (MP3, AAC, ALAC, FLAC, WAV …) und liefert Stücke im Format der Engine
/// (Float32, Stereo, Abtastrate der Engine). Umrechnung mit dem besten Resampler von Core Audio.
final class TrackDecoder: @unchecked Sendable {
    let file: AVAudioFile
    let outFormat: AVAudioFormat
    let duration: Double
    private let srcFormat: AVAudioFormat
    private let midFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inBuffer: AVAudioPCMBuffer
    private var inputDone = false

    init(url: URL, outFormat: AVAudioFormat, startAt seconds: Double = 0) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.outFormat = outFormat
        srcFormat = file.processingFormat
        let rate = srcFormat.sampleRate
        duration = rate > 0 ? Double(file.length) / rate : 0
        let channels = min(srcFormat.channelCount, 2)
        midFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outFormat.sampleRate,
                                  channels: channels, interleaved: false)!
        if srcFormat.sampleRate != outFormat.sampleRate || srcFormat.channelCount > 2 {
            let c = AVAudioConverter(from: srcFormat, to: midFormat)
            c?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            c?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            c?.downmix = srcFormat.channelCount > 2
            converter = c
        } else {
            converter = nil
        }
        inBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 8192)!
        if seconds > 0 {
            file.framePosition = min(file.length, AVAudioFramePosition(seconds * rate))
        }
    }

    /// Nächstes Stück oder nil am Dateiende.
    func read(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let mid: AVAudioPCMBuffer
        if let converter {
            guard let out = AVAudioPCMBuffer(pcmFormat: midFormat, frameCapacity: frames) else { return nil }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [self] packets, outStatus in
                if inputDone { outStatus.pointee = .endOfStream; return nil }
                inBuffer.frameLength = 0
                let want = min(AVAudioFrameCount(packets), inBuffer.frameCapacity)
                do { try file.read(into: inBuffer, frameCount: want) } catch { inBuffer.frameLength = 0 }
                if inBuffer.frameLength == 0 { inputDone = true; outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error || out.frameLength == 0 { return nil }
            mid = out
        } else {
            guard let out = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else { return nil }
            do { try file.read(into: out, frameCount: frames) } catch { return nil }
            if out.frameLength == 0 { return nil }
            mid = out
        }
        return Self.toStereo(mid, format: outFormat)
    }

    /// Mono wird auf beide Kanäle verteilt; Stereo bleibt, wie es ist.
    static func toStereo(_ buf: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer {
        if buf.format.channelCount == 2 && buf.format.sampleRate == format.sampleRate { return buf }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buf.frameLength),
              let src = buf.floatChannelData, let dst = out.floatChannelData else { return buf }
        out.frameLength = buf.frameLength
        let n = Int(buf.frameLength)
        let srcCh = Int(buf.format.channelCount)
        for ch in 0..<2 {
            dst[ch].update(from: src[min(ch, srcCh - 1)], count: n)
        }
        return out
    }
}
