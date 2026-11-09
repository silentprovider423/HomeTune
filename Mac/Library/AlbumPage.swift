import SwiftUI

/// Albumseite: großes Cover, Name, Künstler:in (Akzentfarbe, Klick → Künstlerseite), „Genre · Jahr“, Format,
/// Wiedergabe/Zufällig, ★ und „⋯“; darunter die Titel mit Titelnummer, bei mehreren CDs „Disc 1“, „Disc 2“.
struct AlbumPage: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let albumID: String
    @State private var album: Album?
    @State private var songs: [Song] = []
    @State private var selection = Set<String>()
    @State private var failed = false

    var body: some View {
        Group {
            if let album {
                content(album)
            } else if failed {
                EmptyState(title: "Album nicht verfügbar", systemImage: "square.stack")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: albumID) { await load() }
    }

    private func load() async {
        if let a = app.library.album(albumID) { album = a }
        let known = app.library.songs(ofAlbum: albumID)
        if !known.isEmpty { songs = known }
        if !albumID.isLocalID, let client = app.client, let full = try? await client.album(id: albumID) {
            album = full
            songs = (full.song ?? []).sorted { ($0.discNumber ?? 1, $0.track ?? 0) < ($1.discNumber ?? 1, $1.track ?? 0) }
        } else if album != nil {
            songs = songs.sorted { ($0.discNumber ?? 1, $0.track ?? 0) < ($1.discNumber ?? 1, $1.track ?? 0) }
        } else {
            failed = true
        }
    }

    private var discs: [(Int, [Song])] {
        let groups = Dictionary(grouping: songs.filter { mac.matches($0.title, $0.artist) }) { $0.discNumber ?? 1 }
        return groups.keys.sorted().map { ($0, groups[$0]!) }
    }

    private func content(_ album: Album) -> some View {
        let discs = self.discs
        let flat = discs.flatMap(\.1)
        return List(selection: $selection) {
            AlbumHeader(album: album, songs: songs)
                .selectionDisabled()
                .listRowSeparator(.hidden)
            ForEach(discs, id: \.0) { disc, list in
                Section {
                    ForEach(list) { s in
                        AlbumTrackRow(song: s, play: { play(flat, from: s) })
                            .tag(s.id)
                            .draggable(dragItem(s, flat: flat))
                    }
                } header: {
                    if discs.count > 1 { Text("Disc \(disc)").font(.headline).padding(.top, 8) }
                }
            }
            AlbumFooter(album: album, songs: songs)
                .selectionDisabled()
                .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, mac.listSize.rowHeight)
        .font(.system(size: mac.listSize.fontSize))
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = flat.filter { ids.contains($0.id) }
            if !picked.isEmpty { SongContextMenu(songs: picked) }
        } primaryAction: { ids in
            if let s = flat.first(where: { ids.contains($0.id) }) { play(flat, from: s) }
        }
        .onChange(of: selection) { _, ids in mac.selectedSongs = flat.filter { ids.contains($0.id) } }
        .onAppear { mac.visibleSongs = songs }
        .onChange(of: songs) { _, s in mac.visibleSongs = s }
        .onDisappear { mac.selectedSongs = [] }
    }

    private func play(_ list: [Song], from s: Song) {
        mac.play(list, startAt: list.firstIndex(of: s) ?? 0, name: album?.name, shuffle: app.player.shuffle)
    }

    private func dragItem(_ s: Song, flat: [Song]) -> ItemsTransfer {
        selection.contains(s.id) ? .songs(flat.filter { selection.contains($0.id) }) : .songs([s])
    }
}

private struct AlbumHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let album: Album
    let songs: [Song]

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            CoverArt(id: album.coverArt ?? album.id, size: 270, corner: 8)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .draggable(ItemsTransfer.album(album))
            VStack(alignment: .leading, spacing: 6) {
                Text(album.name).font(.system(size: 28, weight: .bold)).lineLimit(2).textSelection(.enabled)
                if let artist = album.artist {
                    Button(artist) { if let id = album.artistId { mac.showArtist(id) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.accent)
                }
                HStack(spacing: 8) {
                    Text([album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    if let badge = songs.first?.formatBadge {
                        Text(verbatim: badge).font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: .rect(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer().frame(height: 12)
                HStack(spacing: 10) {
                    PlayShuffleButtons(play: { mac.play(songs, name: album.name) },
                                       shuffle: { mac.play(songs, name: album.name, shuffle: true) })
                    Spacer()
                    let fav = app.library.isStarred(album: album.id)
                    Button { app.toggleFavorite(album) } label: {
                        Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? AnyShapeStyle(.accent) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.borderless).controlSize(.large)
                    .help(fav ? Text("„Favorit“ widerrufen") : Text("Favorit"))
                    .accessibilityIdentifier("album.favorite")
                    Menu { AlbumContextMenu(album: album) } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityIdentifier("album.more")
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
    }
}

private struct AlbumFooter: View {
    let album: Album
    let songs: [Song]
    var body: some View {
        let total = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        VStack(alignment: .leading, spacing: 2) {
            if let created = album.year {
                Text("Veröffentlicht \(String(created))")
            }
            Text("\(songs.count) Titel, \(Fmt.total(total))")
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.vertical, 12)
    }
}

/// Titelzeile der Albumseite: Nummer (beim Überfahren ▶, laufend: Lautsprecher), Name, ★, Dauer
struct AlbumTrackRow: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let song: Song
    var showArtist = false
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        let current = app.player.currentSong?.id == song.id
        let fav = app.library.isStarred(song: song.id)
        HStack(spacing: 10) {
            ZStack {
                if hover && !(current && app.player.isPlaying) {
                    Button(action: play) { Image(systemName: "play.fill").font(.system(size: 10)) }.buttonStyle(.plain)
                } else if current {
                    Image(systemName: app.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10)).foregroundStyle(.accent)
                } else {
                    Text(song.track.map(String.init) ?? "").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(song.title).foregroundStyle(current ? AnyShapeStyle(.accent) : AnyShapeStyle(.primary)).lineLimit(1)
                if showArtist, let a = song.artist { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            DownloadCell(song: song).frame(width: 16)
            if mac.showFavoritesColumn {
                FavoriteCell(song: song, on: fav).frame(width: 18)
            }
            Text(Fmt.time(song.duration)).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 40, alignment: .trailing)
        }
        .contentShape(.rect)
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("track.\(song.title)")
    }
}
