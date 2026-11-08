import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false
    @State private var toDelete: Playlist?

    var body: some View {
        List {
            Button { creating = true } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.tertiarySystemFill)).frame(width: 56, height: 56)
                        .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(.accent))
                    Text("Neue Playlist …").foregroundStyle(.accent)
                }
            }
            .accessibilityIdentifier("playlist.new")
            ForEach(app.library.allPlaylists) { p in
                NavigationLink(value: Route.playlist(p.id)) {
                    HStack(spacing: 12) {
                        CoverArt(id: p.coverArt, size: 56, corner: 6).frame(width: 56, height: 56)
                        VStack(alignment: .leading) {
                            Text(p.name).lineLimit(1)
                            if p.id.isLocalPlaylistID {
                                // Eigene Playlist auf diesem iPhone (nicht auf dem Server)
                                Label { Text("Auf diesem iPhone · \(p.songCount ?? 0) Titel") } icon: { Image(systemName: "iphone") }
                                    .font(.subheadline).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                            } else {
                                Text("\(p.songCount ?? 0) Titel").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier(p.id.isLocalPlaylistID ? "playlist.local" : "playlist.server")
                .contextMenu { PlaylistMenu(playlist: p, onDelete: { toDelete = p }) }
                .swipeActions { Button("Löschen", systemImage: "trash", role: .destructive) { toDelete = p } }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Neue Playlist …", systemImage: "plus") { creating = true }
                    // .m3u/.m3u8/.pls, z. B. aus Apple Music am Mac exportiert
                    Button("Playlist importieren …", systemImage: "square.and.arrow.down") { app.importRequest = .files }
                        .accessibilityIdentifier("playlist.import")
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(Text("Mehr"))
            }
        }
        .refreshable { await app.library.refreshPlaylists() }
        .sheet(isPresented: $creating) { PlaylistEditor(playlist: nil, initialSongs: []) }
        .confirmationDialog("Playlist löschen?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible, presenting: toDelete) { p in
            Button("Playlist löschen", role: .destructive) { Task { try? await app.library.delete(playlist: p) } }
        } message: { p in PlaylistDeleteMessage(playlist: p) }
    }
}

/// „Wird auf dem Server gelöscht“ bzw. „von diesem iPhone gelöscht“.
struct PlaylistDeleteMessage: View {
    let playlist: Playlist
    var body: some View {
        if playlist.id.isLocalPlaylistID {
            Text("„\(playlist.name)“ wird von diesem iPhone gelöscht. Die Titel bleiben in der Mediathek.")
        } else {
            Text("„\(playlist.name)“ wird auf dem Server gelöscht. Die Titel bleiben in der Mediathek.")
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @State private var playlist: Playlist?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var error: String?

    private var songs: [Song] { playlist?.entry ?? [] }

    var body: some View {
        List {
            if let p = playlist ?? app.library.allPlaylists.first(where: { $0.id == playlistID }) {
                VStack(spacing: 10) {
                    CoverArt(id: p.coverArt, size: 260, corner: 10).frame(width: 250, height: 250)
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                    Text(p.name).font(.title2.bold()).multilineTextAlignment(.center)
                    if let owner = p.owner { Text(owner).foregroundStyle(.accent) }
                    if p.id.isLocalPlaylistID {
                        Label("Auf diesem iPhone", systemImage: "iphone").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let c = p.comment, !c.isEmpty { Text(c).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    PlayShuffleButtons(play: { app.player.play(songs, name: p.name) },
                                       shuffle: { app.player.play(songs, name: p.name, shuffle: true) })
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                    SongRow(song: song, onRemoveFromPlaylist: { remove(at: i) })
                        .onTapGesture { app.player.play(songs, startAt: i, name: p.name) }
                        .songActions(song, onRemoveFromPlaylist: { remove(at: i) })
                }
                if !songs.isEmpty {
                    Text("\(songs.count) Titel, \(Fmt.minutes(p.duration ?? 0)) Minuten")
                        .font(.subheadline).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .overlay { if playlist == nil && error == nil { ProgressView() } }
        .overlay { if let error { EmptyHint(title: "Nicht verfügbar", icon: "wifi.slash", text: LocalizedStringKey(error)) } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bearbeiten") { editing = true }.disabled(playlist == nil || playlist?.readonly == true)
                    .accessibilityIdentifier("playlist.edit")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let p = playlist {
                    Menu { PlaylistMenu(playlist: p, onEdit: { editing = true }, onDelete: { confirmDelete = true }) }
                        label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let p = playlist { PlaylistEditor(playlist: p, initialSongs: songs) }
        }
        .confirmationDialog("Playlist löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Playlist löschen", role: .destructive) {
                Task {
                    if let p = playlist { try? await app.library.delete(playlist: p) }
                    dismiss()
                }
            }
        } message: { if let p = playlist { PlaylistDeleteMessage(playlist: p) } }
    }

    private func load() async {
        do { playlist = try await app.library.playlistSongs(playlistID); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func remove(at index: Int) {
        guard let p = playlist else { return }
        Task {
            try? await app.library.remove(indexes: [index], from: p)
            await load()
            app.notice.show(String(localized: "Aus Playlist entfernt"), icon: "minus.circle")
        }
    }
}

/// Playlist anlegen oder bearbeiten (Name, Beschreibung, Titel ordnen/entfernen, Musik hinzufügen),
/// mit „Änderungen verwerfen?“ wie bei Apple.
struct PlaylistEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist?
    let initialSongs: [Song]
    @State private var name = ""
    @State private var comment = ""
    @State private var songs: [Song] = []
    @State private var addMusic = false
    @State private var confirmDiscard = false
    @State private var saving = false
    @State private var error: String?
    /// Neue Playlist auf diesem iPhone statt auf dem Server
    @State private var onDevice = false

    /// Lokale Titel können nur in Playlists auf diesem iPhone stehen
    private var needsDevice: Bool { app.client == nil || songs.contains(where: \.isLocal) }
    private var isLocal: Bool { playlist.map { $0.id.isLocalPlaylistID } ?? (onDevice || needsDevice) }

    private var changed: Bool {
        name != (playlist?.name ?? "") || comment != (playlist?.comment ?? "") || songs.map(\.id) != initialSongs.map(\.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Playlist-Titel", text: $name).font(.title3.bold())
                        .accessibilityIdentifier("playlist.name")
                    TextField("Beschreibung", text: $comment, axis: .vertical)
                }
                if playlist == nil && app.client != nil {
                    Section {
                        Toggle(isOn: Binding(get: { isLocal }, set: { onDevice = $0 })) {
                            Label("Auf diesem iPhone speichern", systemImage: "iphone")
                        }
                        .disabled(needsDevice)
                        .accessibilityIdentifier("playlist.onDevice")
                    } footer: {
                        Text(needsDevice ? "Titel auf diesem iPhone können nur in Playlists auf diesem iPhone stehen."
                                         : "Sonst wird die Playlist auf dem Server angelegt.")
                    }
                }
                Section {
                    Button { addMusic = true } label: { Label("Musik hinzufügen", systemImage: "plus.circle.fill") }
                        .accessibilityIdentifier("playlist.addMusic")
                    ForEach(Array(songs.enumerated()), id: \.offset) { _, s in
                        SongRow(song: s).allowsHitTesting(false)
                    }
                    .onMove { songs.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { songs.remove(atOffsets: $0) }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(playlist == nil ? Text("Neue Playlist") : Text("Playlist bearbeiten"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(changed)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .accessibilityIdentifier("playlist.done")
                }
            }
            .confirmationDialog("Änderungen verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Änderungen verwerfen", role: .destructive) { dismiss() }
                Button("Weiter bearbeiten", role: .cancel) {}
            }
            .sheet(isPresented: $addMusic) { AddMusicSheet(includeLocal: isLocal) { songs += $0 } }
        }
        .onAppear {
            name = playlist?.name ?? ""
            comment = playlist?.comment ?? ""
            songs = initialSongs
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let n = name.trimmingCharacters(in: .whitespaces)
            if let playlist {
                try await app.library.save(playlist: playlist, name: n, comment: comment, songs: songs.map(\.id))
            } else {
                _ = try await app.library.createPlaylist(name: n, comment: comment, songs: songs.map(\.id), onDevice: isLocal)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// „Musik hinzufügen“: Titel aus der Mediathek suchen und auswählen.
struct AddMusicSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Playlist auf diesem iPhone: auch lokale Titel anbieten
    var includeLocal = false
    let onAdd: ([Song]) -> Void
    @State private var query = ""
    @State private var picked: [Song] = []

    private var results: [Song] {
        // Server-Playlists können nur Server-Titel enthalten
        let all = includeLocal ? app.library.songs : app.library.serverSongs
        guard !query.isEmpty else { return Array(all.sorted { ($0.created ?? "") > ($1.created ?? "") }.prefix(100)) }
        return all.filter { $0.title.localizedStandardContains(query) || ($0.artist ?? "").localizedStandardContains(query) || ($0.album ?? "").localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(results) { s in
                HStack {
                    SongRow(song: s).allowsHitTesting(false)
                    Image(systemName: picked.contains(s) ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(.accent).font(.title3)
                }
                .contentShape(.rect)
                .onTapGesture {
                    if let i = picked.firstIndex(of: s) { picked.remove(at: i) } else { picked.append(s) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(picked.contains(s) ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("addMusic.row")
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Mediathek durchsuchen"))
            .navigationTitle("Musik hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") { onAdd(picked); dismiss() }.disabled(picked.isEmpty)
                        .accessibilityIdentifier("addMusic.done")
                }
            }
        }
    }
}

/// „Zur Playlist hinzufügen“ mit Hinweis, wenn Titel schon enthalten sind (Erneut hinzufügen / Überspringen).
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let songs: [Song]
    @State private var creating = false
    @State private var duplicate: (Playlist, [Song], [Song])?

    var body: some View {
        NavigationStack {
            List {
                Button { creating = true } label: { Label("Neue Playlist …", systemImage: "plus") }
                // Lokale Titel passen nur in Playlists auf diesem iPhone
                ForEach(app.library.allPlaylists.filter { $0.readonly != true && ($0.id.isLocalPlaylistID || !songs.contains(where: \.isLocal)) }) { p in
                    Button { Task { await add(to: p) } } label: {
                        HStack(spacing: 12) {
                            CoverArt(id: p.coverArt, size: 48, corner: 5).frame(width: 48, height: 48)
                            Text(p.name).foregroundStyle(.primary)
                            if p.id.isLocalPlaylistID {
                                Spacer()
                                Image(systemName: "iphone").foregroundStyle(.secondary).accessibilityLabel(Text("Auf diesem iPhone"))
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Zur Playlist hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } } }
            .sheet(isPresented: $creating, onDismiss: { dismiss() }) { PlaylistEditor(playlist: nil, initialSongs: songs) }
            .confirmationDialog("Bereits in der Playlist", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }),
                                titleVisibility: .visible) {
                Button("Erneut hinzufügen") { if let d = duplicate { Task { await commit(d.0, d.1 + d.2) } } }
                Button("Überspringen") { if let d = duplicate { Task { await commit(d.0, d.1) } } }
            } message: {
                Text("Einige Titel sind schon in dieser Playlist.")
            }
        }
    }

    private func add(to p: Playlist) async {
        let entries = (try? await app.library.playlistSongs(p.id))?.entry ?? []
        let existing = Set(entries.map(\.id))
        let fresh = songs.filter { !existing.contains($0.id) }
        let dupes = songs.filter { existing.contains($0.id) }
        if dupes.isEmpty { await commit(p, fresh) } else { duplicate = (p, fresh, dupes) }
    }

    private func commit(_ p: Playlist, _ list: [Song]) async {
        if !list.isEmpty { try? await app.library.add(list.map(\.id), to: p) }
        app.notice.show(String(localized: "Zur Playlist hinzugefügt"), icon: "text.badge.checkmark")
        dismiss()
    }
}
