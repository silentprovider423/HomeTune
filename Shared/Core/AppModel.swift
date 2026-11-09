import SwiftUI

/// Ziele für die Navigation (Detailseiten), in allen Tabs gleich.
enum Route: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case genre(String)
    case composer(String)
    case section(LibrarySection)
    /// „Auf diesem iPhone“: nur lokale Alben, Künstler:innen, Titel
    case localAlbums, localArtists, localSongs
}

/// Abschnitte der Mediathek (Apple: „Abschnitte bearbeiten“ – ein-/ausblenden und ordnen).
enum LibrarySection: String, CaseIterable, Codable, Identifiable, Hashable {
    case playlists, artists, albums, songs, genres, composers, favorites, downloaded, onThisIPhone
    var id: String { rawValue }

    /// Abschnitte, die nur mit Server-Konto Sinn ergeben (Playlists gibt es auch auf diesem iPhone)
    var needsServer: Bool { self == .downloaded }

    var title: LocalizedStringKey {
        switch self {
        case .playlists: "Playlists"
        case .artists: "Künstler:innen"
        case .albums: "Alben"
        case .songs: "Titel"
        case .genres: "Genres"
        case .composers: "Komponist:innen"
        case .favorites: "Lieblingstitel"
        case .downloaded: "Geladen"
        case .onThisIPhone: "Auf diesem iPhone"
        }
    }

    var icon: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .composers: "music.quarternote.3"
        case .favorites: "star"
        case .downloaded: "arrow.down.circle"
        case .onThisIPhone: "iphone"
        }
    }
}

enum AppTab: Hashable { case home, library, search }

/// Was der Dateien-Dialog auswählen soll.
enum LocalImportKind: Identifiable {
    case folder, files
    var id: Self { self }
}

/// Kurze Rückmeldung nach Aktionen (Apple: `MusicNotice` – „Als Nächstes“, „Favorit“ …).
@MainActor @Observable
final class NoticeCenter {
    struct Notice: Equatable, Identifiable { let id = UUID(); let text: String; let icon: String }
    private(set) var current: Notice?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, icon: String) {
        current = Notice(text: text, icon: icon)
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { current = nil }
        }
    }
}

/// Zentrale App-Zustände: Konto, Server-Client, Mediathek, Player, Downloads, Navigation.
@MainActor @Observable
final class AppModel {
    let accounts = AccountStore()
    let library = LibraryStore()
    let local = LocalLibrary()
    let downloads = DownloadManager()
    let notice = NoticeCenter()
    let stats = ListeningStats()
    let player: PlayerController
    private(set) var client: SubsonicClient?

    var tab: AppTab = .library
    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    var searchPath = NavigationPath()
    var showNowPlaying = false
    var showSettings = false
    /// Blatt „Zur Playlist hinzufügen“ für diese Titel
    var addToPlaylist: [Song]?
    /// Dateien-Dialog für „Musik hinzufügen“
    var importRequest: LocalImportKind?
    /// Titel aus dem HomeTune-Ordner, für die gefragt wird, ob auch die Datei gelöscht werden soll
    var pendingLocalRemoval: [Song]?
    #if os(iOS)
    /// Signatur-Profil gilt für eine andere App-ID (dann übergibt der Dateien-Dialog nichts) – erwartete ID
    let signingMismatch: String? = SigningCheck.currentMismatch()
    #endif
    /// „Ohne Server fortfahren“: Mediathek nur mit Musik auf diesem iPhone (Server kann später dazukommen)
    var localMode: Bool {
        didSet { UserDefaults.standard.set(localMode, forKey: "localMode") }
    }
    @ObservationIgnored private var signedOut = false
    @ObservationIgnored private var folderWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var folderPoll: Task<Void, Never>?
    @ObservationIgnored private var folderDebounce: Task<Void, Never>?

    init() {
        localMode = UserDefaults.standard.bool(forKey: "localMode")
        player = PlayerController()
        player.app = self
        library.local = local
        #if DEBUG
        DebugLogin.apply(to: accounts)
        DebugLocal.apply(to: self)
        #endif
        connect()
        // Beim Start: Rechte im HomeTune-Ordner reparieren und Reste vom Gerätetest entfernen
        Task {
            await local.migrateDocuments()
            await local.repairAppFolder()
            await local.rescanAll()
            _ = await local.refreshAppFolderIfChanged()
        }
        watchAppFolder()
    }

    // MARK: HomeTune-Ordner (Dateien-App › Auf meinem iPhone › HomeTune)

    /// Vordergrund: HomeTune-Ordner prüfen und, solange die App offen ist, sparsam weiter beobachten.
    func becameActive() {
        refreshAppFolder()
        folderPoll?.cancel()
        // Unterordner meldet die Ordner-Beobachtung nicht → zusätzlich alle 20 s ein billiger Fingerabdruck
        folderPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.refreshAppFolder()
            }
        }
    }

    func resignedActive() {
        folderPoll?.cancel()
        folderPoll = nil
        stats.flush()
    }

    private func refreshAppFolder() {
        folderDebounce?.cancel()
        folderDebounce = Task {
            // Beim Kopieren vieler Dateien kommen laufend Meldungen – erst einlesen, wenn kurz Ruhe ist
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let s = await local.refreshAppFolderIfChanged() else { return }
            if s.added > 0 || s.removed > 0 || !s.playlists.isEmpty { report(s, rescan: true) }
        }
    }

    /// Änderungen direkt in Documents/ (neue, gelöschte, umbenannte Dateien) sofort bemerken.
    private func watchAppFolder() {
        let fd = Darwin.open(local.documentsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshAppFolder() }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        folderWatcher = src
    }

    /// Ohne Konto, aber mit lokaler Musik oder „Ohne Server fortfahren“ → Mediathek statt Anmeldung.
    var showsLogin: Bool { client == nil && !localMode }

    /// Mit dem aktuellen Konto verbinden (nach Anmelden oder Umschalten).
    func connect() {
        player.stopAndClear()
        client = signedOut ? nil : accounts.current.flatMap { accounts.client(for: $0) }
        library.attach(client)
        downloads.attach(client)
        player.restoreQueue()
        homePath = NavigationPath(); libraryPath = NavigationPath(); searchPath = NavigationPath()
        if client != nil {
            Task { await library.refresh() }
        }
    }

    /// Navigiert im aktuellen Tab (schließt dafür den Vollbild-Player).
    func open(_ route: Route) {
        showNowPlaying = false
        switch tab {
        case .home: homePath.append(route)
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    func openAlbum(of song: Song) { if let id = song.albumId { open(.album(id)) } }
    func openArtist(of song: Song) { if let id = song.artistId { open(.artist(id)) } }

    // MARK: Musik auf diesem iPhone

    /// Ergebnis des Dateien-Dialogs übernehmen (Ordner/Dateien werden referenziert, nicht kopiert).
    func importLocal(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        Task {
            let s = await local.add(urls)
            report(s)
        }
    }

    /// „Öffnen in HomeTune“ / „Teilen“: aus der Dateien-App ohne Kopie (Bookmark wie im Dialog), aus Mail/AirDrop
    /// als Kopie; Playlists (.m3u/.m3u8/.pls) werden importiert.
    func receive(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if client == nil { localMode = true }
        Task {
            let s = await local.open(files)
            report(s)
        }
    }

    func rescanLocal(_ rootID: String? = nil) {
        Task {
            let s = if let rootID { await local.rescan(rootID) } else { await local.rescanAll() }
            report(s, rescan: true)
        }
    }

    /// Aus der Mediathek nehmen; liegt etwas im HomeTune-Ordner, wird vorher gefragt, ob auch die Datei weg soll.
    func removeLocal(_ songs: [Song]) {
        if songs.contains(where: local.isInAppFolder) {
            pendingLocalRemoval = songs
            return
        }
        local.remove(songs: songs)
        notice.show(String(localized: "Aus der Mediathek entfernt"), icon: "minus.circle")
    }

    func confirmLocalRemoval(deleteFiles: Bool) {
        guard let songs = pendingLocalRemoval else { return }
        pendingLocalRemoval = nil
        local.remove(songs: songs, deleteAppFolderFiles: deleteFiles)
        notice.show(deleteFiles ? String(localized: "Gelöscht") : String(localized: "Aus der Mediathek entfernt"),
                    icon: deleteFiles ? "trash" : "minus.circle")
    }

    private func report(_ s: LocalScanSummary, rescan: Bool = false) {
        if let p = s.playlists.first, s.added == 0 || s.playlists.count == 1 {
            // Playlist-Import: „x von y Titeln gefunden“
            let text = s.playlists.count == 1
                ? String(localized: "„\(p.name)“: \(p.found) von \(p.total) Titeln gefunden")
                : String(localized: "\(s.playlists.count) Playlists importiert")
            notice.show(text, icon: "music.note.list")
            return
        }
        if s.unreachable > 0 {
            notice.show(String(localized: "Ordner nicht erreichbar"), icon: "exclamationmark.triangle")
        } else if s.added == 0 && s.removed == 0 && s.inCloud > 0 {
            notice.show(String(localized: "Wird aus iCloud geladen – später neu einlesen"), icon: "icloud.and.arrow.down")
        } else if rescan || s.removed > 0 {
            notice.show(String(localized: "\(s.added) neu, \(s.removed) entfernt"), icon: "arrow.triangle.2.circlepath")
        } else if s.added > 0 {
            notice.show(String(localized: "\(s.added) Titel hinzugefügt"), icon: "iphone")
        } else if s.skipped > 0 {
            notice.show(String(localized: "Keine abspielbaren Audiodateien gefunden"), icon: "exclamationmark.triangle")
        } else {
            notice.show(String(localized: "Schon in der Mediathek"), icon: "checkmark")
        }
    }

    #if DEBUG
    fileprivate func debugSignOut() { signedOut = true }
    #endif
}

#if DEBUG
/// Nur Debug: Musik auf diesem iPhone ohne Dateien-Dialog (Simulator-/UI-Tests).
/// HOMETUNE_SIGNED_OUT=1 (gespeichertes Konto ignorieren), HOMETUNE_LOCAL_ONLY=1 (gleich „Ohne Server fortfahren“),
/// HOMETUNE_LOCAL_RESET=1 (lokale Mediathek leeren), HOMETUNE_LOCAL_IMPORT=<Ordner>|<Ordner> (per Bookmark hinzufügen)
enum DebugLocal {
    @MainActor static func apply(to app: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if env["HOMETUNE_SIGNED_OUT"] == "1" { app.debugSignOut(); app.localMode = false }
        if env["HOMETUNE_LOCAL_ONLY"] == "1" { app.localMode = true }
        if env["HOMETUNE_LOCAL_RESET"] == "1" { app.local.removeAll() }
        if let paths = env["HOMETUNE_LOCAL_IMPORT"], !paths.isEmpty {
            // relative Pfade (z. B. „Documents/LocalMusic“) gelten ab dem App-Ordner – für Tests auf dem Gerät
            let urls = paths.split(separator: "|").map { p in
                p.hasPrefix("/") ? URL(fileURLWithPath: String(p), isDirectory: true)
                    : URL(fileURLWithPath: NSHomeDirectory()).appending(path: String(p), directoryHint: .isDirectory)
            }
            Task { await app.local.add(urls) }
        }
    }
}

/// Nur Debug: Anmeldung über die Startumgebung (Simulator-Tests ohne Passwort-Tippen).
/// HOMETUNE_SERVER, HOMETUNE_USER, HOMETUNE_PASSWORD
enum DebugLogin {
    @MainActor static func apply(to store: AccountStore) {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["HOMETUNE_SERVER"], let url = AccountStore.normalize(s),
              let user = env["HOMETUNE_USER"], let pw = env["HOMETUNE_PASSWORD"] else { return }
        #if os(macOS)
        Keychain.memoryOnly = [:]
        #endif
        if let existing = store.accounts.first(where: { $0.server == url && $0.username == user }) {
            Keychain.set(pw, for: existing.id)
            store.select(existing.id)
        } else {
            store.add(ServerAccount(server: url, username: user), password: pw)
        }
    }
}
#endif
