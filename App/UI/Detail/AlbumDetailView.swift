import SwiftUI

/// Albumseite wie bei Apple: großes Cover, Titel, Künstler:in (antippbar), Genre · Jahr · Format,
/// Wiedergeben/Zufällig, Titel nach CD, Fußzeile, „Mehr von …“.
struct AlbumDetailView: View {
    @Environment(AppModel.self) private var app
    let albumID: String
    @State private var album: Album?
    @State private var failed = false

    private var base: Album? { album ?? app.library.album(albumID) }
    private var songs: [Song] {
        let s = album?.song ?? app.library.songs(ofAlbum: albumID)
        return s.isEmpty ? app.downloads.downloadedSongs.filter { $0.albumId == albumID } : s
    }

    var body: some View {
        List {
            if let a = base {
                header(a).listRowSeparator(.hidden)
                let discs = Dictionary(grouping: songs) { $0.discNumber ?? 1 }
                ForEach(discs.keys.sorted(), id: \.self) { disc in
                    Section {
                        ForEach(discs[disc] ?? []) { song in
                            let i = songs.firstIndex(of: song) ?? 0
                            SongRow(song: song, number: song.track ?? (i + 1), subtitle: song.artist != a.artist ? song.artist : "",
                                    showGoToAlbum: false)
                                .onTapGesture { app.player.play(songs, startAt: i, name: a.name) }
                                .songActions(song, showGoToAlbum: false)
                                .accessibilityIdentifier("track.\(i)")
                        }
                    } header: {
                        if discs.count > 1 { Text("CD \(disc)").font(.headline).foregroundStyle(.primary) }
                    }
                }
                footer(a).listRowSeparator(.hidden)
                moreFromArtist(a)
            }
        }
        .listStyle(.plain)
        .overlay { if base == nil && !failed { ProgressView() } }
        .overlay { if base == nil && failed { EmptyHint(title: "Nicht verfügbar", icon: "wifi.slash") } }
        .toolbar {
            if base != nil, !albumID.isLocalID {
                ToolbarItem(placement: .topBarTrailing) {
                    let all = app.downloads.allDownloaded(songs)
                    Button {
                        all ? app.removeDownload(songs) : app.download(songs)
                    } label: {
                        Image(systemName: all ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                    .accessibilityLabel(all ? Text("Download entfernen") : Text("Laden"))
                }
            }
            if let a = base {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { AlbumMenu(album: a) } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel(Text("Mehr"))
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Musik auf diesem iPhone kommt nie vom Server
            guard !albumID.isLocalID else { failed = base == nil; return }
            do { album = try await app.client?.album(id: albumID) } catch { failed = true }
        }
    }

    private func header(_ a: Album) -> some View {
        VStack(spacing: 6) {
            CoverArt(id: a.coverArt, size: 280, corner: 10)
                .frame(width: 270, height: 270)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .padding(.bottom, 8)
            Text(a.name).font(.title2.bold()).multilineTextAlignment(.center)
            if let artist = a.artist {
                Button(artist) { if let id = a.artistId { app.open(.artist(id)) } }
                    .font(.title3).foregroundStyle(.accent).buttonStyle(.plain)
            }
            Text(infoLine(a)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            PlayShuffleButtons(play: { app.player.play(songs, name: a.name) },
                               shuffle: { app.player.play(songs, name: a.name, shuffle: true) })
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private func infoLine(_ a: Album) -> String {
        var parts: [String] = []
        if let g = a.genre, !g.isEmpty { parts.append(g.uppercased()) }
        if let y = a.year, y > 0 { parts.append(String(y)) }
        if let f = songs.first?.formatBadge { parts.append(f) }
        return parts.joined(separator: " · ")
    }

    private func footer(_ a: Album) -> some View {
        let secs = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        return VStack(alignment: .leading, spacing: 2) {
            if let d = Fmt.date(a.created) { Text("Hinzugefügt am \(d.formatted(date: .long, time: .omitted))") }
            Text("\(songs.count) Titel, \(Fmt.minutes(secs)) Minuten")
            if let label = a.recordLabels?.first?.name, !label.isEmpty { Text(verbatim: "℗ \(label)") }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    @ViewBuilder private func moreFromArtist(_ a: Album) -> some View {
        let more = a.artistId.map { app.library.albums(ofArtist: $0).filter { $0.id != a.id } } ?? []
        if !more.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(more) { AlbumTile(album: $0, subtitle: $0.year.map { String($0) } ?? "").frame(width: 150) }
                    }
                }
                .listRowSeparator(.hidden)
            } header: {
                Text("Mehr von \(a.artist ?? "")").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
            }
        }
    }
}

/// Künstlerseite: Bild, Name, Wiedergeben, Top-Titel, Alben.
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var app
    let artistID: String
    @State private var artist: Artist?
    @State private var top: [Song] = []

    private var base: Artist? { artist ?? app.library.artist(artistID) }
    private var albums: [Album] {
        let a = artist?.album ?? app.library.albums(ofArtist: artistID)
        return a.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }
    private var topSongs: [Song] {
        if !top.isEmpty { return top }
        return Array(app.library.songs(ofArtist: artistID).sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(5))
    }

    var body: some View {
        ScrollView {
            if let a = base {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 12) {
                        CoverArt(id: a.coverArt, size: 200, circle: true).frame(width: 190, height: 190)
                        HStack(spacing: 16) {
                            Text(a.name).font(.largeTitle.bold()).lineLimit(2)
                            Button {
                                Task { app.player.play(await app.songs(of: a), name: a.name) }
                            } label: {
                                Image(systemName: "play.fill").font(.title2).frame(width: 52, height: 52)
                            }
                            .buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(.accent)
                            .accessibilityLabel(Text("Wiedergeben"))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if !topSongs.isEmpty {
                        Text("Top-Titel").font(.title2.bold())
                        VStack(spacing: 0) {
                            ForEach(Array(topSongs.enumerated()), id: \.element.id) { i, s in
                                SongRow(song: s, subtitle: s.album)
                                    .padding(.vertical, 6)
                                    .onTapGesture { app.player.play(topSongs, startAt: i, name: a.name) }
                                    .contextMenu { SongMenu(song: s, showGoToArtist: false) }
                                Divider().padding(.leading, 58)
                            }
                        }
                    }
                    if !albums.isEmpty {
                        Text("Alben").font(.title2.bold())
                        LazyVGrid(columns: albumGrid, spacing: 20) {
                            ForEach(albums) { AlbumTile(album: $0, subtitle: $0.year.map { String($0) } ?? "") }
                        }
                    }
                }
                .padding()
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .toolbar {
            if let a = base {
                ToolbarItem(placement: .topBarTrailing) {
                    let fav = app.library.isStarred(artist: a.id)
                    Button { app.toggleFavorite(a) } label: { Image(systemName: fav ? "star.fill" : "star") }
                        .accessibilityLabel(fav ? Text("„Favorit“ widerrufen") : Text("Als Favoriten markieren"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { ArtistMenu(artist: a) } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !artistID.isLocalID else { return }
            artist = try? await app.client?.artist(id: artistID)
            if let name = base?.name, let t = try? await app.client?.topSongs(artist: name, count: 5), !t.isEmpty { top = t }
        }
    }
}

struct DownloadedView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRemoveAll = false

    var body: some View {
        let songs = app.downloads.downloadedSongs
        List {
            if !app.downloads.active.isEmpty || !app.downloads.waiting.isEmpty {
                Section("Wird geladen") {
                    ForEach(app.downloads.waiting) { s in
                        HStack { Text(s.title); Spacer(); Text("Wartet").foregroundStyle(.secondary).font(.subheadline) }
                    }
                    ForEach(Array(app.downloads.active.keys), id: \.self) { id in
                        HStack { Text(app.library.songs.first { $0.id == id }?.title ?? id); Spacer(); ProgressView() }
                    }
                }
            }
            if !songs.isEmpty {
                PlayShuffleButtons(play: { app.player.play(songs, name: String(localized: "Geladen")) },
                                   shuffle: { app.player.play(songs, name: String(localized: "Geladen"), shuffle: true) })
                    .listRowSeparator(.hidden)
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                    SongRow(song: s)
                        .onTapGesture { app.player.play(songs, startAt: i, name: String(localized: "Geladen")) }
                        .songActions(s)
                }
                Text("\(songs.count) Titel · \(Fmt.bytes(app.downloads.totalBytes))")
                    .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if songs.isEmpty && app.downloads.active.isEmpty && app.downloads.waiting.isEmpty {
                EmptyHint(title: "Keine geladene Musik", icon: "arrow.down.circle",
                          text: "Lade Titel, Alben oder Playlists über „Laden“, um sie offline zu hören.")
            }
        }
        .navigationTitle("Geladen")
        .toolbar {
            if !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Alle Downloads entfernen", systemImage: "trash", role: .destructive) { confirmRemoveAll = true }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .confirmationDialog("Alle Downloads entfernen?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Alle Downloads entfernen", role: .destructive) { app.downloads.removeAll() }
        }
    }
}
