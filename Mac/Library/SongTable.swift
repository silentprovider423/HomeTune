import SwiftUI

/// Eine Zeile der Titeltabelle (eigene ID je Position, weil ein Titel in einer Playlist mehrfach vorkommen kann)
struct SongRow: Identifiable, Hashable {
    let id: String
    let index: Int
    let song: Song
    let fav: Int

    var title: String { song.title }
    var artist: String { song.artist ?? "" }
    var album: String { song.album ?? "" }
    var genre: String { song.genre ?? "" }
    var duration: Int { song.duration ?? 0 }
    var plays: Int { song.playCount ?? 0 }
    var year: Int { song.year ?? 0 }
    var track: Int { song.track ?? 0 }
    var disc: Int { song.discNumber ?? 0 }
    var composer: String { song.composers.joined(separator: ", ") }
    var added: String { song.created ?? "" }
    var played: String { song.played ?? "" }
    var rating: Int { song.userRating ?? 0 }
    var bitRate: Int { song.bitRate ?? 0 }
    var sampleRate: Int { song.samplingRate ?? 0 }
    var kind: String { Fmt.kind(song) }
    var size: Int { song.size ?? 0 }
    /// Sortierung der Quellen-Spalte: erst dieser Mac, dann Server
    var source: Int { song.isLocal ? 0 : 1 }
}

/// Art der Tabelle: bestimmt Standardsortierung und welche Spalten ab Werk sichtbar sind
enum SongTableStyle {
    /// Mediathek „Titel“, Lieblingstitel, Geladen, Genres …
    case library
    /// Playlist: zusätzlich „Reihenfolge der Playlist“ (= keine Sortierung) und Neu-Ordnen per Ziehen
    case playlist(Playlist)
}

/// Gespeicherte Sortierung einer Ansicht („name:asc“)
private enum SortStore {
    nonisolated(unsafe) static let keys: [String: PartialKeyPath<SongRow>] = [
        "name": \SongRow.title, "time": \SongRow.duration, "artist": \SongRow.artist, "album": \SongRow.album,
        "genre": \SongRow.genre, "fav": \SongRow.fav, "plays": \SongRow.plays, "year": \SongRow.year,
        "track": \SongRow.track, "disc": \SongRow.disc, "composer": \SongRow.composer, "added": \SongRow.added,
        "played": \SongRow.played, "rating": \SongRow.rating, "bitrate": \SongRow.bitRate, "samplerate": \SongRow.sampleRate,
        "kind": \SongRow.kind, "size": \SongRow.size,
    ]

    static func comparator(_ key: String, ascending: Bool) -> KeyPathComparator<SongRow>? {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case "name": return KeyPathComparator(\SongRow.title, comparator: .localizedStandard, order: order)
        case "artist": return KeyPathComparator(\SongRow.artist, comparator: .localizedStandard, order: order)
        case "album": return KeyPathComparator(\SongRow.album, comparator: .localizedStandard, order: order)
        case "genre": return KeyPathComparator(\SongRow.genre, comparator: .localizedStandard, order: order)
        case "composer": return KeyPathComparator(\SongRow.composer, comparator: .localizedStandard, order: order)
        case "kind": return KeyPathComparator(\SongRow.kind, comparator: .localizedStandard, order: order)
        case "added": return KeyPathComparator(\SongRow.added, order: order)
        case "played": return KeyPathComparator(\SongRow.played, order: order)
        case "time": return KeyPathComparator(\SongRow.duration, order: order)
        case "fav": return KeyPathComparator(\SongRow.fav, order: order)
        case "plays": return KeyPathComparator(\SongRow.plays, order: order)
        case "year": return KeyPathComparator(\SongRow.year, order: order)
        case "track": return KeyPathComparator(\SongRow.track, order: order)
        case "disc": return KeyPathComparator(\SongRow.disc, order: order)
        case "rating": return KeyPathComparator(\SongRow.rating, order: order)
        case "bitrate": return KeyPathComparator(\SongRow.bitRate, order: order)
        case "samplerate": return KeyPathComparator(\SongRow.sampleRate, order: order)
        case "size": return KeyPathComparator(\SongRow.size, order: order)
        default: return nil
        }
    }

    static func load(_ context: String, default def: String?) -> [KeyPathComparator<SongRow>] {
        let raw = UserDefaults.standard.string(forKey: "mac.sort.\(context)") ?? def ?? ""
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2, let c = comparator(parts[0], ascending: parts[1] == "asc") else { return [] }
        return [c]
    }

    static func save(_ order: [KeyPathComparator<SongRow>], context: String) {
        guard let first = order.first, let key = keys.first(where: { $0.value == first.keyPath })?.key else {
            UserDefaults.standard.set("none", forKey: "mac.sort.\(context)")
            return
        }
        UserDefaults.standard.set("\(key):\(first.order == .forward ? "asc" : "desc")", forKey: "mac.sort.\(context)")
    }
}

/// Titelliste wie bei Apple: Spalten ein-/ausblenden (Rechtsklick auf den Kopf), verschieben, Breite ändern,
/// Sortieren per Klick auf den Kopf (je Ansicht gemerkt), Mehrfachauswahl, Doppelklick/Return spielt ab.
struct SongTable: View {
    @AppEnv private var app
    @MacEnv private var mac
    let songs: [Song]
    /// Schlüssel für Spaltensatz und Sortierung (z. B. „songs“, „playlist“)
    let context: String
    var style: SongTableStyle = .library
    /// Name der Warteliste beim Abspielen
    var queueName: String?
    /// Standardsortierung, wenn noch nichts gespeichert ist („name:asc“ …, nil = Reihenfolge der Liste)
    var defaultSort: String? = nil

    @State private var selection = Set<SongRow.ID>()
    @State private var sortOrder: [KeyPathComparator<SongRow>] = []
    @State private var columns = TableColumnCustomization<SongRow>()
    @State private var loaded = false

    private var playlist: Playlist? { if case .playlist(let p) = style { p } else { nil } }
    private var sortContext: String { playlist.map { "playlist.\($0.id)" } ?? context }
    private var columnContext: String { playlist != nil ? "playlist" : context == "songs" ? "songs" : "list" }

    /// Gefiltert (Filterfeld, „Nur geladene Musik“) und sortiert
    private var rows: [SongRow] {
        let starred = app.library
        let stats = app.stats
        var out: [SongRow] = []
        out.reserveCapacity(songs.count)
        for (i, s) in songs.enumerated() where mac.matches(s.title, s.artist, s.album) {
            if mac.onlyDownloaded, !s.isLocal, !app.downloads.isDownloaded(s.id) { continue }
            // Musik auf diesem Mac kennt kein Server: Wiedergaben und „Zuletzt gespielt“ aus der eigenen Statistik
            var s = s
            if s.isLocal, stats.plays(of: s.id) > 0 {
                s.playCount = stats.plays(of: s.id)
                s.played = stats.lastPlayed(of: s.id)?.formatted(.iso8601)
            }
            out.append(SongRow(id: "\(i)|\(s.id)", index: i, song: s, fav: starred.isStarred(song: s.id) ? 1 : 0))
        }
        guard !sortOrder.isEmpty else { return out }
        // Zweitschlüssel bei Gleichstand: Künstler:in → Album → Disc → Titelnummer
        let tie = [KeyPathComparator(\SongRow.artist, comparator: .localizedStandard),
                   KeyPathComparator(\SongRow.album, comparator: .localizedStandard),
                   KeyPathComparator(\SongRow.disc), KeyPathComparator(\SongRow.track)]
        let order = sortOrder + tie
        return out.sorted { a, b in
            for c in order {
                let r = c.compare(a, b)
                if r != .orderedSame { return r == .orderedAscending }
            }
            return a.index < b.index
        }
    }

    /// Neu ordnen nur, wenn nach „Reihenfolge der Playlist“ sortiert (wie Apple)
    private var canReorder: Bool { playlist != nil && playlist?.readonly != true && sortOrder.isEmpty && mac.filter.isEmpty }

    var body: some View {
        let rows = self.rows
        lifecycle(interactions(table(rows), rows: rows), rows: rows)
            .accessibilityIdentifier("songTable")
    }

    private func table(_ rows: [SongRow]) -> some View {
        Table(of: SongRow.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            Group {
                mainColumns(rows)
                mainColumnsB
            }
            Group {
                extraColumns
                extraColumnsB
            }
        } rows: {
            ForEach(rows) { r in
                TableRow(r)
                    .draggable(dragItem(r, rows: rows))
            }
            .onInsert(of: [.hometuneItems]) { offset, providers in
                Task { @MainActor in
                    var items: [ItemsTransfer] = []
                    for p in providers {
                        if let t = await ItemsTransfer.load(from: p) { items.append(t) }
                    }
                    drop(items, at: offset, rows: rows)
                }
            }
        }
        .font(Font.system(size: mac.listSize.fontSize))
        .environment(\.defaultMinListRowHeight, mac.listSize.rowHeight)
    }

    private func interactions(_ content: some View, rows: [SongRow]) -> some View {
        content
            .contextMenu(forSelectionType: SongRow.ID.self) { (ids: Set<SongRow.ID>) in
                menu(ids, rows: rows)
            } primaryAction: { (ids: Set<SongRow.ID>) in
                // Doppelklick oder Return: ab der ersten gewählten Zeile die ganze sichtbare Liste abspielen
                guard let first = rows.first(where: { ids.contains($0.id) }) else { return }
                play(rows, from: first)
            }
            .onDeleteCommand { removeSelection(rows: rows) }
            .onCopyCommand { copyItems(rows) }
    }

    @ViewBuilder private func menu(_ ids: Set<SongRow.ID>, rows: [SongRow]) -> some View {
        let picked = songs(for: ids, rows: rows)
        if !picked.isEmpty {
            SongContextMenu(songs: picked, source: menuSource(ids: ids, rows: rows))
        }
    }

    private func copyItems(_ rows: [SongRow]) -> [NSItemProvider] {
        let picked = songs(for: selection, rows: rows)
        let text = picked.map { [$0.title, $0.artist].compactMap { $0 }.joined(separator: " – ") }.joined(separator: "\n")
        return [NSItemProvider(object: text as NSString)]
    }

    private func lifecycle(_ content: some View, rows: [SongRow]) -> some View {
        content
            .onChange(of: selection) { (_, ids: Set<SongRow.ID>) in
                mac.selectedSongs = songs(for: ids, rows: rows)
                if playlist != nil { mac.removeSelectionFromPlaylist = { removeSelection(rows: rows) } }
            }
            .onChange(of: sortOrder) { (_, o: [KeyPathComparator<SongRow>]) in if loaded { SortStore.save(o, context: sortContext) } }
            .onChange(of: columns) { (_, c: TableColumnCustomization<SongRow>) in saveColumns(c) }
            .onAppear { appear(rows) }
            .onChange(of: rows.count) { (_, _: Int) in mac.visibleSongs = self.rows.map(\.song) }
            .onDisappear {
                if mac.focusedPlaylist?.id == playlist?.id { mac.focusedPlaylist = nil }
                mac.selectedSongs = []
            }
    }

    private func saveColumns(_ c: TableColumnCustomization<SongRow>) {
        if loaded, let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: "mac.columns.\(columnContext)") }
    }

    private func appear(_ rows: [SongRow]) {
        if let d = UserDefaults.standard.data(forKey: "mac.columns.\(columnContext)"),
           let c = try? JSONDecoder().decode(TableColumnCustomization<SongRow>.self, from: d) {
            columns = c
        }
        sortOrder = SortStore.load(sortContext, default: defaultSort)
        loaded = true
        mac.visibleSongs = rows.map(\.song)
        mac.focusedPlaylist = playlist
    }

    // MARK: Spalten (aufgeteilt, damit der Compiler die Tabelle schnell prüfen kann)

    @TableColumnBuilder<SongRow, KeyPathComparator<SongRow>>
    private func mainColumns(_ rows: [SongRow]) -> some TableColumnContent<SongRow, KeyPathComparator<SongRow>> {
        TableColumn("") { r in StatusCell(row: r, play: { play(rows, from: r) }) }
            .width(min: 34, ideal: 34, max: 34)
            .customizationID("status")
            .disabledCustomizationBehavior([.reorder, .resize, .visibility])
        TableColumn("Name", value: \.title, comparator: .localizedStandard) { r in
            Text(verbatim: r.title).foregroundStyle(isCurrent(r) ? AnyShapeStyle(.accent) : AnyShapeStyle(.primary))
        }
        .width(min: 170, ideal: 200)
        .customizationID("name")
        .disabledCustomizationBehavior(.visibility)
        TableColumn(Text(Image(systemName: "cloud")), value: \.source) { r in DownloadCell(song: r.song) }
            .width(min: 26, ideal: 26, max: 26)
            .customizationID("cloud")
        TableColumn("Dauer", value: \.duration) { r in Text(verbatim: Fmt.time(r.song.duration)).monospacedDigit() }
            .width(min: 44, ideal: 59)
            .alignment(.trailing)
            .customizationID("time")
    }

    @TableColumnBuilder<SongRow, KeyPathComparator<SongRow>>
    private var mainColumnsB: some TableColumnContent<SongRow, KeyPathComparator<SongRow>> {
        TableColumn("Künstler:in", value: \.artist, comparator: .localizedStandard) { r in Text(verbatim: r.artist) }
            .width(min: 60, ideal: 125)
            .customizationID("artist")
        TableColumn("Album", value: \.album, comparator: .localizedStandard) { r in Text(verbatim: r.album) }
            .width(min: 80, ideal: 180)
            .customizationID("album")
        TableColumn("Genre", value: \.genre, comparator: .localizedStandard) { r in Text(verbatim: r.genre) }
            .width(min: 50, ideal: 80)
            .customizationID("genre")
        TableColumn(Text(Image(systemName: "star")), value: \.fav) { r in FavoriteCell(song: r.song, on: r.fav == 1) }
            .width(min: 24, ideal: 27, max: 40)
            .alignment(.center)
            .customizationID("fav")
            .defaultVisibility(mac.showFavoritesColumn ? .automatic : .hidden)
        TableColumn("Wiedergaben", value: \.plays) { r in Text(verbatim: r.plays > 0 ? "\(r.plays)" : "").monospacedDigit() }
            .width(min: 60, ideal: 100)
            .alignment(.trailing)
            .customizationID("plays")
    }

    @TableColumnBuilder<SongRow, KeyPathComparator<SongRow>>
    private var extraColumns: some TableColumnContent<SongRow, KeyPathComparator<SongRow>> {
            TableColumn("Jahr", value: \.year) { r in Text(verbatim: r.year > 0 ? String(r.year) : "").monospacedDigit() }
                .width(min: 40, ideal: 50).alignment(.trailing)
                .customizationID("year").defaultVisibility(.hidden)
            TableColumn("Titelnummer", value: \.track) { r in Text(verbatim: r.track > 0 ? "\(r.track)" : "").monospacedDigit() }
                .width(min: 40, ideal: 70).alignment(.trailing)
                .customizationID("track").defaultVisibility(.hidden)
            TableColumn("Disc-Nummer", value: \.disc) { r in Text(verbatim: r.disc > 0 ? "\(r.disc)" : "").monospacedDigit() }
                .width(min: 40, ideal: 60).alignment(.trailing)
                .customizationID("disc").defaultVisibility(.hidden)
            TableColumn("Komponist:in", value: \.composer, comparator: .localizedStandard) { r in Text(verbatim: r.composer) }
                .width(min: 60, ideal: 125)
                .customizationID("composer").defaultVisibility(.hidden)
            TableColumn("Hinzugefügt", value: \.added) { r in Text(verbatim: Fmt.date(r.song.created)) }
                .width(min: 80, ideal: 125)
                .customizationID("added").defaultVisibility(.hidden)
            TableColumn("Zuletzt gespielt", value: \.played) { r in Text(verbatim: Fmt.date(r.song.played)) }
                .width(min: 80, ideal: 125)
                .customizationID("played").defaultVisibility(.hidden)
    }

    @TableColumnBuilder<SongRow, KeyPathComparator<SongRow>>
    private var extraColumnsB: some TableColumnContent<SongRow, KeyPathComparator<SongRow>> {
            TableColumn("Bewertung", value: \.rating) { r in
                Text(verbatim: r.rating > 0 ? String(repeating: "★", count: r.rating) : "").foregroundStyle(.secondary)
            }
            .width(min: 79, ideal: 79)
            .customizationID("rating").defaultVisibility(.hidden)
            TableColumn("Datenrate", value: \.bitRate) { r in Text(verbatim: r.bitRate > 0 ? "\(r.bitRate) kbit/s" : "").monospacedDigit() }
                .width(min: 60, ideal: 80).alignment(.trailing)
                .customizationID("bitrate").defaultVisibility(.hidden)
            TableColumn("Abtastrate", value: \.sampleRate) { r in
                Text(verbatim: r.sampleRate > 0 ? "\((Double(r.sampleRate) / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz" : "")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 91).alignment(.trailing)
            .customizationID("samplerate").defaultVisibility(.hidden)
            TableColumn("Art", value: \.kind, comparator: .localizedStandard) { r in Text(verbatim: r.kind) }
                .width(min: 60, ideal: 100)
                .customizationID("kind").defaultVisibility(.hidden)
        TableColumn("Größe", value: \.size) { r in Text(verbatim: r.size > 0 ? Fmt.bytes(Int64(r.size)) : "").monospacedDigit() }
            .width(min: 50, ideal: 60).alignment(.trailing)
            .customizationID("size").defaultVisibility(.hidden)
    }

    private func isCurrent(_ r: SongRow) -> Bool { app.player.currentSong?.id == r.song.id }

    private func songs(for ids: Set<SongRow.ID>, rows: [SongRow]) -> [Song] {
        rows.filter { ids.contains($0.id) }.map(\.song)
    }

    private func play(_ rows: [SongRow], from row: SongRow) {
        let list = rows.map(\.song)
        let i = rows.firstIndex(of: row) ?? 0
        mac.play(list, startAt: i, name: queueName, shuffle: app.player.shuffle)
    }

    private func menuSource(ids: Set<SongRow.ID>, rows: [SongRow]) -> SongMenuSource {
        guard let p = playlist else { return .library }
        let idx = rows.filter { ids.contains($0.id) }.map(\.index)
        return .playlist(p, remove: { remove(indexes: idx) })
    }

    private func dragItem(_ r: SongRow, rows: [SongRow]) -> ItemsTransfer {
        // Ist die gezogene Zeile ausgewählt, kommen alle gewählten Titel mit
        let picked = selection.contains(r.id) ? rows.filter { selection.contains($0.id) } : [r]
        return .songs(picked.map(\.song), fromPlaylist: playlist?.id, indexes: picked.map(\.index))
    }

    // MARK: Playlist bearbeiten

    private func removeSelection(rows: [SongRow]) {
        guard playlist != nil else { return }
        let idx = rows.filter { selection.contains($0.id) }.map(\.index)
        selection = []
        remove(indexes: idx)
    }

    private func remove(indexes: [Int]) {
        guard let p = playlist, p.readonly != true, !indexes.isEmpty else { return }
        Task {
            do {
                try await app.library.remove(indexes: indexes.sorted(), from: p)
                NotificationCenter.default.post(name: .playlistChanged, object: p.id)
            } catch {
                app.notice.show(error.localizedDescription, icon: "exclamationmark.triangle")
            }
        }
    }

    /// Ablegen in der Tabelle: in derselben Playlist neu ordnen, sonst an der Stelle einfügen
    private func drop(_ items: [ItemsTransfer], at offset: Int, rows: [SongRow]) {
        guard let p = playlist, p.readonly != true else { return }
        let order = songs.map(\.id)
        let moving = items.filter { $0.fromPlaylist == p.id }.flatMap(\.indexes)
        if !moving.isEmpty {
            guard canReorder else { return }
            var ids = order
            let set = IndexSet(moving.filter { $0 < ids.count })
            ids.move(fromOffsets: set, toOffset: min(offset, ids.count))
            save(p, ids)
        } else {
            Task {
                let new = await items.resolve(app).map(\.id)
                guard !new.isEmpty else { return }
                // Ohne „Reihenfolge der Playlist“ kommen neue Titel ans Ende
                let at = canReorder ? min(offset, order.count) : order.count
                var ids = order
                ids.insert(contentsOf: new, at: at)
                save(p, ids)
            }
        }
    }

    private func save(_ p: Playlist, _ ids: [String]) {
        Task {
            do {
                try await app.library.save(playlist: p, name: p.name, comment: p.comment ?? "", songs: ids)
                NotificationCenter.default.post(name: .playlistChanged, object: p.id)
            } catch {
                app.notice.show(error.localizedDescription, icon: "exclamationmark.triangle")
            }
        }
    }
}

/// Wiedergabestatus: Lautsprecher am laufenden Titel, beim Überfahren ein kleiner ▶-Knopf
private struct StatusCell: View {
    @AppEnv private var app
    let row: SongRow
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        let current = app.player.currentSong?.id == row.song.id
        ZStack {
            if hover && !(current && app.player.isPlaying) {
                Button(action: play) { Image(systemName: "play.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Wiedergabe"))
            } else if current {
                Image(systemName: app.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.accent)
                    .symbolEffect(.variableColor.iterative, isActive: app.player.isPlaying)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onHover { hover = $0 }
    }
}

/// Woher der Titel kommt: dieser Mac / Server (wird gestreamt) / vom Server geladen (lädt, wartet, Fehler)
struct DownloadCell: View {
    @AppEnv private var app
    let song: Song
    var body: some View {
        Group {
            if song.isLocal {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    .help(Text("Auf diesem Mac"))
            } else {
                switch app.downloads.state(song.id) {
                case .done:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.accent)
                        .help(Text("Vom Server geladen – auch ohne Verbindung abspielbar"))
                case .downloading(let p): ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
                case .waiting: Image(systemName: "clock").foregroundStyle(.tertiary).help(Text("Wartet auf den Download"))
                case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red).help(Text("Download fehlgeschlagen"))
                case .none:
                    Image(systemName: "cloud").foregroundStyle(.tertiary)
                        .help(Text("Auf dem Server – wird gestreamt"))
                }
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity)
    }
}

/// Kleines Zeichen an Alben, Künstler:innen und Playlists, sobald es Server und Musik auf diesem Mac zugleich gibt
struct SourceBadge: View {
    @MacEnv private var mac
    let id: String
    var body: some View {
        if mac.hasBothSources {
            let local = id.isLocalID || id.isLocalPlaylistID
            Image(systemName: local ? "desktopcomputer" : "cloud")
                .font(.system(size: 10))
                .foregroundStyle(local ? .secondary : .tertiary)
                .help(local ? Text("Auf diesem Mac") : Text("Auf dem Server"))
                .accessibilityLabel(local ? Text("Auf diesem Mac") : Text("Auf dem Server"))
        }
    }
}

/// ★ in der Tabelle: Klick schaltet direkt, beim Überfahren leer angedeutet
struct FavoriteCell: View {
    @AppEnv private var app
    let song: Song
    let on: Bool
    @State private var hover = false
    var body: some View {
        Button { app.toggleFavorite(song) } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 10))
                .foregroundStyle(on ? AnyShapeStyle(.accent) : AnyShapeStyle(.tertiary))
                .opacity(on || hover ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(on ? Text("„Favorit“ widerrufen") : Text("Favorit"))
    }
}

/// Seite mit Titel, Wiedergabe-Knöpfen und Titeltabelle (Titel, Geladen, Genre, Komponist:in …)
struct ListPage: View {
    @AppEnv private var app
    @MacEnv private var mac
    let title: Text
    let context: String
    let songs: [Song]
    var name: String?
    var emptyTitle: LocalizedStringKey = "Keine Titel"
    var emptyMessage: LocalizedStringKey?
    var defaultSort: String? = "name:asc"
    var showHeader = true

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                PageHeader(title: title) {
                    if !songs.isEmpty {
                        PlayShuffleButtons(play: { mac.play(mac.available(songs), name: name) },
                                           shuffle: { mac.play(mac.available(songs), name: name, shuffle: true) })
                            .controlSize(.regular)
                    }
                }
            }
            if songs.isEmpty {
                if app.library.isLoading && !app.library.loadedOnce {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(title: emptyTitle, message: emptyMessage)
                }
            } else {
                SongTable(songs: songs, context: context, queueName: name, defaultSort: defaultSort)
            }
        }
    }
}

/// Lieblingstitel
struct FavoritesPage: View {
    @AppEnv private var app
    var body: some View {
        ListPage(title: Text("Lieblingstitel"), context: "favorites", songs: app.library.favoriteSongs,
                 name: String(localized: "Lieblingstitel"), emptyTitle: "Keine Lieblingstitel",
                 emptyMessage: "Favorisierte Titel werden hier angezeigt.")
    }
}
