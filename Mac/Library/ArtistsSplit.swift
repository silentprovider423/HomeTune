import SwiftUI
import AppKit

/// Künstler:innen zweigeteilt: links alle Namen mit rundem Bild, rechts die gewählte Person mit allen Alben als Blöcke.
struct ArtistsSplit: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac

    var body: some View {
        @Bindable var mac = mac
        let list = mac.available(app.library.albums).isEmpty && mac.onlyDownloaded ? [] :
            app.library.artists.filter { mac.matches($0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        HSplitView {
            List(selection: $mac.artistSelection) {
                ForEach(list) { a in
                    HStack(spacing: 10) {
                        ArtistAvatar(artist: a, size: 30)
                        Text(a.name).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(a.id)
                    .contextMenu { ArtistContextMenu(artist: a) }
                    .draggable(ItemsTransfer.artist(a))
                    .accessibilityIdentifier("artist.\(a.name)")
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            Group {
                if let id = mac.artistSelection {
                    ArtistDetail(artistID: id)
                } else if list.isEmpty {
                    EmptyState(title: "Keine Künstler:innen", systemImage: "music.microphone")
                } else {
                    EmptyState(title: "Wähle links eine Künstlerin oder einen Künstler aus.", systemImage: "music.microphone")
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if mac.artistSelection == nil { mac.artistSelection = list.first?.id }
        }
    }
}

/// Künstlerseite: Kopf mit Name + Wiedergabe/Zufällig, darunter jedes Album als Block (Cover links, Titelliste rechts)
struct ArtistDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let artistID: String
    @State private var albums: [Album] = []
    @State private var songsByAlbum: [String: [Song]] = [:]
    @State private var selected: String?

    private var artist: Artist? { app.library.artist(artistID) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 16) {
                    if let a = artist { ArtistAvatar(artist: a, size: 72) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: artist?.name ?? "").font(.system(size: 28, weight: .bold)).lineLimit(1)
                        if let a = artist {
                            HStack(spacing: 10) {
                                PlayShuffleButtons(play: { Task { mac.play(await app.songs(of: a), name: a.name) } },
                                                   shuffle: { Task { mac.play(await app.songs(of: a), name: a.name, shuffle: true) } })
                                    .controlSize(.regular)
                                Menu { ArtistContextMenu(artist: a) } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                ForEach(albums.filter { mac.matches($0.name) }) { al in
                    ArtistAlbumBlock(album: al, songs: (songsByAlbum[al.id] ?? []).filter { mac.matches($0.title, al.name) },
                                     selected: $selected)
                }
            }
            .padding(24)
        }
        .task(id: artistID) { await load() }
    }

    private func load() async {
        selected = nil
        var list = app.library.albums(ofArtist: artistID)
        if list.isEmpty, !artistID.isLocalID, let a = try? await app.client?.artist(id: artistID) { list = a.album ?? [] }
        list = mac.available(list).sorted { ($0.year ?? 0, $0.name) > ($1.year ?? 0, $1.name) }
        albums = list
        var map: [String: [Song]] = [:]
        for al in list {
            map[al.id] = await app.songs(of: al).sorted { ($0.discNumber ?? 1, $0.track ?? 0) < ($1.discNumber ?? 1, $1.track ?? 0) }
        }
        songsByAlbum = map
    }
}

private struct ArtistAlbumBlock: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let album: Album
    let songs: [Song]
    @Binding var selected: String?

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            CoverArt(id: album.coverArt ?? album.id, size: 160)
                .onTapGesture { mac.open(.album(album.id)) }
                .contextMenu { AlbumContextMenu(album: album, showGoToArtist: false) }
                .draggable(ItemsTransfer.album(album))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Button(album.name) { mac.open(.album(album.id)) }
                        .buttonStyle(.plain).font(.title3.bold()).lineLimit(1)
                    Spacer()
                    Menu { AlbumContextMenu(album: album, showGoToArtist: false) } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Text([album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                    AlbumTrackRow(song: s, play: { mac.play(songs, startAt: i, name: album.name, shuffle: app.player.shuffle) })
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(selected == s.id ? AnyShapeStyle(Color.accent.opacity(0.22))
                                    : i % 2 == 1 ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear),
                                    in: .rect(cornerRadius: 4))
                        .onTapGesture(count: 2) { mac.play(songs, startAt: i, name: album.name, shuffle: app.player.shuffle) }
                        .simultaneousGesture(TapGesture().onEnded {
                            selected = s.id
                            mac.selectedSongs = [s]
                        })
                        .contextMenu { SongContextMenu(songs: [s]) }
                        .draggable(ItemsTransfer.songs([s]))
                }
            }
        }
    }
}

/// Genres bzw. Komponist:innen zweigeteilt: links Namensliste, rechts Titeltabelle
struct ItemSplit: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let names: [String]
    let context: String
    let songsFor: (String) -> [Song]
    @Binding var selection: String?
    let emptyTitle: LocalizedStringKey
    let icon: String

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(names, id: \.self) { n in
                    Text(n).lineLimit(1).tag(n)
                        .contextMenu { GenreContextMenu(songs: mac.available(songsFor(n)), name: n) }
                        .draggable(ItemsTransfer.songs(songsFor(n)))
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 160, idealWidth: 220, maxWidth: 320)
            Group {
                if let n = selection {
                    ListPage(title: Text(n), context: context, songs: songsFor(n), name: n)
                        .id(n)
                } else {
                    EmptyState(title: emptyTitle, systemImage: icon)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = names.first } }
    }
}

struct GenresSplit: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    var body: some View {
        @Bindable var mac = mac
        ItemSplit(names: app.library.genres.map(\.value).filter { mac.matches($0) }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                  context: "genre", songsFor: { app.library.songs(ofGenre: $0) },
                  selection: $mac.genreSelection, emptyTitle: "Keine Genres", icon: "guitars")
    }
}

struct ComposersSplit: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    var body: some View {
        @Bindable var mac = mac
        ItemSplit(names: app.library.composers.map(\.name).filter { mac.matches($0) }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                  context: "composer", songsFor: { app.library.songs(ofComposer: $0) },
                  selection: $mac.composerSelection, emptyTitle: "Keine Komponist:innen", icon: "music.quarternote.3")
    }
}

/// „Auf diesem Mac“: Musik aus eigenen Ordnern und aus ~/Music/HomeTune (nur verknüpft, nie kopiert)
struct OnThisMacPage: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    @State private var showFolders = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: Text("Auf diesem Mac")) {
                HStack {
                    if app.local.isScanning { ProgressView().controlSize(.small) }
                    Button { OpenPanel.addMusic(app) } label: { Label("Musik hinzufügen …", systemImage: "plus") }
                        .accessibilityIdentifier("local.add")
                    Button { showFolders.toggle() } label: { Label("Ordner", systemImage: "folder") }
                        .popover(isPresented: $showFolders, arrowEdge: .bottom) { LocalFoldersPopover() }
                    if !app.local.songs.isEmpty {
                        PlayShuffleButtons(play: { mac.play(app.local.songs, name: String(localized: "Auf diesem Mac")) },
                                           shuffle: { mac.play(app.local.songs, name: String(localized: "Auf diesem Mac"), shuffle: true) })
                            .controlSize(.regular)
                    }
                }
            }
            if app.local.songs.isEmpty {
                EmptyState(title: "Keine Musik auf diesem Mac", systemImage: "desktopcomputer",
                           message: "Füge Ordner oder Dateien hinzu (⌘O) oder lege Musik in den Ordner „HomeTune“ im Ordner „Musik“. Dateien werden nur verknüpft, nicht kopiert.")
                    .dropDestination(for: URL.self) { urls, _ in
                        Task { _ = await app.local.add(urls) }
                        return true
                    }
            } else {
                SongTable(songs: app.local.songs, context: "local", queueName: String(localized: "Auf diesem Mac"), defaultSort: "artist:asc")
                    .dropDestination(for: URL.self) { urls, _ in
                        Task { _ = await app.local.add(urls) }
                        return true
                    }
            }
        }
    }
}

/// Liste der eingebundenen Ordner mit Neu einlesen / Entfernen
private struct LocalFoldersPopover: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ordner").font(.headline)
            ForEach(app.local.allRoots, id: \.id) { r in
                HStack {
                    Image(systemName: r.kind == .file ? "music.note" : "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(r.name)
                        Text(r.kind == .appFolder ? AppPaths.appFolder.path : r.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { app.rescanLocal(r.id) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderless).help(Text("Neu einlesen"))
                    if r.kind != .appFolder {
                        Button { app.local.removeRoot(r.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help(Text("Aus der Mediathek entfernen"))
                    } else {
                        Button { NSWorkspace.shared.open(AppPaths.appFolder) } label: { Image(systemName: "arrow.right.circle") }
                            .buttonStyle(.borderless).help(Text("Im Finder zeigen"))
                    }
                }
            }
            Text("Dateien werden nur verknüpft. Beim Entfernen bleiben sie, wo sie sind.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// Ordner- und Dateiauswahl für „Auf diesem Mac“ (Mehrfachauswahl, Ordner und Audiodateien)
enum OpenPanel {
    @MainActor static func addMusic(_ app: AppModel) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.audio, .folder, .m3uPlaylist, .init(filenameExtension: "pls") ?? .playlist]
        p.prompt = String(localized: "Hinzufügen")
        p.message = String(localized: "Ordner oder Audiodateien auswählen. Sie werden nur verknüpft, nicht kopiert.")
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        app.importLocal(.success(p.urls))
    }
}
