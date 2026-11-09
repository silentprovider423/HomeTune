import XCTest
import AVFoundation
#if os(iOS)
@testable import HomeTune
#endif

/// Live-Wiedergabe im Simulator: lückenloser Übergang zum vorgeladenen Titel, Ende der Warteliste,
/// Position, Springen – und eine echte FLAC-Datei vom Testserver.
@MainActor
final class PlaybackEngineTests: XCTestCase {
    private func makeWAV(freq: Double, seconds: Double, rate: Double = 44100, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "t-\(Int(freq))-\(UUID().uuidString.prefix(4)).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = AVAudioFrameCount(seconds * rate)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        for ch in 0..<Int(channels) { for i in 0..<Int(n) { b.floatChannelData![ch][i] = 0.3 * Float(sin(2 * .pi * freq * Double(i) / rate)) } }
        try file.write(from: b)
        return url
    }

    private func activate() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    func testGaplessTransitionAndQueueEnd() async throws {
        try activate()
        let a = try makeWAV(freq: 440, seconds: 1.5)               // Mono 44,1 kHz
        let b = try makeWAV(freq: 660, seconds: 1.5, rate: 96000, channels: 2) // Stereo 96 kHz
        let engine = PlaybackEngine()
        engine.tuning = .hz432
        XCTAssertEqual(engine.pitchCents, Tuning.hz432.cents, accuracy: 1e-3)
        XCTAssertEqual(engine.tempoRate, 1)
        let started = expectation(description: "Folgetitel beginnt")
        let ended = expectation(description: "Ende")
        var startedAt: Date?
        let t0 = Date()
        engine.onTrackStarted = { token in
            XCTAssertEqual(token, 2)
            startedAt = Date()
            started.fulfill()
        }
        engine.onQueueEnded = { token in
            XCTAssertEqual(token, 2)
            ended.fulfill()
        }
        engine.onError = { _, e in XCTFail("\(e)") }
        engine.load(url: a, token: 1, autoplay: true)
        engine.setNext(url: b, token: 2)
        await fulfillment(of: [started], timeout: 6)
        let gap = startedAt!.timeIntervalSince(t0)
        print("Gapless: Folgetitel nach \(String(format: "%.2f", gap)) s (Titel A: 1,50 s)")
        XCTAssertEqual(gap, 1.5, accuracy: 0.45)
        XCTAssertEqual(engine.currentToken, 2)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(engine.currentTime, 0.2)
        await fulfillment(of: [ended], timeout: 6)
        XCTAssertFalse(engine.isPlaying)
    }

    func testSeekAndPause() async throws {
        try activate()
        let a = try makeWAV(freq: 440, seconds: 6)
        let engine = PlaybackEngine()
        engine.load(url: a, token: 7, autoplay: true)
        try await Task.sleep(for: .milliseconds(600))
        engine.seek(to: 4)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(engine.currentTime, 4.4, accuracy: 0.3)
        engine.pause()
        let p = engine.currentTime
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(engine.currentTime, p, accuracy: 0.05)
        engine.stop()
    }

    /// Stimmung live umschalten (432 → 528 → 440 → 432): Wiedergabe läuft ohne Unterbrechung weiter, Position zählt
    /// gleichmäßig, im Original rechnet der Stretcher nicht.
    func testLiveTuningSwitchKeepsPlaying() async throws {
        try activate()
        let a = try makeWAV(freq: 440, seconds: 5, rate: 48000, channels: 2)
        let engine = PlaybackEngine()
        engine.tuning = .hz432
        var failed: Error?
        engine.onError = { _, e in failed = e }
        engine.load(url: a, token: 3, autoplay: true)
        try await Task.sleep(for: .milliseconds(600))
        var times: [Double] = [engine.currentTime]
        for t in [Tuning.hz528, .hz440, .hz432] {
            engine.tuning = t
            XCTAssertEqual(engine.tuning, t)
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertTrue(engine.isPlaying)
            times.append(engine.currentTime)
            if t == .hz440 { XCTAssertFalse(engine.chain.shifter.processingActive, "Original: keine Bearbeitung") }
        }
        XCTAssertNil(failed)
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }
        print("Live-Umschalten (Engine): Position \(times.map { String(format: "%.2f", $0) }), Schritte \(steps.map { String(format: "%.2f", $0) }) s")
        for d in steps { XCTAssertEqual(d, 0.7, accuracy: 0.25, "Position läuft gleichmäßig weiter") }
        XCTAssertEqual(engine.pitchCents, Tuning.hz432.cents, accuracy: 1e-3)
        engine.stop()
    }

    /// Echte FLAC-Datei (Hi-Res, falls vorhanden) aus der Bibliothek „Privat“ live abspielen.
    func testPlayPrivateFlacLive() async throws {
        let c = try SubsonicClientTests.client()
        guard let privat = try await c.musicFolders().first(where: { $0.name == "Privat" }) else { throw XCTSkip("Keine Bibliothek „Privat“") }
        guard let flac = try await c.allSongs(folder: privat.id).filter({ $0.suffix == "flac" }).max(by: { ($0.bitDepth ?? 0, $0.samplingRate ?? 0) < ($1.bitDepth ?? 0, $1.samplingRate ?? 0) }) else {
            throw XCTSkip("Keine FLAC-Datei")
        }
        let url = try await TrackCache.shared.file(for: flac, client: c)
        try activate()
        let engine = PlaybackEngine()
        var failed: Error?
        engine.onError = { _, e in failed = e }
        engine.load(url: url, token: 1, at: 20, autoplay: true)
        try await Task.sleep(for: .seconds(3))
        XCTAssertNil(failed)
        XCTAssertTrue(engine.isPlaying)
        print("FLAC live: \(flac.formatBadge ?? "?"), Position nach 3 s: \(String(format: "%.2f", engine.currentTime)) s (Start 20 s)")
        XCTAssertEqual(engine.currentTime, 23, accuracy: 0.6)
        engine.stop()
    }
}
