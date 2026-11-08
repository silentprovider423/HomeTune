import SwiftUI

// Kontextmenüs je Objektart, wie Apples SongContextMenu/AlbumContextMenu/… aus Menü-Providern
// (Wiedergabe · Mediathek/Playlist · Favorit · Laden · Gehe zu).

struct SongMenu: View {
    @Environment(AppModel.self) private var app
    let song: Song
    var showGoToAlbum = true
    var showGoToArtist = true
    var onRemoveFromPlaylist: (() -> Void)?

    var body: some View {
        if !song.isLocal {
            Section {
                Button("Zur Playlist hinzufügen …", systemImage: "text.badge.plus") { app.addToPlaylist = [song] }
            }
        }
        Section {
            Button("Als Nächstes wiedergeben", systemImage: "text.line.first.and.arrowtriangle.forward") { app.player.playNext([song]) }
            Button("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward") { app.player.playLast([song]) }
        }
        Section {
            let fav = app.library.isStarred(song: song.id)
            Button(fav ? LocalizedStringKey("„Favorit“ widerrufen") : LocalizedStringKey("Als Favoriten markieren"), systemImage: fav ? "star.slash" : "star") {
                app.toggleFavorite(song)
            }
            if song.isLocal {
                // Musik auf diesem iPhone: nichts zu laden; Entfernen löscht nie die Originaldatei
            } else if app.downloads.isDownloaded(song.id) {
                Button("Download entfernen", systemImage: "trash") { app.removeDownload([song]) }
            } else {
                Button("Laden", systemImage: "arrow.down.circle") { app.download([song]) }
            }
        }
        Section {
            if showGoToAlbum, song.albumId != nil {
                Button("Zum Album", systemImage: "square.stack") { app.openAlbum(of: song) }
            }
            if showGoToArtist, song.artistId != nil {
                Button("Zu Künstler:in", systemImage: "music.microphone") { app.openArtist(of: song) }
            }
        }
        if let onRemoveFromPlaylist {
            Section {
                Button("Aus Playlist entfernen", systemImage: "minus.circle", role: .destructive, action: onRemoveFromPlaylist)
            }
        }
        if song.isLocal {
            Section {
                Button("Aus der Mediathek entfernen", systemImage: "minus.circle", role: .destructive) { app.removeLocal([song]) }
            }
        }
    }
}

struct AlbumMenu: View {
    @Environment(AppModel.self) private var app
    let album: Album
    var showGoToArtist = true

    var body: some View {
        Section {
            Button("Wiedergeben", systemImage: "play") { Task { app.player.play(await app.songs(of: album), name: album.name) } }
            Button("Zufällig wiedergeben", systemImage: "shuffle") { Task { app.player.play(await app.songs(of: album), name: album.name, shuffle: true) } }
        }
        Section {
            Button("Als Nächstes wiedergeben", systemImage: "text.line.first.and.arrowtriangle.forward") { Task { app.player.playNext(await app.songs(of: album)) } }
            Button("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward") { Task { app.player.playLast(await app.songs(of: album)) } }
        }
        let isLocal = album.id.isLocalID
        Section {
            if !isLocal {
                Button("Zur Playlist hinzufügen …", systemImage: "text.badge.plus") { Task { app.addToPlaylist = await app.songs(of: album) } }
            }
            let fav = app.library.isStarred(album: album.id)
            Button(fav ? LocalizedStringKey("„Favorit“ widerrufen") : LocalizedStringKey("Als Favoriten markieren"), systemImage: fav ? "star.slash" : "star") { app.toggleFavorite(album) }
            let songs = app.library.songs(ofAlbum: album.id)
            if !isLocal && app.downloads.anyDownloaded(songs) {
                Button("Download entfernen", systemImage: "trash") { app.removeDownload(songs) }
            }
            if !isLocal && !app.downloads.allDownloaded(songs) {
                Button("Laden", systemImage: "arrow.down.circle") { Task { app.download(await app.songs(of: album)) } }
            }
        }
        if showGoToArtist, let id = album.artistId {
            Section { Button("Zu Künstler:in", systemImage: "music.microphone") { app.open(.artist(id)) } }
        }
        if isLocal {
            Section {
                Button("Aus der Mediathek entfernen", systemImage: "minus.circle", role: .destructive) {
                    app.removeLocal(app.library.songs(ofAlbum: album.id))
                }
            }
        }
    }
}

struct ArtistMenu: View {
    @Environment(AppModel.self) private var app
    let artist: Artist

    var body: some View {
        Section {
            Button("Wiedergeben", systemImage: "play") { Task { app.player.play(await app.songs(of: artist), name: artist.name) } }
            Button("Zufällig wiedergeben", systemImage: "shuffle") { Task { app.player.play(await app.songs(of: artist), name: artist.name, shuffle: true) } }
        }
        Section {
            Button("Als Nächstes wiedergeben", systemImage: "text.line.first.and.arrowtriangle.forward") { Task { app.player.playNext(await app.songs(of: artist)) } }
            Button("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward") { Task { app.player.playLast(await app.songs(of: artist)) } }
        }
        Section {
            let fav = app.library.isStarred(artist: artist.id)
            Button(fav ? LocalizedStringKey("„Favorit“ widerrufen") : LocalizedStringKey("Als Favoriten markieren"), systemImage: fav ? "star.slash" : "star") { app.toggleFavorite(artist) }
            if !artist.id.isLocalID {
                Button("Laden", systemImage: "arrow.down.circle") { Task { app.download(await app.songs(of: artist)) } }
            }
        }
    }
}

struct PlaylistMenu: View {
    @Environment(AppModel.self) private var app
    let playlist: Playlist
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        Section {
            Button("Wiedergeben", systemImage: "play") { Task { app.player.play(await app.songs(of: playlist), name: playlist.name) } }
            Button("Zufällig wiedergeben", systemImage: "shuffle") { Task { app.player.play(await app.songs(of: playlist), name: playlist.name, shuffle: true) } }
        }
        Section {
            Button("Als Nächstes wiedergeben", systemImage: "text.line.first.and.arrowtriangle.forward") { Task { app.player.playNext(await app.songs(of: playlist)) } }
            Button("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward") { Task { app.player.playLast(await app.songs(of: playlist)) } }
        }
        Section {
            Button("Laden", systemImage: "arrow.down.circle") { Task { app.download(await app.songs(of: playlist)) } }
            if let onEdit { Button("Bearbeiten", systemImage: "pencil", action: onEdit) }
        }
        if let onDelete {
            Section { Button("Playlist löschen", systemImage: "trash", role: .destructive, action: onDelete) }
        }
    }
}

struct GenreMenu: View {
    @Environment(AppModel.self) private var app
    let genre: String

    var body: some View {
        Button("Wiedergeben", systemImage: "play") { app.player.play(app.library.songs(ofGenre: genre), name: genre) }
        Button("Zufällig wiedergeben", systemImage: "shuffle") { app.player.play(app.library.songs(ofGenre: genre), name: genre, shuffle: true) }
        Button("Als Nächstes wiedergeben", systemImage: "text.line.first.and.arrowtriangle.forward") { app.player.playNext(app.library.songs(ofGenre: genre)) }
    }
}

/// Kontextmenü + Wischaktionen (rechts „Als Nächstes“, links „Zuletzt“) für eine Titelzeile.
struct SongActions: ViewModifier {
    @Environment(AppModel.self) private var app
    let song: Song
    var showGoToAlbum = true
    var onRemoveFromPlaylist: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .contextMenu { SongMenu(song: song, showGoToAlbum: showGoToAlbum, onRemoveFromPlaylist: onRemoveFromPlaylist) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { app.player.playNext([song]) } label: { Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    .tint(.indigo)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { app.player.playLast([song]) } label: { Label("Zuletzt", systemImage: "text.line.last.and.arrowtriangle.forward") }
                    .tint(.orange)
            }
    }
}

extension View {
    func songActions(_ song: Song, showGoToAlbum: Bool = true, onRemoveFromPlaylist: (() -> Void)? = nil) -> some View {
        modifier(SongActions(song: song, showGoToAlbum: showGoToAlbum, onRemoveFromPlaylist: onRemoveFromPlaylist))
    }
}
