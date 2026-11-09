import XCTest
#if os(iOS)
@testable import HomeTune
#endif

#if os(macOS)
/// Pfad-Falle am Mac (ohne Sandbox): App-Daten nur in eigenen Unterordnern, Löschen nie außerhalb des eigenen Ordners.
final class MacPathTests: XCTestCase {
    private let fm = FileManager.default

    func testOwnFoldersOnly() {
        // Unit-Tests schreiben nie in echte Benutzerordner
        XCTAssertTrue(AppPaths.isTesting)
        for u in [AppPaths.applicationSupport, AppPaths.caches, AppPaths.appFolder] {
            XCTAssertTrue(u.path.hasPrefix(fm.temporaryDirectory.path), u.path)
        }
        XCTAssertEqual(AppPaths.macFolderName, "HomeTune Test", "Debug-Build nutzt eigene Ordner")
    }

    func testRemoveItemStaysInsideRoot() throws {
        let base = fm.temporaryDirectory.appending(path: "HomeTunePathTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "root", directoryHint: .isDirectory)
        let outside = base.appending(path: "outside", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let keep = outside.appending(path: "keep.mp3")
        try Data([1]).write(to: keep)

        // „..“ und fremde Pfade werden abgelehnt
        XCTAssertFalse(AppPaths.removeItem(root.appending(path: "../outside/keep.mp3"), inside: root))
        XCTAssertFalse(AppPaths.removeItem(keep, inside: root))
        XCTAssertFalse(AppPaths.removeItem(root, inside: root), "der Wurzelordner selbst bleibt")
        XCTAssertTrue(fm.fileExists(atPath: keep.path))

        // Symlink im eigenen Ordner, der nach außen zeigt: nur der Link verschwindet, nie das Ziel
        let link = root.appending(path: "link.mp3")
        try fm.createSymbolicLink(at: link, withDestinationURL: keep)
        XCTAssertTrue(AppPaths.removeItem(link, inside: root))
        XCTAssertTrue(fm.fileExists(atPath: keep.path))

        // Ordner-Symlink nach außen: Datei „darin“ liegt in Wahrheit außerhalb → abgelehnt
        let dirLink = root.appending(path: "dirlink")
        try fm.createSymbolicLink(at: dirLink, withDestinationURL: outside)
        XCTAssertFalse(AppPaths.removeItem(dirLink.appending(path: "keep.mp3"), inside: root))
        XCTAssertTrue(fm.fileExists(atPath: keep.path))

        // Normale Datei im eigenen Ordner geht
        let mine = root.appending(path: "mine.mp3")
        try Data([2]).write(to: mine)
        XCTAssertTrue(AppPaths.removeItem(mine, inside: root))
        XCTAssertFalse(fm.fileExists(atPath: mine.path))
    }
}
#endif
