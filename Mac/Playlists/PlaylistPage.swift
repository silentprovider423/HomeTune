import SwiftUI

/// Playlist-Seite: Kopf mit Cover, Name, Beschreibung, „<n> Titel, <Dauer>“, Wiedergabe/Zufällig/„⋯“
/// (darin „Playlist bearbeiten“), darunter die Titeltabelle mit „Reihenfolge der Playlist“.
struct PlaylistPage: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    let playlistID: String
    @State private var playlist: Playlist?
    @State private var songs: [Song] = []
    @State private var loading = true
    @State private var editing = false
    @State private var editName = ""
    @State private var editComment = ""
    @State private var tableID = UUID()

    private var meta: Playlist? { app.library.allPlaylists.first { $0.id == playlistID } ?? playlist }
    private var isSmart: Bool { meta?.readonly == true || (meta?.comment ?? "").hasPrefix("Auto-imported") }

    var body: some View {
        VStack(spacing: 0) {
            if let p = meta {
                header(p)
                Divider()
                if songs.isEmpty && !loading {
                    EmptyState(title: "Es befinden sich keine Titel in dieser Playlist.", systemImage: "music.note.list",
                               message: "Zieh Titel hierher oder auf die Playlist in der Seitenleiste.")
                        .dropDestination(for: ItemsTransfer.self) { items, _ in
                            Task { mac.add(await items.resolve(app), to: p) }
                            return true
                        }
                } else if loading && songs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SongTable(songs: songs, context: "playlist", style: .playlist(playlist ?? p), queueName: p.name, defaultSort: nil)
                        .id(tableID)
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(title: "Playlist nicht verfügbar", systemImage: "music.note.list")
            }
        }
        .task(id: playlistID) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .playlistChanged)) { n in
            if n.object == nil || (n.object as? String) == playlistID { Task { await load() } }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let p = try? await app.library.playlistSongs(playlistID) {
            playlist = p
            songs = p.entry ?? []
        }
    }

    @ViewBuilder private func header(_ p: Playlist) -> some View {
        let total = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        HStack(alignment: .bottom, spacing: 20) {
            PlaylistMosaic(playlist: p, songs: songs, size: 150)
            VStack(alignment: .leading, spacing: 5) {
                if editing {
                    TextField("Name der Playlist", text: $editName)
                        .font(.system(size: 24, weight: .bold))
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("playlist.editName")
                    TextField("Beschreibung hinzufügen", text: $editComment, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.secondary)
                        .lineLimit(1...3)
                } else {
                    HStack(spacing: 6) {
                        if isSmart { Image(systemName: "gearshape").foregroundStyle(.secondary) }
                        Text(p.name).font(.system(size: 26, weight: .bold)).lineLimit(1)
                    }
                    if let c = p.comment, !c.isEmpty {
                        Text(c).foregroundStyle(.secondary).lineLimit(2)
                    } else if !isSmart {
                        Button("Beschreibung hinzufügen") { startEditing(p) }.buttonStyle(.link)
                    }
                    if isSmart {
                        Text("Regeln werden auf dem Server festgelegt.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(songs.count) Titel, \(Fmt.total(total))").font(.callout).foregroundStyle(.secondary)
                Spacer().frame(height: 6)
                HStack(spacing: 10) {
                    if editing {
                        Button("Fertig") { finishEditing(p) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [])
                            .accessibilityIdentifier("playlist.done")
                        Button("Abbrechen", role: .cancel) { editing = false }
                    } else {
                        PlayShuffleButtons(play: { mac.play(mac.available(songs), name: p.name) },
                                           shuffle: { mac.play(mac.available(songs), name: p.name, shuffle: true) })
                            .controlSize(.regular)
                            .disabled(songs.isEmpty)
                        Menu {
                            if !isSmart {
                                Button("Playlist bearbeiten") { startEditing(p) }
                                Divider()
                            }
                            PlaylistContextMenu(playlist: p)
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityIdentifier("playlist.more")
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func startEditing(_ p: Playlist) {
        editName = p.name
        editComment = p.comment ?? ""
        editing = true
    }

    private func finishEditing(_ p: Playlist) {
        editing = false
        let name = editName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != p.name || editComment != (p.comment ?? "") else { return }
        Task {
            do {
                try await app.library.save(playlist: p, name: name, comment: editComment, songs: songs.map(\.id))
                await load()
            } catch {
                app.notice.show(error.localizedDescription, icon: "exclamationmark.triangle")
            }
        }
    }
}

/// Cover der Playlist: Server-Cover, sonst 4er-Mosaik aus den ersten Albumcovern
struct PlaylistMosaic: View {
    let playlist: Playlist
    let songs: [Song]
    var size: CGFloat

    var body: some View {
        let covers = Array(NSOrderedSet(array: songs.compactMap(\.coverArt)).array.compactMap { $0 as? String }.prefix(4))
        if playlist.id.isLocalPlaylistID && covers.count >= 4 {
            let half = size / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) { CoverArt(id: covers[0], size: half, corner: 0); CoverArt(id: covers[1], size: half, corner: 0) }
                HStack(spacing: 0) { CoverArt(id: covers[2], size: half, corner: 0); CoverArt(id: covers[3], size: half, corner: 0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            PlaylistCover(playlist: playlist, size: size)
        }
    }
}

/// „Neue Playlist“ (⌘N): Name, Beschreibung (optional), Ort „Auf dem Server“ / „Nur auf diesem Mac“
struct NewPlaylistSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    @Environment(\.dismiss) private var dismiss
    let songs: [Song]
    @State private var name = ""
    @State private var comment = ""
    @State private var onDevice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Neue Playlist").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("Name der Playlist"))
                    .accessibilityIdentifier("newPlaylist.name")
                TextField("Beschreibung (optional)", text: $comment, axis: .vertical)
                    .lineLimit(2...4)
                if app.client != nil {
                    Picker("Ort", selection: $onDevice) {
                        Text("Auf dem Server").tag(false)
                        Text("Nur auf diesem Mac").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
                if !songs.isEmpty {
                    Text("\(songs.count) Titel werden hinzugefügt.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Erstellen") {
                    mac.createPlaylist(name: name.trimmingCharacters(in: .whitespaces), comment: comment, songs: songs,
                                       onDevice: onDevice || app.client == nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("newPlaylist.create")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
