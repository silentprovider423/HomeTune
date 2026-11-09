import SwiftUI

/// Hauptfenster: Seitenleiste · Inhalt · rechte Spalte („Nächster Titel“/Liedtext), Player in der Symbolleiste.
struct MainView: View {
    @AppEnv private var app
    @MacEnv private var mac
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocus: Bool
    @State private var keepQueueDontAsk = false

    var body: some View {
        @Bindable var mac = mac
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            DetailRoot()
        }
        // Rechte Spalte am Split-View (nicht am Inhalt), sonst schließt sie beim Öffnen einer Unterseite
        .inspector(isPresented: Binding(get: { mac.inspector != nil }, set: { if !$0 { mac.inspector = nil } })) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .searchable(text: $mac.search, placement: .sidebar, prompt: Text("Suchen"))
        .searchFocused($searchFocus)
        .onSubmit(of: .search) { NotificationCenter.default.post(name: .searchSubmitted, object: nil) }
        .onChange(of: searchFocus) { _, f in mac.searchFocused = f }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocus = true }
        .toolbar { PlayerToolbar() }
        .navigationTitle("")
        .frame(minWidth: 900, minHeight: 560)
        .overlay(alignment: .bottom) { NoticeOverlay() }
        .overlay {
            if mac.fullScreenPlayer {
                FullScreenPlayer().transition(.opacity)
            }
        }
        .background { HiddenShortcuts() }
        .sheet(isPresented: $mac.showLogin) { LoginSheet() }
        .sheet(item: Binding(get: { mac.newPlaylist.map { NewPlaylistRequest(songs: $0) } },
                             set: { if $0 == nil { mac.newPlaylist = nil } })) { req in
            NewPlaylistSheet(songs: req.songs)
        }
        .confirmationDialog(Text("Warteliste behalten?"), isPresented: Binding(get: { mac.keepQueueQuestion != nil },
                                                                            set: { if !$0 { mac.keepQueueQuestion = nil } })) {
            Button("Löschen", role: .destructive) { mac.answerKeepQueue(clear: true, dontAsk: keepQueueDontAsk) }
            Button("Warteliste behalten") { mac.answerKeepQueue(clear: false, dontAsk: keepQueueDontAsk) }
        } message: {
            Text("Du startest gerade die Wiedergabe. Möchtest du die \(mac.keepQueueQuestion?.queued ?? 0) Titel löschen, die zuvor zu „Nächster Titel“ hinzugefügt wurden?")
        }
        .dialogSuppressionToggle(Text("Nicht mehr fragen"), isSuppressed: $keepQueueDontAsk)
        .alert(Text("Bereits in der Playlist"), isPresented: Binding(get: { mac.duplicateQuestion != nil },
                                                                   set: { if !$0 { mac.duplicateQuestion = nil } })) {
            Button("Erneut hinzufügen") { mac.answerDuplicates(addAgain: true) }
            Button("Überspringen", role: .cancel) { mac.answerDuplicates(addAgain: false) }
        } message: {
            Text("Einige Titel sind bereits in „\(mac.duplicateQuestion?.playlist.name ?? "")“.")
        }
        .alert(Text("Möchtest du diese Playlist wirklich löschen?"),
               isPresented: Binding(get: { mac.deletePlaylistQuestion != nil }, set: { if !$0 { mac.deletePlaylistQuestion = nil } })) {
            Button("Löschen", role: .destructive) {
                if let p = mac.deletePlaylistQuestion { mac.delete(p) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("„\(mac.deletePlaylistQuestion?.name ?? "")“ wird gelöscht. Die Titel bleiben in der Mediathek.")
        }
        .alert(Text("Auch die Datei löschen?"), isPresented: Binding(get: { app.pendingLocalRemoval != nil },
                                                                   set: { if !$0 { app.pendingLocalRemoval = nil } })) {
            Button("Datei löschen", role: .destructive) { app.confirmLocalRemoval(deleteFiles: true) }
            Button("Nur aus der Mediathek entfernen") { app.confirmLocalRemoval(deleteFiles: false) }
            Button("Abbrechen", role: .cancel) { app.pendingLocalRemoval = nil }
        } message: {
            Text("Die Datei liegt im HomeTune-Ordner im Ordner „Musik“.")
        }
        .onAppear {
            mac.openMainWindow = { openWindow(id: "main") }
            mac.openWindow = { openWindow(id: $0) }
            mac.openSettings = { openSettings() }
            if app.showsLogin && app.accounts.accounts.isEmpty && !app.localMode { mac.showLogin = true }
        }
        .task(id: mac.autoplay) { await autoplayLoop() }
    }

    /// „Automatisch wiedergeben“: am Ende der Warteliste ähnliche Titel anhängen (getSimilarSongs2)
    private func autoplayLoop() async {
        while !Task.isCancelled, mac.autoplay {
            try? await Task.sleep(for: .seconds(3))
            let p = app.player
            guard mac.autoplay, p.isPlaying, let song = p.currentSong, !song.isLocal, let client = app.client,
                  p.queue.upNext.isEmpty, p.queue.source.isEmpty, p.repeatMode == .off else { continue }
            let similar = (try? await client.similarSongs(id: song.id, count: 20)) ?? []
            let known = Set(p.queue.history.map(\.song.id) + [song.id])
            let fresh = similar.filter { !known.contains($0.id) }
            if !fresh.isEmpty, p.queue.upNext.isEmpty { p.insertUpNext(fresh, at: 0) }
        }
    }
}

struct NewPlaylistRequest: Identifiable {
    let id = UUID()
    let songs: [Song]
}

extension Notification.Name {
    static let focusSearch = Notification.Name("HomeTune.focusSearch")
    static let focusFilter = Notification.Name("HomeTune.focusFilter")
}

/// Kurze Rückmeldung unten mittig (wie iOS)
struct NoticeOverlay: View {
    @AppEnv private var app
    var body: some View {
        Group {
            if let n = app.notice.current {
                Label(n.text, systemImage: n.icon)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .modifier(GlassBackground(corner: 18))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(n.id)
            }
        }
        .padding(.bottom, 28)
        .animation(.easeOut(duration: 0.2), value: app.notice.current)
        .allowsHitTesting(false)
    }
}

/// Versteckte Navigations-Kürzel (Apple: unsichtbares Menü)
private struct HiddenShortcuts: View {
    @MacEnv private var mac
    var body: some View {
        ZStack {
            Button("") { mac.go(.home) }.keyboardShortcut("1", modifiers: [.option, .command])
            ForEach(MacSection.allCases.filter { $0.shortcut != nil }) { s in
                Button("") { mac.visibleSections.insert(s); mac.go(.library(s)) }.keyboardShortcut(s.shortcut!, modifiers: [.control, .command])
            }
            Button("") { mac.showInfo(mac.selectedSongs) }.keyboardShortcut("i", modifiers: [.option, .command])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// Inhaltsbereich: Navigation innerhalb des gewählten Seitenleisten-Eintrags, Suchergebnisse, Filterfeld, Statusleiste
struct DetailRoot: View {
    @AppEnv private var app
    @MacEnv private var mac

    var body: some View {
        @Bindable var mac = mac
        Group {
            if app.showsLogin && !mac.searchFocused {
                WelcomeView()
            } else if !mac.search.isEmpty || mac.searchFocused {
                SearchResultsView()
            } else {
                NavigationStack(path: $mac.path) {
                    root
                        .navigationDestination(for: MacRoute.self) { route in
                            switch route {
                            case .album(let id): AlbumPage(albumID: id)
                            case .artist(let id): ArtistDetail(artistID: id)
                            case .playlist(let id): PlaylistPage(playlistID: id)
                            case .genre(let g): ListPage(title: Text(g), context: "genre", songs: app.library.songs(ofGenre: g))
                            case .composer(let c): ListPage(title: Text(c), context: "composer", songs: app.library.songs(ofComposer: c))
                            }
                        }
                }
                .id(mac.selection)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if mac.showFilter { FilterBar() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if mac.showStatusBar { StatusBar() }
        }
    }

    @ViewBuilder private var root: some View {
        switch mac.selection {
        case .home: HomePage()
        case .allPlaylists: AllPlaylistsPage()
        case .favorites: FavoritesPage()
        case .playlist(let id): PlaylistPage(playlistID: id)
        case .library(let s):
            switch s {
            case .recentlyAdded: AlbumGridPage(title: Text("Zuletzt hinzugefügt"), albums: recentlyAdded, sortable: false)
            case .albums: AlbumGridPage(title: Text("Alben"), albums: app.library.albums, sortable: true)
            case .compilations: AlbumGridPage(title: Text("Compilations"), albums: app.library.albums.filter { $0.isCompilation == true }, sortable: true)
            case .artists: ArtistsSplit()
            case .songs: ListPage(title: Text("Titel"), context: "songs", songs: app.library.songs)
            case .genres: GenresSplit()
            case .composers: ComposersSplit()
            case .downloaded: ListPage(title: Text("Geladen"), context: "downloaded", songs: app.downloads.downloadedSongs)
            case .onThisMac: OnThisMacPage()
            }
        case nil:
            EmptyState(title: "Wähle links einen Bereich aus.", systemImage: "sidebar.left")
        }
    }

    /// Neueste zuerst: Server-Liste „newest“, ergänzt um lokale Alben
    private var recentlyAdded: [Album] {
        let server = app.library.recentlyAdded.isEmpty
            ? app.library.serverAlbums.sorted { ($0.created ?? "") > ($1.created ?? "") }
            : app.library.recentlyAdded
        let local = app.local.albums.sorted { ($0.created ?? "") > ($1.created ?? "") }
        return server + local
    }
}

/// Filterfeld über der Liste (⌥⌘F): filtert nur die aktuelle Liste, Esc leert es
struct FilterBar: View {
    @MacEnv private var mac
    @FocusState private var focused: Bool
    var body: some View {
        @Bindable var mac = mac
        HStack {
            Spacer()
            TextField(text: $mac.filter, prompt: Text("Filtern")) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onExitCommand { if mac.filter.isEmpty { mac.showFilter = false } else { mac.filter = "" } }
                .accessibilityIdentifier("filter.field")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.bar)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusFilter)) { _ in focused = true }
    }
}

/// Statusleiste (⌘/): „1.234 Titel, 3,2 Tage, 18,4 GB“ bzw. Auswahl
struct StatusBar: View {
    @MacEnv private var mac
    var body: some View {
        let sel = mac.selectedSongs
        let list = sel.count > 1 ? sel : mac.visibleSongs
        let secs = list.reduce(0) { $0 + ($1.duration ?? 0) }
        let bytes = Int64(list.reduce(0) { $0 + ($1.size ?? 0) })
        HStack {
            Spacer()
            Group {
                if sel.count > 1 {
                    Text("\(sel.count) Titel ausgewählt, \(Fmt.total(secs)), \(Fmt.bytes(bytes))")
                } else if !list.isEmpty {
                    Text("\(list.count) Titel, \(Fmt.total(secs)), \(Fmt.bytes(bytes))")
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .background(.bar)
    }
}

/// Ohne Konto: Anmelden oder ohne Server weiter
struct WelcomeView: View {
    @AppEnv private var app
    @MacEnv private var mac
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("HomeTune").font(.largeTitle.bold())
            Text("Deine Musik vom eigenen Navidrome-Server.").foregroundStyle(.secondary)
            HStack {
                Button("Mit einem Server verbinden …") { mac.showLogin = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("welcome.login")
                Button("Ohne Server fortfahren") { app.localMode = true; mac.go(.library(.onThisMac)); mac.visibleSections.insert(.onThisMac) }
                    .controlSize(.large)
            }
            Text("Ohne Server spielt HomeTune nur Musik auf diesem Mac.").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
