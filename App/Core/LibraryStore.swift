import Foundation

/// Lokaler Index der Server-Mediathek (Künstler, Alben, Titel, Playlists, Genres, Favoriten).
/// Wird auf dem Gerät zwischengespeichert, damit Sortieren, Filtern und „In … suchen“ sofort gehen –
/// und die Mediathek auch offline erscheint.
@MainActor @Observable
final class LibraryStore {
    /// Nur vom Server (ohne „Auf diesem iPhone“)
    private(set) var serverAlbums: [Album] = []
    private(set) var serverArtists: [Artist] = []
    private(set) var serverSongs: [Song] = []
    private(set) var playlists: [Playlist] = []
    private(set) var serverGenres: [Genre] = []
    private(set) var starredSongs: Set<String> = []
    private(set) var starredAlbums: Set<String> = []
    private(set) var starredArtists: Set<String> = []
    private(set) var isLoading = false
    private(set) var isOffline = false
    private(set) var lastError: String?
    private(set) var loadedOnce = false
    private(set) var serverVersion: String?

    // Startseite
    private(set) var recentlyAdded: [Album] = []
    private(set) var recentlyPlayed: [Album] = []
    private(set) var frequent: [Album] = []
    private(set) var randomAlbums: [Album] = []

    private var client: SubsonicClient?
    /// Musik auf diesem iPhone – wird in Alben, Künstler:innen, Titel und Genres eingemischt.
    @ObservationIgnored var local: LocalLibrary?
    /// Läuft, solange nach einem Verbindungsfehler automatisch neu versucht wird.
    private var retryTask: Task<Void, Never>?

    struct Snapshot: Codable {
        var albums: [Album]; var artists: [Artist]; var songs: [Song]; var playlists: [Playlist]; var genres: [Genre]
        var starredSongs: Set<String>; var starredAlbums: Set<String>; var starredArtists: Set<String>
        var recentlyAdded: [Album]; var recentlyPlayed: [Album]; var frequent: [Album]
    }

    private func cacheURL(_ account: String) -> URL {
        let d = URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appending(path: "\(account).json")
    }

    func attach(_ client: SubsonicClient?) {
        self.client = client
        serverAlbums = []; serverArtists = []; serverSongs = []; playlists = []; serverGenres = []
        starredSongs = []; starredAlbums = []; starredArtists = []
        recentlyAdded = []; recentlyPlayed = []; frequent = []; randomAlbums = []
        loadedOnce = false
        guard let client else { return }
        if let d = try? Data(contentsOf: cacheURL(client.account.id)), let s = try? JSONDecoder().decode(Snapshot.self, from: d) {
            apply(s)
            loadedOnce = true
        }
    }

    private func apply(_ s: Snapshot) {
        serverAlbums = s.albums; serverArtists = s.artists; serverSongs = s.songs; playlists = s.playlists; serverGenres = s.genres
        starredSongs = s.starredSongs; starredAlbums = s.starredAlbums; starredArtists = s.starredArtists
        recentlyAdded = s.recentlyAdded; recentlyPlayed = s.recentlyPlayed; frequent = s.frequent
    }

    private func persist() {
        guard let client else { return }
        let s = Snapshot(albums: serverAlbums, artists: serverArtists, songs: serverSongs, playlists: playlists, genres: serverGenres,
                         starredSongs: starredSongs, starredAlbums: starredAlbums, starredArtists: starredArtists,
                         recentlyAdded: recentlyAdded, recentlyPlayed: recentlyPlayed, frequent: frequent)
        let url = cacheURL(client.account.id)
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
        }
    }

    /// Kompletter Abgleich mit dem Server (Ziehen zum Aktualisieren).
    func refresh() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let status = try await client.ping()
            serverVersion = status.serverVersion
            async let al = client.allAlbums()
            async let ar = client.artists()
            async let so = client.allSongs()
            async let pl = client.playlists()
            async let ge = client.genres()
            async let st = client.starred()
            async let ra = client.albumList(.newest, size: 30)
            async let rp = client.albumList(.recent, size: 30)
            async let fr = client.albumList(.frequent, size: 30)
            async let rnd = client.albumList(.random, size: 20)
            let (a, b, c, d, e, f) = try await (al, ar, so, pl, ge, st)
            serverAlbums = a; serverArtists = b; serverSongs = c; playlists = d
            serverGenres = e.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
            starredSongs = Set((f.song ?? []).map(\.id))
            starredAlbums = Set((f.album ?? []).map(\.id))
            starredArtists = Set((f.artist ?? []).map(\.id))
            recentlyAdded = (try? await ra) ?? []
            recentlyPlayed = (try? await rp) ?? []
            frequent = (try? await fr) ?? []
            randomAlbums = (try? await rnd) ?? []
            isOffline = false
            lastError = nil
            loadedOnce = true
            persist()
        } catch {
            isOffline = (error as? URLError) != nil
            lastError = error.localizedDescription
            if isOffline { scheduleRetries() }
        }
    }

    /// Nach einem Verbindungsfehler selbst neu versuchen (2, 5, 15 s) – z. B. beim ersten Start, wenn iOS
    /// noch nach dem lokalen Netzwerk fragt und die erste Anfrage deshalb scheitert.
    private func scheduleRetries() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            for delay in [2, 5, 15] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.isOffline else { break }
                await self.refresh()   // scheitert sie, startet kein zweiter Timer (retryTask läuft ja)
                if !self.isOffline { break }
            }
            self?.retryTask = nil
        }
    }

    /// App wieder im Vordergrund: offline → sofort neu versuchen.
    func retryIfOffline() {
        guard isOffline, !isLoading else { return }
        Task { await refresh() }
    }

    func refreshPlaylists() async {
        guard let client else { return }
        if let p = try? await client.playlists() { playlists = p; persist() }
    }

    func refreshRecent() async {
        guard let client else { return }
        if let r = try? await client.albumList(.recent, size: 30) { recentlyPlayed = r }
    }

    func shuffleRandomAlbums() async {
        guard let client else { return }
        if let r = try? await client.albumList(.random, size: 20) { randomAlbums = r }
    }

    // MARK: Abfragen (Server + „Auf diesem iPhone“)

    var albums: [Album] { merged(serverAlbums, local?.albums) }
    var artists: [Artist] { merged(serverArtists, local?.artists) }
    var songs: [Song] { merged(serverSongs, local?.songs) }
    var genres: [Genre] {
        guard let l = local?.genres, !l.isEmpty else { return serverGenres }
        let known = Set(serverGenres.map(\.value))
        return (serverGenres + l.filter { !known.contains($0.value) })
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

    private func merged<T>(_ server: [T], _ local: [T]?) -> [T] {
        guard let local, !local.isEmpty else { return server }
        return server.isEmpty ? local : server + local
    }

    func album(_ id: String) -> Album? { id.isLocalID ? local?.album(id) : serverAlbums.first { $0.id == id } }
    func artist(_ id: String) -> Artist? { id.isLocalID ? local?.artist(id) : serverArtists.first { $0.id == id } }

    func songs(ofAlbum id: String) -> [Song] {
        if id.isLocalID { return local?.songs(ofAlbum: id) ?? [] }
        return serverSongs.filter { $0.albumId == id }.sorted {
            ($0.discNumber ?? 1, $0.track ?? 0, $0.title) < ($1.discNumber ?? 1, $1.track ?? 0, $1.title)
        }
    }

    func albums(ofArtist id: String) -> [Album] {
        (id.isLocalID ? local?.albums ?? [] : serverAlbums).filter { $0.artistId == id }.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    func songs(ofArtist id: String) -> [Song] {
        let albumIDs = Set(albums(ofArtist: id).map(\.id))
        return (id.isLocalID ? local?.songs ?? [] : serverSongs).filter { $0.artistId == id || albumIDs.contains($0.albumId ?? "") }
    }

    func songs(ofGenre g: String) -> [Song] { songs.filter { $0.genre == g } }
    func albums(ofGenre g: String) -> [Album] { albums.filter { $0.genre == g } }

    /// Komponist:innen aus den Titeldaten (Subsonic hat dafür keinen eigenen Endpunkt).
    var composers: [(name: String, count: Int)] {
        var c: [String: Int] = [:]
        for s in songs { for n in s.composers { c[n, default: 0] += 1 } }
        return c.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func songs(ofComposer name: String) -> [Song] { songs.filter { $0.composers.contains(name) } }

    var favoriteSongs: [Song] { songs.filter { isStarred(song: $0.id) } }

    func isStarred(song id: String) -> Bool { id.isLocalID ? local?.isStarred(id) == true : starredSongs.contains(id) }
    func isStarred(album id: String) -> Bool { id.isLocalID ? local?.isStarred(id) == true : starredAlbums.contains(id) }
    func isStarred(artist id: String) -> Bool { id.isLocalID ? local?.isStarred(id) == true : starredArtists.contains(id) }

    // MARK: Favoriten (star/unstar)

    /// Schaltet den Favoriten um und liefert den neuen Zustand (Musik auf diesem iPhone: nur auf dem Gerät).
    func toggleStar(song: Song) async -> Bool {
        if song.isLocal { return local?.toggleStar(song.id) ?? false }
        let on = !starredSongs.contains(song.id)
        guard await setStar(.song(song.id), on: on) else { return !on }
        if on { starredSongs.insert(song.id) } else { starredSongs.remove(song.id) }
        persist()
        return on
    }

    func toggleStar(album: Album) async -> Bool {
        if album.id.isLocalID { return local?.toggleStar(album.id) ?? false }
        let on = !starredAlbums.contains(album.id)
        guard await setStar(.album(album.id), on: on) else { return !on }
        if on { starredAlbums.insert(album.id) } else { starredAlbums.remove(album.id) }
        persist()
        return on
    }

    func toggleStar(artist: Artist) async -> Bool {
        if artist.id.isLocalID { return local?.toggleStar(artist.id) ?? false }
        let on = !starredArtists.contains(artist.id)
        guard await setStar(.artist(artist.id), on: on) else { return !on }
        if on { starredArtists.insert(artist.id) } else { starredArtists.remove(artist.id) }
        persist()
        return on
    }

    private func setStar(_ target: SubsonicClient.StarTarget, on: Bool) async -> Bool {
        guard let client else { return false }
        do {
            try await client.setStar(target, starred: on)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Playlists (Server + „Auf diesem iPhone“)

    /// Server-Playlists und eigene Playlists auf diesem iPhone gemischt, nach Name sortiert.
    var allPlaylists: [Playlist] {
        let own = (local?.playlists ?? []).map { localModel($0, withSongs: false) }
        guard !own.isEmpty else { return playlists }
        return (playlists + own).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Titel einer Playlist auf diesem iPhone auflösen (lokale Titel und, falls bekannt, Server-Titel).
    private func resolve(_ ids: [String]) -> [Song] {
        let server = serverSongs.isEmpty ? [:] : Dictionary(serverSongs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let own = Dictionary((local?.songs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { own[$0] ?? server[$0] }
    }

    private func localModel(_ p: LocalPlaylist, withSongs: Bool) -> Playlist {
        let songs = resolve(p.songIDs)
        let iso = ISO8601DateFormatter()
        return Playlist(id: p.id, name: p.name, comment: p.comment, owner: nil, public: false, songCount: songs.count,
                        duration: songs.reduce(0) { $0 + ($1.duration ?? 0) }, created: iso.string(from: p.created),
                        changed: iso.string(from: p.changed), coverArt: songs.lazy.compactMap(\.coverArt).first,
                        readonly: false, entry: withSongs ? songs : nil)
    }

    func createPlaylist(name: String, comment: String, songs ids: [String], onDevice: Bool = false) async throws -> Playlist {
        if onDevice || client == nil {
            guard let local else { throw SubsonicError.badResponse }
            return localModel(local.createPlaylist(name: name, comment: comment, songIDs: ids), withSongs: false)
        }
        guard let client else { throw SubsonicError.badResponse }
        var p = try await client.createPlaylist(name: name, songIds: ids)
        if !comment.isEmpty {
            try await client.updatePlaylist(id: p.id, comment: comment)
            p.comment = comment
        }
        await refreshPlaylists()
        return p
    }

    func add(_ ids: [String], to playlist: Playlist) async throws {
        if playlist.id.isLocalPlaylistID { local?.addToPlaylist(playlist.id, songIDs: ids); return }
        guard let client else { return }
        try await client.updatePlaylist(id: playlist.id, add: ids)
        await refreshPlaylists()
    }

    /// Speichert Name, Beschreibung und die komplette Titelreihenfolge.
    func save(playlist: Playlist, name: String, comment: String, songs ids: [String]) async throws {
        if playlist.id.isLocalPlaylistID { local?.updatePlaylist(playlist.id, name: name, comment: comment, songIDs: ids); return }
        guard let client else { return }
        try await client.updatePlaylist(id: playlist.id, name: name, comment: comment)
        try await client.replacePlaylistSongs(id: playlist.id, songIds: ids)
        await refreshPlaylists()
    }

    func remove(indexes: [Int], from playlist: Playlist) async throws {
        if playlist.id.isLocalPlaylistID { local?.removeFromPlaylist(playlist.id, at: IndexSet(indexes)); return }
        guard let client else { return }
        try await client.updatePlaylist(id: playlist.id, removeIndexes: indexes)
        await refreshPlaylists()
    }

    func delete(playlist: Playlist) async throws {
        if playlist.id.isLocalPlaylistID { local?.deletePlaylist(playlist.id); return }
        guard let client else { return }
        try await client.deletePlaylist(id: playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        persist()
    }

    func playlistSongs(_ id: String) async throws -> Playlist {
        if id.isLocalPlaylistID {
            guard let p = local?.playlist(id) else { throw LocalError.missing }
            return localModel(p, withSongs: true)
        }
        guard let client else { throw SubsonicError.badResponse }
        return try await client.playlist(id: id)
    }
}
