import SwiftUI

/// Woher ein Titel-Menü kommt (bestimmt Zusatzpunkte wie „Aus Playlist entfernen“)
enum SongMenuSource {
    case library
    case playlist(Playlist, remove: () -> Void)
    case nowPlaying
}

/// „Zur Playlist hinzufügen ▸“ – oben „Neue Playlist“, dann alle eigenen Playlists
struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let songs: () async -> [Song]

    var body: some View {
        Menu("Zur Playlist hinzufügen") {
            Button("Neue Playlist") { Task { mac.newPlaylist = await songs() } }
            Divider()
            ForEach(app.library.allPlaylists.filter { $0.readonly != true }) { p in
                Button(p.name) { Task { mac.add(await songs(), to: p) } }
            }
        }
    }
}

/// Kontextmenü für einen oder mehrere Titel (Apple-Reihenfolge, Gruppen mit Trennern)
struct SongContextMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let songs: [Song]
    var source: SongMenuSource = .library

    var body: some View {
        let one = songs.count == 1 ? songs.first : nil
        let allFav = !songs.isEmpty && songs.allSatisfy { app.library.isStarred(song: $0.id) }
        let server = songs.filter { !$0.isLocal }
        AddToPlaylistMenu { songs }
        Divider()
        Button("Als Nächstes wiedergeben") { app.player.playNext(songs) }
        Button("Zuletzt wiedergeben") { app.player.playLast(songs) }
        if let one, !one.isLocal, app.client != nil {
            Button("Sender erstellen") { mac.startStation(from: one) }
        }
        Divider()
        Button(allFav ? "„Favorit“ widerrufen" : "Favorit") {
            for s in songs where app.library.isStarred(song: s.id) == allFav { app.toggleFavorite(s) }
        }
        if !server.isEmpty, app.client != nil {
            Menu("Bewertung") {
                Button("Ohne") { mac.setRating(server, 0) }
                ForEach(1...5, id: \.self) { n in
                    Button(String(repeating: "★", count: n)) { mac.setRating(server, n) }
                }
            }
        }
        Divider()
        Button("Informationen") { mac.showInfo(songs) }
        Divider()
        if let one {
            if let id = one.artistId { Button("Künstler:in in Mediathek anzeigen") { mac.showArtist(id) } }
            if let id = one.albumId { Button("Album in Mediathek anzeigen") { mac.showAlbum(id) } }
            Divider()
        }
        if !server.isEmpty, app.client != nil {
            Button("Link kopieren") { mac.shareLink(server) }
        }
        Button("Kopieren") { mac.copyToPasteboard(songs) }
        Divider()
        if !server.isEmpty {
            if server.allSatisfy({ app.downloads.isDownloaded($0.id) }) {
                Button("Download entfernen") { app.removeDownload(server) }
            } else {
                Button("Laden") { app.download(server) }
                if server.contains(where: { app.downloads.isDownloaded($0.id) }) {
                    Button("Download entfernen") { app.removeDownload(server) }
                }
            }
        }
        if songs.contains(where: { $0.isLocal || app.downloads.isDownloaded($0.id) }) {
            Button("Im Finder anzeigen") { mac.revealInFinder(songs) }
        }
        if case .playlist(let p, let remove) = source, p.readonly != true {
            Divider()
            Button("Aus Playlist entfernen", role: .destructive, action: remove)
        }
        if songs.contains(where: \.isLocal) {
            Divider()
            Button("Aus „Auf diesem Mac“ entfernen …", role: .destructive) { app.removeLocal(songs.filter(\.isLocal)) }
        }
    }
}

struct AlbumContextMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let album: Album
    var showGoToArtist = true

    var body: some View {
        Button("Wiedergeben") { Task { mac.play(await app.songs(of: album), name: album.name) } }
        Button("Zufällig wiedergeben") { Task { mac.play(await app.songs(of: album), name: album.name, shuffle: true) } }
        Divider()
        Button("Als Nächstes wiedergeben") { Task { app.player.playNext(await app.songs(of: album)) } }
        Button("Zuletzt wiedergeben") { Task { app.player.playLast(await app.songs(of: album)) } }
        Divider()
        AddToPlaylistMenu { await app.songs(of: album) }
        Divider()
        Button(app.library.isStarred(album: album.id) ? "„Favorit“ widerrufen" : "Favorit") { app.toggleFavorite(album) }
        if !album.id.isLocalID {
            Divider()
            let songs = app.library.songs(ofAlbum: album.id)
            if !app.downloads.allDownloaded(songs) {
                Button("Laden") { Task { app.download(await app.songs(of: album)) } }
            }
            if app.downloads.anyDownloaded(songs) {
                Button("Download entfernen") { app.removeDownload(songs) }
            }
        }
        if showGoToArtist, let id = album.artistId {
            Divider()
            Button("Zu Künstler:in") { mac.showArtist(id) }
        }
        if !album.id.isLocalID, app.client != nil {
            Divider()
            Button("Link kopieren") { Task { mac.shareLink(await app.songs(of: album)) } }
        }
        if album.id.isLocalID {
            Divider()
            Button("Aus „Auf diesem Mac“ entfernen …", role: .destructive) { app.removeLocal(app.library.songs(ofAlbum: album.id)) }
        }
    }
}

struct ArtistContextMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let artist: Artist

    var body: some View {
        Button("Wiedergeben") { Task { mac.play(await app.songs(of: artist), name: artist.name) } }
        Button("Zufällig wiedergeben") { Task { mac.play(await app.songs(of: artist), name: artist.name, shuffle: true) } }
        Divider()
        Button("Als Nächstes wiedergeben") { Task { app.player.playNext(await app.songs(of: artist)) } }
        Button("Zuletzt wiedergeben") { Task { app.player.playLast(await app.songs(of: artist)) } }
        Divider()
        AddToPlaylistMenu { await app.songs(of: artist) }
        Button(app.library.isStarred(artist: artist.id) ? "„Favorit“ widerrufen" : "Favorit") { app.toggleFavorite(artist) }
        if !artist.id.isLocalID {
            Divider()
            Button("Laden") { Task { app.download(await app.songs(of: artist)) } }
        }
    }
}

struct PlaylistContextMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let playlist: Playlist

    var body: some View {
        Button("Wiedergeben") { Task { mac.play(await app.songs(of: playlist), name: playlist.name) } }
        Button("Zufällig wiedergeben") { Task { mac.play(await app.songs(of: playlist), name: playlist.name, shuffle: true) } }
        Divider()
        Button("Als Nächstes wiedergeben") { Task { app.player.playNext(await app.songs(of: playlist)) } }
        Button("Zuletzt wiedergeben") { Task { app.player.playLast(await app.songs(of: playlist)) } }
        if !playlist.id.isLocalPlaylistID {
            Divider()
            Button("Laden") { Task { app.download(await app.songs(of: playlist)) } }
            Button("Download entfernen") { Task { app.removeDownload(await app.songs(of: playlist)) } }
        }
        Divider()
        if playlist.readonly != true {
            Button("Umbenennen") { mac.renamingPlaylist = playlist.id }
        }
        Button("Duplizieren") { mac.duplicate(playlist) }
        Divider()
        Button("Löschen …", role: .destructive) { mac.deletePlaylistQuestion = playlist }
    }
}

struct GenreContextMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let songs: [Song]
    let name: String

    var body: some View {
        Button("Wiedergeben") { mac.play(songs, name: name) }
        Button("Zufällig wiedergeben") { mac.play(songs, name: name, shuffle: true) }
        Divider()
        Button("Als Nächstes wiedergeben") { app.player.playNext(songs) }
        Button("Zuletzt wiedergeben") { app.player.playLast(songs) }
    }
}
