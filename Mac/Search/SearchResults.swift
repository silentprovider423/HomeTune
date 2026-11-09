import SwiftUI

/// Suchergebnisse im Inhaltsbereich: Topergebnis · Künstler:innen · Alben · Titel · Playlists.
/// Leeres Feld mit Fokus: „Letzte Sucheinträge“ mit „Löschen“.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    @AppStorage("search.recent") private var recentRaw = "[]"
    @State private var result = SubsonicClient.SearchResult()
    @State private var searching = false
    @State private var selection = Set<String>()

    private var query: String { mac.search.trimmingCharacters(in: .whitespaces) }
    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: Data(recentRaw.utf8))) ?? [] }
    private var playlists: [Playlist] {
        query.isEmpty ? [] : app.library.allPlaylists.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        Group {
            if query.isEmpty {
                recentView
            } else {
                resultsView
            }
        }
        .task(id: query) { await runSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .searchSubmitted)) { _ in remember() }
    }

    private var recentView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Letzte Sucheinträge").font(.title2.bold())
                Spacer()
                if !recent.isEmpty { Button("Löschen") { recentRaw = "[]" }.buttonStyle(.link) }
            }
            if recent.isEmpty {
                Text("Durchsuche deine Mediathek nach Künstler:innen, Alben, Titeln und Playlists.").foregroundStyle(.secondary)
            }
            ForEach(recent, id: \.self) { r in
                Button { mac.search = r } label: { Label(r, systemImage: "magnifyingglass") }
                    .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultsView: some View {
        let empty = result.artists.isEmpty && result.albums.isEmpty && result.songs.isEmpty && playlists.isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(Text("Suchergebnisse")).padding(.horizontal, -24)
                if empty && !searching {
                    EmptyState(title: "In deiner Mediathek wurden keine Ergebnisse für „\(query)“ gefunden.", systemImage: "magnifyingglass")
                        .frame(height: 260)
                }
                if let a = topArtist {
                    section("Topergebnisse") {
                        Button { remember(); mac.showArtist(a.id) } label: {
                            HStack(spacing: 14) {
                                ArtistAvatar(artist: a, size: 72)
                                VStack(alignment: .leading) { Text(a.name).font(.title3.bold()); Text("Künstler:in").foregroundStyle(.secondary) }
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !result.artists.isEmpty {
                    section("Künstler:innen") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 18) {
                                ForEach(result.artists.prefix(12)) { a in
                                    VStack(spacing: 6) {
                                        ArtistAvatar(artist: a, size: 110)
                                        Text(a.name).font(.callout).lineLimit(1).frame(width: 120)
                                    }
                                    .contentShape(.rect)
                                    .onTapGesture { remember(); mac.showArtist(a.id) }
                                    .contextMenu { ArtistContextMenu(artist: a) }
                                    .draggable(ItemsTransfer.artist(a))
                                }
                            }
                        }
                    }
                }
                if !result.albums.isEmpty {
                    section("Alben") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 20) {
                                ForEach(result.albums.prefix(20)) { a in
                                    AlbumTile(album: a, size: 160).simultaneousGesture(TapGesture().onEnded { remember() })
                                }
                            }
                        }
                    }
                }
                if !result.songs.isEmpty {
                    section("Titel") {
                        VStack(spacing: 0) {
                            ForEach(Array(result.songs.prefix(30).enumerated()), id: \.element.id) { i, s in
                                SearchSongRow(song: s, selected: selection.contains(s.id), odd: i % 2 == 1)
                                    .onTapGesture(count: 2) { remember(); mac.play(result.songs, startAt: i, name: query) }
                                    .simultaneousGesture(TapGesture().onEnded { selection = [s.id]; mac.selectedSongs = [s] })
                                    .contextMenu { SongContextMenu(songs: [s]) }
                                    .draggable(ItemsTransfer.songs([s]))
                            }
                        }
                    }
                }
                if !playlists.isEmpty {
                    section("Playlists") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 20) {
                                ForEach(playlists) { p in PlaylistTile(playlist: p, size: 160) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            content()
        }
    }

    /// Bestes Ergebnis: exakter Künstlername (oder nur Künstler:innen gefunden)
    private var topArtist: Artist? {
        let q = query.lowercased()
        return result.artists.first { $0.name.lowercased() == q }
            ?? (result.songs.isEmpty && result.albums.isEmpty ? result.artists.first : nil)
    }

    private func runSearch() async {
        let q = query
        guard !q.isEmpty else { result = .init(); return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        var r: SubsonicClient.SearchResult
        if let client = app.client, !app.library.isOffline, let found = try? await client.search(q) {
            guard !Task.isCancelled else { return }
            r = found
        } else {
            let lib = app.library
            r = .init(artists: lib.serverArtists.filter { $0.name.localizedStandardContains(q) },
                      albums: lib.serverAlbums.filter { $0.name.localizedStandardContains(q) },
                      songs: (lib.serverSongs.isEmpty ? app.downloads.downloadedSongs : lib.serverSongs).filter { $0.title.localizedStandardContains(q) })
        }
        let mine = app.local.search(q)
        r.artists += mine.artists
        r.albums += mine.albums
        r.songs += mine.songs
        if mac.onlyDownloaded {
            r.songs = mac.available(r.songs)
            r.albums = mac.available(r.albums)
        }
        result = r
    }

    private func remember() {
        let q = query
        guard !q.isEmpty else { return }
        var r = recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        r.insert(q, at: 0)
        if let d = try? JSONEncoder().encode(Array(r.prefix(10))) { recentRaw = String(decoding: d, as: UTF8.self) }
    }
}

private struct SearchSongRow: View {
    @Environment(AppModel.self) private var app
    let song: Song
    let selected: Bool
    let odd: Bool
    var body: some View {
        HStack(spacing: 10) {
            CoverArt(id: song.coverArt, size: 32, corner: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1)
                    .foregroundStyle(app.player.currentSong?.id == song.id ? AnyShapeStyle(.accent) : AnyShapeStyle(.primary))
                Text([song.artist, song.album].compactMap { $0 }.joined(separator: " — ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.time(song.duration)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selected ? AnyShapeStyle(Color.accent.opacity(0.22)) : odd ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 4))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.song.\(song.title)")
    }
}

extension Notification.Name {
    static let searchSubmitted = Notification.Name("HomeTune.searchSubmitted")
}
