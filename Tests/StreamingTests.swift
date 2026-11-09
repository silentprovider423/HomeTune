import XCTest
import AVFoundation
import os
@testable import HomeTune

/// Streaming vom Server über eine gedrosselte Leitung (URLProtocol, 10 Mbit/s, kurze Aussetzer, Verbindungsabbrüche):
/// Wiedergabe beginnt nach wenigen Sekunden statt nach dem kompletten Download, läuft ohne Stocken, setzt nach Abbrüchen
/// per Range fort und liefert bit-gleich dieselben Samples wie die fertige Datei.
@MainActor
final class StreamingTests: XCTestCase {
    private var fixture: URL {
        get throws { try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)).appending(path: "Stream/hires.flac") }
    }

    override func setUp() async throws {
        TrackCache.makeStreamConfiguration = {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [ThrottleProtocol.self]
            c.timeoutIntervalForRequest = 15
            return c
        }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        try AVAudioSession.sharedInstance().setActive(true)
    }

    override func tearDown() async throws {
        await TrackCache.shared.keepLoading(only: [])
        ThrottleProtocol.plan = nil
        TrackCache.makeStreamConfiguration = {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 15
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return c
        }
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "Tracks/stream-test"))
    }

    /// Ohne Netz: Konto zeigt auf eine Adresse, die nur die gedrosselte Leitung beantwortet.
    private func offlineClient() -> SubsonicClient {
        SubsonicClient(account: ServerAccount(id: "stream-test", server: URL(string: "http://stream.invalid:4533")!, username: "t"), password: "x")
    }

    private func song(_ id: String, duration: Int = 10) -> Song {
        Song(id: id, title: "Static Bloom", duration: duration, suffix: "flac")
    }

    private func decodeAll(_ d: TrackDecoder) -> [Float] {
        var out: [Float] = []
        while case .data(let b) = d.next(frames: 16384) {
            for i in 0..<Int(b.frameLength) { out.append(b.floatChannelData![0][i]); out.append(b.floatChannelData![1][i]) }
        }
        return out
    }

    /// Lesen, während die Datei wächst (inkl. Resampler 96 → 48 kHz), ergibt exakt dieselben Samples wie die fertige Datei.
    func testProgressiveDecodeIsBitIdentical() throws {
        let src = try fixture
        let all = try Data(contentsOf: src)
        for rate in [48000.0, 96000.0] {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let reference = decodeAll(try TrackDecoder(url: src, outFormat: fmt))
            XCTAssertGreaterThan(reference.count, Int(rate) * 2 * 9)

            let dir = FileManager.default.temporaryDirectory.appending(path: "grow-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let part = dir.appending(path: "t.flac.part"), final = dir.appending(path: "t.flac")
            var written = 0
            func grow(_ n: Int) throws {
                let end = min(all.count, written + n)
                let h = try FileHandle(forWritingTo: part)
                try h.seekToEnd(); try h.write(contentsOf: all.subdata(in: written..<end)); try h.close()
                written = end
            }
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let source = TrackSource(url: part, progressive: true, complete: false)
            func publish() throws {
                if written == all.count {
                    try FileManager.default.moveItem(at: part, to: final)
                    let w = Int64(written)
                    source.update { $0.url = final; $0.bytes = w; $0.total = w; $0.complete = true }
                } else {
                    let w = Int64(written)
                    source.update { $0.bytes = w }
                }
            }
            try grow(20_000); try publish()
            var dec: TrackDecoder?
            var waits = 0
            while dec == nil {
                dec = try TrackDecoder.open(source: source, outFormat: fmt)
                if dec == nil { waits += 1; try grow(40_000); try publish() }
            }
            var out: [Float] = []
            var blocked = 0
            loop: while true {
                switch dec!.next(frames: 16384) {
                case .data(let b):
                    for i in 0..<Int(b.frameLength) { out.append(b.floatChannelData![0][i]); out.append(b.floatChannelData![1][i]) }
                case .wait:
                    blocked += 1
                    try grow(300_000); try publish()
                case .end:
                    break loop
                }
            }
            print("Fortlaufend lesen @\(Int(rate)) Hz: \(waits)× auf den Kopf gewartet, \(blocked)× an der Datengrenze gewartet, \(out.count / 2) Frames")
            XCTAssertGreaterThan(blocked, 5, "Datei war beim Lesen wirklich unvollständig")
            XCTAssertEqual(out.count, reference.count)
            XCTAssertTrue(out == reference, "bit-gleich zur fertigen Datei")
        }
    }

    /// Abbruch der Verbindung zweimal mitten im Laden: es geht per Range an derselben Stelle weiter, Datei ist am Ende identisch.
    func testDownloadResumesWithRangeAfterDropouts() async throws {
        let data = try Data(contentsOf: try fixture)
        ThrottleProtocol.plan = .init(data: data, bitsPerSecond: 80_000_000, stalls: [3_000_000: 0.5], aborts: [1_000_000, 2_500_000])
        let src = try await TrackCache.shared.source(for: song("resume-1"), client: offlineClient())
        XCTAssertFalse(src.isComplete)
        let url = try await src.waitUntilComplete()
        XCTAssertEqual(try Data(contentsOf: url), data, "identisch zum Original")
        XCTAssertEqual(url.pathExtension, "flac")
        let ranges = ThrottleProtocol.ranges
        print("Anfragen (Range): \(ranges)")
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.first, "")
        XCTAssertTrue(ranges.dropFirst().allSatisfy { $0.hasPrefix("bytes=") && !$0.hasPrefix("bytes=0-") }, "Fortsetzen statt neu laden")
        // Zweiter Aufruf kommt aus dem Cache
        let again = try await TrackCache.shared.source(for: song("resume-1"), client: offlineClient())
        XCTAssertTrue(again.isComplete)
    }

    /// 10 Mbit/s mit zwei Aussetzern (je 2 s Stillstand) und einem Verbindungsabbruch: Start nach wenigen Sekunden,
    /// danach kein einziger Aussetzer, keine stille Lücke, Position läuft gleichmäßig.
    func testStreamingAt10MbitPlaysWithoutStalls() async throws {
        let data = try Data(contentsOf: try fixture)
        ThrottleProtocol.plan = .init(data: data, bitsPerSecond: 10_000_000, stalls: [2_200_000: 2.0, 3_400_000: 2.0], aborts: [3_000_000])
        let r = try await playThrottled(song: song("stream-10"), client: offlineClient(), seconds: 9)
        print("10 Mbit/s (Testdatei 96 kHz/24 Bit, \(data.count / 1000) kB): erster Ton nach \(String(format: "%.2f", r.startDelay)) s (ganzer Download hätte ≥ \(String(format: "%.1f", Double(data.count) * 8 / 10_000_000 + 4)) s gedauert), Aussetzer \(r.rebuffers), stille Lücken \(r.gaps), Position \(String(format: "%.2f", r.position)) s")
        XCTAssertLessThan(r.startDelay, 3.0)
        XCTAssertEqual(r.rebuffers, 0)
        XCTAssertEqual(r.gaps, 0)
        XCTAssertEqual(r.position, 9 - r.startDelay, accuracy: 0.6)
    }

    /// Leitung langsamer als die Musik (2,4 Mbit/s bei ~3,4 Mbit/s FLAC): kein Stottern, sondern sauberes Anhalten und
    /// Weiterspielen; die Position springt nie und der Titel wird bis zum Ende gespielt.
    func testTooSlowNetworkPausesCleanlyAndFinishes() async throws {
        let data = try Data(contentsOf: try fixture)
        ThrottleProtocol.plan = .init(data: data, bitsPerSecond: 2_400_000, stalls: [:], aborts: [])
        let c = offlineClient()
        let src = try await TrackCache.shared.source(for: song("stream-slow"), client: c)
        let engine = PlaybackEngine()
        engine.startSeconds = 2
        engine.resumeSeconds = 2
        var bufferingEvents: [Bool] = []
        var errors: [Error] = []
        let ended = expectation(description: "Ende")
        engine.onBuffering = { _, b in bufferingEvents.append(b) }
        engine.onError = { _, e in errors.append(e) }
        engine.onQueueEnded = { _ in ended.fulfill() }
        engine.load(source: src, token: 1, autoplay: true)
        var last = 0.0, jumps = 0
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 40 {
            try await Task.sleep(for: .milliseconds(100))
            let t = engine.currentTime
            // rückwärts nie; vorwärts nur so weit, wie die Abfrage verzögert sein kann
            if t + 0.05 < last || t - last > 1.0 { jumps += 1 }
            last = t
            if !engine.isPlaying && src.isComplete && engine.stats.startDelay != nil && t > 9.5 { break }
        }
        await fulfillment(of: [ended], timeout: 20)
        let s = engine.stats
        print("2,4 Mbit/s: erster Ton nach \(String(format: "%.2f", s.startDelay ?? -1)) s, Anhalten zum Puffern \(s.rebuffers)×, Sprünge \(jumps), Ende bei \(String(format: "%.2f", engine.currentTime)) s")
        XCTAssertTrue(errors.isEmpty)
        XCTAssertGreaterThanOrEqual(s.rebuffers, 1, "musste puffern")
        XCTAssertEqual(jumps, 0, "Position springt nicht")
        XCTAssertEqual(bufferingEvents.first, true)
        XCTAssertEqual(bufferingEvents.last, false)
        XCTAssertEqual(engine.currentTime, 10, accuracy: 0.3)
        engine.stop()
    }

    /// Echter Hi-Res-Titel (96 kHz/24 Bit) vom Testserver über 10 Mbit/s mit zwei 2-s-Aussetzern und einem Abbruch.
    /// Der Titel wird zuerst ungedrosselt geholt (LAN) und dann von der gedrosselten Leitung ausgeliefert.
    func testRealHiResTrackOver10Mbit() async throws {
        let c = try SubsonicClientTests.client()
        let songs = try await c.allSongs()
        guard let hires = songs.filter({ $0.suffix == "flac" && ($0.samplingRate ?? 0) >= 88200 && ($0.size ?? 0) > 40_000_000 })
            .min(by: { ($0.size ?? 0) < ($1.size ?? 0) }) else { throw XCTSkip("Kein Hi-Res-FLAC auf dem Testserver") }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hires-\(UUID().uuidString).flac")
        try await TrackCache.fetch(c.streamRequest(id: hires.id, format: "raw"), client: c, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = try Data(contentsOf: tmp)
        ThrottleProtocol.plan = .init(data: data, bitsPerSecond: 10_000_000, stalls: [4_000_000: 2.0, 12_000_000: 2.0], aborts: [8_000_000])
        let offline = SubsonicClient(account: ServerAccount(id: "stream-test", server: c.account.server, username: "t"), password: "x")
        let r = try await playThrottled(song: hires, client: offline, seconds: 20)
        let full = Double(data.count) * 8 / 10_000_000
        print("Echter Titel \(hires.formatBadge ?? "?"), \(data.count / 1_000_000) MB über 10 Mbit/s: erster Ton nach \(String(format: "%.2f", r.startDelay)) s (vorher: kompletter Download ≈ \(String(format: "%.0f", full)) s), Aussetzer \(r.rebuffers), stille Lücken \(r.gaps), Position \(String(format: "%.2f", r.position)) s, geladen \(String(format: "%.0f", r.loadedFraction * 100)) %")
        XCTAssertLessThan(r.startDelay, 4.0)
        XCTAssertEqual(r.rebuffers, 0)
        XCTAssertEqual(r.gaps, 0)
        XCTAssertLessThan(r.loadedFraction, 1, "spielt, bevor die Datei ganz da ist")
        XCTAssertEqual(r.position, 20 - r.startDelay, accuracy: 0.8)
    }

    private struct Result { var startDelay: Double; var rebuffers: Int; var gaps: Int; var position: Double; var loadedFraction: Double }

    private func playThrottled(song: Song, client: SubsonicClient, seconds: Double) async throws -> Result {
        let t0 = Date()
        let src = try await TrackCache.shared.source(for: song, client: client)
        XCTAssertFalse(src.isComplete)
        let engine = PlaybackEngine()
        let gaps = GapCounter()
        gaps.install(on: engine.engine.mainMixerNode)
        var failed: Error?
        engine.onError = { _, e in failed = e }
        engine.load(source: src, token: 1, autoplay: true)
        var startDelay: Double?
        while Date().timeIntervalSince(t0) < seconds {
            try await Task.sleep(for: .milliseconds(50))
            if startDelay == nil, engine.isPlaying { startDelay = Date().timeIntervalSince(t0) }
        }
        engine.engine.mainMixerNode.removeTap(onBus: 0)
        let s = src.snapshot
        let r = Result(startDelay: startDelay ?? 99, rebuffers: engine.stats.rebuffers, gaps: gaps.gaps, position: engine.currentTime,
                       loadedFraction: Double(s.bytes) / Double(max(1, s.total ?? 1)))
        XCTAssertNil(failed)
        engine.stop()
        return r
    }
}

/// Zählt digitale Stille (≥ 20 ms beide Kanäle exakt 0) im Ausgang – eine Lücke = Stocken.
final class GapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var run = 0, started = false
    private(set) var gaps = 0
    /// Nicht MainActor-gebunden: der Tap läuft auf einem Audio-Thread
    nonisolated func install(on node: AVAudioNode) {
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { [self] b, _ in feed(b) }
    }
    private func feed(_ b: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let d = b.floatChannelData else { return }
        let n = Int(b.frameLength), rate = Int(b.format.sampleRate), r = min(1, Int(b.format.channelCount) - 1)
        for i in 0..<n {
            if d[0][i] == 0 && d[r][i] == 0 { run += 1; continue }
            if started && run >= rate / 50 { gaps += 1 }
            run = 0
            started = true
        }
    }
}

/// Gedrosselte Leitung für `rest/stream`: liefert vorgegebene Bytes mit fester Rate, beachtet Range, hält an
/// bestimmten Stellen kurz an (Stillstand) oder bricht die Verbindung einmalig ab.
final class ThrottleProtocol: URLProtocol, @unchecked Sendable {
    struct Plan {
        var data: Data
        var bitsPerSecond: Double
        /// Byte-Stelle → Stillstand in Sekunden (je einmal)
        var stalls: [Int: Double]
        /// Byte-Stellen, an denen die Verbindung einmal abreißt
        var aborts: Set<Int>
    }
    private static let state = OSAllocatedUnfairLock<(plan: Plan?, ranges: [String])>(initialState: (nil, []))
    static var plan: Plan? {
        get { state.withLock { $0.plan } }
        set { state.withLock { $0 = (newValue, []) } }
    }
    static var ranges: [String] { state.withLock { $0.ranges } }

    private let q = DispatchQueue(label: "throttle")
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.path.hasSuffix("/rest/stream") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        guard let plan = Self.state.withLock({ s -> Plan? in s.ranges.append(range); return s.plan }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let total = plan.data.count
        var start = 0
        if range.hasPrefix("bytes="), let a = Int(range.dropFirst(6).split(separator: "-").first ?? "") { start = a }
        let headers = ["Content-Type": "audio/flac", "Content-Length": "\(total - start)", "Accept-Ranges": "bytes"]
            .merging(start > 0 ? ["Content-Range": "bytes \(start)-\(total - 1)/\(total)"] : [:]) { a, _ in a }
        let resp = HTTPURLResponse(url: request.url!, statusCode: start > 0 ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        let p = Pace(data: plan.data, offset: start, interval: Double(16 * 1024 * 8) / plan.bitsPerSecond)
        q.async { self.step(p) }
    }

    /// Fortschritt einer Auslieferung (nur auf `q`)
    private final class Pace: @unchecked Sendable {
        let data: Data, interval: Double
        var offset: Int
        init(data: Data, offset: Int, interval: Double) { self.data = data; self.offset = offset; self.interval = interval }
    }

    private func step(_ p: Pace) {
        guard !stopped else { return }
        let total = p.data.count
        if p.offset >= total { client?.urlProtocolDidFinishLoading(self); return }
        let end = min(total, p.offset + 16 * 1024)
        // Einmaliger Abbruch bzw. Stillstand, wenn diese Stelle überschritten wird
        if let a = Self.consume(abortIn: p.offset..<end) {
            let piece = p.data.subdata(in: p.offset..<a)
            if !piece.isEmpty { client?.urlProtocol(self, didLoad: piece) }
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(self, didLoad: p.data.subdata(in: p.offset..<end))
        var wait = p.interval
        if let s = Self.consume(stallIn: p.offset..<end) { wait += s }
        p.offset = end
        q.asyncAfter(deadline: .now() + wait) { self.step(p) }
    }

    override func stopLoading() { q.async { self.stopped = true } }

    private static func consume(abortIn r: Range<Int>) -> Int? {
        state.withLock { s in
            guard let a = s.plan?.aborts.first(where: { r.contains($0) }) else { return nil }
            s.plan?.aborts.remove(a)
            return a
        }
    }

    private static func consume(stallIn r: Range<Int>) -> Double? {
        state.withLock { s in
            guard let k = s.plan?.stalls.keys.first(where: { r.contains($0) }) else { return nil }
            return s.plan?.stalls.removeValue(forKey: k)
        }
    }
}
