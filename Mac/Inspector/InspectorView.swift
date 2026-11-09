import SwiftUI

/// Rechte Spalte: „Nächster Titel“/Verlauf oder Liedtext
struct InspectorView: View {
    @MacEnv private var mac
    var body: some View {
        Group {
            switch mac.inspector {
            case .lyrics: LyricsPanel()
            default: QueuePanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Nächster Titel / Verlauf

struct QueuePanel: View {
    @AppEnv private var app
    @MacEnv private var mac
    @State private var selection = Set<UUID>()
    @State private var showAllHistory = false

    var body: some View {
        @Bindable var mac = mac
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mac.queueTab) {
                    Text("queue.playingNext").tag(0)
                    Text("Verlauf").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("queue.tabs")
                Button("Löschen") {
                    if mac.queueTab == 0 { app.player.clearUpcoming() } else { app.player.clearHistory() }
                }
                .buttonStyle(.borderless)
                .help(mac.queueTab == 0 ? Text("Warteliste leeren") : Text("Verlauf löschen"))
                .accessibilityIdentifier("queue.clear")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if mac.queueTab == 0 { upNext } else { history }
        }
        .onDeleteCommand { removeSelected() }
    }

    private var upNext: some View {
        let p = app.player
        let q = p.queue
        return List(selection: $selection) {
            Toggle(isOn: Binding(get: { mac.autoplay }, set: { mac.autoplay = $0 })) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Automatisch wiedergeben")
                        Text(mac.autoplay ? "Automatische Wiedergabe ist aktiviert" : "Automatische Wiedergabe ist deaktiviert")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "infinity").foregroundStyle(mac.autoplay ? AnyShapeStyle(.accent) : AnyShapeStyle(.secondary)) }
            }
            .toggleStyle(.switch).controlSize(.mini)
            .selectionDisabled()
            .disabled(app.client == nil)
            .accessibilityIdentifier("queue.autoplay")

            if p.repeatMode != .off {
                Label(p.repeatMode == .one ? String(localized: "„\(p.currentSong?.title ?? "")“ wiederholen …")
                                           : String(localized: "„\(q.sourceName ?? String(localized: "Warteliste"))“ wiederholen …"),
                      systemImage: p.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.caption).foregroundStyle(.secondary)
                    .selectionDisabled()
            }

            if let cur = q.current {
                Section("Jetzt läuft") {
                    QueueRow(entry: cur, isCurrent: true).selectionDisabled()
                }
            }
            Section {
                ForEach(q.upNext) { e in
                    QueueRow(entry: e).tag(e.id)
                        .contextMenu { QueueRowMenu(entry: e) }
                        .onTapGesture(count: 2) { p.jump(to: e) }
                }
                .onMove { p.moveUpNext(from: $0, to: $1) }
                .dropDestination(for: ItemsTransfer.self) { items, i in insert(items, at: i) }
            } header: {
                if !q.upNext.isEmpty { Text("Als Nächstes") }
            }
            Section {
                ForEach(q.source) { e in
                    QueueRow(entry: e).tag(e.id)
                        .contextMenu { QueueRowMenu(entry: e) }
                        .onTapGesture(count: 2) { p.jump(to: e) }
                }
                .onMove { p.moveSource(from: $0, to: $1) }
            } header: {
                if !q.source.isEmpty {
                    Text(q.sourceName.map { String(localized: "Von \($0)") } ?? String(localized: "Wiedergabe fortsetzen"))
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if q.isEmpty {
                EmptyState(title: "Diese Warteliste enthält keine Musik.", systemImage: "list.bullet")
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: ItemsTransfer.self) { items, _ in
            insert(items, at: app.player.queue.upNext.count)
            return true
        }
        .accessibilityIdentifier("queue.list")
    }

    private var history: some View {
        let all = Array(app.player.queue.history.reversed())
        let shown = showAllHistory ? all : Array(all.prefix(50))
        return List(selection: $selection) {
            ForEach(shown) { e in
                QueueRow(entry: e).tag(e.id)
                    .contextMenu {
                        Button("Aus Verlauf entfernen") { app.player.removeFromHistory(e) }
                        Divider()
                        SongContextMenu(songs: [e.song])
                    }
                    .onTapGesture(count: 2) { mac.play([e.song]) }
            }
            if all.count > shown.count {
                Button("Weiteren Verlauf einblenden") { showAllHistory = true }.buttonStyle(.link).selectionDisabled()
            }
        }
        .listStyle(.plain)
        .overlay {
            if all.isEmpty { EmptyState(title: "Kein Verlauf", systemImage: "clock").allowsHitTesting(false) }
        }
    }

    private func insert(_ items: [ItemsTransfer], at index: Int) {
        Task {
            let songs = await items.resolve(app)
            app.player.insertUpNext(songs, at: index)
            app.notice.show(String(localized: "Zu „Nächster Titel“ hinzugefügt"), icon: "text.badge.plus")
        }
    }

    private func removeSelected() {
        let q = app.player.queue
        if mac.queueTab == 0 {
            for e in q.upNext + q.source where selection.contains(e.id) { app.player.remove(e) }
        } else {
            for e in q.history where selection.contains(e.id) { app.player.removeFromHistory(e) }
        }
        selection = []
    }
}

/// Zeile der Warteliste: Cover 34 pt, Titel, Künstler:in; beim Überfahren „⋯“
private struct QueueRow: View {
    @AppEnv private var app
    let entry: PlayQueue.Entry
    var isCurrent = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            CoverArt(id: entry.song.coverArt, size: 34, corner: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.song.title).lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.accent) : AnyShapeStyle(.primary))
                Text(entry.song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hover && !isCurrent {
                Menu { QueueRowMenu(entry: entry) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else if isCurrent && app.player.isPlaying {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.accent)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            } else {
                Text(Fmt.time(entry.song.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .contentShape(.rect)
        .onHover { hover = $0 }
        .draggable(ItemsTransfer.songs([entry.song]))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue.row.\(entry.song.title)")
    }
}

private struct QueueRowMenu: View {
    @AppEnv private var app
    @MacEnv private var mac
    let entry: PlayQueue.Entry
    var body: some View {
        Button("Aus „Nächster Titel“ entfernen") { app.player.remove(entry) }
        Button("Als Nächstes wiedergeben") {
            app.player.remove(entry)
            app.player.insertUpNext([entry.song], at: 0)
        }
        Divider()
        if let id = entry.song.albumId { Button("Zum Album") { mac.showAlbum(id) } }
        if let id = entry.song.artistId { Button("Zu Künstler:in") { mac.showArtist(id) } }
        Divider()
        Button(app.library.isStarred(song: entry.song.id) ? "„Favorit“ widerrufen" : "Favorit") { app.toggleFavorite(entry.song) }
    }
}

// MARK: Liedtext

/// Liedtext: zeitsynchron (aktuelle Zeile groß und hell, Klick springt) oder einfach scrollbar
struct LyricsPanel: View {
    @AppEnv private var app
    var large = false
    @State private var lyrics: StructuredLyrics?
    @State private var plain: String?
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        let song = app.player.currentSong
        Group {
            if song == nil {
                EmptyState(title: "Spiele einen Titel ab und finde hier den Liedtext.", systemImage: "quote.bubble")
            } else if let l = lyrics, l.synced == true, let lines = l.line, !lines.isEmpty {
                synced(lines, offset: Double(l.offset ?? 0) / 1000)
            } else if let text = plain ?? lyrics?.line?.map(\.value).joined(separator: "\n") {
                ScrollView {
                    Text(text).font(large ? .title2.weight(.semibold) : .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                }
            } else if failed {
                EmptyState(title: "Beim Laden des Liedtexts ist ein Problem aufgetreten.", systemImage: "exclamationmark.triangle")
            } else if loaded {
                EmptyState(title: "Kein Liedtext verfügbar", systemImage: "quote.bubble")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("lyrics")
        .task(id: song?.id) { await load(song) }
    }

    private func synced(_ lines: [StructuredLyrics.Line], offset: Double) -> some View {
        let t = app.player.position + offset
        let current = lines.lastIndex { Double($0.start ?? 0) / 1000 <= t } ?? -1
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: large ? 22 : 14) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.value.isEmpty ? "♪" : line.value)
                            .font(large ? .system(size: 30, weight: .bold) : .system(size: 17, weight: .bold))
                            .foregroundStyle(.primary.opacity(i == current ? 1 : 0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .id(i)
                            .onTapGesture { app.player.seek(to: Double(line.start ?? 0) / 1000 - offset) }
                            .animation(.easeInOut(duration: 0.35), value: current)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 40)
            }
            .onChange(of: current) { _, c in withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(max(0, c), anchor: .center) } }
        }
    }

    private func load(_ song: Song?) async {
        lyrics = nil; plain = nil; loaded = false; failed = false
        defer { loaded = true }
        guard let song, !song.isLocal, let client = app.client else { return }
        do {
            let list = try await client.lyrics(songId: song.id)
            if !list.isEmpty {
                lyrics = list.first { $0.synced == true } ?? list.first
                return
            }
        } catch is CancellationError {
            return
        } catch {
            // ältere Server ohne OpenSubsonic: weiter mit getLyrics
        }
        if let a = song.artist {
            do { plain = try await client.legacyLyrics(artist: a, title: song.title) } catch { if !Task.isCancelled { failed = false } }
        }
    }
}
