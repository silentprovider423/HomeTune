import AVFoundation
import MediaPlayer
import SwiftUI

/// Verbindet Warteliste, 432-Hz-Engine, Cache/Downloads und das System (Sperrbildschirm, Fernbedienung, AirPlay).
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
    @ObservationIgnored private var tokenCounter = 0
    @ObservationIgnored private var currentToken = -1
    @ObservationIgnored private var preloaded: [Int: UUID] = [:]
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var scrobbledToken = -1
    @ObservationIgnored private var sessionReady = false
    @ObservationIgnored private var artworkFor: String?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?

    var currentSong: Song? { queue.current?.song }
    var hasItem: Bool { queue.current != nil }
    var repeatMode: PlayQueue.RepeatMode { queue.repeatMode }
    var shuffle: Bool { queue.shuffle }

    init() {
        engine.onTrackStarted = { [weak self] token in self?.engineAdvanced(to: token) }
        engine.onQueueEnded = { [weak self] token in self?.engineEnded(token) }
        engine.onError = { [weak self] token, error in self?.engineFailed(token, error) }
        setupRemoteCommands()
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
    }

    private var client: SubsonicClient? { app?.client }

    // MARK: Audio-Sitzung

    private func activateSession() {
        guard !sessionReady else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try s.setActive(true)
            sessionReady = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Öffentliche Steuerung

    /// Spielt eine Titelliste ab (Album, Playlist …). `startAt` nil + Zufall = zufälliger Start.
    func play(_ songs: [Song], startAt: Int? = nil, name: String? = nil, shuffle: Bool = false) {
        guard !songs.isEmpty else { return }
        queue.play(songs, startAt: startAt, name: name, shuffle: shuffle)
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
    }

    // MARK: Laden und Vorladen

    private func localFile(for song: Song) async throws -> URL {
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
        if let song = queue.current?.song, let client {
            Task { try? await client.scrobble(id: song.id, submission: false) }
        }
    }

    // MARK: Rückmeldungen der Engine

    private func engineAdvanced(to token: Int) {
        guard let entryID = preloaded[token] else { return }
        preloaded.removeAll()
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
    }

    private func engineEnded(_ token: Int) {
        guard token == currentToken else { return }
        if queue.peekNext() != nil {
            queue.advance(auto: true)
            startCurrent(autoplay: true)
        } else {
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

    // MARK: Fortschritt, Scrobbeln

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isPlaying else { continue }
                if self.engine.currentToken == self.currentToken {
                    self.position = self.engine.currentTime
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
            if let client { Task { try? await client.scrobble(id: song.id, submission: true) } }
        }
    }

    // MARK: Sperrbildschirm / Kontrollzentrum

    private func updateNowPlaying() {
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
        } else if let cover = song.coverArt, let client {
            artworkFor = cover
            nowPlayingArtwork = nil
            Task {
                guard let img = await ArtworkCache.shared.image(id: cover, size: 600, client: client), artworkFor == cover else { return }
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
    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
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

    private var queueKey: String? { app?.client.map { "queue-\($0.account.id)" } }

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
