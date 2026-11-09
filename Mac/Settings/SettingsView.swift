import SwiftUI
import AppKit

/// Einstellungen (⌘,): Tabs Allgemein · Konten · Wiedergabe · Downloads · Erweitert.
/// Raster wie bei Apple: Beschriftungen rechtsbündig in einer 156 pt breiten Spalte.
struct MacSettingsView: View {
    /// Zuletzt gewählter Tab (wird gemerkt)
    @AppStorage("mac.settingsTab") private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }.tag(0)
            AccountsSettings().tabItem { Label("Konten", systemImage: "person.crop.circle") }.tag(1)
            PlaybackSettings().tabItem { Label("settings.playback", systemImage: "play.circle") }.tag(2)
            DownloadSettings().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(3)
            AdvancedSettings().tabItem { Label("Erweitert", systemImage: "gearshape.2") }.tag(4)
        }
        .frame(width: 630)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Zeile im Einstellungsraster: Beschriftung rechtsbündig (156 pt), Steuerelemente rechts davon
private struct SettingsRow<Content: View>: View {
    let label: LocalizedStringKey?
    @ViewBuilder var content: Content
    init(_ label: LocalizedStringKey?, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let label { Text(label) } else { Text(verbatim: "") }
            }
            .frame(width: 156, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) { content }
            Spacer(minLength: 0)
        }
    }
}

private struct Hint: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.vertical, 22).padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Allgemein

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac
    var body: some View {
        @Bindable var mac = mac
        SettingsPage {
            SettingsRow("Anzeigen:") {
                Toggle("Favoriten", isOn: $mac.showFavoritesColumn)
                    .accessibilityIdentifier("settings.showFavorites")
            }
            SettingsRow("Größe der Liste:") {
                Picker("", selection: $mac.listSize) {
                    ForEach(ListSize.allCases) { s in Text(s.title).tag(s) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("settings.listSize")
            }
            SettingsRow("Mediathek:") {
                ForEach(MacSection.allCases) { s in
                    Toggle(isOn: Binding(get: { mac.visibleSections.contains(s) }, set: { on in
                        if on { mac.visibleSections.insert(s) } else { mac.visibleSections.remove(s) }
                    })) { Label(s.title, systemImage: s.icon) }
                }
                Hint("Diese Einträge erscheinen in der Seitenleiste unter „Mediathek“.")
            }
        }
    }
}

// MARK: Konten

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selection: String?
    @State private var addAccount = false
    @State private var confirmRemove: ServerAccount?
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        let accounts = app.accounts.accounts
        SettingsPage {
            List(selection: $selection) {
                ForEach(accounts) { a in
                    HStack {
                        Image(systemName: a.id == app.accounts.current?.id && app.client != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(a.id == app.accounts.current?.id && app.client != nil ? AnyShapeStyle(.accent) : AnyShapeStyle(.tertiary))
                        VStack(alignment: .leading) {
                            Text(a.username).font(.headline)
                            Text(a.server.absoluteString).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(a.id)
                }
            }
            .frame(height: 140)
            .overlay { if accounts.isEmpty { Text("Kein Konto").foregroundStyle(.secondary) } }
            HStack {
                Button { addAccount = true } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("settings.addAccount")
                Button { confirmRemove = accounts.first { $0.id == selection } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                Spacer()
                Button("Verwenden") {
                    if let id = selection { app.accounts.select(id); app.localMode = false; app.connect() }
                }
                .disabled(selection == nil || selection == app.accounts.current?.id)
                Button("Verbindung testen") { Task { await test() } }
                    .disabled(app.client == nil || busy)
                Button("Server-Mediathek aktualisieren") { Task { await scan() } }
                    .disabled(app.client == nil || busy)
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
            Hint("Das Passwort bleibt im Schlüsselbund dieses Macs. HomeTune spricht nur mit deinem Server.")
        }
        .sheet(isPresented: $addAccount) { LoginSheet() }
        .onAppear { selection = app.accounts.current?.id }
        .alert(Text("Konto entfernen?"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
               presenting: confirmRemove) { a in
            Button("Konto entfernen", role: .destructive) {
                app.accounts.remove(a.id)
                if app.accounts.accounts.isEmpty && !app.local.isEmpty { app.localMode = true }
                app.connect()
                selection = app.accounts.current?.id
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { a in Text("Das Konto „\(a.username)“ wird von diesem Mac entfernt. Auf dem Server bleibt alles erhalten.") }
    }

    private func test() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            let s = try await c.ping()
            status = String(localized: "Verbunden: \(s.type ?? "Subsonic") \(s.serverVersion ?? s.version ?? "")")
        } catch {
            status = error.localizedDescription
        }
    }

    private func scan() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await c.startScan()
            status = String(localized: "Der Server liest die Mediathek neu ein.")
            try? await Task.sleep(for: .seconds(3))
            await app.library.refresh()
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Anmeldeblatt: Serveradresse, Benutzername, Passwort (Passwort in den Schlüsselbund, Anfragen mit Salz + Token)
struct LoginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text("Mit einem Server verbinden").font(.headline)
                    Text("Navidrome oder ein anderer Subsonic-Server.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Server", text: $server, prompt: Text(verbatim: "http://musik.local:4533"))
                    .textContentType(.URL)
                    .accessibilityIdentifier("login.server")
                TextField("Benutzername", text: $user)
                    .textContentType(.username)
                    .accessibilityIdentifier("login.user")
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("login.password")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            Text("Das Passwort bleibt im Schlüsselbund dieses Macs. HomeTune spricht nur mit deinem Server.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await login() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Anmelden") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || server.isEmpty || user.isEmpty || password.isEmpty)
                .accessibilityIdentifier("login.submit")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func login() async {
        guard let url = AccountStore.normalize(server) else {
            error = String(localized: "Ungültige Serveradresse.")
            return
        }
        busy = true
        defer { busy = false }
        let account = ServerAccount(server: url, username: user.trimmingCharacters(in: .whitespaces))
        let client = SubsonicClient(account: account, password: password)
        do {
            _ = try await client.ping()
            app.accounts.add(account, password: password)
            app.localMode = false
            app.connect()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Wiedergabe

extension Tuning {
    /// Beschriftung in den Mac-Einstellungen
    var macTitle: LocalizedStringKey {
        switch self {
        case .hz440: "440 Hz – Standard (Original)"
        case .hz432: "432 Hz"
        case .hz528: "528 Hz"
        }
    }
}

/// Streaming-Qualität in kbit/s (0 = Original, verlustfrei)
private let bitRates = [0, 320, 256, 192, 128]

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("streamMaxBitRate") private var maxBitRate = 0

    var body: some View {
        @Bindable var player = app.player
        SettingsPage {
            SettingsRow("Stimmung:") {
                Picker("", selection: $player.tuning) {
                    ForEach(Tuning.allCases) { t in
                        Text(t.macTitle).tag(t).accessibilityIdentifier("tuning.\(t.rawValue)")
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("settings.tuning")
                Hint("Das Tempo bleibt gleich. Die Umstellung wirkt sofort, auch mitten im Titel.")
            }
            SettingsRow("Streaming-Qualität:") {
                Picker("", selection: $maxBitRate) {
                    ForEach(bitRates, id: \.self) { r in
                        if r == 0 { Text("Original (verlustfrei)").tag(r) } else { Text("\(r) kbit/s").tag(r) }
                    }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("settings.quality")
                Hint("Gilt für neu geladene Titel. Geladene Titel bleiben im Original. Lückenlose Wiedergabe ist immer an.")
            }
        }
    }
}

// MARK: Downloads

private struct DownloadSettings: View {
    @Environment(AppModel.self) private var app
    @State private var cacheBytes: Int64 = 0
    @State private var confirmRemoveAll = false

    var body: some View {
        SettingsPage {
            SettingsRow("Speicherort:") {
                HStack {
                    Text(AppPaths.applicationSupport.appending(path: "Downloads").path)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Im Finder zeigen") {
                        let d = AppPaths.applicationSupport.appending(path: "Downloads", directoryHint: .isDirectory)
                        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([d])
                    }
                }
            }
            SettingsRow("Geladen:") {
                HStack {
                    Text(Fmt.bytes(app.downloads.totalBytes)).monospacedDigit()
                    Button("Alle Downloads entfernen …") { confirmRemoveAll = true }
                        .disabled(app.downloads.items.isEmpty)
                }
            }
            SettingsRow("Zwischenspeicher:") {
                HStack {
                    Text(Fmt.bytes(cacheBytes)).monospacedDigit()
                    Button("Cache leeren") {
                        Task { await TrackCache.shared.clear(); cacheBytes = await TrackCache.shared.sizeBytes() }
                    }
                }
                Hint("Zuletzt gespielte Titel bleiben für schnelles Wiederhören im Zwischenspeicher (höchstens 3 GB).")
            }
        }
        .task { cacheBytes = await TrackCache.shared.sizeBytes() }
        .alert(Text("Alle Downloads entfernen?"), isPresented: $confirmRemoveAll) {
            Button("Entfernen", role: .destructive) { app.downloads.removeAll() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die geladenen Titel werden von diesem Mac gelöscht. Auf dem Server bleibt alles erhalten.")
        }
    }
}

// MARK: Erweitert

private struct AdvancedSettings: View {
    @AppStorage("mac.miniOnTop") private var miniOnTop = false
    @State private var reset = false
    var body: some View {
        SettingsPage {
            SettingsRow("MiniPlayer:") {
                Toggle("MiniPlayer immer im Vordergrund halten", isOn: $miniOnTop)
            }
            SettingsRow("Warnhinweise:") {
                HStack {
                    Button("Zurücksetzen") { MacModel.resetWarnings(); reset = true }
                    if reset { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                }
                Hint("Alle Warnhinweise, bei denen „Nicht mehr fragen“ gewählt wurde, erscheinen wieder.")
            }
            SettingsRow("Version:") {
                Text(verbatim: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .foregroundStyle(.secondary)
                Hint("HomeTune ist freie Software (GPLv3). Tonhöhe: signalsmith-stretch (MIT).")
            }
        }
    }
}

// MARK: Informationen (⌘I)

/// Fenster „Informationen“: Datei, Format, Datenrate, Pfad, Wiedergaben – für die gewählten Titel
struct InfoWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(MacModel.self) private var mac

    var body: some View {
        let songs = mac.infoSongs
        VStack(alignment: .leading, spacing: 14) {
            if let s = songs.first, songs.count == 1 {
                HStack(spacing: 14) {
                    CoverArt(id: s.coverArt, size: 80)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.title3.bold()).lineLimit(2)
                        Text(s.artist ?? "").foregroundStyle(.secondary)
                        Text(s.album ?? "").foregroundStyle(.secondary)
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Genre", s.genre)
                    row("Jahr", s.year.map(String.init))
                    row("Titelnummer", s.track.map(String.init))
                    row("Disc-Nummer", s.discNumber.map(String.init))
                    row("Komponist:in", s.composers.isEmpty ? nil : s.composers.joined(separator: ", "))
                    row("Dauer", Fmt.time(s.duration))
                    row("Art", Fmt.kind(s))
                    row("Datenrate", s.bitRate.map { "\($0) kbit/s" })
                    row("Abtastrate", s.samplingRate.map { "\(Double($0) / 1000) kHz" })
                    row("Bittiefe", s.bitDepth.map { "\($0) Bit" })
                    row("Größe", s.size.map { Fmt.bytes(Int64($0)) })
                    row("Wiedergaben", s.playCount.map(String.init))
                    row("Hinzugefügt", Fmt.date(s.created))
                    row("Zuletzt gespielt", Fmt.date(s.played))
                    row("Bewertung", s.userRating.flatMap { $0 > 0 ? String(repeating: "★", count: $0) : nil })
                    row("Pfad", s.path)
                    if app.downloads.isDownloaded(s.id) { row("Geladen", app.downloads.localFile(s.id)?.path) }
                }
                .textSelection(.enabled)
            } else if !songs.isEmpty {
                let secs = songs.reduce(0) { $0 + ($1.duration ?? 0) }
                let bytes = Int64(songs.reduce(0) { $0 + ($1.size ?? 0) })
                Text("\(songs.count) Titel ausgewählt").font(.title3.bold())
                Text("\(Fmt.total(secs)), \(Fmt.bytes(bytes))").foregroundStyle(.secondary)
            } else {
                Text("Keine Titel ausgewählt").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder private func row(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).lineLimit(3).truncationMode(.middle)
            }
        }
    }
}
