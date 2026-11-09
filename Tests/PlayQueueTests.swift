import XCTest
#if os(iOS)
@testable import HomeTune
#endif

/// Warteliste nach Apples Modell: Als Nächstes / Zuletzt / Quelle / Verlauf / Zufall / Wiederholen.
final class PlayQueueTests: XCTestCase {
    private func songs(_ n: Int, prefix: String = "s") -> [Song] {
        (1...n).map { Song(id: "\(prefix)\($0)", title: "\(prefix.uppercased()) \($0)") }
    }

    func testPlayAlbumFromMiddle() {
        var q = PlayQueue()
        q.play(songs(5), startAt: 2, name: "Album")
        XCTAssertEqual(q.current?.song.id, "s3")
        XCTAssertEqual(q.source.map(\.song.id), ["s4", "s5"])
        XCTAssertEqual(q.sourceName, "Album")
    }

    func testPlayNextGoesBeforeEarlierQueuedAndPlayLastAtEnd() {
        var q = PlayQueue()
        q.play(songs(3))
        q.playLast([Song(id: "x", title: "X")])
        q.playNext([Song(id: "a", title: "A")])
        q.playNext([Song(id: "b", title: "B")])
        // Apple: „Als Nächstes“ = direkt nach dem aktuellen Titel, „Zuletzt“ = Ende von „Als Nächstes“
        XCTAssertEqual(q.upNext.map(\.song.id), ["b", "a", "x"])
        XCTAssertEqual(q.peekNext()?.song.id, "b")
        XCTAssertEqual(q.advance()?.song.id, "b")
        XCTAssertEqual(q.advance()?.song.id, "a")
        XCTAssertEqual(q.advance()?.song.id, "x")
        XCTAssertEqual(q.advance()?.song.id, "s2", "danach geht es mit der Quelle weiter")
        XCTAssertEqual(q.history.map(\.song.id), ["s1", "b", "a", "x"])
    }

    func testNewSourceKeepsUpNext() {
        var q = PlayQueue()
        q.play(songs(3))
        q.playNext([Song(id: "a", title: "A")])
        q.play(songs(2, prefix: "t"))
        XCTAssertEqual(q.current?.song.id, "t1")
        XCTAssertEqual(q.upNext.map(\.song.id), ["a"])
        XCTAssertEqual(q.peekNext()?.song.id, "a")
    }

    func testGoBackReturnsEntryToItsList() {
        var q = PlayQueue()
        q.play(songs(3))
        q.playNext([Song(id: "a", title: "A")])
        q.advance() // a
        q.advance() // s2
        q.goBack()
        XCTAssertEqual(q.current?.song.id, "a")
        XCTAssertEqual(q.source.first?.song.id, "s2")
        q.goBack()
        XCTAssertEqual(q.current?.song.id, "s1")
        XCTAssertEqual(q.upNext.first?.song.id, "a", "Eingereihter Titel kommt zurück in „Als Nächstes“")
    }

    func testRepeatOneAndAll() {
        var q = PlayQueue()
        q.play(songs(2))
        q.repeatMode = .one
        XCTAssertEqual(q.peekNext()?.song.id, "s1")
        XCTAssertEqual(q.advance(auto: true)?.song.id, "s1")
        XCTAssertEqual(q.advance(auto: false)?.song.id, "s2", "Weiter-Taste verlässt „Eins wiederholen“")
        q.repeatMode = .all
        XCTAssertEqual(q.peekNext()?.id, PlayQueue.wrapID)
        XCTAssertEqual(q.advance()?.song.id, "s1", "von vorn")
        XCTAssertEqual(q.source.map(\.song.id), ["s2"])
        q.repeatMode = .off
        q.advance()
        XCTAssertNil(q.advance(), "Ende der Warteliste")
    }

    func testCycleRepeat() {
        var q = PlayQueue()
        q.cycleRepeat(); XCTAssertEqual(q.repeatMode, .all)
        q.cycleRepeat(); XCTAssertEqual(q.repeatMode, .one)
        q.cycleRepeat(); XCTAssertEqual(q.repeatMode, .off)
    }

    func testShuffleKeepsAllSongsAndRestoresOrder() {
        var q = PlayQueue()
        let s = songs(30)
        q.play(s, startAt: 0)
        q.setShuffle(true)
        XCTAssertEqual(Set(q.source.map(\.song.id)), Set(s.dropFirst().map(\.id)))
        XCTAssertNotEqual(q.source.map(\.song.id), s.dropFirst().map(\.id), "gemischt (Wahrscheinlichkeit gleicher Reihenfolge ~0)")
        q.setShuffle(false)
        XCTAssertEqual(q.source.map(\.song.id), s.dropFirst().map(\.id))
    }

    func testShufflePlayStartsWithChosenOrRandom() {
        var q = PlayQueue()
        q.play(songs(10), startAt: 4, shuffle: true)
        XCTAssertEqual(q.current?.song.id, "s5")
        XCTAssertEqual(q.source.count, 9)
        q.play(songs(10), shuffle: true)
        XCTAssertNotNil(q.current)
        XCTAssertEqual(q.source.count + 1, 10)
    }

    func testJumpRemoveMoveClear() {
        var q = PlayQueue()
        q.play(songs(5))
        q.playNext([Song(id: "a", title: "A"), Song(id: "b", title: "B")])
        let target = q.source[1] // s3
        q.jump(to: target.id)
        XCTAssertEqual(q.current?.song.id, "s3")
        XCTAssertTrue(q.upNext.isEmpty)
        XCTAssertEqual(q.source.map(\.song.id), ["s4", "s5"])
        q.moveSource(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(q.source.map(\.song.id), ["s5", "s4"])
        q.remove(id: q.source[0].id)
        XCTAssertEqual(q.source.map(\.song.id), ["s4"])
        q.clearUpcoming()
        XCTAssertTrue(q.source.isEmpty && q.upNext.isEmpty)
        XCTAssertEqual(q.current?.song.id, "s3")
        q.clearHistory()
        XCTAssertTrue(q.history.isEmpty)
    }

    func testCodableRoundTrip() throws {
        var q = PlayQueue()
        q.play(songs(3), name: "X")
        q.playNext([Song(id: "a", title: "A")])
        let d = try JSONEncoder().encode(q)
        let r = try JSONDecoder().decode(PlayQueue.self, from: d)
        XCTAssertEqual(r.current?.song.id, "s1")
        XCTAssertEqual(r.upNext.map(\.song.id), ["a"])
        XCTAssertEqual(r.sourceName, "X")
    }
}
