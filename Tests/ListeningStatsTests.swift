import XCTest
#if os(iOS)
@testable import HomeTune
#endif

/// Hör-Statistik (nur auf dem Gerät): Zählen, Zeiträume, Bestenlisten, Hör-Serie, Speichern – und der Schlaf-Timer.
@MainActor
final class ListeningStatsTests: XCTestCase {
    private let fm = FileManager.default
    private var work: URL!
    private var clock = Date(timeIntervalSince1970: 0)
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() async throws {
        work = fm.temporaryDirectory.appending(path: "stats-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        set(2026, 11, 10, 12)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: work)
    }

    private func set(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) {
        clock = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func makeStats() -> ListeningStats {
        ListeningStats(file: work.appending(path: "stats.json"), calendar: calendar, now: { [unowned self] in self.clock })
    }

    private func song(_ id: String, _ title: String, artist: String? = "Band", album: String? = "Platte") -> Song {
        Song(id: id, title: title, album: album, artist: artist, albumId: album.map { "al-" + $0 })
    }

    /// 100 s in Takten von 0,25 s (wie die Wiedergabe)
    private func listen(_ s: ListeningStats, _ song: Song, seconds: Int) {
        for _ in 0..<(seconds * 4) { s.addListening(0.25, song: song) }
    }

    func testCountsPlaysAndSeconds() {
        let s = makeStats()
        XCTAssertTrue(s.isEmpty)
        let a = song("1", "Lied A"), b = song("2", "Lied B")
        listen(s, a, seconds: 100)
        s.notePlay(a); s.notePlay(a); s.notePlay(b)
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.plays(of: "1"), 2)
        XCTAssertEqual(s.plays(of: "unbekannt"), 0)
        XCTAssertEqual(s.lastPlayed(of: "2"), clock)
        let all = s.summary(.all)
        XCTAssertEqual(all.plays, 3)
        XCTAssertEqual(all.songs, 2)
        XCTAssertEqual(all.seconds, 100, accuracy: 0.001)
        XCTAssertEqual(all.days, 1)
        XCTAssertEqual(s.hours[12], 100, accuracy: 0.001)
        XCTAssertEqual(s.hours.reduce(0, +), 100, accuracy: 0.001)
    }

    func testIgnoresJumps() {
        let s = makeStats()
        let a = song("1", "Lied A")
        s.addListening(600, song: a)   // Rechner war im Ruhezustand
        s.addListening(-1, song: a)
        s.addListening(0, song: a)
        XCTAssertEqual(s.summary(.all).seconds, 0)
    }

    func testPeriods() {
        let s = makeStats()
        let a = song("1", "Alt"), b = song("2", "Neu")
        set(2026, 9, 1); listen(s, a, seconds: 120); s.notePlay(a); s.notePlay(a); s.notePlay(a)
        set(2026, 11, 5); listen(s, b, seconds: 90); s.notePlay(b)
        set(2026, 11, 10); listen(s, b, seconds: 60); s.notePlay(b)
        XCTAssertEqual(s.summary(.week), .init(seconds: 150, plays: 2, songs: 1, days: 2))
        XCTAssertEqual(s.summary(.month).plays, 2)
        XCTAssertEqual(s.summary(.year).plays, 5)
        XCTAssertEqual(s.summary(.all), .init(seconds: 270, plays: 5, songs: 2, days: 3))
        XCTAssertEqual(s.topSongs(.week).map(\.title), ["Neu"])
        XCTAssertEqual(s.topSongs(.all).map(\.title), ["Alt", "Neu"])
        XCTAssertEqual(s.topSongs(.all).map(\.plays), [3, 2])
        // 7 Tage einschließlich heute: am 11. zählt der 5. noch, am 12. nicht mehr
        set(2026, 11, 11)
        XCTAssertEqual(s.summary(.week).plays, 2)
        set(2026, 11, 12)
        XCTAssertEqual(s.summary(.week).plays, 1)
    }

    func testTopListsMergeSameNames() {
        let s = makeStats()
        // derselbe Titel vom Server und vom Gerät (verschiedene IDs), Schreibweise leicht anders
        let server = song("srv-1", "Café del Mar", artist: "Energy 52", album: "Sammlung")
        let local = song("local:1", "cafe del mar", artist: "ENERGY 52", album: "sammlung")
        let other = song("2", "Etwas anderes", artist: "Jemand", album: nil)
        s.notePlay(server); s.notePlay(local); s.notePlay(local); s.notePlay(other)
        let songs = s.topSongs(.all)
        XCTAssertEqual(songs.map(\.plays), [3, 1])
        XCTAssertEqual(songs.first?.subtitle?.lowercased(), "energy 52")
        XCTAssertEqual(s.topArtists(.all).map(\.plays), [3, 1])
        XCTAssertEqual(s.topAlbums(.all).map(\.plays), [3])   // Titel ohne Album fehlt in der Albumliste
        XCTAssertEqual(s.topSongs(.all, limit: 1).count, 1)
    }

    func testStreak() {
        let s = makeStats()
        let a = song("1", "Lied")
        XCTAssertEqual(s.streak.current, 0)
        for d in [1, 2, 3, 4] { set(2026, 11, d); listen(s, a, seconds: 70) }
        set(2026, 11, 6); listen(s, a, seconds: 30)   // zu kurz: zählt nicht
        set(2026, 11, 8); listen(s, a, seconds: 70)
        set(2026, 11, 9); listen(s, a, seconds: 70)
        // heute (10.) noch nichts gehört: die Serie von gestern gilt weiter
        set(2026, 11, 10)
        XCTAssertEqual(s.streak.current, 2)
        XCTAssertEqual(s.streak.best, 4)
        listen(s, a, seconds: 70)
        XCTAssertEqual(s.streak.current, 3)
        set(2026, 11, 12)
        XCTAssertEqual(s.streak.current, 0)
        XCTAssertEqual(s.streak.best, 4)
    }

    func testDailyAndAlbums() {
        let s = makeStats()
        let a = song("1", "Eins", album: "Erste"), b = song("2", "Zwei", album: "Zweite")
        set(2026, 11, 8); listen(s, a, seconds: 60); s.notePlay(a); s.notePlay(a)
        set(2026, 11, 10); listen(s, b, seconds: 30); s.notePlay(b)
        let days = s.daily(last: 3)
        XCTAssertEqual(days.map(\.seconds), [60, 0, 30])
        XCTAssertEqual(calendar.component(.day, from: days[0].day), 8)
        XCTAssertEqual(s.recentAlbumIDs(), ["al-Zweite", "al-Erste"])
        XCTAssertEqual(s.frequentAlbumIDs(), ["al-Erste", "al-Zweite"])
    }

    func testSavesAndResets() {
        let s = makeStats()
        let a = song("1", "Lied")
        listen(s, a, seconds: 80); s.notePlay(a)
        s.flush()
        let again = makeStats()
        XCTAssertEqual(again.plays(of: "1"), 1)
        XCTAssertEqual(again.summary(.all).seconds, 80, accuracy: 0.001)
        XCTAssertEqual(again.since, clock)
        again.reset()
        XCTAssertTrue(again.isEmpty)
        XCTAssertTrue(makeStats().isEmpty)
    }

    func testRevisionChangesRarely() {
        let s = makeStats()
        let a = song("1", "Lied")
        let start = s.revision
        listen(s, a, seconds: 20)
        XCTAssertEqual(s.revision, start, "nicht bei jedem Takt neu zeichnen")
        listen(s, a, seconds: 15)
        XCTAssertEqual(s.revision, start + 1)
        s.notePlay(a)
        XCTAssertEqual(s.revision, start + 2)
    }

    // MARK: Schlaf-Timer

    func testSleepTimerRemaining() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(SleepTimer.off.remaining(now: now))
        XCTAssertNil(SleepTimer.endOfTrack.remaining(now: now))
        XCTAssertEqual(SleepTimer.at(now.addingTimeInterval(90)).remaining(now: now), 90)
        XCTAssertEqual(SleepTimer.at(now.addingTimeInterval(-5)).remaining(now: now), 0)
        XCTAssertFalse(SleepTimer.off.isOn)
        XCTAssertTrue(SleepTimer.endOfTrack.isOn)
    }

    func testSleepTimerOnPlayer() {
        let p = PlayerController()
        XCTAssertEqual(p.sleepTimer, .off)
        p.setSleepTimer(minutes: 15)
        let left = p.sleepTimer.remaining() ?? 0
        XCTAssertEqual(left, 900, accuracy: 2)
        p.setSleepTimerEndOfTrack()
        XCTAssertEqual(p.sleepTimer, .endOfTrack)
        p.cancelSleepTimer()
        XCTAssertEqual(p.sleepTimer, .off)
    }
}
