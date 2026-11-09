import XCTest
import AVFoundation
#if os(iOS)
@testable import HomeTune
#endif

/// Neu in 1.1: Ogg/Opus-Tags, eigene Playlists (anlegen, umbenennen, umsortieren, entfernen, löschen), Import von
/// .m3u/.m3u8/.pls mit Zuordnung über Dateinamen/#EXTINF, der HomeTune-Ordner (Documents/) mit Umzug und
/// Posteingang, „Öffnen in“ ohne Kopie und die Prüfung des Signatur-Profils.
@MainActor
final class LocalPlaylistTests: XCTestCase {
    private let fm = FileManager.default
    private var work: URL!

    override func setUp() async throws {
        work = fm.temporaryDirectory.appending(path: "pl-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: work)
    }

    private var bundleFixtures: URL {
        get throws { try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)) }
    }

    private func fixtures(_ name: String = "LocalMusic", as target: String = "Music") throws -> URL {
        let dst = work.appending(path: target, directoryHint: .isDirectory)
        try fm.copyItem(at: try bundleFixtures.appending(path: name), to: dst)
        return dst
    }

    private var docs: URL { work.appending(path: "Documents", directoryHint: .isDirectory) }

    private func makeLibrary() -> LocalLibrary {
        LocalLibrary(directory: work.appending(path: "Store", directoryHint: .isDirectory), documents: docs)
    }

    // MARK: Ogg Vorbis / Opus

    func testOggAndOpusVorbisComments() async throws {
        let dir = try fixtures("OggOpus", as: "Ogg")
        let oggURL = dir.appending(path: "Lantern Hours/01 - river_glass.ogg")
        let opusURL = dir.appending(path: "Lantern Hours/02 - paper_lantern.opus")

        // Opus: iOS dekodiert es, Tags kommen als vorb/* (Schlüssel in Groß- und Kleinschreibung gemischt)
        let opus = try await XCTUnwrapAsync(await TagReader.read(opusURL))
        XCTAssertEqual(opus.title, "Paper Lantern", "Titel aus vorb/TITLE, nicht aus dem Dateinamen")
        XCTAssertEqual(opus.artist, "Quiet Ferry")
        XCTAssertEqual(opus.album, "Lantern Hours")
        XCTAssertEqual(opus.albumArtist, "Quiet Ferry")
        XCTAssertEqual(opus.track, 2)
        XCTAssertEqual(opus.discNumber, 1)
        XCTAssertEqual(opus.year, 2025)
        XCTAssertEqual(opus.genre, "Chamber Pop")
        XCTAssertEqual(opus.duration, 2, accuracy: 0.1)
        XCTAssertNotNil(opus.artwork.flatMap(PlatformImage.init(data:)), "Cover aus METADATA_BLOCK_PICTURE")

        // Ogg Vorbis: Tags werden gelesen; ob iOS den Ton dekodiert, hängt vom System ab
        var vorbis = LocalTags()
        await TagReader.readMetadata(oggURL, into: &vorbis)
        let decodable = (try? AVAudioFile(forReading: oggURL)) != nil
        print("Ogg Vorbis: dekodierbar \(decodable), Titel \(vorbis.title ?? "–"), Cover \(vorbis.artwork != nil)")
        if vorbis.title != nil {
            XCTAssertEqual(vorbis.title, "River Glass")
            XCTAssertEqual(vorbis.albumArtist, "Quiet Ferry")
            XCTAssertEqual(vorbis.track, 1)
            XCTAssertEqual(vorbis.year, 2025)
            XCTAssertEqual(vorbis.composer, "Bea Sample")
        }

        // In der Mediathek als ein Album, abspielbar über den Decoder der Engine
        let lib = makeLibrary()
        let s = await lib.add([dir])
        XCTAssertEqual(s.added, decodable ? 2 : 1)
        let album = try XCTUnwrap(lib.albums.first { $0.name == "Lantern Hours" })
        XCTAssertEqual(lib.songs(ofAlbum: album.id).map(\.title), decodable ? ["River Glass", "Paper Lantern"] : ["Paper Lantern"])
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        for song in lib.songs {
            let dec = try TrackDecoder(url: try lib.fileURL(for: song), outFormat: fmt)
            XCTAssertNotNil(dec.read(frames: 4096), "\(song.title) dekodierbar")
        }
        lib.keepAccess(for: [])
    }

    /// Vorbis-Kommentare direkt (wie in FLAC/Ogg/Opus): Schlüssel ohne Rücksicht auf Groß-/Kleinschreibung.
    func testVorbisCommentKeysAreCaseInsensitive() {
        var t = LocalTags()
        for (k, v) in [("title", "A"), ("Artist", "B"), ("ALBUM", "C"), ("albumartist", "D"), ("TrackNumber", "3/9"),
                       ("discnumber", "2"), ("Date", "2020-01-01"), ("genre", "(17)Rock"), ("Composer", "E")] {
            FLACTags.apply(key: k, value: v, into: &t)
        }
        XCTAssertEqual([t.title, t.artist, t.album, t.albumArtist, t.genre, t.composer], ["A", "B", "C", "D", "Rock", "E"])
        XCTAssertEqual(t.track, 3)
        XCTAssertEqual(t.discNumber, 2)
        XCTAssertEqual(t.year, 2020)
    }

    // MARK: Playlist-Dateien

    func testParsesM3UExtendedAndPLS() {
        let m3u = """
        #EXTM3U
        #PLAYLIST:Road Trip
        #EXTINF:181,Lumenfold - Paper Boats
        /Users/someone/Music/Music/Media.localized/Music/Lumenfold/Morning Set/01 Paper Boats.m4a
        #EXTINF:120,Glass Harbor
        file:///Users/someone/Music/Glass%20Harbor.mp3
        C:\\Music\\Night Drive\\01 - Neon Rain.m4a

        """
        let p = PlaylistFile.parse(Data(m3u.utf8), ext: "m3u8")
        XCTAssertEqual(p.name, "Road Trip")
        XCTAssertEqual(p.entries.count, 3)
        XCTAssertEqual(p.entries[0].display, "Lumenfold - Paper Boats")
        XCTAssertEqual(p.entries[1].path, "/Users/someone/Music/Glass Harbor.mp3")
        XCTAssertEqual(p.entries[2].path, "C:/Music/Night Drive/01 - Neon Rain.m4a")
        XCTAssertNil(p.entries[2].display)

        let pls = """
        [playlist]
        File1=Morning Set/02 - Glass Harbor.mp3
        Title1=Glass Harbor
        File2=Copper Sky.aiff
        NumberOfEntries=2
        Version=2
        """
        let q = PlaylistFile.parse(Data(pls.utf8), ext: "pls")
        XCTAssertEqual(q.entries.map(\.path), ["Morning Set/02 - Glass Harbor.mp3", "Copper Sky.aiff"])
        XCTAssertEqual(q.entries.first?.display, "Glass Harbor")

        // Ältere iTunes-.m3u in Windows-1252 und UTF-16 mit BOM
        let latin = "#EXTINF:1,Caf\u{E9}\nCaf\u{E9}.mp3\n".data(using: .windowsCP1252)!
        XCTAssertEqual(PlaylistFile.parse(latin, ext: "m3u").entries.first?.path, "Café.mp3")
        let utf16 = "#EXTM3U\nSong.mp3\n".data(using: .utf16)!
        XCTAssertEqual(PlaylistFile.parse(utf16, ext: "m3u").entries.map(\.path), ["Song.mp3"])
    }

    func testMatcherUsesBasenameFoldersAndDisplayName() {
        let m = PlaylistMatcher([
            .init(songID: "a", components: PlaylistMatcher.components(of: "Music/Album One/01 Intro.flac"), title: "Intro", artist: "X"),
            .init(songID: "b", components: PlaylistMatcher.components(of: "Music/Album Two/01 Intro.flac"), title: "Intro", artist: "Y"),
            .init(songID: "c", components: PlaylistMatcher.components(of: "Music/Glass Harbor.MP3"), title: "Glass Harbor", artist: "Lumenfold"),
            .init(songID: "d", components: PlaylistMatcher.components(of: "Music/track07.wav"), title: "Neon Rain", artist: "Velvetine Static"),
        ])
        // Dateiname ohne Endung/Pfad, Groß-/Kleinschreibung egal
        XCTAssertEqual(m.match(.init(path: "/Volumes/Other/glass harbor.m4a")), "c")
        // Gleichnamige Dateien: passender Ordnername entscheidet
        XCTAssertEqual(m.match(.init(path: "/Users/x/Music/Album Two/01 Intro.m4a")), "b")
        XCTAssertEqual(m.match(.init(path: "D:/Rips/Album One/01 intro.mp3")), "a")
        // Kein passender Dateiname → #EXTINF „Interpret – Titel“
        XCTAssertEqual(m.match(.init(path: "missing.mp3", display: "Velvetine Static - Neon Rain")), "d")
        XCTAssertNil(m.match(.init(path: "nothing.mp3", display: "Unknown - Song")))
        let r = m.match(PlaylistFile.Parsed(name: nil, entries: [.init(path: "Glass Harbor.flac"), .init(path: "gone.mp3")]))
        XCTAssertEqual(r.ids, ["c"])
        XCTAssertEqual(r.total, 2)
    }

    // MARK: Eigene Playlists

    func testLocalPlaylistLifecycleAndMixedListing() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        await lib.add([dir])
        let ids = lib.songs.prefix(3).map(\.id)
        let p = lib.createPlaylist(name: "Fahrt", comment: "für unterwegs", songIDs: ids)
        XCTAssertTrue(p.id.isLocalPlaylistID && p.id.isLocalID)

        let store = LibraryStore()
        store.local = lib
        let listed = try XCTUnwrap(store.allPlaylists.first { $0.id == p.id })
        XCTAssertEqual(listed.songCount, 3)
        XCTAssertEqual(listed.name, "Fahrt")
        // über dieselben Aufrufe wie Server-Playlists
        try await store.add([lib.songs[3].id], to: listed)
        var full = try await store.playlistSongs(p.id)
        XCTAssertEqual(full.entry?.count, 4)
        try await store.save(playlist: full, name: "Fahrt 2", comment: "", songs: (full.entry ?? []).map(\.id).reversed())
        full = try await store.playlistSongs(p.id)
        XCTAssertEqual(full.name, "Fahrt 2")
        XCTAssertEqual(full.entry?.map(\.id), Array((ids + [lib.songs[3].id]).reversed()), "umsortiert")
        try await store.remove(indexes: [0], from: full)
        let afterRemove = try await store.playlistSongs(p.id)
        XCTAssertEqual(afterRemove.entry?.count, 3)
        let created = try await store.createPlaylist(name: "Neu", comment: "", songs: [], onDevice: true)
        XCTAssertTrue(created.id.isLocalPlaylistID)
        XCTAssertEqual(store.allPlaylists.map(\.name), ["Fahrt 2", "Neu"])

        // übersteht einen Neustart
        let again = makeLibrary()
        XCTAssertEqual(again.playlists.map(\.name).sorted(), ["Fahrt 2", "Neu"])
        try await store.delete(playlist: full)
        XCTAssertNil(lib.playlist(p.id))
    }

    func testImportPlaylistFileFromDialog() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        await lib.add([dir])
        let file = work.appending(path: "Export.m3u8")
        try """
        #EXTM3U
        #EXTINF:2,Lumenfold - Glass Harbor
        /Users/someone/Music/Media/Lumenfold/Morning Set/02 Glass Harbor.m4a
        #EXTINF:2,Velvetine Static - Neon Rain
        /Users/someone/Music/Media/Night Drive/01 - Neon Rain.m4a
        #EXTINF:3,Somebody - Not Here
        /Users/someone/Music/Media/Not Here.m4a
        """.write(to: file, atomically: true, encoding: .utf8)
        let s = await lib.add([file])
        XCTAssertEqual(s.playlists, [PlaylistImportResult(name: "Export", found: 2, total: 3)], "„2 von 3 Titeln gefunden“")
        let p = try XCTUnwrap(lib.playlists.first)
        XCTAssertEqual(p.songIDs.compactMap { id in lib.songs.first { $0.id == id }?.title }, ["Glass Harbor", "Neon Rain"])
        // Gleiche Datei noch einmal → aktualisiert, kein Duplikat
        _ = await lib.add([file])
        XCTAssertEqual(lib.playlists.count, 1)
    }

    func testPlaylistInsideFolderIsImportedAndFollowsTheFile() async throws {
        let dir = try fixtures()
        let m3u = dir.appending(path: "Favoriten.m3u")
        try "Morning Set/01 - Paper Boats.flac\nCopper Sky.aiff\n".write(to: m3u, atomically: true, encoding: .utf8)
        let lib = makeLibrary()
        let s = await lib.add([dir])
        XCTAssertEqual(s.added, 6)
        XCTAssertEqual(s.playlists.first?.found, 2)
        XCTAssertEqual(lib.playlists.map(\.name), ["Favoriten"])
        // Datei geändert → neu zugeordnet
        try "Night Drive/02 - Tunnel Lights.m4a\n".write(to: m3u, atomically: true, encoding: .utf8)
        await lib.rescanAll()
        XCTAssertEqual(lib.playlists.first?.songIDs.count, 1)
        // Datei gelöscht → Playlist verschwindet (nicht bearbeitet)
        try fm.removeItem(at: m3u)
        await lib.rescanAll()
        XCTAssertTrue(lib.playlists.isEmpty)
    }

    // MARK: HomeTune-Ordner (Documents/)

    func testAppFolderScanSkipsInboxAndFindsChanges() async throws {
        let lib = makeLibrary()
        XCTAssertEqual(lib.allRoots.first?.kind, .appFolder, "fester Eintrag zuerst")
        XCTAssertTrue(lib.roots.isEmpty)
        let src = try bundleFixtures.appending(path: "LocalMusic")
        try fm.createDirectory(at: docs.appending(path: "Sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.inboxDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: src.appending(path: "Copper Sky.aiff"), to: docs.appending(path: "Copper Sky.aiff"))
        try fm.copyItem(at: src.appending(path: "Night Drive"), to: docs.appending(path: "Sub/Night Drive"))
        try fm.copyItem(at: src.appending(path: "Morning Set/02 - Glass Harbor.mp3"), to: lib.inboxDirectory.appending(path: "Glass.mp3"))
        try "Sub/Night Drive/01 - Neon Rain.m4a\n".write(to: docs.appending(path: "Liste.m3u8"), atomically: true, encoding: .utf8)

        let first = try await XCTUnwrapAsync(await lib.refreshAppFolderIfChanged())
        XCTAssertEqual(first.added, 3, "rekursiv, ohne Posteingang")
        XCTAssertFalse(lib.songs.contains { $0.title == "Glass Harbor" }, "Documents/Inbox zählt nicht")
        XCTAssertEqual(lib.playlists.map(\.name), ["Liste"])
        XCTAssertEqual(lib.playlists.first?.songIDs.count, 1)
        XCTAssertEqual(lib.albums.first { $0.name == "Night Drive" }?.songCount, 2)
        let none = await lib.refreshAppFolderIfChanged()
        XCTAssertNil(none, "nichts geändert → kein Einlesen")

        // Datei gelöscht → verschwindet; neue Datei → erscheint
        try fm.removeItem(at: docs.appending(path: "Copper Sky.aiff"))
        try fm.copyItem(at: src.appending(path: "Morning Set/01 - Paper Boats.flac"), to: docs.appending(path: "Sub/Paper Boats.flac"))
        let second = try await XCTUnwrapAsync(await lib.refreshAppFolderIfChanged())
        XCTAssertEqual(second.added, 1)
        XCTAssertEqual(second.removed, 1)
        XCTAssertNil(lib.songs.first { $0.title == "Copper Sky" })

        // Entfernen: nur aus der Mediathek (Datei bleibt) oder mit Löschen
        let paper = try XCTUnwrap(lib.songs.first { $0.title == "Paper Boats" })
        XCTAssertTrue(lib.isInAppFolder(paper))
        lib.remove(songs: [paper])
        XCTAssertTrue(fm.fileExists(atPath: docs.appending(path: "Sub/Paper Boats.flac").path))
        await lib.rescan(LocalLibrary.appFolderRootID)
        XCTAssertNil(lib.songs.first { $0.title == "Paper Boats" }, "bleibt draußen")
        let neon = try XCTUnwrap(lib.songs.first { $0.title == "Neon Rain" })
        lib.remove(songs: [neon], deleteAppFolderFiles: true)
        XCTAssertFalse(fm.fileExists(atPath: docs.appending(path: "Sub/Night Drive/01 - Neon Rain.m4a").path))
        // Fester Eintrag lässt sich nicht entfernen
        lib.removeRoot(LocalLibrary.appFolderRootID)
        XCTAssertEqual(lib.allRoots.first?.kind, .appFolder)
    }

    #if os(macOS)
    /// Mac: Der sichtbare Musikordner (~/Music/HomeTune) wird nie umgeräumt – kein Altbestand, nichts verschieben.
    func testMacMigrationNeverMovesAnything() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "migration-\(UUID().uuidString)"))
        try fm.createDirectory(at: docs.appending(path: "Inbox"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: docs.appending(path: "Inbox/a.mp3"))
        try fm.createDirectory(at: docs.appending(path: "Covers"), withIntermediateDirectories: true)
        let lib = makeLibrary()
        let moved = await lib.migrateDocuments(defaults: defaults)
        XCTAssertEqual(moved, 0)
        XCTAssertTrue(fm.fileExists(atPath: docs.appending(path: "Inbox/a.mp3").path))
        XCTAssertTrue(fm.fileExists(atPath: docs.appending(path: "Covers").path))
    }
    #else
    func testMigrationMovesInternalFilesOutOfDocuments() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "migration-\(UUID().uuidString)"))
        try fm.createDirectory(at: docs.appending(path: "Covers"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: docs.appending(path: "Covers/abc.jpg"))
        try fm.createDirectory(at: docs.appending(path: "Inbox"), withIntermediateDirectories: true)
        let src = try bundleFixtures.appending(path: "LocalMusic")
        try fm.copyItem(at: src.appending(path: "Copper Sky.aiff"), to: docs.appending(path: "Inbox/Copper Sky.aiff"))
        try "Copper Sky.aiff\n".write(to: docs.appending(path: "Inbox/Mitgebracht.m3u"), atomically: true, encoding: .utf8)
        let lib = makeLibrary()
        let n = await lib.migrateDocuments(defaults: defaults)
        XCTAssertGreaterThanOrEqual(n, 3)
        XCTAssertFalse(fm.fileExists(atPath: docs.appending(path: "Covers").path), "nichts Internes mehr im sichtbaren Ordner")
        // (das Test-Cover gehört zu keinem Titel und wird danach beim Aufräumen entfernt)
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: lib.inboxDirectory.path))?.count ?? 0, 0, "Posteingang geleert")
        XCTAssertEqual(lib.songs.map(\.title), ["Copper Sky"])
        XCTAssertEqual(lib.roots.first?.kind, .copied, "als empfangene Datei (App Support)")
        XCTAssertEqual(lib.playlists.first?.songIDs.count, 1)
        // nur einmal
        let again = await lib.migrateDocuments(defaults: defaults)
        XCTAssertEqual(again, 0)
    }

    #endif

    // MARK: „Öffnen in“ ohne Kopie

    func testOpenInPlaceReferencesFilesAppOriginals() async throws {
        let lib = makeLibrary()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #if os(iOS)
        XCTAssertTrue(lib.needsCopy(lib.inboxDirectory.appending(path: "a.mp3")), "Mail/AirDrop → Posteingang → Kopie")
        XCTAssertTrue(lib.needsCopy(home.appending(path: "tmp/org.homeroll.hometune-Inbox/a.mp3")))
        #else
        // Mac (ohne Sandbox): alles wird nur verknüpft, nie kopiert
        XCTAssertFalse(lib.needsCopy(lib.inboxDirectory.appending(path: "a.mp3")))
        XCTAssertFalse(lib.needsCopy(home.appending(path: "Music/a.mp3")))
        #endif
        XCTAssertFalse(lib.needsCopy(URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/a.flac")),
                       "iCloud Drive / andere Apps → Original")
        XCTAssertFalse(lib.needsCopy(docs.appending(path: "Sub/a.flac")), "HomeTune-Ordner gehört schon dazu")

        // Datei außerhalb des App-Containers (Test-Bundle) → Bookmark, keine Kopie
        let original = try bundleFixtures.appending(path: "LocalMusic/Copper Sky.aiff")
        let s = await lib.open([original])
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(lib.roots.map(\.kind), [.file])
        XCTAssertNotNil(lib.roots.first?.bookmark)
        XCTAssertEqual(lib.importedBytes, 0, "nichts kopiert")
    }

    // MARK: Signatur-Profil

    /// Beispiel-Profil (erfundene Werte) in einer CMS-Hülle wie embedded.mobileprovision.
    private func profile(appID: String) -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>Example Profile</string>
        <key>Entitlements</key><dict>
        <key>application-identifier</key><string>A1B2C3D4E5.\(appID)</string>
        <key>com.apple.developer.team-identifier</key><string>A1B2C3D4E5</string>
        </dict></dict></plist>
        """
        return Data([0x30, 0x82, 0x10, 0x00, 0x06, 0x09]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00, 0x01, 0x30])
    }

    #if os(iOS)
    func testSigningProfileMismatch() {
        XCTAssertEqual(SigningCheck.applicationIdentifier(in: profile(appID: "com.example.other")), "com.example.other")
        XCTAssertEqual(SigningCheck.mismatch(profile: profile(appID: "com.example.other"), bundleID: "org.homeroll.hometune"), "com.example.other")
        XCTAssertNil(SigningCheck.mismatch(profile: profile(appID: "org.homeroll.hometune"), bundleID: "org.homeroll.hometune"))
        XCTAssertNil(SigningCheck.mismatch(profile: profile(appID: "*"), bundleID: "org.homeroll.hometune"))
        XCTAssertNil(SigningCheck.mismatch(profile: profile(appID: "org.homeroll.*"), bundleID: "org.homeroll.hometune"))
        XCTAssertEqual(SigningCheck.mismatch(profile: profile(appID: "com.example.*"), bundleID: "org.homeroll.hometune"), "com.example.*")
        XCTAssertNil(SigningCheck.mismatch(profile: Data("kein Profil".utf8), bundleID: "org.homeroll.hometune"))
        XCTAssertNil(SigningCheck.currentMismatch(), "Simulator: kein Profil")
    }
    #endif
}
