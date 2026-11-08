import XCTest
import AVFoundation
import Accelerate
@testable import HomeSpin

/// Klangprüfung der 432-Hz-Kette: Sinus durch genau dieselbe Kette (TimePitch + Limiter) rendern
/// und per FFT messen. 440 Hz muss 432 Hz ergeben, das Tempo muss gleich bleiben.
final class Tuning432Tests: XCTestCase {
    let rate = 48000.0

    func testCentsValue() {
        XCTAssertEqual(Double(Tuning432.cents), 1200 * log2(432.0 / 440.0), accuracy: 1e-4)
        XCTAssertEqual(Double(Tuning432.cents), -31.766, accuracy: 0.001)
    }

    func testSine440Becomes432() throws {
        let out = try render(sine([440], seconds: 4), seconds: 4)
        let m = measure(out)
        print("432-Messung: 440 Hz → \(String(format: "%.3f", m.freq)) Hz, Störabstand \(String(format: "%.1f", m.snr)) dB")
        XCTAssertEqual(m.freq, 432.0, accuracy: 0.1)
        XCTAssertGreaterThan(m.snr, 40, "kaum Nebengeräusche/Artefakte")
    }

    func testOtherFrequenciesScaleByRatio() throws {
        for f in [110.0, 1000.0, 4000.0] {
            let m = measure(try render(sine([f], seconds: 4), seconds: 4))
            print("432-Messung: \(f) Hz → \(String(format: "%.3f", m.freq)) Hz (Soll \(String(format: "%.3f", f * Tuning432.ratio))), Störabstand \(String(format: "%.1f", m.snr)) dB")
            XCTAssertEqual(m.freq, f * Tuning432.ratio, accuracy: max(0.1, f * 0.0003))
            XCTAssertGreaterThan(m.snr, 35)
        }
    }

    /// Akkord: Teiltöne dürfen nicht verschmieren (Intermodulation klein).
    func testChordStaysClean() throws {
        let out = try render(sine([261.63, 329.63, 392.0], seconds: 4, amp: 0.25), seconds: 4)
        let spec = spectrum(out)
        for f in [261.63, 329.63, 392.0] {
            let got = peak(in: spec, near: f * Tuning432.ratio)
            XCTAssertEqual(got, f * Tuning432.ratio, accuracy: 0.15)
        }
    }

    /// Tempo unverändert: Tonstoß von 1,0 s bis 3,0 s bleibt 2,0 s lang.
    func testTempoUnchanged() throws {
        let buf = sine([440], seconds: 5)
        let n = Int(buf.frameLength)
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<n where i < Int(1.0 * rate) || i >= Int(3.0 * rate) { p[i] = 0 }
        }
        let out = try render(buf, seconds: 5)
        let thr: Float = 0.1
        // Hüllkurve über 5-ms-Fenster
        let win = Int(0.005 * rate)
        var env: [Float] = []
        stride(from: 0, to: out.count - win, by: win).forEach { i in
            env.append(out[i..<(i + win)].map { abs($0) }.max() ?? 0)
        }
        guard let on = env.firstIndex(where: { $0 > thr }), let off = env.lastIndex(where: { $0 > thr }) else { return XCTFail("kein Signal") }
        let dur = Double(off - on + 1) * Double(win) / rate
        print("432-Messung: Tonstoß 2,000 s → \(String(format: "%.3f", dur)) s, Latenz \(String(format: "%.3f", Double(on * win) / rate - 1.0)) s")
        XCTAssertEqual(dur, 2.0, accuracy: 0.03)
        XCTAssertEqual(Tuning432.overlap, PitchChain().timePitch.overlap)
        XCTAssertEqual(PitchChain().timePitch.rate, 1)
    }

    /// Limiter: übersteuertes Eingangssignal bleibt unter 0 dBFS.
    func testLimiterPreventsClipping() throws {
        let out = try render(sine([440, 660], seconds: 3, amp: 0.95), seconds: 3)
        let peak = out.map { abs($0) }.max() ?? 0
        print("432-Messung: Spitzenpegel nach Limiter \(String(format: "%.3f", peak))")
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    // MARK: Hilfen

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

    /// Offline durch PitchChain rendern (gleiche Kette wie in der App), linker Kanal.
    func render(_ input: AVAudioPCMBuffer, seconds: Double) throws -> [Float] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let chain = PitchChain()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        chain.attach(to: engine, player: player, format: fmt)
        try engine.start()
        player.scheduleBuffer(input)
        player.play()
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var samples: [Float] = []
        let total = Int(seconds * rate)
        while samples.count < total {
            let st = try engine.renderOffline(4096, to: out)
            guard st == .success else { break }
            samples += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
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
    func measure(_ x: [Float]) -> (freq: Double, snr: Double) {
        let spec = spectrum(x)
        let k = (2..<spec.count - 1).max { spec[$0] < spec[$1] }!
        let band = max(2, k - 12)...min(spec.count - 1, k + 12)
        let signal = band.reduce(0.0) { $0 + Double(spec[$1]) }
        let total = spec.dropFirst(2).reduce(0.0) { $0 + Double($1) }
        return (interpolate(spec, k), 10 * log10(signal / max(1e-30, total - signal)))
    }
}
