import SwiftUI

/// Menüeinträge „Musik hinzufügen“: Ordner oder einzelne Dateien aus der Dateien-App (Mehrfachauswahl).
struct AddLocalMusicMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section("Musik vom iPhone hinzufügen") {
            Button("Ordner hinzufügen …", systemImage: "folder.badge.plus") { app.importRequest = .folder }
                .accessibilityIdentifier("local.addFolder")
            Button("Dateien hinzufügen …", systemImage: "doc.badge.plus") { app.importRequest = .files }
                .accessibilityIdentifier("local.addFiles")
        }
    }
}

/// Leerer Zustand mit den beiden Wegen, Musik vom iPhone hinzuzufügen.
struct AddLocalMusicHint: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.accent)
                .padding(.bottom, 2)
            Text("Musik vom iPhone hinzufügen").font(.title3.bold()).multilineTextAlignment(.center)
            Text("Wähle einen Ordner oder einzelne Dateien in der Dateien-App – FLAC, MP3, AAC, ALAC, WAV, AIFF oder Opus. HomeTune merkt sich nur, wo sie liegen.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            AppFolderHint()
            HStack(spacing: 12) {
                Button { app.importRequest = .folder } label: {
                    Label("Ordner", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("local.empty.addFolder")
                Button { app.importRequest = .files } label: {
                    Label("Dateien", systemImage: "doc.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("local.empty.addFiles")
            }
            .controlSize(.large)
            .tint(.accent)
            .padding(.top, 4)
            if app.client == nil {
                Button("Mit einem Server verbinden …") { app.showSettings = true }
                    .font(.subheadline)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 8)
    }
}

/// Hinweis auf den eigenen Ordner in der Dateien-App (funktioniert ohne Dateien-Dialog).
struct AppFolderHint: View {
    var body: some View {
        Label {
            Text("Musik in der Dateien-App nach „Auf meinem iPhone › HomeTune“ verschieben – sie erscheint hier automatisch.")
        } icon: { Image(systemName: "folder.fill").foregroundStyle(.accent) }
        .font(.subheadline).foregroundStyle(.secondary)
        .accessibilityIdentifier("local.appFolderHint")
    }
}

/// Signatur-Profil gilt für eine andere App-ID: dann übergibt iOS aus dem Dateien-Dialog nichts.
struct SigningHint: View {
    let appID: String
    var body: some View {
        Label {
            Text("Dein Signatur-Profil gilt für die App-ID \(appID). Damit der Dateien-Dialog Musik übergeben kann, im Sideload-Tool die Bundle-ID auf \(appID) setzen.")
        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        .font(.subheadline)
        .accessibilityIdentifier("local.signingHint")
    }
}

/// „Auf diesem iPhone“: Musik aus der Dateien-App – Alben, Künstler:innen, Titel, zuletzt hinzugefügt, der
/// HomeTune-Ordner und die gemerkten Ordner (neu einlesen, entfernen). Entfernen löscht nie Originaldateien
/// außerhalb des HomeTune-Ordners.
struct LocalMusicView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRemove: LocalRoot?

    var body: some View {
        let local = app.local
        let name = String(localized: "Auf diesem iPhone")
        List {
            if let id = app.signingMismatch {
                Section { SigningHint(appID: id) }
            }
            if local.isEmpty && !local.isScanning {
                AddLocalMusicHint().listRowSeparator(.hidden)
            } else {
                PlayShuffleButtons(play: { app.player.play(local.songs, name: name) },
                                   shuffle: { app.player.play(local.songs, name: name, shuffle: true) })
                    .listRowSeparator(.hidden)
                Section {
                    link(.localAlbums, "Alben", icon: "square.stack", count: local.albums.count, id: "local.albums")
                    link(.localArtists, "Künstler:innen", icon: "music.microphone", count: local.artists.count, id: "local.artists")
                    link(.localSongs, "Titel", icon: "music.note", count: local.songs.count, id: "local.songs")
                }
            }
            if local.isScanning {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        if local.scanTotal > 0 {
                            Text("Wird eingelesen … \(local.scanDone) von \(local.scanTotal)")
                        } else {
                            Text("Wird eingelesen …")
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !local.albums.isEmpty {
                Section {
                    Text("Zuletzt hinzugefügt").font(.title2.bold())
                        .padding(.top, 8)
                        .listRowSeparator(.hidden)
                    LazyVGrid(columns: albumGrid, spacing: 18) {
                        ForEach(local.recentAlbums.prefix(8)) { AlbumTile(album: $0) }
                    }
                    .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(local.allRoots) { r in
                    rootRow(r)
                        .swipeActions(edge: .trailing) {
                            if r.kind != .appFolder {
                                Button("Entfernen", systemImage: "minus.circle", role: .destructive) { confirmRemove = r }
                            }
                            Button("Neu einlesen", systemImage: "arrow.triangle.2.circlepath") { app.rescanLocal(r.id) }
                                .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Neu einlesen", systemImage: "arrow.triangle.2.circlepath") { app.rescanLocal(r.id) }
                            Button("Wiedergeben", systemImage: "play") {
                                app.player.play(local.songs(ofRoot: r.id).sorted(by: Self.albumOrder), name: displayName(r))
                            }
                            if r.kind != .appFolder {
                                Button("Aus der Mediathek entfernen", systemImage: "minus.circle", role: .destructive) { confirmRemove = r }
                            }
                        }
                }
            } header: {
                Text("Ordner und Dateien").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if !local.isEmpty { AppFolderHint() }
                    Text("HomeTune merkt sich nur, wo die Musik liegt. Entfernen nimmt sie aus der Mediathek – die Dateien selbst bleiben unverändert.")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Auf diesem iPhone")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    AddLocalMusicMenu()
                    Section {
                        Button("Alle neu einlesen", systemImage: "arrow.triangle.2.circlepath") { app.rescanLocal() }
                    }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel(Text("Musik hinzufügen"))
                .accessibilityIdentifier("local.add")
            }
        }
        .refreshable { await app.local.rescanAll() }
        .confirmationDialog("Aus der Mediathek entfernen?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible, presenting: confirmRemove) { r in
            Button("Aus der Mediathek entfernen", role: .destructive) {
                app.local.removeRoot(r.id)
                app.notice.show(String(localized: "Aus der Mediathek entfernt"), icon: "minus.circle")
            }
        } message: { r in
            if r.kind == .copied {
                Text("Die an HomeTune geschickten Kopien werden gelöscht. Deine Originale bleiben, wo sie sind.")
            } else {
                Text("„\(r.name)“ verschwindet aus HomeTune. Die Dateien bleiben unverändert in der Dateien-App.")
            }
        }
    }

    static func albumOrder(_ a: Song, _ b: Song) -> Bool {
        ((a.album ?? ""), a.discNumber ?? 1, a.track ?? 0, a.title) < ((b.album ?? ""), b.discNumber ?? 1, b.track ?? 0, b.title)
    }

    private func displayName(_ r: LocalRoot) -> String {
        switch r.kind {
        case .copied: String(localized: "Empfangene Dateien")
        case .appFolder: String(localized: "HomeTune-Ordner")
        default: r.name
        }
    }

    private func link(_ route: Route, _ title: LocalizedStringKey, icon: String, count: Int, id: String) -> some View {
        NavigationLink(value: route) {
            HStack {
                Label { Text(title).font(.title3) } icon: { Image(systemName: icon).foregroundStyle(.accent) }
                Spacer()
                Text(verbatim: "\(count)").foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier(id)
    }

    private func rootRow(_ r: LocalRoot) -> some View {
        let n = app.local.trackCount(root: r.id)
        let icon = switch r.kind { case .folder: "folder"; case .file: "doc"; case .copied: "tray.and.arrow.down"; case .appFolder: "folder.fill" }
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(r)).lineLimit(1)
                if app.local.unreachable.contains(r.id) {
                    Label("Nicht erreichbar – bitte erneut hinzufügen", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
                } else {
                    Text("\(n) Titel").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("local.root")
    }
}
