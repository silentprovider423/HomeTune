import SwiftUI

/// Seitenleiste: Suchfeld (oben, vom Fenster), HomeTune · Mediathek („Bearbeiten“) · Playlists
struct Sidebar: View {
    @AppEnv private var app
    @MacEnv private var mac
    @AppStorage("mac.sidebar.libraryExpanded") private var libraryExpanded = true
    @AppStorage("mac.sidebar.playlistsExpanded") private var playlistsExpanded = true
    @State private var hoverLibrary = false

    var body: some View {
        @Bindable var mac = mac
        List(selection: $mac.selection) {
            Section("HomeTune") {
                Label("Startseite", systemImage: "house").tag(SidebarItem.home)
                    .accessibilityIdentifier("sidebar.home")
            }
            Section(isExpanded: $libraryExpanded) {
                if mac.editingSections {
                    ForEach(availableSections) { s in
                        Toggle(isOn: Binding(get: { mac.visibleSections.contains(s) }, set: { on in
                            if on { mac.visibleSections.insert(s) } else { mac.visibleSections.remove(s) }
                        })) { Label(s.title, systemImage: s.icon) }
                        .toggleStyle(.checkbox)
                        .selectionDisabled()
                    }
                } else {
                    ForEach(availableSections.filter { mac.visibleSections.contains($0) || autoVisible($0) }) { s in
                        Label(s.title, systemImage: s.icon).tag(SidebarItem.library(s))
                            .accessibilityIdentifier("sidebar.\(s.rawValue)")
                    }
                }
            } header: {
                HStack {
                    Text("Mediathek")
                    Spacer()
                    if hoverLibrary || mac.editingSections {
                        Button(mac.editingSections ? "Fertig" : "Bearbeiten") { mac.editingSections.toggle() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.accent)
                            .accessibilityIdentifier("sidebar.editSections")
                    }
                }
                .contentShape(.rect)
                .onHover { hoverLibrary = $0 }
            }
            Section(isExpanded: $playlistsExpanded) {
                Label("Alle Playlists", systemImage: "square.grid.2x2").tag(SidebarItem.allPlaylists)
                Label("Lieblingstitel", systemImage: "star").tag(SidebarItem.favorites)
                    .dropDestination(for: ItemsTransfer.self) { items, _ in
                        Task { for s in await items.resolve(app) where !app.library.isStarred(song: s.id) { app.toggleFavorite(s) } }
                        return true
                    }
                ForEach(app.library.allPlaylists) { p in
                    PlaylistSidebarRow(playlist: p).tag(SidebarItem.playlist(p.id))
                }
            } header: {
                Text("Playlists")
                    .dropDestination(for: ItemsTransfer.self) { items, _ in
                        newPlaylist(from: items)
                        return true
                    }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("Neue Playlist") { mac.newPlaylist = [] }
        }
        .dropDestination(for: ItemsTransfer.self) { items, _ in
            // Ablegen auf freier Fläche: neue Playlist mit diesen Titeln
            newPlaylist(from: items)
            return true
        }
    }

    /// „Geladen“ und „Auf diesem Mac“ nur, wenn es dort etwas gibt
    private var availableSections: [MacSection] {
        MacSection.allCases.filter { s in
            switch s {
            case .downloaded: app.client != nil
            case .compilations: app.client != nil || !app.local.albums.isEmpty
            default: true
            }
        }
    }

    private func autoVisible(_ s: MacSection) -> Bool {
        switch s {
        case .downloaded: !app.downloads.items.isEmpty
        case .onThisMac: !app.local.songs.isEmpty || app.localMode
        default: false
        }
    }

    private func newPlaylist(from items: [ItemsTransfer]) {
        Task {
            let songs = await items.resolve(app)
            guard !songs.isEmpty else { return }
            let name = items.count == 1 && items[0].kind != .songs ? (items[0].name ?? String(localized: "Neue Playlist")) : String(localized: "Neue Playlist")
            mac.createPlaylist(name: name, comment: "", songs: songs, onDevice: app.client == nil)
        }
    }
}

/// Playlist-Zeile: Ablegen fügt hinzu, Doppelklick/„Umbenennen“ bearbeitet den Namen direkt
struct PlaylistSidebarRow: View {
    @AppEnv private var app
    @MacEnv private var mac
    let playlist: Playlist
    @State private var targeted = false
    @State private var name = ""
    @FocusState private var editing: Bool

    private var isSmart: Bool { playlist.readonly == true || (playlist.comment ?? "").hasPrefix("Auto-imported") }

    var body: some View {
        Label {
            if mac.renamingPlaylist == playlist.id {
                TextField("", text: $name)
                    .focused($editing)
                    .onSubmit { commit() }
                    .onExitCommand { mac.renamingPlaylist = nil }
                    .onAppear { name = playlist.name; editing = true }
                    .onChange(of: editing) { _, e in if !e { commit() } }
            } else {
                Text(playlist.name)
            }
        } icon: {
            Image(systemName: playlist.id.isLocalPlaylistID ? "music.note.list" : (isSmart ? "gearshape" : "music.note.list"))
        }
        .padding(.horizontal, 2)
        .background(targeted ? RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accent, lineWidth: 2) : nil)
        .dropDestination(for: ItemsTransfer.self) { items, _ in
            Task {
                let songs = await items.resolve(app)
                mac.add(songs, to: playlist)
            }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu { PlaylistContextMenu(playlist: playlist) }
        .accessibilityIdentifier("sidebar.playlist.\(playlist.name)")
    }

    private func commit() {
        guard mac.renamingPlaylist == playlist.id else { return }
        mac.renamingPlaylist = nil
        mac.rename(playlist, to: name.trimmingCharacters(in: .whitespaces))
    }
}
