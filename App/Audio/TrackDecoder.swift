import AVFoundation
import os

/// Audiodatei für die Engine: entweder vollständig vorhanden (lokal, Cache, Download) oder gerade im Laden
/// (`TrackCache` schreibt sie fortlaufend). Der Decoder liest dann nur, was schon da ist, und wartet sonst.
final class TrackSource: @unchecked Sendable {
    struct State: Sendable {
        /// Aktueller Pfad (beim Laden die `.part`-Datei, danach die fertige Datei)
        var url: URL
        var bytes: Int64 = 0
        var total: Int64?
        var complete = false
        var error: Error?
    }

    /// Darf die Datei schon gelesen werden, bevor sie vollständig ist? (FLAC, WAV, AIFF, ALAC/AAC in MP4:
    /// Länge steht im Kopf. MP3 ohne Xing-Kopf würde eine falsche Länge liefern → erst fertig laden.)
    let progressive: Bool
    private let state: OSAllocatedUnfairLock<State>

    init(url: URL, progressive: Bool, complete: Bool) {
        self.progressive = progressive
        var s = State(url: url)
        s.complete = complete
        if complete { s.bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0); s.total = s.bytes }
        state = OSAllocatedUnfairLock(initialState: s)
    }

    /// Fertige Datei (lokal, Cache, Download).
    static func file(_ url: URL) -> TrackSource { TrackSource(url: url, progressive: true, complete: true) }

    var snapshot: State { state.withLock { $0 } }
    var isComplete: Bool { state.withLock { $0.complete } }
    var url: URL { state.withLock { $0.url } }

    func update(_ body: (inout State) -> Void) { state.withLockUnchecked { body(&$0) } }

    /// Wartet, bis die Datei vollständig ist (oder das Laden endgültig scheiterte bzw. die Aufgabe abgebrochen wird).
    func waitUntilComplete() async throws -> URL {
        while true {
            let s = snapshot
            if s.complete { return s.url }
            if let e = s.error { throw e }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    static let progressiveSuffixes: Set<String> = ["flac", "wav", "wave", "aif", "aiff", "aifc", "m4a", "mp4", "caf", "alac"]
}

/// Liest eine Audiodatei (MP3, AAC, ALAC, FLAC, WAV …) und liefert Stücke im Format der Engine
/// (Float32, Stereo, Abtastrate der Engine). Umrechnung mit dem besten Resampler von Core Audio.
///
/// Wird die Datei noch geladen, liest der Decoder bis an die Grenze der vorhandenen Daten (Core Audio bricht dort
/// sauber an einer Frame-Grenze ab) und meldet `.wait`. Sind genug neue Daten da, wird die Datei an derselben
/// Stelle neu geöffnet – der Resampler behält seinen Zustand, das Ergebnis ist bit-gleich zum Lesen der fertigen Datei.
final class TrackDecoder: @unchecked Sendable {
    enum ReadResult {
        case data(AVAudioPCMBuffer)
        /// Noch nicht genug geladen
        case wait
        case end
    }

    let source: TrackSource
    let outFormat: AVAudioFormat
    let duration: Double
    private var file: AVAudioFile
    private let length: AVAudioFramePosition
    private let srcFormat: AVAudioFormat
    private let midFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inBuffer: AVAudioPCMBuffer
    private var inputDone = false
    /// Nächster zu lesender Frame der Datei
    private var filePos: AVAudioFramePosition = 0
    /// Datenstand, an dem das Lesen zuletzt an die Grenze stieß (nil = frei)
    private var blockedAt: Int64?
    /// Datei wurde geöffnet, als sie schon vollständig war
    private var openedComplete: Bool
    /// Erst neu öffnen, wenn so viel dazugekommen ist (≈ 0,3–1,5 s Musik)
    private static let minGrowth: Int64 = 256 * 1024

    /// Fertige Datei öffnen (wirft, wenn sie nicht lesbar ist).
    convenience init(url: URL, outFormat: AVAudioFormat, startAt seconds: Double = 0) throws {
        try self.init(source: .file(url), outFormat: outFormat, startAt: seconds)
    }

    init(source: TrackSource, outFormat: AVAudioFormat, startAt seconds: Double = 0) throws {
        self.source = source
        let s = source.snapshot
        file = try AVAudioFile(forReading: s.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        openedComplete = s.complete
        self.outFormat = outFormat
        srcFormat = file.processingFormat
        length = file.length
        let rate = srcFormat.sampleRate
        duration = rate > 0 ? Double(length) / rate : 0
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
            filePos = min(length, AVAudioFramePosition(seconds * rate))
            file.framePosition = filePos
        }
    }

    /// Öffnet den Decoder, sobald genug von der Datei da ist: nil = noch warten, Fehler = nicht abspielbar.
    static func open(source: TrackSource, outFormat: AVAudioFormat, startAt seconds: Double = 0) throws -> TrackDecoder? {
        let s = source.snapshot
        if let e = s.error, !s.complete { throw e }
        if !s.complete {
            // Kopf (inkl. eingebettetem Cover) noch nicht da oder Format braucht die ganze Datei
            guard source.progressive, s.bytes >= 64 * 1024 else { return nil }
        }
        do {
            let d = try TrackDecoder(source: source, outFormat: outFormat, startAt: seconds)
            // Ohne bekannte Länge lässt sich unterwegs nicht sicher lesen
            if !s.complete && d.length <= 0 { return nil }
            return d
        } catch {
            if s.complete { throw error }
            return nil
        }
    }

    /// Nächstes Stück oder nil am Dateiende (bzw. wenn noch Daten fehlen).
    func read(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if case .data(let b) = next(frames: frames) { return b }
        return nil
    }

    /// Nächstes Stück, `.wait` (Daten fehlen noch) oder `.end`.
    func next(frames: AVAudioFrameCount) -> ReadResult {
        let mid: AVAudioPCMBuffer
        if let converter {
            if inputDone && converterFlushed { return .end }
            guard let out = AVAudioPCMBuffer(pcmFormat: midFormat, frameCapacity: frames) else { return .end }
            var error: NSError?
            waiting = false
            let status = converter.convert(to: out, error: &error) { [self] packets, outStatus in
                if inputDone { outStatus.pointee = .endOfStream; return nil }
                switch readFile(into: inBuffer, max: min(AVAudioFrameCount(packets), inBuffer.frameCapacity)) {
                case .some(true):
                    outStatus.pointee = .haveData
                    return inBuffer
                case .some(false):
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                case .none:
                    waiting = true
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            if status == .error { return .end }
            if status == .endOfStream { converterFlushed = true }
            if out.frameLength == 0 { return waiting ? .wait : .end }
            mid = out
        } else {
            guard let out = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else { return .end }
            switch readFile(into: out, max: frames) {
            case .some(true): mid = out
            case .some(false): return .end
            case .none: return .wait
            }
        }
        return .data(Self.toStereo(mid, format: outFormat))
    }

    private var converterFlushed = false
    /// Im letzten Umrechnungs-Durchgang fehlten Daten
    private var waiting = false

    /// true = gelesen, false = Dateiende, nil = Daten fehlen noch.
    private func readFile(into buf: AVAudioPCMBuffer, max n: AVAudioFrameCount) -> Bool? {
        buf.frameLength = 0
        if length > 0 && filePos >= length { return false }
        if let b = blockedAt {
            let s = source.snapshot
            if !s.complete {
                if s.error != nil { return false }
                if s.bytes < b + Self.minGrowth { return nil }
            }
            // An derselben Stelle neu öffnen (ein einmal an die Grenze gestoßenes AVAudioFile liest nicht weiter)
            guard let f = try? AVAudioFile(forReading: s.url, commonFormat: .pcmFormatFloat32, interleaved: false) else {
                if s.complete { return false }
                blockedAt = s.bytes
                return nil
            }
            f.framePosition = filePos
            file = f
            openedComplete = s.complete
            blockedAt = nil
        }
        do {
            try file.read(into: buf, frameCount: n)
        } catch {
            buf.frameLength = 0
        }
        if buf.frameLength > 0 {
            filePos += AVAudioFramePosition(buf.frameLength)
            return true
        }
        // Grenze erreicht: echtes Ende nur bei vollständiger Datei
        if openedComplete { return false }
        let s = source.snapshot
        if s.error != nil && !s.complete { return false }
        blockedAt = s.complete ? Int64.min : s.bytes
        return s.complete ? readFile(into: buf, max: n) : nil
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
