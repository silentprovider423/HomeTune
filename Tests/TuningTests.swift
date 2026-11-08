import XCTest
import AVFoundation
import Accelerate
@testable import HomeTune

/// Klangprüfung der Stimmungs-Kette: Sinus durch genau dieselbe Kette wie in der App rendern (offline) und
/// per FFT messen. 440 Hz muss bei 432 Hz ≈ 432,0 Hz, bei „528 Hz“ (A4 = 444) ≈ 444,0 Hz und bei 440 Hz
/// exakt 440 Hz (bit-genau) ergeben; Tempo gleich; Umschalten mitten im Titel ohne Lücke und ohne Knacken.
/// Zum Vergleich wird dieselbe Messung mit Apples AVAudioUnitTimePitch (Kette bis Version 1.0) gemacht.
final class TuningTests: XCTestCase {
    let rate = 48000.0

    func testTuningValues() {
        XCTAssertEqual(Tuning.hz432.cents, 1200 * log2(432.0 / 440.0), accuracy: 1e-9)
        XCTAssertEqual(Tuning.hz432.cents, -31.766, accuracy: 0.001)
        XCTAssertEqual(Tuning.hz440.cents, 0)
        XCTAssertTrue(Tuning.hz440.isOriginal)
        // 528 Hz = A4 444 Hz (C5 = 528 Hz), nicht A4 = 528 Hz
        XCTAssertEqual(Tuning.hz528.a4, 444)
        XCTAssertEqual(Tuning.hz528.cents, 15.667, accuracy: 0.001)
        XCTAssertEqual(Tuning.hz528.semitones, 12 * log2(444.0 / 440.0), accuracy: 1e-12)
        XCTAssertEqual(Tuning.standard, .hz432)
        // C5 in 444er-Stimmung ≈ 528 Hz
        XCTAssertEqual(444 * pow(2, 3.0 / 12), 528, accuracy: 0.1)
    }

    func testSavedTuningDefaultsTo432() {
        let old = UserDefaults.standard.string(forKey: Tuning.storageKey)
        defer { UserDefaults.standard.set(old, forKey: Tuning.storageKey) }
        UserDefaults.standard.removeObject(forKey: Tuning.storageKey)
        XCTAssertEqual(Tuning.saved, .hz432)
        Tuning.saved = .hz528
        XCTAssertEqual(Tuning.saved, .hz528)
        XCTAssertEqual(PitchChain(tuning: .hz528).tuning, .hz528)
        XCTAssertEqual(PitchChain(tuning: .hz440).tuning, .hz440)
    }

    func testSine440Becomes432() throws {
        let m = measure(try render(sine([440], seconds: 4), seconds: 4, tuning: .hz432))
        let tp = measure(try renderTimePitch(sine([440], seconds: 4), seconds: 4, cents: Tuning.hz432.cents))
        print("Stimmung 432: 440 Hz → \(f3(m.freq)) Hz, Störabstand \(f1(m.snr)) dB (TimePitch: \(f3(tp.freq)) Hz, \(f1(tp.snr)) dB)")
        XCTAssertEqual(m.freq, 432.0, accuracy: 0.1)
        XCTAssertGreaterThan(m.snr, 40, "kaum Nebengeräusche/Artefakte")
    }

    /// Kleine und krumme Render-Blöcke (wie live auf dem iPhone: 256…1024, bei gesperrtem Bildschirm 4096).
    func testSmallRenderBlocks() throws {
        for chunk in [256, 333, 1024] {
            for tuning in [Tuning.hz432, .hz528] {
                let m = measure(try render(sine([440], seconds: 4), seconds: 4, chain: PitchChain(tuning: tuning), chunk: chunk)[0])
                print("Stimmung \(tuning.rawValue), Block \(chunk): 440 Hz → \(f3(m.freq)) Hz, Störabstand \(f1(m.snr)) dB")
                XCTAssertEqual(m.freq, 440 * tuning.ratio, accuracy: 0.1)
                XCTAssertGreaterThan(m.snr, 40)
            }
        }
    }

    func testSine440Becomes444For528() throws {
        let m = measure(try render(sine([440], seconds: 4), seconds: 4, tuning: .hz528))
        let tp = measure(try renderTimePitch(sine([440], seconds: 4), seconds: 4, cents: Tuning.hz528.cents))
        print("Stimmung 528 (A4 = 444): 440 Hz → \(f3(m.freq)) Hz, Störabstand \(f1(m.snr)) dB (TimePitch: \(f3(tp.freq)) Hz, \(f1(tp.snr)) dB)")
        XCTAssertEqual(m.freq, 444.0, accuracy: 0.1)
        XCTAssertGreaterThan(m.snr, 40)
    }

    /// 440 Hz = Original: Ausgang ist der Eingang, Sample für Sample identisch (nur um die feste Latenz verschoben).
    func testOriginalIsBitExact() throws {
        // Rauschen + Sinus, damit jedes Bit zählt
        let input = sine([440, 1234.5], seconds: 3, amp: 0.3)
        var seed: UInt64 = 42
        for i in 0..<Int(input.frameLength) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed >> 11) % 1000) / 1_000_000
            input.floatChannelData![0][i] += noise
            input.floatChannelData![1][i] -= noise
        }
        let chain = PitchChain(tuning: .hz440)
        let out = try render(input, seconds: 3, chain: chain, channels: 2)
        let lat = chain.latencyFrames
        XCTAssertGreaterThan(lat, 0)
        XCTAssertFalse(chain.shifter.processingActive, "im Original rechnet der Stretcher nicht")
        var mismatches = 0
        for ch in 0..<2 {
            let src = input.floatChannelData![ch]
            for i in 0..<(Int(input.frameLength) - lat) where out[ch][i + lat].bitPattern != src[i].bitPattern { mismatches += 1 }
            for i in 0..<lat where out[ch][i] != 0 { mismatches += 1 }
        }
        let m = measure(Array(out[0][lat...]), single: false)
        print("Stimmung 440: Original bit-genau (\(mismatches) Abweichungen), Spitze \(f3(m.freq)) Hz, Latenz \(lat) Frames = \(f1(Double(lat) / rate * 1000)) ms")
        XCTAssertEqual(mismatches, 0, "Original muss bit-genau sein")
    }

    func testOtherFrequenciesScaleByRatio() throws {
        for tuning in [Tuning.hz432, .hz528] {
            for f in [110.0, 1000.0, 4000.0] {
                let m = measure(try render(sine([f], seconds: 4), seconds: 4, tuning: tuning))
                let tp = measure(try renderTimePitch(sine([f], seconds: 4), seconds: 4, cents: tuning.cents))
                print("Stimmung \(tuning.rawValue): \(f) Hz → \(f3(m.freq)) Hz (Soll \(f3(f * tuning.ratio))), Störabstand \(f1(m.snr)) dB (TimePitch \(f1(tp.snr)) dB)")
                XCTAssertEqual(m.freq, f * tuning.ratio, accuracy: max(0.1, f * 0.0003))
                XCTAssertGreaterThan(m.snr, 35)
            }
        }
    }

    /// Akkord: Teiltöne dürfen nicht verschmieren (Intermodulation klein).
    func testChordStaysClean() throws {
        let chord = [261.63, 329.63, 392.0]
        for tuning in [Tuning.hz432, .hz528] {
            let spec = spectrum(try render(sine(chord, seconds: 4, amp: 0.25), seconds: 4, tuning: tuning))
            for f in chord {
                XCTAssertEqual(peak(in: spec, near: f * tuning.ratio), f * tuning.ratio, accuracy: 0.15)
            }
            let snr = chordSNR(spec, chord.map { $0 * tuning.ratio })
            let tpSNR = chordSNR(spectrum(try renderTimePitch(sine(chord, seconds: 4, amp: 0.25), seconds: 4, cents: tuning.cents)),
                                 chord.map { $0 * tuning.ratio })
            print("Stimmung \(tuning.rawValue): Akkord-Störabstand \(f1(snr)) dB (TimePitch \(f1(tpSNR)) dB)")
            XCTAssertGreaterThan(snr, 30)
        }
    }

    /// Tempo unverändert: Tonstoß von 1,0 s bis 3,0 s bleibt 2,0 s lang; gleich viele Samples heraus wie hinein.
    func testTempoUnchanged() throws {
        for tuning in Tuning.allCases {
            let buf = sine([440], seconds: 5)
            let n = Int(buf.frameLength)
            for ch in 0..<2 {
                let p = buf.floatChannelData![ch]
                for i in 0..<n where i < Int(1.0 * rate) || i >= Int(3.0 * rate) { p[i] = 0 }
            }
            let chain = PitchChain(tuning: tuning)
            let out = try render(buf, seconds: 5, chain: chain)[0]
            XCTAssertEqual(out.count, n)
            let thr: Float = 0.1
            let win = Int(0.005 * rate)
            var env: [Float] = []
            stride(from: 0, to: out.count - win, by: win).forEach { i in
                env.append(out[i..<(i + win)].map { abs($0) }.max() ?? 0)
            }
            guard let on = env.firstIndex(where: { $0 > thr }), let off = env.lastIndex(where: { $0 > thr }) else { return XCTFail("kein Signal") }
            let dur = Double(off - on + 1) * Double(win) / rate
            let latency = Double(on * win) / rate - 1.0
            print("Stimmung \(tuning.rawValue): Tonstoß 2,000 s → \(f3(dur)) s, Latenz \(f3(latency)) s (Kette \(f3(Double(chain.latencyFrames) / rate)) s)")
            XCTAssertEqual(dur, 2.0, accuracy: 0.03)
            XCTAssertEqual(latency, Double(chain.latencyFrames) / rate, accuracy: 0.03)
        }
    }

    /// Begrenzer: übersteuertes Eingangssignal bleibt unter 0 dBFS.
    func testLimiterPreventsClipping() throws {
        let out = try render(sine([440, 660], seconds: 3, amp: 0.95), seconds: 3, tuning: .hz432)
        let peak = out.map { abs($0) }.max() ?? 0
        print("Stimmung 432: Spitzenpegel nach Begrenzer \(f3(Double(peak)))")
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    /// Bearbeitet bei 0 Halbtönen liegt zeitgleich zum (verzögerten) Original – Voraussetzung für das
    /// Überblenden ohne Auslöschung.
    func testProcessedPathIsAlignedWithOriginal() throws {
        let input = sine([220, 330, 440, 550], seconds: 3, amp: 0.15)
        let chain = PitchChain(tuning: .hz432)
        chain.shifter.semitones = 0
        let out = try render(input, seconds: 3, chain: chain)[0]
        let lat = chain.latencyFrames
        let src = UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength))
        var best = (lag: 0, corr: -1.0)
        for lag in (lat - 200)...(lat + 200) {
            var dot = 0.0, e1 = 0.0, e2 = 0.0
            for i in stride(from: Int(rate), to: Int(2.5 * rate), by: 1) {
                let a = Double(out[i]), b = Double(src[i - lag])
                dot += a * b; e1 += a * a; e2 += b * b
            }
            let c = dot / sqrt(e1 * e2)
            if c > best.corr { best = (lag, c) }
        }
        print("Ausrichtung: bearbeitet (0 Halbtöne) ↔ Original Versatz \(best.lag - lat) Frames, Korrelation \(String(format: "%.4f", best.corr))")
        XCTAssertLessThanOrEqual(abs(best.lag - lat), 2)
        XCTAssertGreaterThan(best.corr, 0.98)
    }

    /// Live umschalten 432 → 528 → 440 → 432 mitten im Ton: keine Lücke (Hüllkurve), kein Knacken
    /// (kein Sprung zwischen Nachbar-Samples), danach jeweils die richtige Frequenz.
    func testLiveSwitchWithoutGap() throws {
        let seg = 2.5
        let plan: [(at: Double, tuning: Tuning)] = [(seg, .hz528), (2 * seg, .hz440), (3 * seg, .hz432)]
        let total = 4 * seg
        // Klang mit Obertönen (440 Hz am stärksten), Summe ≈ 0,5 Spitze
        let partials = [220.0, 440, 660, 880, 1320, 1760]
        let amps: [Float] = [0.06, 0.2, 0.08, 0.06, 0.05, 0.05]
        let input = sine([], seconds: total)
        for (f, a) in zip(partials, amps) {
            for i in 0..<Int(input.frameLength) {
                let v = a * Float(sin(2 * .pi * f * Double(i) / rate))
                input.floatChannelData![0][i] += v; input.floatChannelData![1][i] += v
            }
        }
        let chain = PitchChain(tuning: .hz432)
        var active: [Bool] = []
        let out = try render(input, seconds: total, chain: chain) { t in
            for p in plan where t >= p.at && t < p.at + 4096 / self.rate { chain.apply(p.tuning) }
            active.append(chain.shifter.processingActive)
        }[0]
        let lat = chain.latencyFrames
        // Frequenz je Abschnitt (nach dem Einschwingen)
        let expected: [Double] = [432, 444, 440, 432]
        for (k, want) in expected.enumerated() {
            let start = Int((Double(k) * seg + 0.6) * rate) + lat
            let m = measure(Array(out[start..<(start + 80_000)]))
            print("Live-Umschalten: Abschnitt \(k + 1) → \(f3(m.freq)) Hz (Soll \(want))")
            XCTAssertEqual(m.freq, want, accuracy: 0.15)
        }
        // Hüllkurve in 10-ms-Fenstern ab Ende der Anlaufzeit
        let win = Int(0.01 * rate)
        var minRMS = Float.greatestFiniteMagnitude, maxRMS: Float = 0
        for i in stride(from: lat + Int(0.3 * rate), to: out.count - win, by: win) {
            var rms: Float = 0
            vDSP_rmsqv(Array(out[i..<(i + win)]), 1, &rms, vDSP_Length(win))
            minRMS = min(minRMS, rms); maxRMS = max(maxRMS, rms)
        }
        // Größter Sprung zwischen Nachbar-Samples im Vergleich zum unbearbeiteten Eingang
        var maxStep: Float = 0, inStep: Float = 0
        for i in (lat + Int(0.3 * rate))..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        for i in 1..<Int(input.frameLength) { inStep = max(inStep, abs(input.floatChannelData![0][i] - input.floatChannelData![0][i - 1])) }
        var nominal: Float = 0
        vDSP_rmsqv(input.floatChannelData![0], 1, &nominal, vDSP_Length(input.frameLength))
        print("Live-Umschalten: Hüllkurve \(f3(Double(minRMS / nominal)))…\(f3(Double(maxRMS / nominal))) × Soll, größter Sample-Sprung \(String(format: "%.4f", maxStep)) (Eingang \(String(format: "%.4f", inStep)))")
        XCTAssertGreaterThan(minRMS / nominal, 0.6, "keine Lücke beim Umschalten")
        XCTAssertLessThan(maxRMS / nominal, 1.4)
        XCTAssertLessThan(maxStep, inStep * 1.3, "kein Knacken")
        // Im 440-Abschnitt rechnet der Stretcher nach der Überblendung nicht mehr
        let mid = Int((2.5 * seg) * rate / 4096)
        XCTAssertFalse(active[mid], "Original: Stretcher aus")
        XCTAssertTrue(active.last ?? false)
    }

    /// Grobe Rechenzeit im Simulator (Mac-CPU): Anteil der Echtzeit für Musik-ähnliches Signal.
    func testCPULoad() throws {
        let seconds = 30.0
        let input = sine([110, 220, 261.63, 329.63, 392, 880, 1760, 3520], seconds: seconds, amp: 0.08)
        var seed: UInt64 = 7
        for i in 0..<Int(input.frameLength) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed >> 11) % 1000) / 20_000
            input.floatChannelData![0][i] += noise
            input.floatChannelData![1][i] += noise * 0.7
        }
        func load(_ body: () throws -> Void) rethrows -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            try body()
            return (CFAbsoluteTimeGetCurrent() - t0) / seconds * 100
        }
        _ = try render(input, seconds: 2, tuning: .hz432) // Aufwärmen
        let ss = try load { _ = try render(input, seconds: seconds, tuning: .hz432) }
        let orig = try load { _ = try render(input, seconds: seconds, tuning: .hz440) }
        let tp = try load { _ = try renderTimePitch(input, seconds: seconds, cents: Tuning.hz432.cents) }
        print("CPU (Simulator, ein Kern, inkl. Engine-Overhead): signalsmith \(String(format: "%.2f", ss)) % · Original \(String(format: "%.2f", orig)) % · TimePitch \(String(format: "%.2f", tp)) %")
        XCTAssertLessThan(ss, 15)
    }

    // MARK: Hilfen

    func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    func sine(_ freqs: [Double], seconds: Double, amp: Float = 0.5) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let n = AVAudioFrameCount(seconds * rate)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        for i in 0..<Int(n) {
            var v: Float = 0
            for f in freqs { v += amp * Float(sin(2 * .pi * f * Double(i) / rate)) }
            b.floatChannelData![0][i] = v
            b.floatChannelData![1][i] = v
        }
        return b
    }

    /// Offline durch die Kette der App rendern (linker Kanal).
    func render(_ input: AVAudioPCMBuffer, seconds: Double, tuning: Tuning = .hz432) throws -> [Float] {
        try render(input, seconds: seconds, chain: PitchChain(tuning: tuning))[0]
    }

    /// Offline rendern mit beliebiger Kette in Blöcken zu `chunk` Frames; `each` läuft vor jedem Block (Startzeit in Sekunden).
    func render(_ input: AVAudioPCMBuffer, seconds: Double, chain: PitchChain, channels: Int = 1, chunk: Int = 4096,
                each: ((Double) -> Void)? = nil) throws -> [[Float]] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        chain.attach(to: engine, player: player, format: fmt)
        return try renderOffline(engine: engine, player: player, input: input, seconds: seconds, channels: channels, chunk: chunk, each: each)
    }

    /// Vergleich: Apples AVAudioUnitTimePitch (Overlap 32), wie in HomeTune 1.0.
    func renderTimePitch(_ input: AVAudioPCMBuffer, seconds: Double, cents: Double) throws -> [Float] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let tp = AVAudioUnitTimePitch()
        tp.pitch = Float(cents); tp.rate = 1; tp.overlap = 32
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        engine.attach(player); engine.attach(tp)
        engine.connect(player, to: tp, format: fmt)
        engine.connect(tp, to: engine.mainMixerNode, format: fmt)
        return try renderOffline(engine: engine, player: player, input: input, seconds: seconds, channels: 1, chunk: 4096, each: nil)[0]
    }

    private func renderOffline(engine: AVAudioEngine, player: AVAudioPlayerNode, input: AVAudioPCMBuffer, seconds: Double,
                               channels: Int, chunk: Int, each: ((Double) -> Void)?) throws -> [[Float]] {
        try engine.start()
        player.scheduleBuffer(input)
        player.play()
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var samples = [[Float]](repeating: [], count: channels)
        let total = Int(seconds * rate)
        samples[0].reserveCapacity(total + 4096)
        while samples[0].count < total {
            each?(Double(samples[0].count) / rate)
            let want = AVAudioFrameCount(min(chunk, total - samples[0].count))
            let st = try engine.renderOffline(want, to: out)
            guard st == .success else { break }
            for ch in 0..<channels {
                samples[ch] += UnsafeBufferPointer(start: out.floatChannelData![ch], count: Int(out.frameLength))
            }
        }
        engine.stop()
        return samples
    }

    /// Betrags-Spektrum (Hann-Fenster) über 65536 Werte aus der Mitte.
    func spectrum(_ x: [Float]) -> [Float] {
        let n = 65536
        let start = max(0, (x.count - n) / 2)
        var frame = Array(x[start..<min(x.count, start + n)])
        if frame.count < n { frame += [Float](repeating: 0, count: n - frame.count) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP.multiply(frame, window, result: &frame)
        let dft = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
        let zeros = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        dft.transform(inputReal: frame, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
        return (0..<n / 2).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }

    func binHz() -> Double { rate / 65536 }

    /// Spitze mit parabolischer Interpolation (log-Betrag) nahe `f` (± 5 Hz).
    func peak(in spec: [Float], near f: Double) -> Double {
        let c = Int(f / binHz())
        let lo = max(1, c - Int(5 / binHz())), hi = min(spec.count - 2, c + Int(5 / binHz()))
        let k = (lo...hi).max { spec[$0] < spec[$1] }!
        return interpolate(spec, k)
    }

    func interpolate(_ spec: [Float], _ k: Int) -> Double {
        let a = log(Double(spec[k - 1]) + 1e-20), b = log(Double(spec[k]) + 1e-20), c = log(Double(spec[k + 1]) + 1e-20)
        let d = 0.5 * (a - c) / (a - 2 * b + c)
        return (Double(k) + d) * binHz()
    }

    /// Frequenz der stärksten Spitze und Störabstand (Energie der Spitze ± 12 Bins zu allem anderen).
    /// `single: false` = nur die Frequenz zählt (Störabstand bedeutungslos).
    func measure(_ x: [Float], single: Bool = true) -> (freq: Double, snr: Double) {
        let spec = spectrum(x)
        let k = (2..<spec.count - 1).max { spec[$0] < spec[$1] }!
        let band = max(2, k - 12)...min(spec.count - 1, k + 12)
        let signal = band.reduce(0.0) { $0 + Double(spec[$1]) }
        let total = spec.dropFirst(2).reduce(0.0) { $0 + Double($1) }
        return (interpolate(spec, k), 10 * log10(signal / max(1e-30, total - signal)))
    }

    /// Störabstand eines Akkords: Energie um alle Soll-Teiltöne (± 12 Bins) zum Rest.
    func chordSNR(_ spec: [Float], _ freqs: [Double]) -> Double {
        var inBand = Set<Int>()
        for f in freqs {
            let k = Int((f / binHz()).rounded())
            for b in max(2, k - 12)...min(spec.count - 1, k + 12) { inBand.insert(b) }
        }
        var signal = 0.0, rest = 0.0
        for b in 2..<spec.count { if inBand.contains(b) { signal += Double(spec[b]) } else { rest += Double(spec[b]) } }
        return 10 * log10(signal / max(1e-30, rest))
    }
}
