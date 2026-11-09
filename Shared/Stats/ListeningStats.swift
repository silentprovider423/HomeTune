import SwiftUI

/// Zeitraum der Auswertung
enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, year, all
    var id: String { rawValue }

    /// Tage einschließlich heute; nil = alles
    var days: Int? {
        switch self { case .week: 7; case .month: 30; case .year: 365; case .all: nil }
    }

    var title: LocalizedStringKey {
        switch self { case .week: "7 Tage"; case .month: "30 Tage"; case .year: "12 Monate"; case .all: "Gesamt" }
    }
}

/// Hör-Statistik. Bleibt auf diesem Gerät (eine Datei im App-Speicher) – kein Konto, kein Server.
/// Eine Wiedergabe zählt nach der üblichen Regel (ab der Hälfte bzw. nach 4 Minuten, siehe `PlayerController`),
/// die Hörzeit läuft mit der Wiedergabe mit.
@MainActor @Observable
final class ListeningStats {
    struct SongEntry: Codable, Sendable, Equatable {
        var title: String
        var artist: String?
        var album: String?
        var albumId: String?
        var coverArt: String?
        var plays = 0
        var seconds: Double = 0
        var last: Date?
    }

    struct PlayEvent: Codable, Sendable, Equatable {
        var t: Date
        var id: String
    }

    private struct Stored: Codable {
        var songs: [String: SongEntry] = [:]
        /// Gezählte Wiedergaben mit Zeitpunkt (für 7 Tage/30 Tage/12 Monate), älteste zuerst
        var events: [PlayEvent] = []
        /// Gehörte Sekunden je Tag („2026-11-10“, Ortszeit)
        var days: [String: Double] = [:]
        /// Gehörte Sekunden je Uhrzeit (0–23)
        var hours: [Double] = Array(repeating: 0, count: 24)
        var since: Date?
    }

    /// Eintrag einer Bestenliste
    struct Ranked: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let subtitle: String?
        let plays: Int
        /// Titel-Liste: der zuletzt gespielte Titel mit diesem Namen
        var songID: String?
        var albumId: String?
        var coverArt: String?
    }

    struct Summary: Sendable, Equatable {
        var seconds: Double = 0
        var plays = 0
        var songs = 0
        var days = 0
    }

    /// Ab so vielen Sekunden zählt ein Tag für die Hör-Serie
    static let dayThreshold: Double = 60
    static let maxEvents = 50_000

    /// Ändert sich bei jeder gezählten Wiedergabe und etwa alle 30 s Hörzeit – Ansichten hängen nur daran,
    /// nicht an jedem Takt der Wiedergabe
    private(set) var revision = 0

    @ObservationIgnored private var data = Stored()
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var pending: Double = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(file: URL = AppPaths.applicationSupport.appending(path: "stats.json"),
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.calendar = calendar
        self.now = now
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            data = s
            if data.hours.count != 24 { data.hours = Array(repeating: 0, count: 24) }
        }
    }

    // MARK: Zählen

    /// Hörzeit mitlaufen lassen (aus dem Takt der Wiedergabe). Sprünge über 5 s werden verworfen.
    func addListening(_ seconds: Double, song: Song) {
        guard seconds > 0, seconds <= 5 else { return }
        let t = now()
        data.days[dayKey(t), default: 0] += seconds
        data.hours[calendar.component(.hour, from: t)] += seconds
        update(song) { $0.seconds += seconds }
        if data.since == nil { data.since = t }
        pending += seconds
        if pending >= 30 { pending = 0; revision += 1 }
        scheduleSave()
    }

    /// Eine Wiedergabe zählen.
    func notePlay(_ song: Song) {
        let t = now()
        update(song) { $0.plays += 1; $0.last = t }
        data.events.append(PlayEvent(t: t, id: song.id))
        if data.events.count > Self.maxEvents { data.events.removeFirst(data.events.count - Self.maxEvents) }
        if data.since == nil { data.since = t }
        revision += 1
        scheduleSave()
    }

    private func update(_ song: Song, _ change: (inout SongEntry) -> Void) {
        var e = data.songs[song.id] ?? SongEntry(title: song.title)
        e.title = song.title
        e.artist = song.artist
        e.album = song.album
        e.albumId = song.albumId
        e.coverArt = song.coverArt
        change(&e)
        data.songs[song.id] = e
    }

    func reset() {
        data = Stored()
        pending = 0
        revision += 1
        flush(force: true)
    }

    // MARK: Abfragen

    var isEmpty: Bool { _ = revision; return data.songs.isEmpty }
    var since: Date? { _ = revision; return data.since }

    func plays(of songID: String) -> Int { _ = revision; return data.songs[songID]?.plays ?? 0 }
    func lastPlayed(of songID: String) -> Date? { _ = revision; return data.songs[songID]?.last }

    func summary(_ period: StatsPeriod) -> Summary {
        _ = revision
        guard let days = period.days else {
            let played = data.songs.values.filter { $0.plays > 0 }
            return Summary(seconds: data.days.values.reduce(0, +), plays: played.reduce(0) { $0 + $1.plays }, songs: played.count,
                           days: data.days.values.count { $0 >= Self.dayThreshold })
        }
        let from = start(daysBack: days - 1)
        let key = dayKey(from)
        let inRange = data.days.filter { $0.key >= key }
        let events = data.events.filter { $0.t >= from }
        return Summary(seconds: inRange.values.reduce(0, +), plays: events.count, songs: Set(events.map(\.id)).count,
                       days: inRange.values.count { $0 >= Self.dayThreshold })
    }

    /// Wiedergaben je Titel-ID im Zeitraum
    private func counts(_ period: StatsPeriod) -> [String: Int] {
        guard let days = period.days else { return data.songs.compactMapValues { $0.plays > 0 ? $0.plays : nil } }
        let from = start(daysBack: days - 1)
        var out: [String: Int] = [:]
        for e in data.events where e.t >= from { out[e.id, default: 0] += 1 }
        return out
    }

    /// Meistgespielte Titel. Gleicher Titel von Server und Gerät (verschiedene IDs) zählt zusammen.
    func topSongs(_ period: StatsPeriod, limit: Int = 10) -> [Ranked] {
        ranked(period, limit: limit) { e in
            (Self.fold(e.title) + "\u{1}" + Self.fold(e.artist ?? ""), e.title, e.artist)
        }
    }

    func topArtists(_ period: StatsPeriod, limit: Int = 10) -> [Ranked] {
        ranked(period, limit: limit) { e in
            guard let a = e.artist, !a.isEmpty else { return nil }
            return (Self.fold(a), a, nil)
        }
    }

    func topAlbums(_ period: StatsPeriod, limit: Int = 10) -> [Ranked] {
        ranked(period, limit: limit) { e in
            guard let a = e.album, !a.isEmpty else { return nil }
            return (Self.fold(a), a, nil)
        }
    }

    private func ranked(_ period: StatsPeriod, limit: Int,
                        key: (SongEntry) -> (key: String, title: String, subtitle: String?)?) -> [Ranked] {
        _ = revision
        struct Acc { var title: String; var subtitle: String?; var plays = 0; var best: (id: String, entry: SongEntry)? }
        var groups: [String: Acc] = [:]
        for (id, n) in counts(period) {
            guard let e = data.songs[id], let k = key(e) else { continue }
            var g = groups[k.key] ?? Acc(title: k.title, subtitle: k.subtitle)
            g.plays += n
            if g.best == nil || (e.last ?? .distantPast) > (g.best?.entry.last ?? .distantPast) { g.best = (id, e) }
            groups[k.key] = g
        }
        return groups.map { k, g in
            Ranked(id: k, title: g.title, subtitle: g.subtitle, plays: g.plays, songID: g.best?.id,
                   albumId: g.best?.entry.albumId, coverArt: g.best?.entry.coverArt)
        }
        .sorted { ($1.plays, $0.title) < ($0.plays, $1.title) }
        .prefix(limit).map { $0 }
    }

    /// Alben-IDs, zuletzt gehörte zuerst (Regal „Zuletzt gespielt“ ohne Server)
    func recentAlbumIDs(limit: Int = 20) -> [String] {
        albumIDs(limit: limit) { $0.last ?? .distantPast > $1.last ?? .distantPast }
    }

    /// Alben-IDs, meistgehörte zuerst (Regal „Häufig gespielt“ ohne Server)
    func frequentAlbumIDs(limit: Int = 20) -> [String] {
        albumIDs(limit: limit) { $0.plays > $1.plays }
    }

    private func albumIDs(limit: Int, by order: (SongEntry, SongEntry) -> Bool) -> [String] {
        _ = revision
        var albums: [String: SongEntry] = [:]
        for e in data.songs.values where e.plays > 0 {
            guard let id = e.albumId else { continue }
            var a = albums[id] ?? SongEntry(title: "")
            a.plays += e.plays
            a.last = max(a.last ?? .distantPast, e.last ?? .distantPast)
            albums[id] = a
        }
        return albums.sorted { order($0.value, $1.value) }.prefix(limit).map(\.key)
    }

    /// Gehörte Sekunden je Tag, ältester zuerst, heute zuletzt
    func daily(last days: Int) -> [(day: Date, seconds: Double)] {
        _ = revision
        return (0..<days).reversed().map { back in
            let d = start(daysBack: back)
            return (d, data.days[dayKey(d)] ?? 0)
        }
    }

    /// Gehörte Sekunden je Uhrzeit (0–23), über die ganze Zeit
    var hours: [Double] { _ = revision; return data.hours }

    /// Tage in Folge mit Musik (heute oder gestern als Ende) und die längste Serie überhaupt
    var streak: (current: Int, best: Int) {
        _ = revision
        let active = Set(data.days.filter { $0.value >= Self.dayThreshold }.keys)
        guard !active.isEmpty else { return (0, 0) }
        var current = 0
        var back = active.contains(dayKey(start(daysBack: 0))) ? 0 : 1
        while active.contains(dayKey(start(daysBack: back))) { current += 1; back += 1 }
        var best = 0, run = 0
        var previous: Date?
        for d in active.compactMap(date(fromKey:)).sorted() {
            if let p = previous, calendar.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
            best = max(best, run)
            previous = d
        }
        return (current, max(best, current))
    }

    // MARK: Tage

    private func start(daysBack: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now())) ?? now()
    }

    private func dayKey(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func date(fromKey key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Speichern

    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.saveTask = nil
            self?.flush()
        }
    }

    /// Sofort sichern (Pause, Hintergrund, Beenden).
    func flush(force: Bool = false) {
        guard dirty || force else { return }
        dirty = false
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
    }
}

#if DEBUG
extension ListeningStats {
    /// Nur Debug: erfundene Statistik aus vorhandenen Titeln (Sichtprüfung, Bildschirmfotos) – ersetzt die echte.
    func seedDemo(songs: [Song]) {
        let pool = Array(songs.prefix(120))
        guard !pool.isEmpty else { return }
        var rng: UInt64 = 42
        func next() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int(rng >> 33)
        }
        data = Stored()
        let end = now(), today = calendar.startOfDay(for: end)
        let hours = [7, 8, 8, 9, 12, 13, 17, 18, 19, 19, 20, 20, 21, 21, 22, 23]
        for back in (0..<75).reversed() where back % 13 != 9 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            for _ in 0..<(3 + next() % 18) {
                // zwei Würfe, der kleinere gewinnt: die ersten Titel werden deutlich öfter gehört
                let song = pool[min(next() % pool.count, next() % pool.count)]
                let hour = hours[next() % hours.count]
                let t = day.addingTimeInterval(Double(hour * 3600 + next() % 3000))
                guard t <= end else { continue }
                let seconds = Double(120 + next() % 140)
                data.days[dayKey(t), default: 0] += seconds
                data.hours[hour] += seconds
                update(song) { $0.seconds += seconds; $0.plays += 1; $0.last = max($0.last ?? t, t) }
                data.events.append(PlayEvent(t: t, id: song.id))
            }
        }
        data.events.sort { $0.t < $1.t }
        data.since = data.events.first?.t
        revision += 1
    }
}
#endif
