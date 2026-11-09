import AVFoundation
import MediaPlayer
import SwiftUI

/// Verbindet Warteliste, Engine (Stimmung 432/440/528 Hz), Cache/Downloads und das System (Sperrbildschirm, Fernbedienung, AirPlay).
@MainActor @Observable
final class PlayerController {
    private(set) var queue = PlayQueue()
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var lastError: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let engine = PlaybackEngine()
    /// Stimmung (Einstellungen → Stimmung): gespeichert und sofort wirksam, auch mitten im Titel
    var tuning: Tuning = .saved {
        didSet {
            Tuning.saved = tuning
            engine.tuning = tuning
        }
    }
    @ObservationIgnored private var tokenCounter = 0
    @ObservationIgnored private var currentToken = -1
    @ObservationIgnored private var preloaded: [Int: UUID] = [:]
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var scrobbledToken = -1
    @ObservationIgnored private var lastTick: ContinuousClock.Instant?
    /// Schlaf-Timer: hält die Wiedergabe zur gesetzten Zeit bzw. am Ende des laufenden Titels an
    private(set) var sleepTimer: SleepTimer = .off
    @ObservationIgnored private var sessionReady = false
    @ObservationIgnored private var artworkFor: String?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?

    var currentSong: Song? { queue.current?.song }
    var hasItem: Bool { queue.current != nil }
    var repeatMode: PlayQueue.RepeatMode { queue.repeatMode }
    var shuffle: Bool { queue.shuffle }

    init() {
        engine.tuning = tuning
        engine.onTrackStarted = { [weak self] token in self?.engineAdvanced(to: token) }
        engine.onQueueEnded = { [weak self] token in self?.engineEnded(token) }
        engine.onError = { [weak self] token, error in self?.engineFailed(token, error) }
        setupRemoteCommands()
        #if os(macOS)
        engine.engine.mainMixerNode.outputVolume = volume
        #else
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                if type == .began { self?.pause() }
                else if type == .ended, opts.contains(.shouldResume) { self?.play() }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Kopfhörer abgezogen → anhalten (wie Apple)
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        }
        #endif
    }

    private var client: SubsonicClient? { app?.client }

    // MARK: Audio-Sitzung

    private func activateSession() {
        #if os(iOS)
        guard !sessionReady else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try s.setActive(true)
            sessionReady = true
        } catch {
            lastError = error.localizedDescription
        }
        #endif
    }

    #if os(macOS)
    // MARK: Mac: Lautstärke der App, App Nap

    /// App-eigene Lautstärke (nicht die des Systems), 0…1, gemerkt
    var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1 {
        didSet {
            // Nur zuweisen, wenn wirklich begrenzt werden muss – sonst ruft @Observable didSet endlos erneut auf
            let clamped = min(1, max(0, volume))
            if clamped != volume { volume = clamped; return }
            engine.engine.mainMixerNode.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    /// Hält macOS davon ab, die App während der Wiedergabe zu drosseln (Puffer-Zubringer)
    @ObservationIgnored private var playActivity: NSObjectProtocol?

    private func syncActivity() {
        if isPlaying, playActivity == nil {
            playActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "playback")
        } else if !isPlaying, let a = playActivity {
            ProcessInfo.processInfo.endActivity(a)
            playActivity = nil
        }
    }
    #endif

    // MARK: Öffentliche Steuerung

    /// Spielt eine Titelliste ab (Album, Playlist …). `startAt` nil + Zufall = zufälliger Start.
    func play(_ songs: [Song], startAt: Int? = nil, name: String? = nil, shuffle: Bool = false, clearUpNext: Bool = false) {
        guard !songs.isEmpty else { return }
        queue.play(songs, startAt: startAt, name: name, shuffle: shuffle, clearUpNext: clearUpNext)
        startCurrent(autoplay: true)
    }

    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let wasEmpty = queue.current == nil
        queue.playNext(songs)
        if wasEmpty { startCurrent(autoplay: true) } else { queueChanged() }
        app?.notice.show(String(localized: "Als Nächstes"), icon: "text.line.first.and.arrowtriangle.forward")
    }

    func playLast(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let wasEmpty = queue.current == nil
        queue.playLast(songs)
        if wasEmpty { startCurrent(autoplay: true) } else { queueChanged() }
        app?.notice.show(String(localized: "Zuletzt wiedergeben"), icon: "text.line.last.and.arrowtriangle.forward")
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard queue.current != nil else { return }
        activateSession()
        if currentToken < 0 || engine.currentToken != currentToken {
            startCurrent(autoplay: true, at: position)
            return
        }
        engine.play()
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    func pause() {
        engine.pause()
        isPlaying = false
        position = engine.currentTime
        updateNowPlaying()
        saveQueue()
        app?.stats.flush()
    }

    func next() {
        guard queue.current != nil else { return }
        queue.advance(auto: false)
        if queue.current == nil { stopAndClear(); return }
        startCurrent(autoplay: true)
    }

    /// Wie Apple: nach mehr als 3 s zurück an den Titelanfang, sonst vorheriger Titel.
    func previous() {
        guard queue.current != nil else { return }
        if position > 3 || queue.history.isEmpty {
            seek(to: 0)
        } else {
            queue.goBack()
            startCurrent(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, duration > 0 ? duration - 0.25 : seconds))
        position = t
        if engine.currentToken == currentToken && currentToken >= 0 {
            engine.seek(to: t)
        } else if queue.current != nil {
            startCurrent(autoplay: isPlaying, at: t)
        }
        updateNowPlaying()
    }

    func skip(by delta: Double) { seek(to: position + delta) }

    func jump(to entry: PlayQueue.Entry) {
        queue.jump(to: entry.id)
        startCurrent(autoplay: true)
    }

    func toggleShuffle() {
        queue.setShuffle(!queue.shuffle)
        queueChanged()
    }

    func cycleRepeat() {
        queue.cycleRepeat()
        queueChanged()
    }

    func setRepeat(_ mode: PlayQueue.RepeatMode) {
        queue.repeatMode = mode
        queueChanged()
    }

    func remove(_ entry: PlayQueue.Entry) { queue.remove(id: entry.id); queueChanged() }
    func moveUpNext(from: IndexSet, to: Int) { queue.moveUpNext(from: from, to: to); queueChanged() }
    func moveSource(from: IndexSet, to: Int) { queue.moveSource(from: from, to: to); queueChanged() }
    func clearUpcoming() { queue.clearUpcoming(); queueChanged() }
    func clearHistory() { queue.clearHistory(); saveQueue() }
    func removeFromHistory(_ entry: PlayQueue.Entry) { queue.removeHistory(id: entry.id); saveQueue() }

    /// Titel an einer Stelle der Warteliste „Als Nächstes“ einfügen (Ziehen in die Warteliste)
    func insertUpNext(_ songs: [Song], at index: Int) {
        guard !songs.isEmpty else { return }
        let wasEmpty = queue.current == nil
        queue.insertUpNext(songs, at: index)
        if wasEmpty { startCurrent(autoplay: true) } else { queueChanged() }
    }

    func updateSong(_ song: Song) { queue.updateSong(song) }

    func stopAndClear() {
        loadTask?.cancel(); preloadTask?.cancel()
        engine.stop()
        queue.reset()
        isPlaying = false; isLoading = false
        position = 0; duration = 0
        currentToken = -1
        ticker?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        syncActivity()
        #endif
        app?.local.keepAccess(for: [])
    }

    /// Security-scoped Zugriff nur für die Ordner des laufenden und des nächsten Titels offen halten.
    private func syncLocalAccess(next: Song? = nil) {
        app?.local.keepAccess(for: [queue.current?.song, next].compactMap { $0 })
    }

    // MARK: Laden und Vorladen

    private func localFile(for song: Song) async throws -> URL {
        // Musik auf diesem iPhone: Originaldatei über das Bookmark (Zugriff bleibt offen, solange gebraucht)
        if song.isLocal {
            guard let local = app?.local else { throw LocalError.missing }
            return try local.fileURL(for: song)
        }
        if let f = app?.downloads.localFile(song.id) { return f }
        guard let client else { throw URLError(.notConnectedToInternet) }
        return try await TrackCache.shared.file(for: song, client: client)
    }

    private func startCurrent(autoplay: Bool, at seconds: Double = 0) {
        guard let entry = queue.current else { return }
        if autoplay { activateSession() }
        tokenCounter += 1
        let token = tokenCounter
        currentToken = token
        preloaded.removeAll()
        preloadTask?.cancel()
        loadTask?.cancel()
        isLoading = true
        position = seconds
        duration = entry.song.durationSeconds
        if autoplay { isPlaying = true }
        updateNowPlaying()
        loadTask = Task {
            do {
                let url = try await localFile(for: entry.song)
                guard token == currentToken, !Task.isCancelled else { return }
                engine.load(url: url, token: token, at: seconds, autoplay: autoplay)
                isLoading = false
                isPlaying = autoplay
                trackDidStart()
            } catch {
                guard token == currentToken, !Task.isCancelled else { return }
                isLoading = false
                handleUnplayable(error)
            }
        }
    }

    private func handleUnplayable(_ error: Error) {
        lastError = error.localizedDescription
        app?.notice.show(String(localized: "Titel nicht verfügbar"), icon: "exclamationmark.triangle")
        isPlaying = false
        // Nächsten Titel versuchen, wenn noch etwas kommt
        if queue.peekNext(auto: false) != nil, app?.library.isOffline == false {
            queue.advance(auto: false)
            startCurrent(autoplay: true)
        }
    }

    /// Nach jeder Änderung an der Warteliste: Folgetitel neu vorladen und speichern.
    private func queueChanged() {
        schedulePreload()
        saveQueue()
    }

    private func schedulePreload() {
        preloadTask?.cancel()
        syncLocalAccess(next: queue.peekNext()?.song)
        guard currentToken >= 0, let next = queue.peekNext() else {
            engine.setNext(url: nil, token: -1)
            return
        }
        preloadTask = Task {
            guard let url = try? await localFile(for: next.song), !Task.isCancelled else { return }
            tokenCounter += 1
            let token = tokenCounter
            preloaded[token] = next.id
            engine.setNext(url: url, token: token)
        }
    }

    private func trackDidStart() {
        duration = queue.current?.song.durationSeconds ?? 0
        scrobbledToken = -1
        startTicker()
        updateNowPlaying()
        schedulePreload()
        saveQueue()
        if let song = queue.current?.song, !song.isLocal, let client {
            Task { try? await client.scrobble(id: song.id, submission: false) }
        }
    }

    // MARK: Rückmeldungen der Engine

    private func engineAdvanced(to token: Int) {
        guard let entryID = preloaded[token] else { return }
        preloaded.removeAll()
        let sleep = sleepTimer == .endOfTrack
        if entryID == queue.current?.id && queue.repeatMode == .one {
            // gleicher Titel noch einmal
        } else if entryID == PlayQueue.wrapID {
            queue.advance(auto: false)
        } else if queue.upNext.first?.id == entryID || queue.source.first?.id == entryID {
            queue.advance(auto: false)
        } else {
            queue.jump(to: entryID)
        }
        currentToken = token
        position = 0
        trackDidStart()
        // Schlaf-Timer „Ende des Titels“: der nächste Titel ist nahtlos schon angelaufen → an seinem Anfang anhalten
        if sleep { sleepTimer = .off; pause(); seek(to: 0) }
    }

    private func engineEnded(_ token: Int) {
        guard token == currentToken else { return }
        if queue.peekNext() != nil {
            let sleep = sleepTimer == .endOfTrack
            if sleep { sleepTimer = .off; isPlaying = false; ticker?.cancel() }
            queue.advance(auto: true)
            startCurrent(autoplay: !sleep)
        } else {
            sleepTimer = .off
            // Ende der Warteliste: auf dem letzten Titel anhalten (Apple: PausedAtQueueEnd)
            isPlaying = false
            position = 0
            ticker?.cancel()
            startCurrent(autoplay: false)
        }
    }

    private func engineFailed(_ token: Int, _ error: Error) {
        if token == currentToken { handleUnplayable(error) }
        else { preloaded[token] = nil }
    }

    // MARK: Fortschritt, Scrobbeln, Statistik

    private func startTicker() {
        ticker?.cancel()
        lastTick = nil
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.checkSleepTimer()
                guard self.isPlaying else { self.lastTick = nil; continue }
                let now = ContinuousClock.now
                if self.engine.currentToken == self.currentToken {
                    self.position = self.engine.currentTime
                    // Hörzeit: echte Zeit seit dem letzten Takt, solange dieser Titel wirklich läuft
                    if let last = self.lastTick, let song = self.queue.current?.song {
                        let d = last.duration(to: now)
                        self.app?.stats.addListening(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18, song: song)
                    }
                    self.lastTick = now
                } else {
                    self.lastTick = nil
                }
                self.checkScrobble()
            }
        }
    }

    /// Wiedergabe zählt ab der Hälfte oder nach 4 Minuten (übliche Scrobble-Regel).
    private func checkScrobble() {
        guard scrobbledToken != currentToken, let song = queue.current?.song, duration > 0 else { return }
        if position >= min(duration / 2, 240) {
            scrobbledToken = currentToken
            app?.stats.notePlay(song)
            if !song.isLocal, let client { Task { try? await client.scrobble(id: song.id, submission: true) } }
        }
    }

    // MARK: Schlaf-Timer

    /// Wiedergabe in so vielen Minuten anhalten (die letzten Sekunden werden leiser).
    func setSleepTimer(minutes: Int) {
        sleepTimer = .at(Date().addingTimeInterval(Double(minutes) * 60))
    }

    func setSleepTimerEndOfTrack() { sleepTimer = .endOfTrack }

    func cancelSleepTimer() {
        sleepTimer = .off
        engine.engine.mainMixerNode.outputVolume = volume
    }

    private func checkSleepTimer() {
        guard case .at(let end) = sleepTimer else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            sleepTimer = .off
            if isPlaying { pause() }
            engine.engine.mainMixerNode.outputVolume = volume
        } else if left < SleepTimer.fade, isPlaying {
            engine.engine.mainMixerNode.outputVolume = volume * Float(left / SleepTimer.fade)
        }
    }

    // MARK: Sperrbildschirm / Kontrollzentrum

    private func updateNowPlaying() {
        #if os(macOS)
        // Mac: ohne playbackState erscheint die App nicht unter „Jetzt läuft“ und die Medientasten gehen woanders hin
        MPNowPlayingInfoCenter.default().playbackState = queue.current == nil ? .stopped : isPlaying ? .playing : .paused
        syncActivity()
        #endif
        guard let song = queue.current?.song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if artworkFor == song.coverArt, let art = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = art
        } else if let cover = song.coverArt, client != nil || cover.isLocalID {
            artworkFor = cover
            nowPlayingArtwork = nil
            let client = client
            Task {
                guard let img = await Artwork.image(id: cover, size: 600, client: client), artworkFor == cover else { return }
                nowPlayingArtwork = Self.makeArtwork(img)
                updateNowPlaying()
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = queue.shuffle ? .items : .off
        MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType =
            switch queue.repeatMode { case .off: .off; case .all: .all; case .one: .one }
    }

    /// Außerhalb des MainActors gebaut: iOS ruft den Block auf einem Hintergrund-Thread auf.
    nonisolated private static func makeArtwork(_ img: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ action: @escaping @MainActor (PlayerController, MPRemoteCommandEvent) -> Void) {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                MainActor.assumeIsolated { action(self, event) }
                return .success
            }
        }
        on(c.playCommand) { p, _ in p.play() }
        on(c.pauseCommand) { p, _ in p.pause() }
        on(c.togglePlayPauseCommand) { p, _ in p.togglePlay() }
        on(c.stopCommand) { p, _ in p.pause() }
        on(c.nextTrackCommand) { p, _ in p.next() }
        on(c.previousTrackCommand) { p, _ in p.previous() }
        on(c.changePlaybackPositionCommand) { p, e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { p.seek(to: e.positionTime) }
        }
        on(c.changeShuffleModeCommand) { p, e in
            if let e = e as? MPChangeShuffleModeCommandEvent { p.queue.setShuffle(e.shuffleType != .off); p.queueChanged() }
        }
        on(c.changeRepeatModeCommand) { p, e in
            if let e = e as? MPChangeRepeatModeCommandEvent {
                let mode: PlayQueue.RepeatMode = switch e.repeatType { case .one: .one; case .all: .all; default: .off }
                p.setRepeat(mode)
            }
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    // MARK: Warteliste merken (nach Neustart weiter, angehalten)

    private var queueKey: String? {
        guard let app else { return nil }
        return app.client.map { "queue-\($0.account.id)" } ?? (app.localMode ? "queue-local" : nil)
    }

    func saveQueue() {
        guard let key = queueKey else { return }
        struct Saved: Codable { var queue: PlayQueue; var position: Double }
        if let d = try? JSONEncoder().encode(Saved(queue: queue, position: position)) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    func restoreQueue() {
        guard let key = queueKey, let d = UserDefaults.standard.data(forKey: key) else { return }
        struct Saved: Codable { var queue: PlayQueue; var position: Double }
        guard let s = try? JSONDecoder().decode(Saved.self, from: d), s.queue.current != nil else { return }
        queue = s.queue
        position = s.position
        duration = s.queue.current?.song.durationSeconds ?? 0
        currentToken = -1
        updateNowPlaying()
    }
}
