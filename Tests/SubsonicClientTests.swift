import XCTest
import AVFoundation
#if os(iOS)
@testable import HomeTune
#endif

/// Tests gegen ein Test-Navidrome. Zugang nur über die Umgebung (nie im Repo):
/// HOMETUNE_SERVER, HOMETUNE_USER, HOMETUNE_PASSWORD (sieht alle Bibliotheken),
/// HOMETUNE_DEMO_USER, HOMETUNE_DEMO_PASSWORD (sieht nur die Demo-Bibliothek). Siehe `test.sh`.
final class SubsonicClientTests: XCTestCase {
    static func client(demo: Bool = false) throws -> SubsonicClient {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["HOMETUNE_SERVER"], let url = AccountStore.normalize(s),
              let u = env[demo ? "HOMETUNE_DEMO_USER" : "HOMETUNE_USER"],
              let p = env[demo ? "HOMETUNE_DEMO_PASSWORD" : "HOMETUNE_PASSWORD"] else {
            throw XCTSkip("Kein Testserver in der Umgebung")
        }
        return SubsonicClient(account: ServerAccount(id: demo ? "test-demo" : "test-main", server: url, username: u), password: p)
    }

    func testRequestKeepsCredentialsOutOfURL() throws {
        let c = SubsonicClient(account: ServerAccount(server: URL(string: "http://example.invalid:4533")!, username: "u"), password: "geheim+1")
        let r = c.request("ping", [("query", "a+b c")])
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "http://example.invalid:4533/rest/ping")
        let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("t="), "Token-Anmeldung")
        XCTAssertTrue(body.contains("s="))
        XCTAssertFalse(body.contains("geheim"), "Passwort nie im Klartext")
        XCTAssertTrue(body.contains("query=a%2Bb%20c"))
    }

    func testNormalizeServer() {
        XCTAssertEqual(AccountStore.normalize("musik.local:4533/")?.absoluteString, "http://musik.local:4533")
        XCTAssertEqual(AccountStore.normalize(" https://m.example.com ")?.absoluteString, "https://m.example.com")
        XCTAssertNil(AccountStore.normalize(""))
    }

    func testErrorDecoding() {
        let json = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#
        XCTAssertThrowsError(try SubsonicClient.decode(Data(json.utf8), as: EmptyResponse.self)) { e in
            XCTAssertEqual(e as? SubsonicError, .server(code: 40, message: "Wrong username or password"))
        }
    }

    func testPingAndExtensions() async throws {
        let c = try Self.client()
        let s = try await c.ping()
        XCTAssertEqual(s.status, "ok")
        XCTAssertEqual(s.openSubsonic, true)
        let ext = try await c.openSubsonicExtensions().map(\.name)
        XCTAssertTrue(ext.contains("songLyrics"))
        XCTAssertTrue(ext.contains("formPost"))
    }

    func testWrongPassword() async throws {
        let good = try Self.client()
        let bad = SubsonicClient(account: good.account, password: "falsch-\(UUID().uuidString)")
        do { _ = try await bad.ping(); XCTFail("muss fehlschlagen") }
        catch { XCTAssertEqual((error as? SubsonicError).map { if case .server(let code, _) = $0 { code } else { -1 } }, 40) }
    }

    func testLibrariesPerAccount() async throws {
        let main = try await Self.client().musicFolders()
        let demo = try await Self.client(demo: true).musicFolders()
        XCTAssertGreaterThanOrEqual(main.count, 2, "Testkonto sieht Demo + Privat")
        XCTAssertEqual(demo.count, 1, "Demo-Konto sieht nur die Demo-Bibliothek")
    }

    func testLibraryEndpoints() async throws {
        let c = try Self.client(demo: true)
        let albums = try await c.allAlbums()
        XCTAssertFalse(albums.isEmpty)
        let artists = try await c.artists()
        XCTAssertFalse(artists.isEmpty)
        let songs = try await c.allSongs()
        XCTAssertGreaterThan(songs.count, 10)
        let album = try await c.album(id: albums[0].id)
        XCTAssertFalse(album.song?.isEmpty ?? true)
        let artist = try await c.artist(id: artists[0].id)
        XCTAssertFalse(artist.album?.isEmpty ?? true)
        let song = try await c.song(id: songs[0].id)
        XCTAssertEqual(song.id, songs[0].id)
        let genres = try await c.genres()
        XCTAssertFalse(genres.isEmpty)
        let byGenre = try await c.songsByGenre(genres[0].value)
        XCTAssertFalse(byGenre.isEmpty)
        let found = try await c.search(String(albums[0].name.prefix(4)))
        XCTAssertFalse(found.albums.isEmpty && found.songs.isEmpty)
        for t in [AlbumListType.newest, .recent, .frequent, .random] { _ = try await c.albumList(t, size: 5) }
        let random = try await c.randomSongs(size: 5)
        XCTAssertEqual(random.count, 5)
        _ = try await c.lyrics(songId: songs[0].id) // Endpunkt muss antworten (Demo hat keine Texte)
        _ = try await c.scanStatus()
    }

    func testStarRoundTrip() async throws {
        let c = try Self.client(demo: true)
        let song = try await c.allSongs()[0]
        try await c.setStar(.song(song.id), starred: true)
        var st = try await c.starred()
        XCTAssertTrue((st.song ?? []).contains { $0.id == song.id })
        try await c.setStar(.song(song.id), starred: false)
        st = try await c.starred()
        XCTAssertFalse((st.song ?? []).contains { $0.id == song.id })
    }

    func testPlaylistLifecycle() async throws {
        let c = try Self.client(demo: true)
        let songs = Array(try await c.allSongs().prefix(4))
        let name = "Test \(UUID().uuidString.prefix(6))"
        let p = try await c.createPlaylist(name: name, songIds: songs.prefix(2).map(\.id))
        defer { Task { try? await c.deletePlaylist(id: p.id) } }
        try await c.updatePlaylist(id: p.id, name: name + " B", comment: "Beschreibung", add: [songs[2].id, songs[3].id])
        var got = try await c.playlist(id: p.id)
        XCTAssertEqual(got.name, name + " B")
        XCTAssertEqual(got.comment, "Beschreibung")
        XCTAssertEqual(got.entry?.map(\.id), songs.map(\.id))
        // Neu ordnen: komplette Reihenfolge ersetzen
        let reordered = [songs[3], songs[0], songs[2], songs[1]].map(\.id)
        try await c.replacePlaylistSongs(id: p.id, songIds: reordered)
        got = try await c.playlist(id: p.id)
        XCTAssertEqual(got.entry?.map(\.id), reordered)
        try await c.updatePlaylist(id: p.id, removeIndexes: [0])
        got = try await c.playlist(id: p.id)
        XCTAssertEqual(got.entry?.map(\.id), Array(reordered.dropFirst()))
        try await c.deletePlaylist(id: p.id)
        let all = try await c.playlists()
        XCTAssertFalse(all.contains { $0.id == p.id })
    }

    /// Zeitsynchroner Liedtext live vom Server (Demo-Titel „Velvet“ hat eine .lrc-Datei).
    func testSyncedLyricsLive() async throws {
        let c = try Self.client(demo: true)
        guard let song = try await c.search("Velvet").songs.first(where: { $0.album == "Harbor Lights" }) else {
            throw XCTSkip("Demo-Titel fehlt")
        }
        let list = try await c.lyrics(songId: song.id)
        let synced = try XCTUnwrap(list.first { $0.synced == true }, "keine synchronen Liedtexte")
        let lines = synced.line ?? []
        XCTAssertGreaterThan(lines.count, 5)
        XCTAssertEqual(lines.compactMap(\.start), lines.compactMap(\.start).sorted(), "Zeilen nach Zeit geordnet")
    }

    func testCoverArt() async throws {
        let c = try Self.client(demo: true)
        let album = try await c.allAlbums()[0]
        let (data, resp) = try await c.session.data(for: c.coverArtRequest(id: album.coverArt ?? album.id, size: 300))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNotNil(PlatformImage(data: data))
    }

    /// Verlustfreie FLAC-Datei aus der privaten Bibliothek als Original laden und dekodieren.
    /// (Gibt keine Titelnamen aus.)
    func testFlacFromPrivateLibraryRawStream() async throws {
        let c = try Self.client()
        let folders = try await c.musicFolders()
        guard let privat = folders.first(where: { $0.name == "Privat" }) else { throw XCTSkip("Keine Bibliothek „Privat“") }
        let songs = try await c.allSongs(folder: privat.id)
        guard let flac = songs.filter({ $0.suffix == "flac" }).max(by: { ($0.samplingRate ?? 0) < ($1.samplingRate ?? 0) }) else {
            throw XCTSkip("Keine FLAC-Datei")
        }
        let url = try await TrackCache.shared.file(for: flac, client: c)
        XCTAssertEqual(url.pathExtension, "flac", "Original, nicht transkodiert")
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Int(file.fileFormat.sampleRate), flac.samplingRate)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, Double(flac.duration ?? 0), accuracy: 1.5)
        // Durch den Decoder (Resampling auf 48 kHz) – Signal darf nicht stumm sein
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let dec = try TrackDecoder(url: url, outFormat: fmt, startAt: min(30, (dec0Duration(url)) / 2))
        var peak: Float = 0
        for _ in 0..<20 {
            guard let b = dec.read(frames: 8192) else { break }
            for i in 0..<Int(b.frameLength) { peak = max(peak, abs(b.floatChannelData![0][i])) }
        }
        XCTAssertGreaterThan(peak, 0.01)
    }

    private func dec0Duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }
}
