import AVFoundation
import os

/// Wiedergabe-Motor: AVAudioEngine mit Stimmungs-Kette (432/440/528 Hz, live umschaltbar), lückenlosem Übergang zum vorgeladenen
/// Folgetitel und eigenem Puffer-Zubringer (wie Apples „AssetSlidingQueue“, nur kleiner).
///
/// Jeder Titel bekommt eine Marke (`token`). Der Zubringer plant immer nur ~1,5 s im Voraus ein; endet die
/// Datei, geht es ohne Pause mit dem vorgeladenen Folgetitel weiter. Rückmeldungen kommen auf dem Hauptthread.
final class PlaybackEngine: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    let chain = PitchChain()
    private(set) var format: AVAudioFormat

    /// Neuer Titel hat hörbar begonnen (am lückenlosen Übergang).
    var onTrackStarted: (@MainActor (Int) -> Void)?
    /// Letzter eingeplanter Titel ist zu Ende, kein Folgetitel da.
    var onQueueEnded: (@MainActor (Int) -> Void)?
    /// Datei ließ sich nicht öffnen.
    var onError: (@MainActor (Int, Error) -> Void)?

    private let q = DispatchQueue(label: "hometune.audio.feeder", qos: .userInitiated)
    private let chunkFrames: AVAudioFrameCount = 16384
    private let maxInFlight = 4

    // Zustand des Zubringers – nur auf `q`
    private var generation = 0
    private var current: (decoder: TrackDecoder, token: Int, url: URL)?
    private var pending: (url: URL, token: Int)?
    private var fifo: [Int] = []
    private var scheduledFrames: AVAudioFramePosition = 0
    private var starts: [Int: (frame: AVAudioFramePosition, offset: Double, duration: Double)] = [:]
    private var activeURL: [Int: URL] = [:]

    // Für die Positionsabfrage vom Hauptthread
    private struct Position { var token: Int = -1; var baseFrame: AVAudioFramePosition = 0; var offset: Double = 0; var duration: Double = 0 }
    private let pos = OSAllocatedUnfairLock(initialState: Position())
    private let playing = OSAllocatedUnfairLock(initialState: false)

    init() {
        let rate = AVAudioSession.sharedInstance().sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48000, channels: 2)!
        chain.attach(to: engine, player: player, format: format)
        engine.prepare()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    var isPlaying: Bool { playing.withLock { $0 } }
    var currentToken: Int { pos.withLock { $0.token } }
    /// Stimmung – Umschalten wirkt sofort, auch mitten im Titel
    var tuning: Tuning {
        get { chain.tuning }
        set { chain.apply(newValue) }
    }
    /// Tonhöhe in Cent (0 bei 440 Hz/Original)
    var pitchCents: Double { tuning.isOriginal ? 0 : Double(chain.shifter.semitones) * 100 }
    /// Tempo: signalsmith bekommt immer gleich viele Samples, wie es ausgibt (rate = 1)
    let tempoRate: Double = 1

    /// Aktuelle Position im laufenden Titel (Sekunden).
    var currentTime: Double {
        let p = pos.withLock { $0 }
        guard p.token >= 0 else { return 0 }
        guard isPlaying, let nodeTime = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nodeTime) else {
            return pausedTime ?? p.offset
        }
        let t = p.offset + Double(max(0, pt.sampleTime - p.baseFrame)) / format.sampleRate
        return p.duration > 0 ? min(t, p.duration) : t
    }
    private let pausedLock = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private var pausedTime: Double? {
        get { pausedLock.withLock { $0 } }
        set { pausedLock.withLock { $0 = newValue } }
    }

    // MARK: Steuerung (vom Hauptthread)

    /// Lädt einen Titel neu (alles Eingeplante wird verworfen) und spielt ab `seconds`.
    func load(url: URL, token: Int, at seconds: Double = 0, autoplay: Bool) {
        pausedTime = nil
        q.async { [self] in
            reset()
            do {
                let dec = try TrackDecoder(url: url, outFormat: format, startAt: seconds)
                current = (dec, token, url)
                starts[token] = (0, seconds, dec.duration)
                activeURL[token] = url
                pos.withLock { $0 = Position(token: token, baseFrame: 0, offset: seconds, duration: dec.duration) }
                pump()
                if autoplay { startPlayer() }
            } catch {
                notify { $0.onError?(token, error) }
            }
        }
        if !autoplay { pausedTime = seconds }
    }

    /// Folgetitel für den lückenlosen Übergang (nil = keiner). Ersetzt einen bisherigen Folgetitel.
    func setNext(url: URL?, token: Int) {
        q.async { [self] in
            pending = url.map { ($0, token) }
            pump()
        }
    }

    func play() {
        pausedTime = nil
        q.async { [self] in startPlayer() }
    }

    func pause() {
        pausedTime = currentTime
        q.async { [self] in
            player.pause()
            playing.withLock { $0 = false }
        }
    }

    func seek(to seconds: Double) {
        let p = pos.withLock { $0 }
        guard p.token >= 0 else { return }
        let wasPlaying = isPlaying
        if !wasPlaying { pausedTime = seconds }
        q.async { [self] in
            guard let url = activeURL[p.token] else { return }
            let next = pending
            reset()
            do {
                let dec = try TrackDecoder(url: url, outFormat: format, startAt: seconds)
                current = (dec, p.token, url)
                starts[p.token] = (0, seconds, dec.duration)
                activeURL[p.token] = url
                pending = next
                pos.withLock { $0 = Position(token: p.token, baseFrame: 0, offset: seconds, duration: dec.duration) }
                pump()
                if wasPlaying { startPlayer() }
            } catch {
                notify { $0.onError?(p.token, error) }
            }
        }
    }

    func stop() {
        pausedTime = nil
        q.async { [self] in
            reset()
            pos.withLock { $0 = Position() }
        }
    }

    // MARK: Zubringer (auf q)

    private func reset() {
        generation += 1
        player.stop()
        playing.withLock { $0 = false }
        current = nil
        pending = nil
        fifo.removeAll()
        scheduledFrames = 0
        starts.removeAll()
        activeURL.removeAll()
    }

    private func startPlayer() {
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.play()
        playing.withLock { $0 = true }
    }

    private func pump() {
        while fifo.count < maxInFlight {
            if current == nil {
                guard let p = pending else { break }
                pending = nil
                do {
                    let dec = try TrackDecoder(url: p.url, outFormat: format)
                    current = (dec, p.token, p.url)
                    starts[p.token] = (scheduledFrames, 0, dec.duration)
                    activeURL[p.token] = p.url
                } catch {
                    let t = p.token
                    notify { $0.onError?(t, error) }
                    continue
                }
            }
            guard let cur = current else { break }
            guard let buf = cur.decoder.read(frames: chunkFrames) else {
                current = nil
                continue
            }
            fifo.append(cur.token)
            scheduledFrames += AVAudioFramePosition(buf.frameLength)
            let gen = generation
            player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.q.async { self.bufferDone(generation: gen) }
            }
        }
        // Läuft der Spieler „leer“ weiter, obwohl nichts mehr kommt: Ende melden
        if fifo.isEmpty, current == nil, pending == nil, isPlaying {
            let t = pos.withLock { $0.token }
            if t >= 0 { finish(token: t) }
        }
    }

    private func bufferDone(generation gen: Int) {
        guard gen == generation, !fifo.isEmpty else { return }
        let finished = fifo.removeFirst()
        if let next = fifo.first {
            if next != finished, let s = starts[next] {
                pos.withLock { $0 = Position(token: next, baseFrame: s.frame, offset: s.offset, duration: s.duration) }
                starts[finished] = nil
                activeURL[finished] = nil
                notify { $0.onTrackStarted?(next) }
            }
        } else if current == nil && pending == nil {
            finish(token: finished)
            return
        }
        pump()
    }

    private func finish(token: Int) {
        player.stop()
        playing.withLock { $0 = false }
        generation += 1
        let d = pos.withLock { $0.duration }
        pausedTime = d
        notify { $0.onQueueEnded?(token) }
    }

    private func notify(_ body: @escaping @MainActor (PlaybackEngine) -> Void) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { body(self) }
        }
    }

    // MARK: Gerätewechsel (Kopfhörer, AirPlay …)

    @MainActor private func handleConfigurationChange() {
        let wasPlaying = isPlaying
        let t = currentTime
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        if wasPlaying {
            try? engine.start()
            seek(to: t)
            play()
        }
    }
}
