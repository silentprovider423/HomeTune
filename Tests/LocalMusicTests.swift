import XCTest
import AVFoundation
@testable import HomeTune

/// „Musik auf diesem iPhone“: Tags lokal lesen, Ordner per Bookmark merken und wiederfinden, neu einlesen,
/// in die Mediathek einreihen, entfernen ohne Originale zu löschen – und 432 Hz auch für lokale FLAC-Dateien.
/// Testdateien: Tests/Fixtures (erfundene Titel, Sinustöne/Stille, erzeugt mit tools/make-test-audio.sh).
@MainActor
final class LocalMusicTests: XCTestCase {
    private let fm = FileManager.default
    private var work: URL!

    override func setUp() async throws {
        work = fm.temporaryDirectory.appending(path: "local-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: work)
    }

    /// Kopie eines Fixture-Ordners, damit Tests Dateien hinzufügen/löschen/verschieben können.
    private func fixtures(_ name: String = "LocalMusic", as target: String = "Music") throws -> URL {
        let base = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        let dst = work.appending(path: target, directoryHint: .isDirectory)
        try fm.copyItem(at: base.appending(path: name), to: dst)
        return dst
    }

    private func makeLibrary() -> LocalLibrary { LocalLibrary(directory: work.appending(path: "Store", directoryHint: .isDirectory)) }

    // MARK: Metadaten

    func testReadsTagsFromEveryFormat() async throws {
        let dir = try fixtures()
        let flac = try await XCTUnwrapAsync(await TagReader.read(dir.appending(path: "Morning Set/01 - Paper Boats.flac")))
        XCTAssertEqual(flac.title, "Paper Boats")
        XCTAssertEqual(flac.artist, "Lumenfold")
        XCTAssertEqual(flac.album, "Morning Set")
        XCTAssertEqual(flac.albumArtist, "Lumenfold")
        XCTAssertEqual(flac.track, 1)
        XCTAssertEqual(flac.discNumber, 1)
        XCTAssertEqual(flac.year, 2021)
        XCTAssertEqual(flac.genre, "Ambient")
        XCTAssertEqual(flac.composer, "Ada Example")
        XCTAssertEqual(flac.sampleRate, 48000)
        XCTAssertEqual(flac.bitDepth, 16)
        XCTAssertEqual(flac.duration, 3, accuracy: 0.01)
        XCTAssertNotNil(flac.artwork.flatMap(UIImage.init(data:)), "Cover aus dem FLAC-PICTURE-Block")

        let mp3 = try await XCTUnwrapAsync(await TagReader.read(dir.appending(path: "Morning Set/02 - Glass Harbor.mp3")))
        XCTAssertEqual(mp3.title, "Glass Harbor")
        XCTAssertEqual(mp3.artist, "Lumenfold")
        XCTAssertEqual(mp3.album, "Morning Set")
        XCTAssertEqual(mp3.albumArtist, "Lumenfold")
        XCTAssertEqual(mp3.track, 2)
        XCTAssertEqual(mp3.discNumber, 1)
        XCTAssertEqual(mp3.year, 2021)
        XCTAssertEqual(mp3.genre, "Ambient")
        XCTAssertNil(mp3.bitDepth)
        XCTAssertEqual(mp3.duration, 2, accuracy: 0.15)
        XCTAssertEqual(Double(mp3.bitRate ?? 0), 96, accuracy: 30)
        XCTAssertNotNil(mp3.artwork.flatMap(UIImage.init(data:)), "Cover aus ID3 APIC")

        let aac = try await XCTUnwrapAsync(await TagReader.read(dir.appending(path: "Night Drive/01 - Neon Rain.m4a")))
        XCTAssertEqual(aac.title, "Neon Rain")
        XCTAssertEqual(aac.artist, "Velvetine Static")
        XCTAssertEqual(aac.album, "Night Drive")
        XCTAssertEqual(aac.albumArtist, "Velvetine Static")
        XCTAssertEqual(aac.track, 1)
        XCTAssertEqual(aac.discNumber, 1)
        XCTAssertEqual(aac.year, 2019)
        XCTAssertEqual(aac.genre, "Synthwave")
        XCTAssertNotNil(aac.artwork.flatMap(UIImage.init(data:)), "Cover aus iTunes covr")

        let alac = try await XCTUnwrapAsync(await TagReader.read(dir.appending(path: "Night Drive/02 - Tunnel Lights.m4a")))
        XCTAssertEqual(alac.title, "Tunnel Lights")
        XCTAssertEqual(alac.artist, "Velvetine Static feat. Kite Assembly Club")
        XCTAssertEqual(alac.albumArtist, "Velvetine Static")
        XCTAssertEqual(alac.track, 2)
        XCTAssertEqual(alac.bitDepth, 16, "ALAC ist verlustfrei")

        let wav = try await XCTUnwrapAsync(await TagReader.read(dir.appending(path: "Morning Set/03 - Quiet Field.wav")))
        XCTAssertNil(wav.title)
        XCTAssertEqual(wav.bitDepth, 16)
        XCTAssertEqual(wav.duration, 1, accuracy: 0.01)

        let aiff = try await XCTUnwrapAsync(await TagReader.read(dir.appending(path: "Copper Sky.aiff")))
        XCTAssertEqual(aiff.duration, 1, accuracy: 0.01)
        XCTAssertEqual(aiff.title, "Copper Sky", "ID3-Chunk in AIFF")
        XCTAssertEqual(aiff.artist, "Marigold Engine")
        XCTAssertEqual(aiff.year, 2018)
        XCTAssertNil(aiff.album)

        // Keine Audiodatei
        let notes = await TagReader.read(dir.appending(path: "Morning Set/notes.txt"))
        XCTAssertNil(notes)
    }

    func testFilenameFallback() {
        XCTAssertEqual(TagReader.fromFilename("03 - Quiet Field.wav").track, 3)
        XCTAssertEqual(TagReader.fromFilename("03 - Quiet Field.wav").title, "Quiet Field")
        XCTAssertEqual(TagReader.fromFilename("7. Seventh.flac").track, 7)
        XCTAssertEqual(TagReader.fromFilename("7. Seventh.flac").title, "Seventh")
        XCTAssertEqual(TagReader.fromFilename("12 Twelve Bars.mp3").track, 12)
        XCTAssertNil(TagReader.fromFilename("Copper Sky.aiff").track)
        XCTAssertEqual(TagReader.fromFilename("Copper Sky.aiff").title, "Copper Sky")
        XCTAssertEqual(TagReader.firstInt("4/12"), 4)
        XCTAssertEqual(TagReader.year("2021-05-01T00:00:00Z"), 2021)
        XCTAssertEqual(TagReader.genre("(17)Rock"), "Rock")
    }

    // MARK: Mediathek

    func testFolderImportBuildsAlbumsArtistsAndSongs() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        let s = await lib.add([dir])
        XCTAssertEqual(s.added, 6, "FLAC, MP3, WAV, AAC, ALAC, AIFF – notes.txt wird übergangen")
        XCTAssertEqual(s.skipped, 0)
        XCTAssertEqual(lib.roots.count, 1)
        XCTAssertEqual(lib.roots.first?.kind, .folder)
        XCTAssertEqual(lib.songs.count, 6)
        XCTAssertTrue(lib.songs.allSatisfy(\.isLocal))

        let morning = try XCTUnwrap(lib.albums.first { $0.name == "Morning Set" })
        XCTAssertEqual(morning.artist, "Lumenfold")
        XCTAssertEqual(morning.year, 2021)
        XCTAssertEqual(morning.songCount, 3)
        XCTAssertNotNil(morning.coverArt)
        XCTAssertTrue(morning.id.isLocalID)
        let tracks = lib.songs(ofAlbum: morning.id)
        XCTAssertEqual(tracks.map(\.title), ["Paper Boats", "Glass Harbor", "Quiet Field"], "Nummer aus Tag bzw. Dateiname")
        XCTAssertEqual(tracks.last?.album, "Morning Set", "ungetaggte WAV bekommt den Ordnernamen als Album")
        XCTAssertEqual(tracks.first?.formatBadge, "FLAC 16/48")

        let night = try XCTUnwrap(lib.albums.first { $0.name == "Night Drive" })
        XCTAssertEqual(night.artist, "Velvetine Static", "Albuminterpret:in, nicht „feat.“")
        XCTAssertEqual(lib.songs(ofAlbum: night.id).count, 2)
        XCTAssertEqual(lib.albums.count, 2, "Copper Sky hat kein Album (Single)")

        XCTAssertEqual(Set(lib.artists.map(\.name)), ["Lumenfold", "Velvetine Static", "Marigold Engine"])
        let velvet = try XCTUnwrap(lib.artists.first { $0.name == "Velvetine Static" })
        XCTAssertEqual(lib.songs.first { $0.title == "Tunnel Lights" }?.artistId, velvet.id)
        XCTAssertEqual(Set(lib.genres.map(\.value)), ["Ambient", "Synthwave"])

        // In der gemeinsamen Mediathek (ohne Server) wie Server-Musik
        let store = LibraryStore()
        store.local = lib
        XCTAssertEqual(store.albums.count, 2)
        XCTAssertEqual(store.songs.count, 6)
        XCTAssertEqual(store.album(morning.id)?.name, "Morning Set")
        XCTAssertEqual(store.songs(ofAlbum: night.id).map(\.title), ["Neon Rain", "Tunnel Lights"])
        XCTAssertEqual(store.albums(ofArtist: velvet.id).map(\.name), ["Night Drive"])
        XCTAssertEqual(store.songs(ofArtist: velvet.id).count, 2)
        XCTAssertEqual(store.composers.first?.name, "Ada Example")
        XCTAssertEqual(store.songs(ofGenre: "Synthwave").count, 2)

        // Suche findet lokale Titel, Alben, Künstler:innen
        XCTAssertEqual(lib.search("neon").songs.map(\.title), ["Neon Rain"])
        XCTAssertEqual(lib.search("Morning").albums.count, 1)
        XCTAssertEqual(lib.search("Marigold").artists.count, 1)

        // Favoriten bleiben auf dem Gerät
        let paper = try XCTUnwrap(lib.songs.first { $0.title == "Paper Boats" })
        let on = await store.toggleStar(song: paper)
        XCTAssertTrue(on)
        XCTAssertTrue(store.isStarred(song: paper.id))
        XCTAssertEqual(store.favoriteSongs.map(\.id), [paper.id])

        // Übersteht einen Neustart (gleiche IDs, gleicher Favorit)
        let again = makeLibrary()
        XCTAssertEqual(Set(again.songs.map(\.id)), Set(lib.songs.map(\.id)))
        XCTAssertEqual(again.albums.map(\.id).sorted(), lib.albums.map(\.id).sorted())
        XCTAssertTrue(again.isStarred(paper.id))

        // Gleichen Ordner noch einmal wählen → kein Duplikat
        let twice = await again.add([dir])
        XCTAssertEqual(twice.added, 0)
        XCTAssertEqual(twice.unchanged, 6)
        XCTAssertEqual(again.roots.count, 1)
    }

    // MARK: Bookmarks

    func testBookmarkIsStoredResolvedAndRenewedAfterMove() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        await lib.add([dir])
        let root = try XCTUnwrap(lib.roots.first)
        let bookmark = try XCTUnwrap(root.bookmark)
        XCTAssertFalse(bookmark.isEmpty)
        XCTAssertEqual(lib.resolve(root)?.standardizedFileURL.path, dir.standardizedFileURL.path)

        // Datei über das Bookmark öffnen; Zugriff bleibt offen, bis er nicht mehr gebraucht wird
        let song = try XCTUnwrap(lib.songs.first { $0.title == "Neon Rain" })
        let url = try lib.fileURL(for: song)
        XCTAssertTrue(TrackCache.canOpen(url))
        XCTAssertEqual(lib.openRootIDs, [root.id])
        lib.keepAccess(for: [song])
        XCTAssertEqual(lib.openRootIDs, [root.id])
        lib.keepAccess(for: [])
        XCTAssertTrue(lib.openRootIDs.isEmpty)

        // Ordner umbenennen: Bookmark findet ihn wieder, ist „stale“ und wird erneuert
        let moved = work.appending(path: "Renamed Music", directoryHint: .isDirectory)
        try fm.moveItem(at: dir, to: moved)
        let after = makeLibrary()
        let r2 = try XCTUnwrap(after.roots.first)
        let resolved = try XCTUnwrap(after.resolve(r2), "Bookmark folgt dem umbenannten Ordner")
        XCTAssertEqual(resolved.lastPathComponent, "Renamed Music")
        let renewed = try XCTUnwrap(after.roots.first)
        XCTAssertEqual(renewed.path, moved.standardizedFileURL.path, "Bookmark erneuert, Pfad aktualisiert")
        XCTAssertNotEqual(renewed.bookmark, bookmark)
        XCTAssertTrue(TrackCache.canOpen(try after.fileURL(for: song)))

        // Und ein Neu-Einlesen findet weiterhin alle Titel
        let s = await after.rescan(r2.id)
        XCTAssertEqual(s.unchanged, 6)
        XCTAssertEqual(s.removed, 0)
        after.keepAccess(for: [])
    }

    func testMissingFolderKeepsSongsAndReportsUnreachable() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        await lib.add([dir])
        try fm.removeItem(at: dir)
        let root = try XCTUnwrap(lib.roots.first)
        let s = await lib.rescan(root.id)
        XCTAssertEqual(s.unreachable, 1)
        XCTAssertEqual(lib.songs.count, 6, "nichts löschen, nur weil der Ordner gerade fehlt")
        XCTAssertTrue(lib.unreachable.contains(root.id))
        XCTAssertThrowsError(try lib.fileURL(for: lib.songs[0]))
    }

    // MARK: Neu einlesen, Entfernen

    func testRescanFindsNewAndDeletedFilesAndRemoveNeverDeletesOriginals() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        await lib.add([dir])
        let rootID = try XCTUnwrap(lib.roots.first?.id)
        let paperID = try XCTUnwrap(lib.songs.first { $0.title == "Paper Boats" }?.id)

        // Neue Datei in einem neuen Unterordner, eine gelöscht
        let demo = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
            .appending(path: "DemoAlbums/Tidal Rooms/01 - Low Tide.m4a")
        try fm.createDirectory(at: dir.appending(path: "Tidal Rooms"), withIntermediateDirectories: true)
        try fm.copyItem(at: demo, to: dir.appending(path: "Tidal Rooms/01 - Low Tide.m4a"))
        try fm.removeItem(at: dir.appending(path: "Morning Set/02 - Glass Harbor.mp3"))
        let s = await lib.rescan(rootID)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 1)
        XCTAssertEqual(s.unchanged, 5)
        XCTAssertNil(lib.songs.first { $0.title == "Glass Harbor" })
        XCTAssertNotNil(lib.albums.first { $0.name == "Tidal Rooms" })
        XCTAssertEqual(lib.songs.first { $0.title == "Paper Boats" }?.id, paperID, "unveränderte Titel behalten ihre ID")

        // Aus der Mediathek entfernen: Datei bleibt, kommt beim Neu-Einlesen nicht zurück
        let paper = try XCTUnwrap(lib.songs.first { $0.id == paperID })
        lib.remove(songs: [paper])
        XCTAssertNil(lib.songs.first { $0.id == paperID })
        XCTAssertTrue(fm.fileExists(atPath: dir.appending(path: "Morning Set/01 - Paper Boats.flac").path))
        let s2 = await lib.rescan(rootID)
        XCTAssertEqual(s2.added, 0)
        XCTAssertNil(lib.songs.first { $0.id == paperID })

        // Gleichen Ordner bewusst erneut hinzufügen → entfernte Titel sind wieder da
        await lib.add([dir])
        XCTAssertNotNil(lib.songs.first { $0.id == paperID })

        // Ganzen Ordner entfernen: Mediathek leer, alle Dateien noch da, Cover aufgeräumt
        lib.removeRoot(rootID)
        XCTAssertTrue(lib.isEmpty)
        XCTAssertTrue(lib.albums.isEmpty)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.appending(path: "Night Drive").path).count, 2)
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: lib.coversDirectory.path))?.count ?? 0, 0)
    }

    func testSingleFilesAreReferencedIndividually() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        let s = await lib.add([dir.appending(path: "Night Drive/01 - Neon Rain.m4a"), dir.appending(path: "Copper Sky.aiff")])
        XCTAssertEqual(s.added, 2)
        XCTAssertEqual(lib.roots.map(\.kind), [.file, .file])
        XCTAssertEqual(lib.albums.map(\.name), ["Night Drive"])
        let neon = try XCTUnwrap(lib.songs.first { $0.title == "Neon Rain" })
        XCTAssertTrue(TrackCache.canOpen(try lib.fileURL(for: neon)))
        lib.keepAccess(for: [])
        // Einzeldatei entfernen = Eintrag weg, Datei bleibt
        lib.remove(songs: [neon])
        XCTAssertEqual(lib.roots.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: dir.appending(path: "Night Drive/01 - Neon Rain.m4a").path))
    }

    /// „Öffnen in HomeTune“: kein Bookmark möglich → Kopie im App-Speicher, ohne Duplikate.
    func testReceivedFilesAreCopiedOnce() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        let inbox = work.appending(path: "Inbox", directoryHint: .isDirectory)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        try fm.copyItem(at: dir.appending(path: "Morning Set/01 - Paper Boats.flac"), to: inbox.appending(path: "01 - Paper Boats.flac"))
        let s = await lib.receive([inbox.appending(path: "01 - Paper Boats.flac")])
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(lib.roots.first?.kind, .copied)
        XCTAssertFalse(fm.fileExists(atPath: inbox.appending(path: "01 - Paper Boats.flac").path), "aus dem Posteingang verschoben")
        XCTAssertGreaterThan(lib.importedBytes, 0)
        // Gleiche Datei noch einmal (von außerhalb des Posteingangs) → keine zweite Kopie
        let s2 = await lib.receive([dir.appending(path: "Morning Set/01 - Paper Boats.flac")])
        XCTAssertEqual(s2.added, 0)
        XCTAssertEqual(lib.songs.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: dir.appending(path: "Morning Set/01 - Paper Boats.flac").path), "Original unangetastet")
        let song = try XCTUnwrap(lib.songs.first)
        XCTAssertTrue(TrackCache.canOpen(try lib.fileURL(for: song)))
        // Entfernen löscht nur die App-eigene Kopie
        lib.remove(songs: [song])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: lib.importedDirectory.path).count, 0)
        XCTAssertTrue(fm.fileExists(atPath: dir.appending(path: "Morning Set/01 - Paper Boats.flac").path))
    }

    // MARK: 432 Hz

    /// Lokale FLAC (440-Hz-Sinus) über das Bookmark öffnen, mit dem Decoder der Engine lesen und durch die
    /// 432-Hz-Kette rendern: 440 Hz muss 432 Hz ergeben. Danach live über die PlaybackEngine abspielen.
    func testLocalFLACPlaysIn432Hz() async throws {
        let dir = try fixtures()
        let lib = makeLibrary()
        await lib.add([dir])
        let song = try XCTUnwrap(lib.songs.first { $0.title == "Paper Boats" })
        let url = try lib.fileURL(for: song)
        defer { lib.keepAccess(for: []) }

        let m = Tuning432Tests()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: m.rate, channels: 2)!
        let dec = try TrackDecoder(url: url, outFormat: fmt)
        XCTAssertEqual(dec.duration, 3, accuracy: 0.01)
        let all = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(4 * m.rate))!
        while let b = dec.read(frames: 16384) {
            for ch in 0..<2 {
                all.floatChannelData![ch].advanced(by: Int(all.frameLength)).update(from: b.floatChannelData![ch], count: Int(b.frameLength))
            }
            all.frameLength += b.frameLength
        }
        XCTAssertEqual(Double(all.frameLength), 3 * m.rate, accuracy: 10)
        let out = try m.render(all, seconds: 3)
        let r = m.measure(Array(out.prefix(Int(2.9 * m.rate))))
        print("432-Messung lokal (FLAC): 440 Hz → \(String(format: "%.3f", r.freq)) Hz, Störabstand \(String(format: "%.1f", r.snr)) dB")
        XCTAssertEqual(r.freq, 432.0, accuracy: 0.1)
        XCTAssertGreaterThan(r.snr, 35)

        // Live: gleiche Engine wie in der App (TimePitch −31,77 Cent), Datei bleibt per Bookmark geöffnet
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        let engine = PlaybackEngine()
        var failed: Error?
        engine.onError = { _, e in failed = e }
        engine.load(url: url, token: 1, autoplay: true)
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertNil(failed)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.pitchCents, Tuning432.cents)
        XCTAssertEqual(engine.tempoRate, 1)
        XCTAssertEqual(engine.currentTime, 1.2, accuracy: 0.5)
        XCTAssertEqual(lib.openRootIDs.count, 1)
        engine.stop()
    }
}

/// `XCTUnwrap` für async-Ausdrücke.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
