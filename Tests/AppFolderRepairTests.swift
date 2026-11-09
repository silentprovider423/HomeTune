import XCTest
import Darwin
#if os(iOS)
@testable import HomeTune
#endif

/// HomeTune-Ordner: Rechte-Reparatur beim Start, Entfernen des Testordners vom Gerätetest (nur nachweislich unsere
/// Testdateien), Verschieben von Ordnern ohne Neu-Lesen, Import-Fortschritt mit Zwischenständen.
@MainActor
final class AppFolderRepairTests: XCTestCase {
    private let fm = FileManager.default
    /// Nicht am Testende freigeben (Swift-6-Falle beim isolierten deinit, siehe REGELN)
    private static var keepAlive: [LocalLibrary] = []
    private var work: URL!
    private var docs: URL { work.appending(path: "Documents", directoryHint: .isDirectory) }
    private var defaults: UserDefaults!

    override func setUp() async throws {
        work = fm.temporaryDirectory.appending(path: "repair-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "repair-\(UUID().uuidString)")
        LocalLibrary.changeMode = { chmod($0, $1) == 0 }
    }

    override func tearDown() async throws {
        LocalLibrary.changeMode = { chmod($0, $1) == 0 }
        LocalLibrary.checkpointEvery = 250
        LocalLibrary.afterCheckpoint = nil
        LocalLibrary.flushSaves()
        // Schreibschutz aufheben, damit alles gelöscht werden kann
        for rel in fm.subpaths(atPath: work.path) ?? [] { chmod(work.appending(path: rel).path, 0o755) }
        try? fm.removeItem(at: work)
    }

    private var bundleFixtures: URL {
        get throws { try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)) }
    }

    private func makeLibrary() -> LocalLibrary {
        LocalLibrary(directory: work.appending(path: "Store", directoryHint: .isDirectory), documents: docs)
    }

    private func mode(_ url: URL) -> mode_t {
        var st = stat()
        lstat(url.path, &st)
        return st.st_mode & 0o777
    }

    /// Falsche Rechte (Ordner ohne Schreibrecht, auch `.Trash`, schreibgeschützte Datei) blockieren Löschen und Verschieben
    /// in der Dateien-App – wie beim Gerätetest. Nach der Reparatur geht beides.
    func testRepairRestoresWritePermissions() async throws {
        let trash = docs.appending(path: ".Trash", directoryHint: .isDirectory)
        let locked = docs.appending(path: "Locked", directoryHint: .isDirectory)
        let other = docs.appending(path: "Playlists", directoryHint: .isDirectory)
        for d in [trash, locked, other] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try fm.copyItem(at: try bundleFixtures.appending(path: "LocalMusic/Copper Sky.aiff"), to: locked.appending(path: "Copper Sky.aiff"))
        chmod(locked.appending(path: "Copper Sky.aiff").path, 0o444)
        chmod(locked.path, 0o555)
        chmod(trash.path, 0o555)
        // Vorher: Verschieben in den Ordner bzw. in den Papierkorb scheitert (Zugriffsrechte)
        XCTAssertThrowsError(try fm.moveItem(at: other, to: locked.appending(path: "Playlists")))
        XCTAssertThrowsError(try fm.moveItem(at: locked, to: trash.appending(path: "Locked")))

        let lib = makeLibrary()
        let r = await lib.repairAppFolder(defaults: defaults)
        XCTAssertEqual(r.fixedPermissions, 3, "Locked, .Trash, Datei")
        XCTAssertTrue(r.foreign.isEmpty)
        XCTAssertEqual(mode(locked), 0o755)
        XCTAssertEqual(mode(trash), 0o755)
        XCTAssertEqual(mode(locked.appending(path: "Copper Sky.aiff")), 0o644)
        // Nachher: beides geht
        try fm.moveItem(at: other, to: locked.appending(path: "Playlists"))
        try fm.moveItem(at: locked, to: trash.appending(path: "Locked"))
        // Zweiter Lauf: nichts mehr zu tun
        let again = await lib.repairAppFolder(defaults: defaults)
        XCTAssertEqual(again.fixedPermissions, 0)
    }

    /// Testordner vom Gerätetest (genau unsere Fixture-Dateien) wird gelöscht und aus der Mediathek ausgetragen –
    /// auch der doppelte Eintrag aus dem damaligen Debug-Import (Ordner-Bookmark im HomeTune-Ordner).
    func testRemovesDeviceTestFolderAndStaleRoot() async throws {
        let test = docs.appending(path: "LocalMusic", directoryHint: .isDirectory)
        try fm.copyItem(at: try bundleFixtures.appending(path: "LocalMusic"), to: test)
        // Gespeicherte Mediathek wie auf dem Gerät: Ordner-Eintrag „LocalMusic“ (Bookmark) im HomeTune-Ordner
        let store = work.appending(path: "Store", directoryHint: .isDirectory)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let bookmark = try test.bookmarkData().base64EncodedString()
        let json = #"{"roots":[{"id":"r1","name":"LocalMusic","kind":"folder","path":"\#(test.standardizedFileURL.path)","added":0,"excluded":[],"bookmark":"\#(bookmark)"}],"tracks":[],"starred":[]}"#
        try Data(json.utf8).write(to: store.appending(path: "library.json"))
        let lib = makeLibrary()
        XCTAssertEqual(lib.roots.count, 1)
        await lib.rescanAll()
        XCTAssertEqual(lib.songs.count, 12, "vorher doppelt: 6 über den Ordner-Eintrag + 6 im HomeTune-Ordner")

        let r = await lib.repairAppFolder(defaults: defaults)
        XCTAssertEqual(r.removedTestFiles, 7)
        XCTAssertTrue(r.removedTestFolder)
        XCTAssertEqual(r.removedRoots, 1)
        XCTAssertFalse(fm.fileExists(atPath: test.path))
        XCTAssertTrue(lib.roots.isEmpty)
        await lib.rescanAll()
        XCTAssertTrue(lib.songs.isEmpty)
    }

    /// Fremde Dateien im Ordner „LocalMusic“ (andere Größe/Inhalt oder zusätzliche Musik) → nichts wird angefasst.
    func testKeepsLocalMusicFolderWithOtherFiles() async throws {
        let test = docs.appending(path: "LocalMusic", directoryHint: .isDirectory)
        try fm.copyItem(at: try bundleFixtures.appending(path: "LocalMusic"), to: test)
        try fm.copyItem(at: try bundleFixtures.appending(path: "LocalMusic/Copper Sky.aiff"), to: test.appending(path: "Meine Musik.aiff"))
        let lib = makeLibrary()
        let r = await lib.repairAppFolder(defaults: defaults)
        XCTAssertEqual(r.removedTestFiles, 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: test.path).count, 4)
        // Gleicher Name, aber anderer Inhalt
        try fm.removeItem(at: test.appending(path: "Meine Musik.aiff"))
        try Data(count: 12).write(to: test.appending(path: "Morning Set/notes.txt"))
        let r2 = await lib.repairAppFolder(defaults: defaults)
        XCTAssertEqual(r2.removedTestFiles, 0)
        XCTAssertTrue(fm.fileExists(atPath: test.appending(path: "Copper Sky.aiff").path))
    }

    /// Wie auf dem iPhone: „LocalMusic“ gehört root (Rechte nicht änderbar). Löschbares wird gelöscht, der Rest aus der
    /// Mediathek ausgeschlossen; ist der Ordner später leer (z. B. per devicectl geleert), entfernt die App ihn.
    func testRootOwnedTestFolderIsHiddenThenRemovedWhenEmpty() async throws {
        let test = docs.appending(path: "LocalMusic", directoryHint: .isDirectory)
        try fm.copyItem(at: try bundleFixtures.appending(path: "LocalMusic"), to: test)
        let lib = makeLibrary()
        await lib.rescan(LocalLibrary.appFolderRootID)
        XCTAssertEqual(lib.songs.count, 6)
        chmod(test.path, 0o555)
        let blocked = test.standardizedFileURL.path
        LocalLibrary.changeMode = { path, m in path == blocked ? false : chmod(path, m) == 0 }

        let r = await lib.repairAppFolder(defaults: defaults)
        XCTAssertEqual(r.removedTestFiles, 6, "Dateien in den Unterordnern")
        XCTAssertEqual(r.testLeftovers, ["LocalMusic/Copper Sky.aiff"])
        XCTAssertFalse(r.removedTestFolder)
        XCTAssertEqual(r.foreign, [], "eigener Ordner ohne Schreibrecht, nur nicht änderbar")
        XCTAssertTrue(lib.songs.isEmpty, "Testtitel aus der Mediathek ausgetragen")
        await lib.rescan(LocalLibrary.appFolderRootID)
        XCTAssertTrue(lib.songs.isEmpty, "nicht löschbarer Rest bleibt ausgeschlossen")

        // Ordner wurde von außen geleert (root) → beim nächsten Start entfernt
        chmod(test.path, 0o755)
        try fm.removeItem(at: test.appending(path: "Copper Sky.aiff"))
        for d in ["Morning Set", "Night Drive"] { try? fm.removeItem(at: test.appending(path: d)) }
        chmod(test.path, 0o555)
        let r2 = await lib.repairAppFolder(defaults: defaults)
        XCTAssertTrue(r2.removedTestFolder)
        XCTAssertFalse(fm.fileExists(atPath: test.path))
    }

    /// Ordner im HomeTune-Ordner verschieben: kein Neu-Lesen, IDs (und damit Playlists/Favoriten) bleiben.
    func testMovedFolderKeepsIDsWithoutRereading() async throws {
        try fm.copyItem(at: try bundleFixtures.appending(path: "LocalMusic"), to: docs.appending(path: "Music"))
        try "Music/Night Drive/01 - Neon Rain.m4a\nMusic/Morning Set/01 - Paper Boats.flac\n"
            .write(to: docs.appending(path: "Mix.m3u8"), atomically: true, encoding: .utf8)
        let lib = makeLibrary()
        _ = await lib.refreshAppFolderIfChanged()
        let ids = Dictionary(uniqueKeysWithValues: lib.songs.map { ($0.title, $0.id) })
        let neon = try XCTUnwrap(ids["Neon Rain"])
        lib.toggleStar(neon)
        XCTAssertEqual(lib.playlists.first?.songIDs.count, 2)

        try fm.createDirectory(at: docs.appending(path: "Archiv"), withIntermediateDirectories: true)
        try fm.moveItem(at: docs.appending(path: "Music/Night Drive"), to: docs.appending(path: "Archiv/Night Drive"))
        let s = try await XCTUnwrapAsync(await lib.refreshAppFolderIfChanged())
        XCTAssertEqual(s.moved, 2)
        XCTAssertEqual(s.added, 0)
        XCTAssertEqual(s.removed, 0)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: lib.songs.map { ($0.title, $0.id) }), ids, "gleiche IDs")
        XCTAssertTrue(lib.isStarred(neon))
        XCTAssertEqual(try lib.fileURL(for: try XCTUnwrap(lib.songs.first { $0.id == neon })).deletingLastPathComponent().lastPathComponent,
                       "Night Drive")
        XCTAssertTrue(TrackCache.canOpen(try lib.fileURL(for: try XCTUnwrap(lib.songs.first { $0.id == neon }))))
        XCTAssertEqual(lib.playlists.first?.songIDs.count, 2, "Playlist findet die verschobenen Titel")
        let none = await lib.refreshAppFolderIfChanged()
        XCTAssertNil(none, "Fingerabdruck stimmt nach dem Einlesen")
    }

    /// Großer Ordner: Fortschritt zählt die zu lesenden Dateien, Zwischenstände werden gespeichert (ein Abbruch verwirft
    /// nicht alles), danach Phase „Wird fertiggestellt“, und der Hauptthread bleibt frei.
    func testImportProgressCheckpointsAndFreeMainThread() async throws {
        let src = try bundleFixtures.appending(path: "LocalMusic")
        for i in 1...40 { try fm.copyItem(at: src, to: docs.appending(path: "Copy \(i)")) }   // 240 Titel
        LocalLibrary.checkpointEvery = 50
        let lib = makeLibrary()
        var partialOnDisk: [Int] = []
        LocalLibrary.afterCheckpoint = { [unowned self] in
            // „App beendet“ direkt nach dem Zwischenstand: neue Instanz liest, was gespeichert ist
            LocalLibrary.flushSaves()
            let reopened = self.makeLibrary()
            Self.keepAlive.append(reopened)
            partialOnDisk.append(reopened.songs.count)
        }
        var seen: [LocalLibrary.ImportProgress] = []
        let probe = HangProbe()
        probe.start()
        let scan = Task { await lib.rescan(LocalLibrary.appFolderRootID) }
        while true {
            if let p = lib.importProgress, seen.last != p { seen.append(p) }
            if lib.scanning == 0 && seen.count > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let s = await scan.value
        let hang = probe.take()
        probe.stop()
        print("Import 240 Titel: Fortschritt \(seen.count) Schritte, Zwischenstände auf Platte \(partialOnDisk), Hauptthread max. \(Int(hang.maxHang * 1000)) ms")
        XCTAssertEqual(s.added, 240)
        XCTAssertEqual(lib.songs.count, 240)
        XCTAssertGreaterThanOrEqual(lib.checkpoints, 4)
        XCTAssertTrue(partialOnDisk.contains { $0 > 0 && $0 < 240 }, "Zwischenstand gespeichert")
        XCTAssertEqual(seen.map(\.total).max(), 240)
        XCTAssertTrue(seen.contains { $0.done > 0 && $0.done < 240 }, "zählt hoch")
        XCTAssertTrue(seen.contains { $0.finishing }, "eigener Schritt „Wird fertiggestellt …“")
        XCTAssertNil(lib.importProgress, "danach weg")
        XCTAssertLessThan(hang.maxHang, 0.25)
        // Ohne Änderung: kein sichtbarer Import (nichts zu lesen)
        seen.removeAll()
        let again = Task { await lib.rescan(LocalLibrary.appFolderRootID) }
        while lib.scanning > 0 || seen.isEmpty {
            if let p = lib.importProgress { seen.append(p) }
            if lib.scanning == 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = await again.value
        XCTAssertTrue(seen.isEmpty)
    }
}
