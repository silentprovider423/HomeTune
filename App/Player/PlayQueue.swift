import Foundation

/// Warteliste nach Apples Modell (`InternalMusicPlayer.Queue`: history · current · upNext · Rest der Quelle).
/// - `upNext` = von Hand eingereiht („Als Nächstes“ vorne, „Zuletzt wiedergeben“ hinten)
/// - `source` = „Wiedergabe fortsetzen von …“ (Rest des Albums/der Playlist, ggf. gemischt)
/// Reine Logik ohne Wiedergabe – dadurch per Unit-Test prüfbar.
struct PlayQueue: Codable, Sendable {
    enum Origin: String, Codable, Sendable { case user, source }
    enum RepeatMode: String, Codable, Sendable, CaseIterable { case off, all, one }

    struct Entry: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var song: Song
        var origin: Origin
    }

    private(set) var history: [Entry] = []
    private(set) var current: Entry?
    var upNext: [Entry] = []
    var source: [Entry] = []
    private(set) var sourceName: String?
    /// Komplette Quelle in Originalreihenfolge (für Wiederholen und Zufall aus)
    private(set) var sourceAll: [Song] = []
    private(set) var shuffle = false
    var repeatMode: RepeatMode = .off
    private static let historyLimit = 200

    var isEmpty: Bool { current == nil && upNext.isEmpty && source.isEmpty }

    /// Neue Quelle abspielen (Album, Playlist, Titelliste). „Als Nächstes“ bleibt erhalten (Apple: keepUpNext),
    /// außer `clearUpNext` ist gesetzt.
    mutating func play(_ songs: [Song], startAt index: Int? = nil, name: String? = nil, shuffle: Bool = false, clearUpNext: Bool = false) {
        guard !songs.isEmpty else { return }
        if let current { pushHistory(current) }
        if clearUpNext { upNext.removeAll() }
        sourceAll = songs
        sourceName = name
        self.shuffle = shuffle
        if shuffle {
            var rest = songs
            let i = index.map { min(max(0, $0), songs.count - 1) } ?? Int.random(in: 0..<songs.count)
            let first = rest.remove(at: i)
            current = Entry(song: first, origin: .source)
            source = rest.shuffled().map { Entry(song: $0, origin: .source) }
        } else {
            let i = min(max(0, index ?? 0), songs.count - 1)
            current = Entry(song: songs[i], origin: .source)
            source = songs[(i + 1)...].map { Entry(song: $0, origin: .source) }
        }
    }

    /// „Als Nächstes wiedergeben“: direkt nach dem aktuellen Titel (vor bisher Eingereihtem).
    mutating func playNext(_ songs: [Song]) {
        let entries = songs.map { Entry(song: $0, origin: .user) }
        if current == nil, let first = entries.first {
            current = first
            upNext.insert(contentsOf: entries.dropFirst(), at: 0)
        } else {
            upNext.insert(contentsOf: entries, at: 0)
        }
    }

    /// „Zuletzt wiedergeben“: ans Ende von „Als Nächstes“ (vor dem Rest der Quelle).
    mutating func playLast(_ songs: [Song]) {
        let entries = songs.map { Entry(song: $0, origin: .user) }
        if current == nil, let first = entries.first {
            current = first
            upNext.append(contentsOf: entries.dropFirst())
        } else {
            upNext.append(contentsOf: entries)
        }
    }

    /// Was nach dem aktuellen Titel käme (ohne etwas zu ändern) – für das Vorladen.
    func peekNext(auto: Bool = true) -> Entry? {
        if auto && repeatMode == .one { return current }
        if let e = upNext.first { return e }
        if let e = source.first { return e }
        if repeatMode == .all, let first = sourceAll.first {
            return Entry(id: Self.wrapID, song: first, origin: .source)
        }
        return nil
    }
    /// Feste Marke für den Neubeginn bei „Alle wiederholen“
    static let wrapID = UUID(uuidString: "00000000-0000-0000-0000-000000000432")!

    /// Weiter zum nächsten Titel. `auto` = Titel lief zu Ende (bei „Eins wiederholen“ bleibt er).
    @discardableResult
    mutating func advance(auto: Bool = true) -> Entry? {
        if auto && repeatMode == .one, current != nil { return current }
        if let current { pushHistory(current) }
        if !upNext.isEmpty {
            current = upNext.removeFirst()
        } else if !source.isEmpty {
            current = source.removeFirst()
        } else if repeatMode == .all, !sourceAll.isEmpty {
            // Erster Titel wie in peekNext (Vorladen), der Rest ggf. neu gemischt
            let songs = shuffle ? [sourceAll[0]] + sourceAll.dropFirst().shuffled() : sourceAll
            current = Entry(song: songs[0], origin: .source)
            source = songs.dropFirst().map { Entry(song: $0, origin: .source) }
        } else {
            current = nil
        }
        return current
    }

    /// Zurück zum vorherigen Titel aus dem Verlauf. Der aktuelle Titel kommt wieder vorne in seine Liste.
    @discardableResult
    mutating func goBack() -> Entry? {
        guard let prev = history.popLast() else { return current }
        if let current {
            if current.origin == .user { upNext.insert(current, at: 0) } else { source.insert(current, at: 0) }
        }
        current = prev
        return current
    }

    /// Springt direkt zu einem Eintrag aus „Als Nächstes“ oder der Quelle (Antippen in der Warteliste).
    mutating func jump(to id: UUID) {
        if let i = upNext.firstIndex(where: { $0.id == id }) {
            if let current { pushHistory(current) }
            for e in upNext[..<i] { pushHistory(e) }
            current = upNext[i]
            upNext.removeFirst(i + 1)
        } else if let i = source.firstIndex(where: { $0.id == id }) {
            if let current { pushHistory(current) }
            for e in upNext { pushHistory(e) }
            upNext.removeAll()
            for e in source[..<i] { pushHistory(e) }
            current = source[i]
            source.removeFirst(i + 1)
        } else if let i = history.firstIndex(where: { $0.id == id }) {
            let e = history.remove(at: i)
            if let current { pushHistory(current) }
            current = Entry(song: e.song, origin: .source)
        }
    }

    mutating func setShuffle(_ on: Bool) {
        guard on != shuffle else { return }
        shuffle = on
        if on {
            source.shuffle()
        } else if let cur = current {
            // Reihenfolge der Quelle nach dem aktuellen Titel wiederherstellen
            let remaining = Set(source.map(\.song.id))
            if let i = sourceAll.firstIndex(where: { $0.id == cur.song.id }) {
                let after = sourceAll[(i + 1)...].filter { remaining.contains($0.id) }
                let before = sourceAll[..<i].filter { remaining.contains($0.id) }
                source = (Array(after) + Array(before)).map { Entry(song: $0, origin: .source) }
            } else {
                source = sourceAll.filter { remaining.contains($0.id) }.map { Entry(song: $0, origin: .source) }
            }
        }
    }

    mutating func cycleRepeat() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
    }

    /// „Warteliste leeren“: alles nach dem aktuellen Titel entfernen.
    mutating func clearUpcoming() {
        upNext.removeAll()
        source.removeAll()
        sourceAll = current.map { [$0.song] } ?? []
        sourceName = nil
    }

    mutating func clearHistory() { history.removeAll() }

    mutating func remove(id: UUID) {
        upNext.removeAll { $0.id == id }
        source.removeAll { $0.id == id }
    }

    mutating func moveUpNext(from: IndexSet, to: Int) { upNext.move(fromOffsets: from, toOffset: to) }
    mutating func moveSource(from: IndexSet, to: Int) { source.move(fromOffsets: from, toOffset: to) }

    mutating func reset() { self = PlayQueue(repeatMode: repeatMode) }

    private init(repeatMode: RepeatMode) { self.repeatMode = repeatMode }
    init() {}

    private mutating func pushHistory(_ e: Entry) {
        history.append(Entry(song: e.song, origin: e.origin))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// Aktualisiert Titel-Metadaten (z. B. Favorit) überall in der Warteliste.
    mutating func updateSong(_ song: Song) {
        func upd(_ e: inout Entry) { if e.song.id == song.id { e.song = song } }
        if current?.song.id == song.id { current?.song = song }
        for i in upNext.indices { upd(&upNext[i]) }
        for i in source.indices { upd(&source[i]) }
    }
}
