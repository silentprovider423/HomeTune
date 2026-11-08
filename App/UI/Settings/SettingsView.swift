import SwiftUI

/// Konten (umschalten, hinzufügen, entfernen), Server, Speicher und Erklärung zur 432-Hz-Stimmung.
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
                Section {
                    LabeledContent("Server", value: app.library.serverVersion ?? "–")
                    LabeledContent("Titel", value: "\(app.library.songs.count)")
                    LabeledContent("Alben", value: "\(app.library.albums.count)")
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
                Section {
                    LabeledContent("Geladen", value: Fmt.bytes(app.downloads.totalBytes))
                    LabeledContent("Zwischenspeicher", value: Fmt.bytes(cacheBytes))
                    Button("Zwischenspeicher leeren", systemImage: "trash") {
                        Task { await TrackCache.shared.clear(); cacheBytes = await TrackCache.shared.sizeBytes() }
                    }
                } header: { Text("Speicher") }
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Immer in 432 Hz").font(.headline)
                            Text("HomeSpin spielt jeden Titel um 31,77 Cent tiefer (A4 = 432 Hz statt 440 Hz). Das Tempo bleibt gleich, die Originaldatei wird verlustfrei geladen.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "tuningfork").foregroundStyle(.accent) }
                } header: { Text("Klang") }
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
                    app.connect()
                    if app.client == nil { dismiss() }
                }
            } message: { a in Text("Das Konto „\(a.username)“ wird von diesem iPhone entfernt. Auf dem Server bleibt alles erhalten.") }
        }
    }
}
