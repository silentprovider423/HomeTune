import Foundation

/// Lokaler Index der Server-Mediathek (Künstler, Alben, Titel, Playlists, Genres, Favoriten).
/// Wird auf dem Gerät zwischengespeichert, damit Sortieren, Filtern und „In … suchen“ sofort gehen –
/// und die Mediathek auch offline erscheint.
@MainActor @Observable
final class LibraryStore {
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var songs: [Song] = []
    private(set) var playlists: [Playlist] = []
    private(set) var genres: [Genre] = []
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
        albums = []; artists = []; songs = []; playlists = []; genres = []
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
        albums = s.albums; artists = s.artists; songs = s.songs; playlists = s.playlists; genres = s.genres
        starredSongs = s.starredSongs; starredAlbums = s.starredAlbums; starredArtists = s.starredArtists
        recentlyAdded = s.recentlyAdded; recentlyPlayed = s.recentlyPlayed; frequent = s.frequent
    }

    private func persist() {
        guard let client else { return }
        let s = Snapshot(albums: albums, artists: artists, songs: songs, playlists: playlists, genres: genres,
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
            albums = a; artists = b; songs = c; playlists = d
            genres = e.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
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
        }
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

    // MARK: Abfragen

    func album(_ id: String) -> Album? { albums.first { $0.id == id } }
    func artist(_ id: String) -> Artist? { artists.first { $0.id == id } }

    func songs(ofAlbum id: String) -> [Song] {
        songs.filter { $0.albumId == id }.sorted {
            ($0.discNumber ?? 1, $0.track ?? 0, $0.title) < ($1.discNumber ?? 1, $1.track ?? 0, $1.title)
        }
    }

    func albums(ofArtist id: String) -> [Album] {
        albums.filter { $0.artistId == id }.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    func songs(ofArtist id: String) -> [Song] {
        let albumIDs = Set(albums(ofArtist: id).map(\.id))
        return songs.filter { $0.artistId == id || albumIDs.contains($0.albumId ?? "") }
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

    var favoriteSongs: [Song] { songs.filter { starredSongs.contains($0.id) } }

    func isStarred(song id: String) -> Bool { starredSongs.contains(id) }
    func isStarred(album id: String) -> Bool { starredAlbums.contains(id) }
    func isStarred(artist id: String) -> Bool { starredArtists.contains(id) }

    // MARK: Favoriten (star/unstar)

    /// Schaltet den Favoriten um und liefert den neuen Zustand.
    func toggleStar(song: Song) async -> Bool {
        let on = !starredSongs.contains(song.id)
        guard await setStar(.song(song.id), on: on) else { return !on }
        if on { starredSongs.insert(song.id) } else { starredSongs.remove(song.id) }
        persist()
        return on
    }

    func toggleStar(album: Album) async -> Bool {
        let on = !starredAlbums.contains(album.id)
        guard await setStar(.album(album.id), on: on) else { return !on }
        if on { starredAlbums.insert(album.id) } else { starredAlbums.remove(album.id) }
        persist()
        return on
    }

    func toggleStar(artist: Artist) async -> Bool {
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

    // MARK: Playlists

    func createPlaylist(name: String, comment: String, songs ids: [String]) async throws -> Playlist {
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
        guard let client else { return }
        try await client.updatePlaylist(id: playlist.id, add: ids)
        await refreshPlaylists()
    }

    /// Speichert Name, Beschreibung und die komplette Titelreihenfolge.
    func save(playlist: Playlist, name: String, comment: String, songs ids: [String]) async throws {
        guard let client else { return }
        try await client.updatePlaylist(id: playlist.id, name: name, comment: comment)
        try await client.replacePlaylistSongs(id: playlist.id, songIds: ids)
        await refreshPlaylists()
    }

    func remove(indexes: [Int], from playlist: Playlist) async throws {
        guard let client else { return }
        try await client.updatePlaylist(id: playlist.id, removeIndexes: indexes)
        await refreshPlaylists()
    }

    func delete(playlist: Playlist) async throws {
        guard let client else { return }
        try await client.deletePlaylist(id: playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        persist()
    }

    func playlistSongs(_ id: String) async throws -> Playlist {
        guard let client else { throw SubsonicError.badResponse }
        return try await client.playlist(id: id)
    }
}
