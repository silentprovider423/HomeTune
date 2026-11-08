import SwiftUI

/// Ziele für die Navigation (Detailseiten), in allen Tabs gleich.
enum Route: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case genre(String)
    case composer(String)
    case section(LibrarySection)
}

/// Abschnitte der Mediathek (Apple: „Abschnitte bearbeiten“ – ein-/ausblenden und ordnen).
enum LibrarySection: String, CaseIterable, Codable, Identifiable, Hashable {
    case playlists, artists, albums, songs, genres, composers, favorites, downloaded
    var id: String { rawValue }

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
        }
    }
}

enum AppTab: Hashable { case home, library, search }

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
    let downloads = DownloadManager()
    let notice = NoticeCenter()
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

    init() {
        player = PlayerController()
        player.app = self
        #if DEBUG
        DebugLogin.apply(to: accounts)
        #endif
        connect()
    }

    /// Mit dem aktuellen Konto verbinden (nach Anmelden oder Umschalten).
    func connect() {
        player.stopAndClear()
        client = accounts.current.flatMap { accounts.client(for: $0) }
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
}

#if DEBUG
/// Nur Debug: Anmeldung über die Startumgebung (Simulator-Tests ohne Passwort-Tippen).
/// HOMESPIN_SERVER, HOMESPIN_USER, HOMESPIN_PASSWORD
enum DebugLogin {
    @MainActor static func apply(to store: AccountStore) {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["HOMESPIN_SERVER"], let url = AccountStore.normalize(s),
              let user = env["HOMESPIN_USER"], let pw = env["HOMESPIN_PASSWORD"] else { return }
        if let existing = store.accounts.first(where: { $0.server == url && $0.username == user }) {
            Keychain.set(pw, for: existing.id)
            store.select(existing.id)
        } else {
            store.add(ServerAccount(server: url, username: user), password: pw)
        }
    }
}
#endif
