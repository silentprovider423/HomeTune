import SwiftUI
import AppKit

/// Einträge der Seitenleiste
enum SidebarItem: Hashable, Codable {
    case home, allPlaylists, favorites
    case library(MacSection)
    case playlist(String)
}

/// Woher die Musik der Mediathek kommt (Umschalter über den Listen, Menü „Darstellung“)
enum MusicSource: String, CaseIterable, Identifiable {
    case all, server, local
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "Alle"
        case .server: "Server"
        case .local: "Auf diesem Mac"
        }
    }

    /// Im Menü „Darstellung“ ausgeschrieben
    var menuTitle: LocalizedStringKey {
        switch self {
        case .all: "Musik von Server und Mac"
        case .server: "Nur Musik vom Server"
        case .local: "Nur Musik auf diesem Mac"
        }
    }

    var icon: String {
        switch self {
        case .all: "music.note"
        case .server: "cloud"
        case .local: "desktopcomputer"
        }
    }
}

/// Mediathek-Einträge der Seitenleiste (Apple: einzeln ein-/ausblendbar über „Bearbeiten“)
enum MacSection: String, CaseIterable, Codable, Identifiable, Hashable {
    case recentlyAdded, artists, albums, songs, genres, composers, compilations, downloaded, onThisMac
    var id: String { rawValue }

    /// Ab Werk sichtbar (Rest ausgeblendet)
    static let defaultVisible: Set<MacSection> = [.recentlyAdded, .artists, .albums, .songs]

    var title: LocalizedStringKey {
        switch self {
        case .recentlyAdded: "Zuletzt hinzugefügt"
        case .artists: "Künstler:innen"
        case .albums: "Alben"
        case .songs: "Titel"
        case .genres: "Genres"
        case .composers: "Komponist:innen"
        case .compilations: "Compilations"
        case .downloaded: "Geladen"
        case .onThisMac: "Auf diesem Mac"
        }
    }

    var icon: String {
        switch self {
        case .recentlyAdded: "clock"
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .composers: "music.quarternote.3"
        case .compilations: "person.2.crop.square.stack"
        case .downloaded: "arrow.down.circle"
        case .onThisMac: "desktopcomputer"
        }
    }

    /// ⌃⌘1 … ⌃⌘6 (Apple: versteckte Kürzel)
    var shortcut: KeyEquivalent? {
        switch self {
        case .recentlyAdded: "1"
        case .artists: "2"
        case .albums: "3"
        case .songs: "4"
        case .genres: "5"
        case .composers: "6"
        default: nil
        }
    }
}

/// Detailseiten innerhalb eines Seitenleisten-Eintrags (Zurück mit ⌘[)
enum MacRoute: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case genre(String)
    case composer(String)
}

enum InspectorPanel: String { case queue, lyrics }

/// Größe der Liste (Einstellungen → Allgemein)
enum ListSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var fontSize: CGFloat { switch self { case .small: 11; case .medium: 13; case .large: 15 } }
    var rowHeight: CGFloat { switch self { case .small: 20; case .medium: 24; case .large: 30 } }
    var title: LocalizedStringKey { switch self { case .small: "Klein"; case .medium: "Mittel"; case .large: "Groß" } }
}

/// Sortierung im Raster (Alben, Zuletzt hinzugefügt)
enum AlbumSort: String, CaseIterable, Identifiable {
    case title, artist, year, added, played
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .title: "sort.title"
        case .artist: "Künstler:in"
        case .year: "Jahr"
        case .added: "Zuletzt hinzugefügt"
        case .played: "Zuletzt gespielt"
        }
    }
}

/// Wiedergabe, die auf die Antwort „Warteliste behalten?“ wartet
struct PendingPlay: Identifiable {
    let id = UUID()
    let songs: [Song]
    let startAt: Int?
    let name: String?
    let shuffle: Bool
    let queued: Int
}

/// Rückfrage „bereits in der Playlist“
struct DuplicateQuestion: Identifiable {
    let id = UUID()
    let playlist: Playlist
    let songs: [Song]
    let duplicates: Set<String>
}

/// Zustand des Mac-Fensters: Seitenleiste, Navigation, rechte Spalte, Suche, Filter, Auswahl.
@MainActor @Observable
final class MacModel {
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let d = UserDefaults.standard
    /// Öffnet das Hauptfenster wieder (vom Fenster gesetzt)
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openWindow: ((String) -> Void)?
    /// Öffnet die Einstellungen (vom Fenster gesetzt)
    @ObservationIgnored var openSettings: (() -> Void)?

    var selection: SidebarItem? = .library(.albums) {
        didSet {
            if oldValue != selection { path = [] }
            if let s = selection, let data = try? JSONEncoder().encode(s) { d.set(data, forKey: "mac.selection") }
        }
    }
    var path: [MacRoute] = []
    var artistSelection: String?
    var genreSelection: String?
    var composerSelection: String?

    var inspector: InspectorPanel? {
        didSet { d.set(inspector?.rawValue ?? "", forKey: "mac.inspector") }
    }
    var queueTab: Int {
        didSet { d.set(queueTab, forKey: "mac.queueTab") }
    }
    var autoplay: Bool {
        didSet { d.set(autoplay, forKey: "mac.autoplay") }
    }

    var search = ""
    var searchFocused = false
    var filter = ""
    var showFilter = false {
        didSet { if !showFilter { filter = "" } }
    }
    var showStatusBar: Bool {
        didSet { d.set(showStatusBar, forKey: "mac.statusBar") }
    }
    var visibleSections: Set<MacSection> {
        didSet { d.set(visibleSections.map(\.rawValue), forKey: "mac.sections") }
    }
    var editingSections = false
    var listSize: ListSize {
        didSet { d.set(listSize.rawValue, forKey: "mac.listSize") }
    }
    var showFavoritesColumn: Bool {
        didSet { d.set(showFavoritesColumn, forKey: "mac.showFavorites") }
    }
    var onlyDownloaded: Bool {
        didSet { d.set(onlyDownloaded, forKey: "mac.onlyDownloaded") }
    }
    /// Gewählte Quelle; wirkt nur, solange es Server und Musik auf diesem Mac zugleich gibt (siehe `activeSource`)
    var source: MusicSource {
        didSet { d.set(source.rawValue, forKey: "mac.source") }
    }
    var albumSort: AlbumSort {
        didSet { d.set(albumSort.rawValue, forKey: "mac.albumSort") }
    }
    var albumSortAscending: Bool {
        didSet { d.set(albumSortAscending, forKey: "mac.albumSortAsc") }
    }

    /// Aktuelle Auswahl einer Titelliste (für das Menü „Titel“) und sichtbare Titel (Statusleiste)
    var selectedSongs: [Song] = []
    var visibleSongs: [Song] = []
    /// Playlist, deren Titelliste gerade den Fokus hat (für „Aus Playlist entfernen“)
    var focusedPlaylist: Playlist?
    @ObservationIgnored var removeSelectionFromPlaylist: (() -> Void)?

    // Blätter und Rückfragen
    var showLogin = false
    var newPlaylist: [Song]?
    var keepQueueQuestion: PendingPlay?
    var duplicateQuestion: DuplicateQuestion?
    var deletePlaylistQuestion: Playlist?
    var renamingPlaylist: String?
    var infoSongs: [Song] = []
    var fullScreenPlayer = false

    init() {
        if let data = d.data(forKey: "mac.selection"), let s = try? JSONDecoder().decode(SidebarItem.self, from: data) {
            selection = s
        }
        inspector = InspectorPanel(rawValue: d.string(forKey: "mac.inspector") ?? "")
        queueTab = d.integer(forKey: "mac.queueTab")
        autoplay = d.bool(forKey: "mac.autoplay")
        showStatusBar = d.bool(forKey: "mac.statusBar")
        if let raw = d.stringArray(forKey: "mac.sections") {
            visibleSections = Set(raw.compactMap(MacSection.init(rawValue:)))
        } else {
            visibleSections = MacSection.defaultVisible
        }
        listSize = ListSize(rawValue: d.string(forKey: "mac.listSize") ?? "") ?? .medium
        showFavoritesColumn = d.object(forKey: "mac.showFavorites") as? Bool ?? true
        onlyDownloaded = d.bool(forKey: "mac.onlyDownloaded")
        source = MusicSource(rawValue: d.string(forKey: "mac.source") ?? "") ?? .all
        albumSort = AlbumSort(rawValue: d.string(forKey: "mac.albumSort") ?? "") ?? .title
        albumSortAscending = d.object(forKey: "mac.albumSortAsc") as? Bool ?? true
    }

    // MARK: Navigation

    func go(_ item: SidebarItem) {
        search = ""
        selection = item
        path = []
    }

    func open(_ route: MacRoute) {
        search = ""
        path.append(route)
    }

    func back() { if !path.isEmpty { path.removeLast() } }

    /// „Künstler:in in Mediathek anzeigen“
    func showArtist(_ id: String) {
        search = ""
        visibleSections.insert(.artists)
        selection = .library(.artists)
        path = []
        artistSelection = id
    }

    /// „Album in Mediathek anzeigen“
    func showAlbum(_ id: String) {
        search = ""
        visibleSections.insert(.albums)
        selection = .library(.albums)
        path = [.album(id)]
    }

    func showPlaylist(_ id: String) {
        search = ""
        selection = .playlist(id)
    }

    /// „Zum aktuellen Titel“ (⌘L): Album des laufenden Titels öffnen
    func revealCurrent() {
        guard let s = app?.player.currentSong, let id = s.albumId else { return }
        showAlbum(id)
    }

    func toggleInspector(_ panel: InspectorPanel) {
        withAnimation(.easeInOut(duration: 0.25)) {
            inspector = inspector == panel ? nil : panel
        }
    }

    // MARK: Wiedergabe mit Rückfrage „Warteliste behalten“

    func play(_ songs: [Song], startAt: Int? = nil, name: String? = nil, shuffle: Bool = false) {
        guard let app, !songs.isEmpty else { return }
        let queued = app.player.queue.upNext.filter { $0.origin == .user }.count
        if queued > 0 && !d.bool(forKey: "mac.keepQueue.dontAsk") {
            keepQueueQuestion = PendingPlay(songs: songs, startAt: startAt, name: name, shuffle: shuffle, queued: queued)
        } else {
            app.player.play(songs, startAt: startAt, name: name, shuffle: shuffle)
        }
    }

    func answerKeepQueue(clear: Bool, dontAsk: Bool) {
        guard let p = keepQueueQuestion, let app else { return }
        keepQueueQuestion = nil
        if dontAsk { d.set(true, forKey: "mac.keepQueue.dontAsk") }
        app.player.play(p.songs, startAt: p.startAt, name: p.name, shuffle: p.shuffle, clearUpNext: clear)
    }

    static func resetWarnings() {
        UserDefaults.standard.removeObject(forKey: "mac.keepQueue.dontAsk")
    }

    // MARK: Playlists

    /// Titel zu einer Playlist hinzufügen – bei Doppelten erst nachfragen (wie iOS)
    func add(_ songs: [Song], to playlist: Playlist) {
        guard let app, !songs.isEmpty else { return }
        Task {
            let existing = Set((try? await app.library.playlistSongs(playlist.id).entry)?.map(\.id) ?? [])
            let dups = Set(songs.map(\.id)).intersection(existing)
            if dups.isEmpty {
                await commitAdd(songs, to: playlist)
            } else {
                duplicateQuestion = DuplicateQuestion(playlist: playlist, songs: songs, duplicates: dups)
            }
        }
    }

    func answerDuplicates(addAgain: Bool) {
        guard let q = duplicateQuestion else { return }
        duplicateQuestion = nil
        let songs = addAgain ? q.songs : q.songs.filter { !q.duplicates.contains($0.id) }
        guard !songs.isEmpty else { return }
        Task { await commitAdd(songs, to: q.playlist) }
    }

    private func commitAdd(_ songs: [Song], to playlist: Playlist) async {
        guard let app else { return }
        do {
            try await app.library.add(songs.map(\.id), to: playlist)
            app.notice.show(String(localized: "Zu „\(playlist.name)“ hinzugefügt"), icon: "text.badge.plus")
            NotificationCenter.default.post(name: .playlistChanged, object: playlist.id)
        } catch {
            app.notice.show(error.localizedDescription, icon: "exclamationmark.triangle")
        }
    }

    func createPlaylist(name: String, comment: String, songs: [Song], onDevice: Bool) {
        guard let app else { return }
        Task {
            do {
                let p = try await app.library.createPlaylist(name: name, comment: comment, songs: songs.map(\.id), onDevice: onDevice)
                showPlaylist(p.id)
            } catch {
                app.notice.show(error.localizedDescription, icon: "exclamationmark.triangle")
            }
        }
    }

    /// „Playlist aus Auswahl“: sofort anlegen, Name in der Seitenleiste zum Umbenennen markieren
    func playlistFromSelection() {
        guard let app else { return }
        let songs = selectedSongs
        Task {
            let local = app.client == nil
            guard let p = try? await app.library.createPlaylist(name: String(localized: "Neue Playlist"), comment: "",
                                                                songs: songs.map(\.id), onDevice: local) else { return }
            showPlaylist(p.id)
            renamingPlaylist = p.id
        }
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard let app, !name.isEmpty, name != playlist.name else { return }
        Task {
            do {
                let full = try await app.library.playlistSongs(playlist.id)
                try await app.library.save(playlist: playlist, name: name, comment: playlist.comment ?? "",
                                           songs: (full.entry ?? []).map(\.id))
                NotificationCenter.default.post(name: .playlistChanged, object: playlist.id)
            } catch {
                app.notice.show(error.localizedDescription, icon: "exclamationmark.triangle")
            }
        }
    }

    func duplicate(_ playlist: Playlist) {
        guard let app else { return }
        Task {
            let songs = await app.songs(of: playlist)
            let name = String(localized: "\(playlist.name) Kopie")
            if let p = try? await app.library.createPlaylist(name: name, comment: playlist.comment ?? "", songs: songs.map(\.id),
                                                             onDevice: playlist.id.isLocalPlaylistID || app.client == nil) {
                showPlaylist(p.id)
            }
        }
    }

    func delete(_ playlist: Playlist) {
        guard let app else { return }
        Task {
            do {
                try await app.library.delete(playlist: playlist)
                if selection == .playlist(playlist.id) { selection = .allPlaylists }
            } catch {
                app.notice.show(error.localizedDescription, icon: "exclamationmark.triangle")
            }
        }
    }

    // MARK: Menü „Titel“ – Hilfen

    /// Titel ins Finder-Fenster: nur geladene Titel und Musik auf diesem Mac
    func revealInFinder(_ songs: [Song]) {
        guard let app else { return }
        let urls = songs.compactMap { s -> URL? in
            if s.isLocal { return try? app.local.fileURL(for: s) }
            return app.downloads.localFile(s.id)
        }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func copyToPasteboard(_ songs: [Song]) {
        let text = songs.map { [$0.title, $0.artist].compactMap { $0 }.joined(separator: " – ") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func shareLink(_ songs: [Song]) {
        guard let app, let client = app.client else { return }
        let ids = songs.filter { !$0.isLocal }.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            do {
                if let url = try await client.createShare(ids: ids) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    app.notice.show(String(localized: "Link kopiert"), icon: "link")
                }
            } catch {
                app.notice.show(String(localized: "Teilen ist am Server nicht aktiviert"), icon: "exclamationmark.triangle")
            }
        }
    }

    /// „Sender erstellen“: ähnliche Titel vom Server abspielen
    func startStation(from song: Song) {
        guard let app, let client = app.client, !song.isLocal else { return }
        Task {
            let similar = (try? await client.similarSongs(id: song.id, count: 50)) ?? []
            app.player.play([song] + similar.filter { $0.id != song.id }, name: String(localized: "Sender: \(song.title)"))
        }
    }

    func setRating(_ songs: [Song], _ rating: Int) {
        guard let app, let client = app.client else { return }
        Task {
            for s in songs where !s.isLocal { try? await client.setRating(id: s.id, rating: rating) }
            app.notice.show(rating == 0 ? String(localized: "Bewertung entfernt") : String(localized: "Bewertet"), icon: "star")
        }
    }

    func showInfo(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        infoSongs = songs
        openWindow?("info")
    }

    /// Ganze Ansicht neu vom Server holen (⌘R)
    func reload() {
        guard let app else { return }
        Task { await app.library.refresh() }
        NotificationCenter.default.post(name: .playlistChanged, object: nil)
    }

    // MARK: Hilfen für Listen

    /// „Nur geladene Musik“ (Darstellung): nur Geladenes und Musik auf diesem Mac
    func available(_ songs: [Song]) -> [Song] {
        guard onlyDownloaded, let app else { return songs }
        return songs.filter { $0.isLocal || app.downloads.isDownloaded($0.id) }
    }

    func available(_ albums: [Album]) -> [Album] {
        guard onlyDownloaded, let app else { return albums }
        let ids = Set(app.downloads.downloadedSongs.compactMap(\.albumId))
        return albums.filter { $0.id.isLocalID || ids.contains($0.id) }
    }

    /// Server und Musik auf diesem Mac zugleich vorhanden: nur dann gibt es etwas zu unterscheiden
    var hasBothSources: Bool {
        guard let app else { return false }
        return app.client != nil && !app.local.songs.isEmpty
    }

    var activeSource: MusicSource { hasBothSources ? source : .all }

    /// Umschalter „Alle · Server · Auf diesem Mac“ (IDs mit „local“-Vorsatz liegen auf diesem Mac)
    func inSource(_ id: String) -> Bool {
        switch activeSource {
        case .all: true
        case .server: !id.isLocalID
        case .local: id.isLocalID
        }
    }

    func inSource(_ songs: [Song]) -> [Song] { activeSource == .all ? songs : songs.filter { inSource($0.id) } }
    func inSource(_ albums: [Album]) -> [Album] { activeSource == .all ? albums : albums.filter { inSource($0.id) } }
    func inSource(_ artists: [Artist]) -> [Artist] { activeSource == .all ? artists : artists.filter { inSource($0.id) } }

    func sorted(_ albums: [Album]) -> [Album] {
        let asc = albumSortAscending
        func cmp(_ a: String?, _ b: String?) -> Bool { (a ?? "").localizedStandardCompare(b ?? "") == .orderedAscending }
        let s: [Album] = switch albumSort {
        case .title: albums.sorted { cmp($0.name, $1.name) }
        case .artist: albums.sorted { ($0.artist ?? "") == ($1.artist ?? "") ? cmp($0.name, $1.name) : cmp($0.artist, $1.artist) }
        case .year: albums.sorted { ($0.year ?? 0, $0.name) < ($1.year ?? 0, $1.name) }
        case .added: albums.sorted { ($0.created ?? "") < ($1.created ?? "") }
        case .played: albums.sorted { ($0.played ?? "") < ($1.played ?? "") }
        }
        return asc ? s : s.reversed()
    }

    /// Filterfeld (⌥⌘F): nur die aktuelle Liste
    func matches(_ text: String?...) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return true }
        return text.contains { $0?.localizedStandardContains(f) == true }
    }
}

extension Notification.Name {
    /// Inhalt einer Playlist hat sich geändert (object = Playlist-ID oder nil für alle)
    static let playlistChanged = Notification.Name("HomeTune.playlistChanged")
}
