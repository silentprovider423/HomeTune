import SwiftUI

enum AlbumSort: String, CaseIterable, Identifiable {
    case title, artist, added, played, year
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .title: "Titel"
        case .artist: "Künstler:in"
        case .added: "Zuletzt hinzugefügt"
        case .played: "Zuletzt gespielt"
        case .year: "Erscheinungsdatum"
        }
    }
}

/// Filter wie bei Apple: Favoriten, nur Geladenes.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case none, favorites, downloaded
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .none: "Filter deaktivieren"
        case .favorites: "Favoriten"
        case .downloaded: "Geladen"
        }
    }
}

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    /// Nur „Auf diesem iPhone“
    var localOnly = false
    @AppStorage("albums.sort") private var sort = AlbumSort.title
    @AppStorage("albums.ascending") private var ascending = true
    @AppStorage("albums.grid") private var grid = true
    @State private var filter = LibraryFilter.none
    @State private var query = ""

    private var albums: [Album] {
        var a: [Album]
        if localOnly {
            a = app.local.albums
        } else {
            a = app.library.serverAlbums
            if app.library.isOffline || a.isEmpty { a = downloadedAlbums }
            a += app.local.albums
        }
        switch filter {
        case .favorites: a = a.filter { app.library.isStarred(album: $0.id) }
        case .downloaded:
            let ids = Set(app.downloads.downloadedSongs.compactMap(\.albumId))
            a = a.filter { ids.contains($0.id) || $0.id.isLocalID }
        case .none: break
        }
        if !query.isEmpty {
            a = a.filter { $0.name.localizedStandardContains(query) || ($0.artist ?? "").localizedStandardContains(query) }
        }
        let sorted: [Album]
        switch sort {
        case .title: sorted = a.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .artist: sorted = a.sorted {
            let c = ($0.artist ?? "").localizedStandardCompare($1.artist ?? "")
            return c == .orderedSame ? ($0.year ?? 0) < ($1.year ?? 0) : c == .orderedAscending
        }
        case .added: sorted = a.sorted { ($0.created ?? "") > ($1.created ?? "") }
        case .played: sorted = a.sorted { ($0.played ?? "") > ($1.played ?? "") }
        case .year: sorted = a.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
        let natural = sort == .title || sort == .artist
        return natural == ascending ? sorted : sorted.reversed()
    }

    /// Offline: Alben aus den geladenen Titeln bilden
    private var downloadedAlbums: [Album] {
        var seen: [String: Album] = [:]
        for s in app.downloads.downloadedSongs {
            guard let id = s.albumId, seen[id] == nil else { continue }
            seen[id] = Album(id: id, name: s.album ?? "", artist: s.artist, artistId: s.artistId, coverArt: s.coverArt, year: s.year)
        }
        return Array(seen.values)
    }

    var body: some View {
        Group {
            if albums.isEmpty && query.isEmpty {
                EmptyHint(title: "Keine Alben", icon: "square.stack")
            } else if grid {
                ScrollView {
                    LazyVGrid(columns: albumGrid, spacing: 20) {
                        ForEach(albums) { AlbumTile(album: $0) }
                    }
                    .padding(.horizontal)
                }
            } else {
                List(albums) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        HStack(spacing: 12) {
                            CoverArt(id: album.coverArt, size: 56, corner: 6).frame(width: 56, height: 56)
                            VStack(alignment: .leading) {
                                Text(album.name).lineLimit(1)
                                Text(album.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .contextMenu { AlbumMenu(album: album) }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Alben")
        .searchable(text: $query, prompt: Text("In Alben suchen"))
        .toolbar { sortMenu }
        .refreshable { if localOnly { await app.local.rescanAll() } else { await app.library.refresh() } }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sortieren nach", selection: $sort) {
                    ForEach(AlbumSort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Reihenfolge", selection: $ascending) {
                    Text(sort == .title || sort == .artist ? "A–Z" : "Neuestes zuerst").tag(true)
                    Text(sort == .title || sort == .artist ? "Z–A" : "Ältestes zuerst").tag(false)
                }
                Section {
                    Picker("Filtern", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Picker("Darstellung", selection: $grid) {
                        Label("Raster", systemImage: "square.grid.2x2").tag(true)
                        Label("Liste", systemImage: "list.bullet").tag(false)
                    }
                }
            } label: {
                Image(systemName: filter == .none ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel(Text("Sortieren und Filtern"))
        }
    }
}

struct ArtistsView: View {
    @Environment(AppModel.self) private var app
    var localOnly = false
    @State private var query = ""
    @State private var onlyFavorites = false

    private var artists: [Artist] {
        var a = localOnly ? app.local.artists : app.library.artists
        if onlyFavorites { a = a.filter { app.library.isStarred(artist: $0.id) } }
        if !query.isEmpty { a = a.filter { $0.name.localizedStandardContains(query) } }
        return a.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(artists) { artist in
            NavigationLink(value: Route.artist(artist.id)) {
                HStack(spacing: 12) {
                    CoverArt(id: artist.coverArt, size: 48, circle: true).frame(width: 48, height: 48)
                    Text(artist.name)
                }
            }
            .contextMenu { ArtistMenu(artist: artist) }
        }
        .listStyle(.plain)
        .overlay { if artists.isEmpty && query.isEmpty { EmptyHint(title: "Keine Künstler:innen", icon: "music.microphone") } }
        .navigationTitle("Künstler:innen")
        .searchable(text: $query, prompt: Text("In Künstler:innen suchen"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Nur Favoriten", systemImage: "star", isOn: $onlyFavorites)
                } label: { Image(systemName: onlyFavorites ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease") }
            }
        }
        .refreshable { if localOnly { await app.local.rescanAll() } else { await app.library.refresh() } }
    }
}
