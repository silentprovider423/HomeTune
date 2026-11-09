import AVFoundation
import os

/// Wiedergabe-Motor: AVAudioEngine mit Stimmungs-Kette (432/440/528 Hz, live umschaltbar), lückenlosem Übergang zum vorgeladenen
/// Folgetitel und eigenem Puffer-Zubringer (wie Apples „AssetSlidingQueue“).
///
/// Jeder Titel bekommt eine Marke (`token`). Der Zubringer hält immer ~10 s dekodierte Musik im Spieler eingeplant;
/// endet die Datei, geht es ohne Pause mit dem vorgeladenen Folgetitel weiter. Wird eine Datei noch geladen,
/// startet die Wiedergabe erst, wenn einige Sekunden da sind; fehlen unterwegs Daten, hält der Spieler sauber an
/// („Puffern“), statt zu stottern, und läuft weiter, sobald wieder genug da ist. Rückmeldungen kommen auf dem Hauptthread.
final class PlaybackEngine: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    let chain = PitchChain()
    private(set) var format: AVAudioFormat

    /// Neuer Titel hat hörbar begonnen (am lückenlosen Übergang).
    var onTrackStarted: (@MainActor (Int) -> Void)?
    /// Letzter eingeplanter Titel ist zu Ende, kein Folgetitel da.
    var onQueueEnded: (@MainActor (Int) -> Void)?
    /// Datei ließ sich nicht öffnen bzw. nicht fertig laden.
    var onError: (@MainActor (Int, Error) -> Void)?
    /// Wartet auf Daten (true) bzw. spielt wieder (false) – für die Ladeanzeige.
    var onBuffering: (@MainActor (Int, Bool) -> Void)?

    // Puffer-Einstellungen
    /// So viel Musik ist immer dekodiert im Spieler eingeplant
    var aheadSeconds = 10.0
    /// Datei wird noch geladen: erst starten, wenn so viel dekodiert bereitliegt
    var startSeconds = 4.0
    /// Nach einem Aussetzer erst weiter, wenn wieder so viel da ist
    var resumeSeconds = 6.0
    /// Vollständige Datei: sofort starten, sobald so viel eingeplant ist
    private let quickStartSeconds = 0.5
    /// Fehlen Daten und ist weniger als das eingeplant: anhalten statt leerlaufen
    private let lowWaterSeconds = 0.6

    private let q = DispatchQueue(label: "hometune.audio.feeder", qos: .userInitiated)
    private let chunkFrames: AVAudioFrameCount = 16384
    /// Höchstens so viele Stücke je Durchgang dekodieren (Steuerbefehle bleiben flott, Start kommt früh)
    private let chunksPerPass = 4

    /// Ein Titel im Zubringer: Datei (evtl. noch ladend), Decoder sobald lesbar.
    private struct Slot {
        let source: TrackSource
        let token: Int
        let startAt: Double
        var decoder: TrackDecoder?
        /// Spieler-Frame, an dem der Titel beginnt (für die Position)
        var frameBase: AVAudioFramePosition
    }

    // Zustand des Zubringers – nur auf `q`
    private var generation = 0
    private var current: Slot?
    private var pending: Slot?
    private var fifo: [(token: Int, frames: AVAudioFramePosition)] = []
    /// Eingeplant, aber noch nicht gespielt
    private var aheadFrames: AVAudioFramePosition = 0
    private var scheduledFrames: AVAudioFramePosition = 0
    private var starts: [Int: (frame: AVAudioFramePosition, offset: Double, duration: Double)] = [:]
    private var activeSource: [Int: TrackSource] = [:]
    /// Wiedergabe gewünscht (Play gedrückt)
    private var wantPlay = false
    /// Wartet auf genug Daten (Start bzw. nach Aussetzer)
    private var buffering = false
    /// Schwelle für das Weiterspielen aus dem Puffern
    private var bufferTarget = 0.0
    private var passScheduled = false
    private var retryScheduled = false

    // Für die Positionsabfrage vom Hauptthread
    private struct Position { var token: Int = -1; var baseFrame: AVAudioFramePosition = 0; var offset: Double = 0; var duration: Double = 0 }
    private let pos = OSAllocatedUnfairLock(initialState: Position())
    private let playing = OSAllocatedUnfairLock(initialState: false)

    /// Messwerte (Tests, Diagnose)
    struct Stats: Sendable {
        /// Aussetzer nach dem Start (Spieler musste auf Daten warten)
        var rebuffers = 0
        /// Zeit vom Laden bis zum ersten Ton des aktuellen Titels
        var startDelay: Double?
        var loadedAt: Date?
    }
    private let statsLock = OSAllocatedUnfairLock(initialState: Stats())
    var stats: Stats { statsLock.withLock { $0 } }

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

    /// Aktuelle Position im laufenden Titel (Sekunden). Läuft der Spieler, zählt seine Zeit; direkt nach dem
    /// (Wieder-)Start hat er noch keine – dann die zuletzt bekannte Position statt des Titelanfangs.
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

    /// Fertige Datei laden (alles Eingeplante wird verworfen) und ab `seconds` spielen.
    func load(url: URL, token: Int, at seconds: Double = 0, autoplay: Bool) {
        load(source: .file(url), token: token, at: seconds, autoplay: autoplay)
    }

    /// Titel laden – die Datei darf noch im Laden sein (Start, sobald genug da ist).
    func load(source: TrackSource, token: Int, at seconds: Double = 0, autoplay: Bool, durationHint: Double = 0) {
        pausedTime = seconds
        statsLock.withLock { $0 = Stats(loadedAt: Date()) }
        q.async { [self] in
            reset()
            current = Slot(source: source, token: token, startAt: seconds, decoder: nil, frameBase: 0)
            activeSource[token] = source
            pos.withLock { $0 = Position(token: token, baseFrame: 0, offset: seconds, duration: durationHint) }
            wantPlay = autoplay
            if autoplay { beginBuffering(token: token, target: source.isComplete ? quickStartSeconds : startSeconds) }
            pass()
        }
    }

    /// Folgetitel für den lückenlosen Übergang (nil = keiner). Ersetzt einen bisherigen Folgetitel.
    func setNext(url: URL?, token: Int) {
        setNext(source: url.map(TrackSource.file), token: token)
    }

    func setNext(source: TrackSource?, token: Int) {
        q.async { [self] in
            pending = source.map { Slot(source: $0, token: token, startAt: 0, decoder: nil, frameBase: 0) }
            pass()
        }
    }

    func play() {
        q.async { [self] in
            wantPlay = true
            guard current != nil || !fifo.isEmpty else { return }
            if isPlaying { return }
            // Genug eingeplant → sofort, sonst erst puffern
            let complete = current?.source.isComplete ?? true
            let need = complete ? quickStartSeconds : startSeconds
            if aheadFrames >= frames(need) || (current?.decoder != nil && complete && !fifo.isEmpty) || current == nil {
                startPlayer()
            } else {
                beginBuffering(token: pos.withLock { $0.token }, target: need)
            }
            pass()
        }
    }

    func pause() {
        pausedTime = currentTime
        q.async { [self] in
            wantPlay = false
            if buffering { endBuffering(token: pos.withLock { $0.token }) }
            player.pause()
            playing.withLock { $0 = false }
        }
    }

    func seek(to seconds: Double) {
        let p = pos.withLock { $0 }
        guard p.token >= 0 else { return }
        let wasPlaying = isPlaying
        pausedTime = seconds
        q.async { [self] in
            guard let source = activeSource[p.token] else { return }
            let want = wasPlaying || wantPlay
            let next = pending
            reset()
            current = Slot(source: source, token: p.token, startAt: seconds, decoder: nil, frameBase: 0)
            activeSource[p.token] = source
            pending = next
            pos.withLock { $0 = Position(token: p.token, baseFrame: 0, offset: seconds, duration: p.duration) }
            wantPlay = want
            if want { beginBuffering(token: p.token, target: source.isComplete ? quickStartSeconds : startSeconds) }
            pass()
        }
    }

    func stop() {
        pausedTime = nil
        q.async { [self] in
            if buffering { endBuffering(token: pos.withLock { $0.token }) }
            reset()
            wantPlay = false
            pos.withLock { $0 = Position() }
        }
    }

    // MARK: Zubringer (auf q)

    private func frames(_ seconds: Double) -> AVAudioFramePosition { AVAudioFramePosition(seconds * format.sampleRate) }

    private func reset() {
        generation += 1
        player.stop()
        playing.withLock { $0 = false }
        current = nil
        pending = nil
        fifo.removeAll()
        aheadFrames = 0
        scheduledFrames = 0
        starts.removeAll()
        activeSource.removeAll()
        buffering = false
    }

    private func startPlayer() {
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.play()
        playing.withLock { $0 = true }
        // `pausedTime` bleibt stehen, bis der Spieler eine gültige Zeit meldet (sonst springt die Anzeige kurz zurück)
        statsLock.withLock { s in
            if s.startDelay == nil, let l = s.loadedAt { s.startDelay = Date().timeIntervalSince(l) }
        }
    }

    private func beginBuffering(token: Int, target: Double) {
        bufferTarget = target
        guard !buffering else { return }
        buffering = true
        notify { $0.onBuffering?(token, true) }
    }

    private func endBuffering(token: Int) {
        guard buffering else { return }
        buffering = false
        notify { $0.onBuffering?(token, false) }
    }

    /// Nächsten Durchgang einplanen (statt alles auf einmal zu dekodieren)
    private func pass() {
        guard !passScheduled else { return }
        passScheduled = true
        q.async { [self] in
            passScheduled = false
            pump()
        }
    }

    private enum Fill { case full, starved, done }

    private func pump() {
        let target = frames(aheadSeconds)
        var chunks = 0
        var fill = Fill.full
        while aheadFrames < target {
            if chunks >= chunksPerPass { pass(); fill = .full; break }
            if current == nil {
                guard var p = pending else { fill = .done; break }
                pending = nil
                p.frameBase = scheduledFrames
                current = p
                activeSource[p.token] = p.source
            }
            guard var cur = current else { fill = .done; break }
            if cur.decoder == nil {
                do {
                    guard let d = try TrackDecoder.open(source: cur.source, outFormat: format, startAt: cur.startAt) else {
                        fill = .starved; break
                    }
                    cur.decoder = d
                    current = cur
                    starts[cur.token] = (cur.frameBase, cur.startAt, d.duration)
                    if pos.withLock({ $0.token }) == cur.token {
                        pos.withLock { $0.duration = d.duration }
                    }
                } catch {
                    failed(cur.token, error)
                    continue
                }
            }
            switch cur.decoder!.next(frames: chunkFrames) {
            case .data(let buf):
                chunks += 1
                let n = AVAudioFramePosition(buf.frameLength)
                fifo.append((cur.token, n))
                aheadFrames += n
                scheduledFrames += n
                let gen = generation
                player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.q.async { self.bufferDone(generation: gen) }
                }
            case .wait:
                fill = .starved
            case .end:
                // Datei vorzeitig zu Ende, weil das Laden scheiterte → Fehler melden
                let s = cur.source.snapshot
                if !s.complete, let e = s.error { failed(cur.token, e); continue }
                current = nil
                continue
            }
            if fill == .starved { break }
        }
        manageBuffering(fill)
        if fill == .starved && !retryScheduled {
            retryScheduled = true
            q.asyncAfter(deadline: .now() + 0.15) { [self] in
                retryScheduled = false
                pump()
            }
        }
    }

    /// Titel ließ sich nicht öffnen/laden: melden und mit dem Folgetitel weitermachen.
    private func failed(_ token: Int, _ error: Error) {
        if current?.token == token { current = nil }
        // Laufender Titel kaputt und nichts danach: nicht als „Ende der Warteliste“ melden, nur als Fehler
        if pos.withLock({ $0.token }) == token, pending == nil, fifo.isEmpty {
            wantPlay = false
            endBuffering(token: token)
        }
        notify { $0.onError?(token, error) }
    }

    private func manageBuffering(_ fill: Fill) {
        let token = pos.withLock { $0.token }
        let nothingMore = current == nil && pending == nil
        // Ende der Warteliste
        if fifo.isEmpty, nothingMore, wantPlay {
            if token >= 0, buffering || isPlaying { endBuffering(token: token); finish(token: token) }
            return
        }
        guard wantPlay else { return }
        if buffering {
            // Weiter, wenn genug da ist – oder nichts mehr kommen kann (Titelende ist eingeplant)
            if aheadFrames >= frames(bufferTarget) || fill == .full && aheadFrames >= frames(aheadSeconds) || fill == .done && !fifo.isEmpty {
                endBuffering(token: token)
                startPlayer()
            }
        } else if fill == .starved, isPlaying, aheadFrames < frames(lowWaterSeconds) {
            // Daten fehlen: anhalten, bevor der Spieler leerläuft (sonst Stottern), und Position festhalten
            pausedTime = currentTime
            player.pause()
            playing.withLock { $0 = false }
            statsLock.withLock { $0.rebuffers += 1 }
            beginBuffering(token: token, target: resumeSeconds)
        }
    }

    private func bufferDone(generation gen: Int) {
        guard gen == generation, !fifo.isEmpty else { return }
        let finished = fifo.removeFirst()
        aheadFrames -= finished.frames
        if let next = fifo.first {
            if next.token != finished.token, let s = starts[next.token] {
                pos.withLock { $0 = Position(token: next.token, baseFrame: s.frame, offset: s.offset, duration: s.duration) }
                pausedTime = nil
                starts[finished.token] = nil
                activeSource[finished.token] = nil
                notify { $0.onTrackStarted?(next.token) }
            }
        } else if current == nil && pending == nil {
            finish(token: finished.token)
            return
        }
        pump()
    }

    private func finish(token: Int) {
        player.stop()
        playing.withLock { $0 = false }
        wantPlay = false
        generation += 1
        fifo.removeAll()
        aheadFrames = 0
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
