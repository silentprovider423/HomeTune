import Foundation

/// Zentrale Ablageorte der App. Auf dem iPhone (eigener Container) unverändert wie bisher; auf dem Mac (ohne
/// Sandbox) zeigen die System-Ordner auf die gemeinsamen Benutzerordner – deshalb dort eigene Unterordner:
/// `~/Library/Application Support/HomeTune`, `~/Library/Caches/HomeTune` und als sichtbarer Musikordner
/// `~/Music/HomeTune` („Auf diesem Mac“). Die Debug-Variante nutzt „HomeTune Test“, Unit-Tests einen
/// temporären Ordner.
enum AppPaths {
    /// Name des App-Unterordners auf dem Mac
    static let macFolderName: String = {
        #if DEBUG
        "HomeTune Test"
        #else
        "HomeTune"
        #endif
    }()

    /// Läuft gerade ein XCTest-Lauf? (dann nie in echte Benutzerordner schreiben)
    static let isTesting: Bool = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    #if os(macOS)
    /// Gemeinsamer Wurzelordner für Tests (einmal je Prozess)
    private static let testRoot: URL = {
        let u = FileManager.default.temporaryDirectory.appending(path: "HomeTuneTests-\(ProcessInfo.processInfo.processIdentifier)",
                                                                  directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    #endif

    /// Interne Daten (Mediathek-Index, Downloads, lokale Mediathek)
    static var applicationSupport: URL {
        #if os(macOS)
        if isTesting { return testRoot.appending(path: "Support", directoryHint: .isDirectory) }
        return URL.applicationSupportDirectory.appending(path: macFolderName, directoryHint: .isDirectory)
        #else
        return URL.applicationSupportDirectory
        #endif
    }

    /// Zwischenspeicher (Cover, Titel-Cache) – darf jederzeit gelöscht werden
    static var caches: URL {
        #if os(macOS)
        if isTesting { return testRoot.appending(path: "Caches", directoryHint: .isDirectory) }
        return URL.cachesDirectory.appending(path: macFolderName, directoryHint: .isDirectory)
        #else
        return URL.cachesDirectory
        #endif
    }

    /// Sichtbarer App-Ordner für eigene Musik (iPhone: Dateien-App › HomeTune; Mac: ~/Music/HomeTune)
    static var appFolder: URL {
        #if os(macOS)
        if isTesting { return testRoot.appending(path: "Music", directoryHint: .isDirectory) }
        return URL.musicDirectory.appending(path: macFolderName, directoryHint: .isDirectory)
        #else
        return URL.documentsDirectory
        #endif
    }

    /// Löscht nur, wenn `url` wirklich innerhalb von `root` liegt (Schutz gegen „..“ oder Symlinks nach außen).
    @discardableResult
    static func removeItem(_ url: URL, inside root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        // Nur den Elternordner auflösen: ein Symlink selbst wird entfernt, nie sein Ziel
        let name = url.standardizedFileURL.lastPathComponent
        guard !name.isEmpty, name != "..", name != "." else { return false }
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let target = (parent as NSString).appendingPathComponent(name)
        guard target.hasPrefix(base + "/"), target != base else { return false }
        return (try? FileManager.default.removeItem(atPath: target)) != nil
    }
}
