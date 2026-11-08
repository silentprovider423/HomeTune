import SwiftUI

enum SongSort: String, CaseIterable, Identifiable {
    case title, artist, album, added
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .title: "Titel"
        case .artist: "Künstler:in"
        case .album: "Album"
        case .added: "Zuletzt hinzugefügt"
        }
    }
}

/// Wiederverwendbare Titelliste mit „Wiedergeben / Zufällig“ oben.
struct SongList: View {
    @Environment(AppModel.self) private var app
    let songs: [Song]
    let name: String
    var showArtwork = true

    var body: some View {
        List {
            if !songs.isEmpty {
                PlayShuffleButtons(play: { app.player.play(songs, name: name) },
                                   shuffle: { app.player.play(songs, name: name, shuffle: true) })
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song, showArtwork: showArtwork)
                    .onTapGesture { app.player.play(songs, startAt: i, name: name) }
                    .songActions(song)
            }
        }
        .listStyle(.plain)
    }
}

struct SongsView: View {
    @Environment(AppModel.self) private var app
    /// Nur „Auf diesem iPhone“
    var localOnly = false
    @AppStorage("songs.sort") private var sort = SongSort.title
    @State private var filter = LibraryFilter.none
    @State private var query = ""

    private var songs: [Song] {
        var s: [Song]
        if localOnly {
            s = app.local.songs
        } else {
            s = app.library.serverSongs
            if app.library.isOffline || s.isEmpty { s = app.downloads.downloadedSongs }
            s += app.local.songs
        }
        switch filter {
        case .favorites: s = s.filter { app.library.isStarred(song: $0.id) }
        case .downloaded: s = s.filter { $0.isLocal || app.downloads.isDownloaded($0.id) }
        case .none: break
        }
        if !query.isEmpty {
            s = s.filter { $0.title.localizedStandardContains(query) || ($0.artist ?? "").localizedStandardContains(query) || ($0.album ?? "").localizedStandardContains(query) }
        }
        switch sort {
        case .title: return s.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: return s.sorted { ($0.artist ?? "").localizedStandardCompare($1.artist ?? "") == .orderedAscending }
        case .album: return s.sorted { (($0.album ?? ""), $0.track ?? 0) < (($1.album ?? ""), $1.track ?? 0) }
        case .added: return s.sorted { ($0.created ?? "") > ($1.created ?? "") }
        }
    }

    var body: some View {
        SongList(songs: songs, name: String(localized: "Titel"))
            .overlay { if songs.isEmpty && query.isEmpty { EmptyHint(title: "Keine Titel", icon: "music.note") } }
            .navigationTitle("Titel")
            .searchable(text: $query, prompt: Text("In Titeln suchen"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sortieren nach", selection: $sort) { ForEach(SongSort.allCases) { Text($0.label).tag($0) } }
                        Section { Picker("Filtern", selection: $filter) { ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) } } }
                    } label: { Image(systemName: filter == .none ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                    .accessibilityLabel(Text("Sortieren und Filtern"))
                }
            }
            .refreshable { if localOnly { await app.local.rescanAll() } else { await app.library.refresh() } }
    }
}

struct FavoriteSongsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        SongList(songs: app.library.favoriteSongs, name: String(localized: "Lieblingstitel"))
            .overlay { if app.library.favoriteSongs.isEmpty { EmptyHint(title: "Keine Lieblingstitel", icon: "star", text: "Markiere Titel mit dem Stern als Favoriten.") } }
            .navigationTitle("Lieblingstitel")
    }
}

struct GenresView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        List(app.library.genres) { g in
            NavigationLink(value: Route.genre(g.value)) {
                HStack {
                    Text(g.value)
                    Spacer()
                    Text(verbatim: "\(g.songCount ?? 0)").foregroundStyle(.secondary).font(.subheadline)
                }
            }
            .contextMenu { GenreMenu(genre: g.value) }
        }
        .listStyle(.plain)
        .overlay { if app.library.genres.isEmpty { EmptyHint(title: "Keine Genres", icon: "guitars") } }
        .navigationTitle("Genres")
    }
}

struct GenreDetailView: View {
    @Environment(AppModel.self) private var app
    let genre: String
    var body: some View {
        let albums = app.library.albums(ofGenre: genre)
        let songs = app.library.songs(ofGenre: genre)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PlayShuffleButtons(play: { app.player.play(songs, name: genre) },
                                   shuffle: { app.player.play(songs, name: genre, shuffle: true) })
                if !albums.isEmpty {
                    Text("Alben").font(.title2.bold())
                    LazyVGrid(columns: albumGrid, spacing: 20) { ForEach(albums) { AlbumTile(album: $0) } }
                }
            }
            .padding()
        }
        .navigationTitle(genre)
    }
}

struct ComposersView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let composers = app.library.composers
        List(composers, id: \.name) { c in
            NavigationLink(value: Route.composer(c.name)) {
                HStack { Text(c.name); Spacer(); Text(verbatim: "\(c.count)").foregroundStyle(.secondary).font(.subheadline) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if composers.isEmpty {
                EmptyHint(title: "Keine Komponist:innen", icon: "music.quarternote.3",
                          text: "Komponist:innen erscheinen, wenn deine Dateien ein Komponisten-Tag haben.")
            }
        }
        .navigationTitle("Komponist:innen")
    }
}

struct ComposerDetailView: View {
    @Environment(AppModel.self) private var app
    let name: String
    var body: some View {
        SongList(songs: app.library.songs(ofComposer: name), name: name).navigationTitle(name)
    }
}
