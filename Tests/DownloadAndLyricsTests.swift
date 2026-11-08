import XCTest
@testable import HomeSpin

@MainActor
final class DownloadAndLyricsTests: XCTestCase {
    /// Offline-Download eines Demo-Titels (Original über `download`), danach wieder entfernen.
    func testDownloadAndRemove() async throws {
        let c = try SubsonicClientTests.client(demo: true)
        let song = try await c.allSongs()[0]
        let dm = DownloadManager()
        dm.attach(c)
        dm.remove([song])
        dm.download([song])
        let deadline = Date().addingTimeInterval(20)
        while !dm.isDownloaded(song.id) && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertEqual(dm.state(song.id), .done)
        let file = try XCTUnwrap(dm.localFile(song.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(TrackCache.canOpen(file))
        XCTAssertGreaterThan(dm.totalBytes, 0)
        // Manifest übersteht einen Neustart
        let dm2 = DownloadManager()
        dm2.attach(c)
        XCTAssertTrue(dm2.isDownloaded(song.id))
        dm2.remove([song])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// OpenSubsonic `songLyrics`: synchronisierte Zeilen mit Startzeit (ms) und Versatz.
    func testStructuredLyricsDecoding() throws {
        let json = #"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[
          {"lang":"und","synced":false,"line":[{"value":"Zeile eins"},{"value":"Zeile zwei"}]},
          {"lang":"en","synced":true,"offset":-100,"displayTitle":"Probe","line":[
            {"start":0,"value":"Erste Zeile"},{"start":2500,"value":"Zweite Zeile"},{"start":5000,"value":""}]}
        ]}}}
        """#
        let r = try SubsonicClient.decode(Data(json.utf8), as: LyricsListResponse.self)
        let list = try XCTUnwrap(r.lyricsList?.structuredLyrics)
        XCTAssertEqual(list.count, 2)
        let synced = try XCTUnwrap(list.first { $0.synced == true })
        XCTAssertEqual(synced.offset, -100)
        XCTAssertEqual(synced.line?.map(\.start), [0, 2500, 5000])
    }
}
