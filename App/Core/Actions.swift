import Foundation

/// Aktionen, die Menüs, Wischgesten und Knöpfe gemeinsam nutzen (Apple: `…ActionImplementation`).
extension AppModel {
    func songs(of album: Album) async -> [Song] {
        let local = library.songs(ofAlbum: album.id)
        if !local.isEmpty { return local }
        return (try? await client?.album(id: album.id).song) ?? downloads.downloadedSongs.filter { $0.albumId == album.id }
    }

    func songs(of artist: Artist) async -> [Song] {
        var albums = library.albums(ofArtist: artist.id)
        if albums.isEmpty, let a = try? await client?.artist(id: artist.id) { albums = a.album ?? [] }
        var out: [Song] = []
        for al in albums.sorted(by: { ($0.year ?? 0, $0.name) < ($1.year ?? 0, $1.name) }) {
            out += await songs(of: al)
        }
        return out
    }

    func songs(of playlist: Playlist) async -> [Song] {
        (try? await library.playlistSongs(playlist.id).entry) ?? []
    }

    func toggleFavorite(_ song: Song) {
        Task {
            let on = await library.toggleStar(song: song)
            var s = song
            s.starred = on ? ISO8601DateFormatter().string(from: Date()) : nil
            player.updateSong(s)
            notice.show(on ? String(localized: "Favorisiert") : String(localized: "„Favorit“ widerrufen"),
                        icon: on ? "star.fill" : "star.slash")
        }
    }

    func toggleFavorite(_ album: Album) {
        Task {
            let on = await library.toggleStar(album: album)
            notice.show(on ? String(localized: "Favorisiert") : String(localized: "„Favorit“ widerrufen"), icon: on ? "star.fill" : "star.slash")
        }
    }

    func toggleFavorite(_ artist: Artist) {
        Task {
            let on = await library.toggleStar(artist: artist)
            notice.show(on ? String(localized: "Favorisiert") : String(localized: "„Favorit“ widerrufen"), icon: on ? "star.fill" : "star.slash")
        }
    }

    func download(_ songs: [Song]) {
        downloads.download(songs)
        notice.show(String(localized: "Wird geladen"), icon: "arrow.down.circle")
    }

    func removeDownload(_ songs: [Song]) {
        downloads.remove(songs)
        notice.show(String(localized: "Download entfernt"), icon: "trash")
    }

    /// Ganze Mediathek zufällig (Apple: „Alles zufällig“).
    func shuffleAll() {
        Task {
            var songs = library.songs
            if songs.isEmpty, let r = try? await client?.randomSongs(size: 200) { songs = r }
            if library.isOffline { songs = downloads.downloadedSongs }
            player.play(songs, name: String(localized: "Mediathek"), shuffle: true)
        }
    }
}
