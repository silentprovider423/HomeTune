import SwiftUI

/// Raster-Kachel eines Albums: Cover mit runden Ecken, darunter Name (fett) und Künstler:in. Beim Überfahren
/// unten links ▶ (sofort abspielen) und unten rechts „⋯“ (Album-Kontextmenü). Klick öffnet die Albumseite.
struct AlbumTile: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let album: Album
    var size: CGFloat = 180
    var focused = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverArt(id: album.coverArt ?? album.id, size: size)
                .overlay(alignment: .bottom) {
                    if hover {
                        HStack {
                            HoverCircleButton(systemImage: "play.fill", size: 27) {
                                Task { mac.play(await app.songs(of: album), name: album.name) }
                            }
                            .accessibilityLabel(Text("Wiedergabe"))
                            Spacer()
                            Menu {
                                AlbumContextMenu(album: album)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 27, height: 27)
                                    .background(.black.opacity(0.55), in: .circle)
                            }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                            .fixedSize()
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accent, lineWidth: 3).padding(-3)
                    }
                }
            Text(album.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(album.artist ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: size)
        .contentShape(.rect)
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hover = h } }
        .onTapGesture { mac.open(.album(album.id)) }
        .contextMenu { AlbumContextMenu(album: album) }
        .draggable(ItemsTransfer.album(album)) {
            CoverArt(id: album.coverArt ?? album.id, size: 64)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("album.\(album.name)")
    }
}

/// Raster mit Albumkacheln, Spaltenzahl wächst mit der Breite. Pfeiltasten bewegen die Auswahl, Return öffnet.
struct AlbumGridPage: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let title: Text
    let albums: [Album]
    var sortable = true
    @State private var focusIndex: Int?
    @State private var columnsCount = 4
    @FocusState private var gridFocused: Bool

    private var shown: [Album] {
        let base = mac.available(albums).filter { mac.matches($0.name, $0.artist) }
        return sortable ? mac.sorted(base) : base
    }

    var body: some View {
        let list = shown
        VStack(spacing: 0) {
            PageHeader(title: title) {
                if sortable { AlbumSortMenu() }
            }
            if list.isEmpty {
                if app.library.isLoading && !app.library.loadedOnce {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(title: "Keine Alben", systemImage: "square.stack")
                }
            } else {
                GeometryReader { geo in
                    let side = Self.tileSide(width: geo.size.width)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side), spacing: 20, alignment: .top)],
                                      alignment: .leading, spacing: 22) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                                    AlbumTile(album: a, size: side, focused: gridFocused && focusIndex == i).id(a.id)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                        }
                        .onChange(of: focusIndex) { _, i in
                            if let i, i < list.count { withAnimation { proxy.scrollTo(list[i].id) } }
                        }
                    }
                    .onAppear { columnsCount = Self.columns(width: geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in columnsCount = Self.columns(width: w) }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($gridFocused)
                .onMoveCommand { dir in move(dir, count: list.count) }
                .onKeyPress(.return) {
                    guard let i = focusIndex, i < list.count else { return .ignored }
                    mac.open(.album(list[i].id))
                    return .handled
                }
            }
        }
    }

    /// Kante 160–220 pt, so dass die Breite gut ausgenutzt wird
    static func tileSide(width: CGFloat) -> CGFloat {
        let avail = max(200, width - 48)
        let n = max(1, Int((avail + 20) / (180 + 20)))
        return min(220, max(160, (avail - CGFloat(n - 1) * 20) / CGFloat(n)))
    }

    static func columns(width: CGFloat) -> Int {
        let side = tileSide(width: width)
        return max(1, Int((width - 48 + 20) / (side + 20)))
    }

    private func move(_ dir: MoveCommandDirection, count: Int) {
        guard count > 0 else { return }
        let i = focusIndex ?? -1
        let n: Int = switch dir {
        case .left: max(0, i - 1)
        case .right: min(count - 1, i + 1)
        case .up: max(0, i - columnsCount)
        case .down: min(count - 1, i < 0 ? 0 : i + columnsCount)
        @unknown default: i
        }
        focusIndex = n
    }
}

/// „Sortieren nach“ im Raster (auch im Menü Darstellung)
struct AlbumSortMenu: View {
    @Environment(MacModel.self) private var mac
    var body: some View {
        @Bindable var mac = mac
        Menu {
            Picker("Sortieren nach", selection: $mac.albumSort) {
                ForEach(AlbumSort.allCases) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Reihenfolge", selection: $mac.albumSortAscending) {
                Text("Aufsteigend").tag(true)
                Text("Absteigend").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sortieren nach", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("albums.sort")
    }
}

/// Alle Playlists als Raster
struct AllPlaylistsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac

    var body: some View {
        let list = app.library.allPlaylists.filter { mac.matches($0.name) }
        VStack(spacing: 0) {
            PageHeader(title: Text("Alle Playlists")) {
                Button { mac.newPlaylist = [] } label: { Label("Neue Playlist", systemImage: "plus") }
            }
            if list.isEmpty {
                EmptyState(title: "Keine Playlists", systemImage: "music.note.list",
                           message: "Lege mit ⌘N eine Playlist an oder zieh Titel auf „Playlists“ in der Seitenleiste.")
            } else {
                GeometryReader { geo in
                    let side = AlbumGridPage.tileSide(width: geo.size.width)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side), spacing: 20, alignment: .top)],
                                  alignment: .leading, spacing: 22) {
                            ForEach(list) { p in PlaylistTile(playlist: p, size: side) }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 24)
                    }
                }
            }
        }
    }
}

struct PlaylistTile: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let playlist: Playlist
    var size: CGFloat = 180
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlaylistCover(playlist: playlist, size: size)
                .overlay(alignment: .bottomLeading) {
                    if hover {
                        HoverCircleButton(systemImage: "play.fill") {
                            Task { mac.play(await app.songs(of: playlist), name: playlist.name) }
                        }
                        .padding(8)
                    }
                }
            Text(playlist.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(playlist.songCount ?? 0) Titel").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(width: size)
        .contentShape(.rect)
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hover = h } }
        .onTapGesture { mac.showPlaylist(playlist.id) }
        .contextMenu { PlaylistContextMenu(playlist: playlist) }
        .draggable(ItemsTransfer.playlist(playlist))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Playlist-Cover: Bild vom Server bzw. erstes Cover, sonst Notensymbol
struct PlaylistCover: View {
    let playlist: Playlist
    var size: CGFloat
    var body: some View {
        if let c = playlist.coverArt {
            CoverArt(id: c, size: size)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color.accent.opacity(0.75), Color.accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: "music.note.list").font(.system(size: size * 0.3)).foregroundStyle(.white.opacity(0.9)))
                .frame(width: size, height: size)
        }
    }
}

/// Startseite: Regale aus eigenen Serverlisten (waagrecht scrollende Coverreihen)
struct HomePage: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac

    var body: some View {
        let lib = app.library
        let favorites = lib.albums.filter { lib.isStarred(album: $0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(Text("Startseite")).padding(.horizontal, -24)
                if app.client == nil && app.local.albums.isEmpty {
                    EmptyState(title: "Noch keine Musik", systemImage: "music.note.house",
                               message: "Verbinde einen Server oder füge Musik auf diesem Mac hinzu.")
                        .frame(height: 300)
                }
                Shelf(title: "Zuletzt hinzugefügt", albums: lib.recentlyAdded.isEmpty ? Array(app.local.albums.prefix(20)) : lib.recentlyAdded) {
                    mac.visibleSections.insert(.recentlyAdded); mac.go(.library(.recentlyAdded))
                }
                Shelf(title: "Zuletzt gespielt", albums: lib.recentlyPlayed)
                Shelf(title: "Häufig gespielt", albums: lib.frequent)
                Shelf(title: "Favoriten", albums: favorites)
                Shelf(title: "Zufällig", albums: lib.randomAlbums, trailing: AnyView(
                    Button { Task { await app.library.shuffleRandomAlbums() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(Text("Neu mischen"))))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task { await app.library.refreshRecent() }
    }
}

private struct Shelf: View {
    let title: LocalizedStringKey
    let albums: [Album]
    var trailing: AnyView?
    var showAll: (() -> Void)?

    init(title: LocalizedStringKey, albums: [Album], trailing: AnyView? = nil, showAll: (() -> Void)? = nil) {
        self.title = title; self.albums = albums; self.trailing = trailing; self.showAll = showAll
    }

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title2.bold())
                    trailing
                    Spacer()
                    if let showAll { Button("Alle anzeigen", action: showAll).buttonStyle(.link) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(albums) { a in AlbumTile(album: a, size: 170) }
                    }
                }
            }
        }
    }
}
