import SwiftUI

/// Konten (umschalten, hinzufügen, entfernen), Server, Speicher, Stimmung (432/440/528 Hz) und Version.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var addAccount = false
    @State private var cacheBytes: Int64 = 0
    @State private var scanText: String?
    @State private var confirmRemove: ServerAccount?

    var body: some View {
        NavigationStack {
            Form {
                Section("Konten") {
                    ForEach(app.accounts.accounts) { a in
                        Button {
                            guard a.id != app.accounts.current?.id else { return }
                            app.accounts.select(a.id)
                            app.connect()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(a.username).foregroundStyle(.primary)
                                    Text(a.server.absoluteString).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if a.id == app.accounts.current?.id { Image(systemName: "checkmark").foregroundStyle(.accent) }
                            }
                        }
                        .swipeActions { Button("Entfernen", role: .destructive) { confirmRemove = a } }
                    }
                    Button("Konto hinzufügen …", systemImage: "plus") { addAccount = true }
                }
                if app.client != nil {
                    Section {
                        LabeledContent("Server", value: app.library.serverVersion ?? "–")
                        LabeledContent("Titel", value: "\(app.library.serverSongs.count)")
                        LabeledContent("Alben", value: "\(app.library.serverAlbums.count)")
                        Button("Mediathek aktualisieren", systemImage: "arrow.clockwise") { Task { await app.library.refresh() } }
                        Button("Server-Mediathek neu einlesen", systemImage: "arrow.triangle.2.circlepath") {
                            Task {
                                do {
                                    let s = try await app.client?.startScan()
                                    scanText = s?.scanning == true ? String(localized: "Einlesen läuft …") : String(localized: "Fertig")
                                } catch { scanText = error.localizedDescription }
                            }
                        }
                        if let scanText { Text(scanText).font(.footnote).foregroundStyle(.secondary) }
                    } header: { Text("Mediathek") } footer: {
                        Text("Neu einlesen braucht ein Administrator-Konto in Navidrome.")
                    }
                }
                Section {
                    LabeledContent("Titel", value: "\(app.local.songs.count)")
                    LabeledContent("Alben", value: "\(app.local.albums.count)")
                    if app.local.importedBytes > 0 {
                        LabeledContent("Empfangene Dateien", value: Fmt.bytes(app.local.importedBytes))
                    }
                    Button("Alle neu einlesen", systemImage: "arrow.triangle.2.circlepath") { app.rescanLocal() }
                } header: { Text("Auf diesem iPhone") } footer: {
                    Text("Musik aus der Dateien-App wird nur verknüpft, nicht kopiert, und läuft offline und ohne Server.")
                }
                Section {
                    LabeledContent("Geladen", value: Fmt.bytes(app.downloads.totalBytes))
                    LabeledContent("Zwischenspeicher", value: Fmt.bytes(cacheBytes))
                    Button("Zwischenspeicher leeren", systemImage: "trash") {
                        Task { await TrackCache.shared.clear(); cacheBytes = await TrackCache.shared.sizeBytes() }
                    }
                } header: { Text("Speicher") }
                Section {
                    ForEach(Tuning.allCases) { t in
                        Button {
                            app.player.tuning = t
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(t.hz) Hz").foregroundStyle(.primary)
                                    Text(t.subtitle).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.player.tuning == t { Image(systemName: "checkmark").foregroundStyle(.accent).fontWeight(.semibold) }
                            }
                            .contentShape(.rect)
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(app.player.tuning == t ? .isSelected : [])
                        .accessibilityIdentifier("tuning.\(t.rawValue)")
                    }
                } header: { Text("Stimmung") } footer: {
                    Text("Musik ist meist auf A = 440 Hz gestimmt. HomeTune verschiebt die Tonhöhe direkt auf dem iPhone, das Tempo bleibt gleich. Bei 440 Hz läuft die Datei unverändert.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Konto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: $addAccount) { LoginView(isSheet: true) }
            .task { cacheBytes = await TrackCache.shared.sizeBytes() }
            .confirmationDialog("Konto entfernen?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                                titleVisibility: .visible, presenting: confirmRemove) { a in
                Button("Konto entfernen", role: .destructive) {
                    app.accounts.remove(a.id)
                    // Ohne Konto, aber mit Musik auf diesem iPhone: in der Mediathek bleiben
                    if app.accounts.accounts.isEmpty && !app.local.isEmpty { app.localMode = true }
                    app.connect()
                    if app.showsLogin { dismiss() }
                }
            } message: { a in Text("Das Konto „\(a.username)“ wird von diesem iPhone entfernt. Auf dem Server bleibt alles erhalten.") }
        }
    }
}

extension Tuning {
    /// Zweite Zeile in den Einstellungen
    var subtitle: LocalizedStringKey {
        switch self {
        case .hz440: "Standard · Original, keine Bearbeitung"
        case .hz432: "A = 432 Hz"
        case .hz528: "A = 444 Hz (C = 528 Hz)"
        }
    }
}
