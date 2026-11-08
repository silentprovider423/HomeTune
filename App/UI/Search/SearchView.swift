import SwiftUI

/// Suche in der Mediathek (search3): letzte Suchen, Kategorien (Genres), Topergebnisse, Künstler, Alben, Titel, Playlists.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("search.recent") private var recentRaw = "[]"
    @State private var query = ""
    @State private var result = SubsonicClient.SearchResult()
    @State private var searching = false

    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: Data(recentRaw.utf8))) ?? [] }

    private var playlists: [Playlist] {
        query.isEmpty ? [] : app.library.playlists.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            if query.isEmpty {
                if !recent.isEmpty {
                    Section {
                        ForEach(recent, id: \.self) { r in
                            Button { query = r } label: { Label(r, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary) }
                        }
                    } header: {
                        HStack {
                            Text("Zuletzt gesucht").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                            Spacer()
                            Button("Löschen") { recentRaw = "[]" }.font(.subheadline).textCase(nil)
                        }
                    }
                }
                if !app.library.genres.isEmpty {
                    Section {
                        LazyVGrid(columns: albumGrid, spacing: 12) {
                            ForEach(Array(app.library.genres.enumerated()), id: \.element.id) { i, g in
                                NavigationLink(value: Route.genre(g.value)) {
                                    Text(g.value).font(.headline).foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .bottomLeading)
                                        .padding(12)
                                        .background(Self.tileColor(i).gradient, in: .rect(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("Kategorien").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                    }
                }
            } else {
                if let top = topResult {
                    Section("Topergebnisse") { top }
                }
                if !result.artists.isEmpty {
                    Section("Künstler:innen") {
                        ForEach(result.artists.prefix(5)) { a in
                            NavigationLink(value: Route.artist(a.id)) {
                                HStack(spacing: 12) { CoverArt(id: a.coverArt, size: 48, circle: true).frame(width: 48, height: 48); Text(a.name) }
                            }
                            .simultaneousGesture(TapGesture().onEnded { remember() })
                            .contextMenu { ArtistMenu(artist: a) }
                        }
                    }
                }
                if !result.albums.isEmpty {
                    Section("Alben") {
                        ForEach(result.albums.prefix(8)) { al in
                            NavigationLink(value: Route.album(al.id)) {
                                HStack(spacing: 12) {
                                    CoverArt(id: al.coverArt, size: 48, corner: 5).frame(width: 48, height: 48)
                                    VStack(alignment: .leading) {
                                        Text(al.name).lineLimit(1)
                                        Text(al.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .simultaneousGesture(TapGesture().onEnded { remember() })
                            .contextMenu { AlbumMenu(album: al) }
                        }
                    }
                }
                if !result.songs.isEmpty {
                    Section("Titel") {
                        ForEach(Array(result.songs.enumerated()), id: \.element.id) { i, s in
                            SongRow(song: s)
                                .onTapGesture { remember(); app.player.play(result.songs, startAt: i, name: query) }
                                .songActions(s)
                        }
                    }
                }
                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { p in NavigationLink(p.name, value: Route.playlist(p.id)) }
                    }
                }
                if !searching && result.artists.isEmpty && result.albums.isEmpty && result.songs.isEmpty && playlists.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Suchen")
        .searchable(text: $query, prompt: Text("Künstler:innen, Titel, Alben"))
        .onSubmit(of: .search) { remember() }
        .task(id: query) { await runSearch() }
    }

    @ViewBuilder private var topResultView: some View { EmptyView() }

    /// Bestes Ergebnis: exakter Künstlername vor Album vor Titel.
    private var topResult: AnyView? {
        let q = query.lowercased()
        if let a = result.artists.first(where: { $0.name.lowercased() == q }) ?? (result.songs.isEmpty && result.albums.isEmpty ? result.artists.first : nil) {
            return AnyView(NavigationLink(value: Route.artist(a.id)) {
                HStack(spacing: 14) {
                    CoverArt(id: a.coverArt, size: 70, circle: true).frame(width: 70, height: 70)
                    VStack(alignment: .leading) { Text(a.name).font(.headline); Text("Künstler:in").font(.subheadline).foregroundStyle(.secondary) }
                }
            })
        }
        if let al = result.albums.first(where: { $0.name.lowercased() == q }) {
            return AnyView(NavigationLink(value: Route.album(al.id)) {
                HStack(spacing: 14) {
                    CoverArt(id: al.coverArt, size: 70, corner: 6).frame(width: 70, height: 70)
                    VStack(alignment: .leading) { Text(al.name).font(.headline); Text("Album · \(al.artist ?? "")").font(.subheadline).foregroundStyle(.secondary) }
                }
            })
        }
        return nil
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { result = .init(); return }
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        var r: SubsonicClient.SearchResult
        if let client = app.client, !app.library.isOffline, let found = try? await client.search(q) {
            guard !Task.isCancelled else { return }
            r = found
        } else {
            // Offline: im zwischengespeicherten Server-Index suchen
            let lib = app.library
            r = .init(artists: lib.serverArtists.filter { $0.name.localizedStandardContains(q) },
                      albums: lib.serverAlbums.filter { $0.name.localizedStandardContains(q) },
                      songs: (lib.serverSongs.isEmpty ? app.downloads.downloadedSongs : lib.serverSongs).filter { $0.title.localizedStandardContains(q) })
        }
        // Musik auf diesem iPhone immer mit durchsuchen
        let mine = app.local.search(q)
        r.artists += mine.artists
        r.albums += mine.albums
        r.songs += mine.songs
        result = r
    }

    private func remember() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var r = recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        r.insert(q, at: 0)
        if let d = try? JSONEncoder().encode(Array(r.prefix(10))) { recentRaw = String(decoding: d, as: UTF8.self) }
    }

    static func tileColor(_ i: Int) -> Color {
        let colors: [Color] = [.pink, .orange, .purple, .teal, .indigo, .red, .green, .blue, .brown, .mint]
        return colors[i % colors.count]
    }
}
