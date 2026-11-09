import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

extension String {
    /// IDs von Musik auf diesem iPhone (Titel, Alben, Künstler:innen, Cover) – kommen nie vom Server.
    var isLocalID: Bool { hasPrefix("local:") || hasPrefix("local-") }
}

extension Song {
    var isLocal: Bool { id.isLocalID }
}

/// Ein im Dateien-Dialog gewählter Ordner oder eine einzelne Datei. Gemerkt wird nur ein security-scoped
/// Bookmark – die Musik bleibt, wo sie ist (wie in der Frequenz-App: referenzieren statt kopieren).
/// `copied` = über „Öffnen in“/„Teilen“ empfangene Dateien (Mail, AirDrop …); dafür gibt es kein Bookmark, sie
/// liegen als Kopie im App-Speicher. `appFolder` = der eigene Ordner „HomeTune“ in der Dateien-App
/// (Documents/ der App, kein Bookmark nötig).
struct LocalRoot: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case folder, file, copied, appFolder }
    var id: String
    var name: String
    var kind: Kind
    var bookmark: Data?
    /// Zuletzt bekannter Pfad (Duplikat-Erkennung; wird nie angezeigt)
    var path: String
    var added: Date
    var lastScan: Date?
    /// Aus der Mediathek entfernte Dateien (relativer Pfad) – beim Neu-Einlesen nicht wieder aufnehmen
    var excluded: Set<String> = []
}

/// Ein Titel auf diesem iPhone: Ordner + relativer Pfad, Tags und Dateistand (für das Neu-Einlesen).
struct LocalTrack: Codable, Hashable, Sendable {
    var song: Song
    var root: String
    /// Pfad relativ zum Ordner ("" bei einer einzeln gewählten Datei)
    var rel: String
    var size: Int64
    var modified: Date?
    /// Ordner der Datei – trennt gleichnamige Alben ohne Albuminterpret:in
    var dir: String
    var albumArtist: String?
    var added: Date
}

/// Rückmeldung nach dem Einlesen.
struct LocalScanSummary: Sendable, Equatable {
    var added = 0
    var removed = 0
    var unchanged = 0
    var skipped = 0
    var inCloud = 0
    var unreachable = 0
    /// Verschobene Dateien (neuer Pfad, gleiche Datei) – ohne neues Lesen übernommen, in `unchanged` enthalten
    var moved = 0
    /// Neu importierte Playlists („x von y Titeln gefunden“)
    var playlists: [PlaylistImportResult] = []

    static func + (a: Self, b: Self) -> Self {
        Self(added: a.added + b.added, removed: a.removed + b.removed, unchanged: a.unchanged + b.unchanged,
             skipped: a.skipped + b.skipped, inCloud: a.inCloud + b.inCloud, unreachable: a.unreachable + b.unreachable,
             moved: a.moved + b.moved, playlists: a.playlists + b.playlists)
    }
}

enum LocalError: LocalizedError {
    case missing, noAccess

    var errorDescription: String? {
        switch self {
        case .missing: String(localized: "Datei nicht gefunden – wurde sie verschoben oder gelöscht?")
        case .noAccess: String(localized: "Kein Zugriff auf den Ordner. Bitte erneut hinzufügen.")
        }
    }
}

/// „Auf diesem iPhone“: der HomeTune-Ordner in der Dateien-App, Musik aus dem Dateien-Dialog (Ordner/Dateien
/// per Bookmark) und über „Öffnen in“ empfangene Dateien, dazu eigene Playlists. Liest Tags lokal, bildet
/// Alben/Künstler:innen wie die Server-Mediathek und liefert der PlaybackEngine die Originaldatei – also in der
/// gewählten Stimmung, offline und ohne Server-Anmeldung.
@MainActor @Observable
final class LocalLibrary {
    /// Gemerkte Ordner/Dateien und empfangene Dateien (ohne den HomeTune-Ordner)
    private(set) var roots: [LocalRoot] = []
    /// Fester Eintrag „HomeTune-Ordner“ (Documents/ der App, in der Dateien-App unter „Auf meinem iPhone“)
    private(set) var appFolder = LocalRoot(id: LocalLibrary.appFolderRootID, name: "HomeTune", kind: .appFolder,
                                           bookmark: nil, path: "", added: Date())
    private(set) var playlists: [LocalPlaylist] = []
    /// Gelöschte Playlists aus Ordner-Dateien – beim Neu-Einlesen nicht wieder anlegen
    @ObservationIgnored private var dismissedSources: Set<String> = []
    private(set) var tracks: [String: LocalTrack] = [:]
    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var genres: [Genre] = []
    private(set) var starred: Set<String> = []
    /// Ordner, deren Bookmark sich nicht mehr auflösen/lesen ließ
    private(set) var unreachable: Set<String> = []
    private(set) var scanning = 0
    /// Fortschritt beim Einlesen: gelesene neue/geänderte Dateien von allen, die gelesen werden müssen
    private(set) var scanDone = 0
    private(set) var scanTotal = 0
    /// Abschnitt des Einlesens (Dateien lesen → Mediathek fertigstellen)
    private(set) var scanPhase: ScanPhase = .idle

    enum ScanPhase: Sendable { case idle, reading, finishing }

    /// Sichtbarer Import-Fortschritt (Balken in der Mediathek und „Auf diesem iPhone“) – nur, wenn wirklich Dateien
    /// gelesen werden, nicht beim schnellen Abgleich ohne Änderungen.
    struct ImportProgress: Equatable { var done: Int; var total: Int; var finishing: Bool }
    var importProgress: ImportProgress? {
        guard scanning > 0, importing else { return nil }
        return ImportProgress(done: scanDone, total: scanTotal, finishing: scanPhase == .finishing)
    }
    /// Im laufenden Einlesen werden Dateien gelesen (nicht nur abgeglichen)
    private(set) var importing = false

    /// Interne Daten (nicht in der Dateien-App sichtbar): Application Support/Local
    let directory: URL
    /// Der HomeTune-Ordner (Documents/ der App, per Dateifreigabe sichtbar)
    let documentsDirectory: URL
    var coversDirectory: URL { directory.appending(path: "Covers", directoryHint: .isDirectory) }
    var importedDirectory: URL { directory.appending(path: "Imported", directoryHint: .isDirectory) }
    /// Posteingang von iOS für „Öffnen in“-Kopien – zählt nicht als Musikordner
    var inboxDirectory: URL { documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory) }
    static let importedRootID = "imported"
    static let appFolderRootID = "documents"

    /// Offene security-scoped Zugriffe (Ordner des laufenden und des vorgeladenen Titels)
    @ObservationIgnored private var open: [String: (url: URL, scoped: Bool)] = [:]

    init(directory: URL = AppPaths.applicationSupport.appending(path: "Local", directoryHint: .isDirectory),
         documents: URL = AppPaths.appFolder) {
        self.directory = directory
        documentsDirectory = documents
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        appFolder.path = documents.standardizedFileURL.path
        load()
    }

    /// Alle Einträge für „Auf diesem iPhone“: HomeTune-Ordner zuerst
    var allRoots: [LocalRoot] { [appFolder] + roots }

    func root(_ id: String) -> LocalRoot? { id == Self.appFolderRootID ? appFolder : roots.first { $0.id == id } }

    private func updateRoot(_ id: String, _ body: (inout LocalRoot) -> Void) {
        if id == Self.appFolderRootID { body(&appFolder) }
        else if let i = roots.firstIndex(where: { $0.id == id }) { body(&roots[i]) }
    }

    /// Liegt der Titel im HomeTune-Ordner (Datei gehört der App, Löschen möglich)?
    func isInAppFolder(_ song: Song) -> Bool { tracks[song.id]?.root == Self.appFolderRootID }

    var isEmpty: Bool { tracks.isEmpty }
    var isScanning: Bool { scanning > 0 }
    var openRootIDs: Set<String> { Set(open.keys) }

    // MARK: Speichern

    private struct Stored: Codable, Sendable {
        var roots: [LocalRoot]
        var tracks: [LocalTrack]
        var starred: Set<String>
        var playlists: [LocalPlaylist]?
        var appFolder: LocalRoot?
        var dismissedPlaylistSources: Set<String>?
    }

    private var storeURL: URL { directory.appending(path: "library.json") }

    /// Speichern läuft nacheinander im Hintergrund (Kodieren von Tausenden Titeln blockiert sonst den Hauptthread)
    nonisolated private static let saveQueue = DispatchQueue(label: "hometune.local.save", qos: .utility)

    /// Wartet, bis alle angestoßenen Speichervorgänge geschrieben sind.
    nonisolated static func flushSaves() { saveQueue.sync {} }

    private func load() {
        Self.flushSaves()
        guard let d = try? Data(contentsOf: storeURL), let s = try? JSONDecoder().decode(Stored.self, from: d) else { return }
        roots = s.roots.filter { $0.kind != .appFolder }
        if let a = s.appFolder { appFolder.excluded = a.excluded; appFolder.lastScan = a.lastScan; appFolder.added = a.added }
        tracks = Dictionary(s.tracks.map { ($0.song.id, $0) }, uniquingKeysWith: { a, _ in a })
        starred = s.starred
        playlists = s.playlists ?? []
        dismissedSources = s.dismissedPlaylistSources ?? []
        rebuild()
    }

    private func save() {
        let s = Stored(roots: roots, tracks: Array(tracks.values), starred: starred, playlists: playlists, appFolder: appFolder,
                       dismissedPlaylistSources: dismissedSources)
        let url = storeURL
        Self.saveQueue.async {
            if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
        }
    }

    // MARK: Hinzufügen (Dateien-Dialog)

    /// Ordner und/oder Dateien aus dem Dateien-Dialog übernehmen: je Auswahl ein Bookmark, Ordner rekursiv.
    /// Wird ein schon bekannter Ordner erneut gewählt, wird er neu eingelesen (Bookmark erneuert).
    @discardableResult
    func add(_ urls: [URL]) async -> LocalScanSummary {
        var total = LocalScanSummary()
        // Playlists zuletzt, damit sie die gleichzeitig gewählten Titel schon finden
        let audioFirst = urls.filter { !PlaylistFile.isPlaylist($0) } + urls.filter(PlaylistFile.isPlaylist)
        for url in audioFirst {
            if PlaylistFile.isPlaylist(url) {
                if let r = importPlaylist(at: url) { total.playlists.append(r) } else { total.skipped += 1 }
                continue
            }
            // Datei/Ordner im HomeTune-Ordner: gehört schon dazu → nur neu einlesen
            if isInsideAppFolder(url) {
                total = total + (await rescan(Self.appFolderRootID))
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { total.skipped += 1; continue }
            let path = url.standardizedFileURL.path
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if let i = roots.firstIndex(where: { $0.kind != .copied && $0.path == path }) {
                if let bookmark { roots[i].bookmark = bookmark }
                roots[i].excluded = []
                total = total + (await scan(rootID: roots[i].id, url: url))
                continue
            }
            // Datei liegt in einem schon bekannten Ordner → dort neu einlesen statt doppelt aufnehmen
            if !isDir.boolValue, let r = roots.first(where: { $0.kind == .folder && path.hasPrefix($0.path + "/") }) {
                if let i = roots.firstIndex(of: r) { roots[i].excluded.remove(String(path.dropFirst(r.path.count + 1))) }
                total = total + (await rescan(r.id))
                continue
            }
            guard let bookmark else { total.skipped += 1; continue }
            let root = LocalRoot(id: UUID().uuidString, name: url.lastPathComponent, kind: isDir.boolValue ? .folder : .file,
                                 bookmark: bookmark, path: path, added: Date())
            roots.append(root)
            let s = await scan(rootID: root.id, url: url)
            total = total + s
            if !tracks.values.contains(where: { $0.root == root.id }) {
                // Nichts Abspielbares gefunden → Eintrag nicht behalten
                roots.removeAll { $0.id == root.id }
            }
        }
        save()
        return total
    }

    // MARK: Empfangen („Öffnen in“ / „Teilen“)

    /// Muss die eingehende Datei kopiert werden? Nur echte Posteingangs-Kopien (Mail, AirDrop, „Teilen“ aus
    /// anderen Apps → Documents/Inbox bzw. tmp der App). Dateien aus der Dateien-App kommen dank
    /// LSSupportsOpeningDocumentsInPlace als Original (security-scoped) und werden wie im Dialog referenziert.
    func needsCopy(_ url: URL) -> Bool {
        #if os(macOS)
        // Mac (ohne Sandbox): alles wird referenziert, nie kopiert
        return false
        #else
        let path = url.standardizedFileURL.path
        if path.hasPrefix(inboxDirectory.standardizedFileURL.path + "/") { return true }
        if path.contains("/Inbox/") || path.contains("-Inbox/") { return true }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        return path.hasPrefix(home + "/") && !isInsideAppFolder(url)
        #endif
    }

    /// Kopie im Posteingang (iOS „Öffnen in“), die verschoben statt kopiert wird. Mac: nie – dort wird außerhalb
    /// des eigenen Ordners nichts verschoben oder gelöscht.
    nonisolated static func isInboxCopy(_ url: URL) -> Bool {
        #if os(macOS)
        return false
        #else
        return url.path.contains("/Inbox/") || url.path.contains("-Inbox/")
        #endif
    }

    func isInsideAppFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let docs = documentsDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let inbox = inboxDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return (path == docs || path.hasPrefix(docs + "/")) && !path.hasPrefix(inbox + "/") && path != inbox
    }

    /// „Öffnen in“ / „Teilen“: Playlists importieren, Dateien aus der Dateien-App per Bookmark referenzieren,
    /// nur Posteingangs-Dateien kopieren.
    @discardableResult
    func open(_ urls: [URL]) async -> LocalScanSummary {
        var total = LocalScanSummary()
        let copies = urls.filter { needsCopy($0) && !PlaylistFile.isPlaylist($0) }
        if !copies.isEmpty { total = total + (await receive(copies)) }
        let inPlace = urls.filter { !copies.contains($0) }
        if !inPlace.isEmpty { total = total + (await add(inPlace)) }
        // Playlists aus dem Posteingang wurden gelesen – Kopie wegräumen
        for u in urls where PlaylistFile.isPlaylist(u) && needsCopy(u) { try? FileManager.default.removeItem(at: u) }
        return total
    }

    /// Eingehende Dateien in den App-Speicher übernehmen (kein Bookmark möglich → Kopie, aus dem Posteingang
    /// verschoben). Gleiche Datei (Name + Größe) wird nicht doppelt abgelegt.
    @discardableResult
    func receive(_ urls: [URL]) async -> LocalScanSummary {
        let fm = FileManager.default
        try? fm.createDirectory(at: importedDirectory, withIntermediateDirectories: true)
        var skipped = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard TagReader.isAudio(url) else { skipped += 1; continue }
            // iOS legt „Öffnen in“-Dateien als Kopie in Documents/Inbox ab → verschieben statt nochmal kopieren
            let inbox = Self.isInboxCopy(url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent
            var target = importedDirectory.appending(path: url.lastPathComponent)
            var n = 2
            var duplicate = false
            while fm.fileExists(atPath: target.path) {
                if let size, (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == size { duplicate = true; break }
                target = importedDirectory.appending(path: "\(base) \(n).\(ext)")
                n += 1
            }
            if duplicate {
                if inbox { try? fm.removeItem(at: url) }
                continue
            }
            do {
                if inbox { try fm.moveItem(at: url, to: target) } else { try fm.copyItem(at: url, to: target) }
            } catch {
                skipped += 1
            }
        }
        if !roots.contains(where: { $0.id == Self.importedRootID }) {
            roots.append(LocalRoot(id: Self.importedRootID, name: String(localized: "Empfangene Dateien"), kind: .copied,
                                   bookmark: nil, path: importedDirectory.path, added: Date()))
        }
        var s = await scan(rootID: Self.importedRootID, url: importedDirectory)
        s.skipped += skipped
        save()
        return s
    }

    // MARK: Umzug beim Update (Documents/ ist jetzt sichtbar)

    static let migrationKey = "migration.documents.v1"

    /// Einmalig: Documents/ ist ab 1.1 der sichtbare HomeTune-Ordner. Interne Dateien, die dort aus älteren
    /// Fassungen oder Debug-Importen liegen könnten (Cover, Kopien, Datenbank), nach Application Support
    /// verschieben; liegengebliebene „Öffnen in“-Kopien aus Documents/Inbox als empfangene Dateien übernehmen.
    @discardableResult
    func migrateDocuments(defaults: UserDefaults = .standard) async -> Int {
        guard !defaults.bool(forKey: Self.migrationKey) else { return 0 }
        #if os(macOS)
        // Mac: kein Altbestand – im sichtbaren Musikordner nie etwas verschieben
        defaults.set(true, forKey: Self.migrationKey)
        return 0
        #else
        let fm = FileManager.default
        var moved = 0
        let internalItems: [(name: String, to: URL)] = [("Covers", coversDirectory), ("Imported", importedDirectory),
                                                   ("library.json", storeURL), ("Local", directory)]
        for item in internalItems {
            let src = documentsDirectory.appending(path: item.name)
            guard fm.fileExists(atPath: src.path) else { continue }
            if item.name == "Local" || !fm.fileExists(atPath: item.to.path) {
                if item.name == "Local" {
                    // Inhalt einzeln übernehmen, Vorhandenes nicht überschreiben
                    for f in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                        let dst = directory.appending(path: f.lastPathComponent)
                        if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: f, to: dst) }
                    }
                    try? fm.removeItem(at: src)
                } else {
                    try? fm.createDirectory(at: item.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.moveItem(at: src, to: item.to)
                }
                moved += 1
            } else if let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
                for f in files where !fm.fileExists(atPath: item.to.appending(path: f.lastPathComponent).path) {
                    try? fm.moveItem(at: f, to: item.to.appending(path: f.lastPathComponent))
                }
                try? fm.removeItem(at: src)
                moved += 1
            }
        }
        if moved > 0 { load() }
        let inbox = (try? fm.contentsOfDirectory(at: inboxDirectory, includingPropertiesForKeys: nil)) ?? []
        let audio = inbox.filter(TagReader.isAudio)
        if !audio.isEmpty { await receive(audio); moved += audio.count }
        for f in inbox where PlaylistFile.isPlaylist(f) {
            _ = importPlaylist(at: f)
            try? fm.removeItem(at: f)
            moved += 1
        }
        defaults.set(true, forKey: Self.migrationKey)
        return moved
        #endif
    }

    // MARK: Rechte im HomeTune-Ordner, Testreste

    /// Ergebnis der Prüfung beim Start
    struct AppFolderRepair: Sendable, Equatable {
        /// Einträge, deren Rechte ergänzt wurden (Ordner u+rwx, Dateien u+rw)
        var fixedPermissions = 0
        /// Einträge, die nicht der App gehören und nicht beschreibbar sind (z. B. root) – lassen sich nicht reparieren
        var foreign: [String] = []
        /// Gelöschte Testdateien vom Gerätetest (LocalMusic)
        var removedTestFiles = 0
        /// Testdateien, die sich nicht löschen ließen (relativ zu Documents) – werden aus der Mediathek ausgeschlossen
        var testLeftovers: [String] = []
        var removedTestFolder = false
        /// Entfernte Einträge aus dem Dateien-Dialog, die im HomeTune-Ordner liegen (doppelt eingelesen)
        var removedRoots = 0
    }

    /// Testordner vom Gerätetest am 08.11. (Debug-Hook HOMETUNE_LOCAL_IMPORT=Documents/LocalMusic): genau diese Dateien
    /// (Name, Größe, SHA-256-Anfang) aus Tests/Fixtures/LocalMusic. Nur wenn der Ordner ausschließlich daraus besteht, wird
    /// er gelöscht – nie fremde Musik.
    nonisolated static let testFolderName = "LocalMusic"
    nonisolated static let testFolderFiles: [String: (size: Int, sha: String)] = [
        "Copper Sky.aiff": (88390, "7da0e31da92facc8"),
        "Morning Set/01 - Paper Boats.flac": (50636, "e80045b3cb73fd84"),
        "Morning Set/02 - Glass Harbor.mp3": (27669, "ce7f4413aa5597a2"),
        "Morning Set/03 - Quiet Field.wav": (88278, "00e509b455e8b32e"),
        "Morning Set/notes.txt": (12, "e7dad54d16f192e1"),
        "Night Drive/01 - Neon Rain.m4a": (21029, "119d0adba38fcc8a"),
        "Night Drive/02 - Tunnel Lights.m4a": (39023, "9a7fde7f217d6147"),
    ]
    static let testFolderSeenKey = "cleanup.testLocalMusic.v1"

    /// Rechte ändern (Tests ersetzen das, um einen root-eigenen Ordner nachzustellen)
    nonisolated(unsafe) static var changeMode: (String, mode_t) -> Bool = { chmod($0, $1) == 0 }

    /// Beim Start: Rechte im HomeTune-Ordner reparieren (auch `.Trash`), den Testordner vom Gerätetest entfernen
    /// (nur nachweislich unsere Testdateien) und aus der Mediathek austragen.
    @discardableResult
    func repairAppFolder(defaults: UserDefaults = .standard) async -> AppFolderRepair {
        let docs = documentsDirectory
        let seen = defaults.bool(forKey: Self.testFolderSeenKey)
        var r = await Task.detached(priority: .utility) { Self.repair(documents: docs, testFolderSeen: seen) }.value
        if r.removedTestFiles > 0 || !r.testLeftovers.isEmpty || r.removedTestFolder { defaults.set(true, forKey: Self.testFolderSeenKey) }
        // Ordner/Dateien aus dem Dateien-Dialog, die im HomeTune-Ordner liegen: sind schon über den festen Eintrag
        // da (sonst doppelt, z. B. LocalMusic vom Gerätetest)
        for root in roots where root.kind == .folder || root.kind == .file {
            if isInsideAppFolder(URL(fileURLWithPath: root.path)) || Self.sameContainerPath(root.path, docs.path) {
                removeRoot(root.id)
                r.removedRoots += 1
            }
        }
        // Testdateien aus der Mediathek: gelöschte verschwinden beim nächsten Einlesen, nicht löschbare ausschließen
        let leftovers = Set(r.testLeftovers)
        if !leftovers.isEmpty {
            appFolder.excluded.formUnion(leftovers)
        }
        let prefix = Self.testFolderName + "/"
        let testRels = Set(Self.testFolderFiles.keys.map { prefix + $0 })
        let gone = tracks.values.filter { $0.root == Self.appFolderRootID && testRels.contains($0.rel)
            && (leftovers.contains($0.rel) || !FileManager.default.fileExists(atPath: docs.appending(path: $0.rel).path)) }
        if !gone.isEmpty || !leftovers.isEmpty || r.removedRoots > 0 {
            for t in gone { tracks[t.song.id] = nil; starred.remove(t.song.id) }
            rebuild()
            cleanupCovers()
            save()
        }
        return r
    }

    /// Gleicher Pfad im App-Container, auch wenn sich der Container-Pfad geändert hat (…/Application/<UUID>/Documents/…).
    nonisolated static func sameContainerPath(_ path: String, _ docs: String) -> Bool {
        func tail(_ p: String) -> String? {
            guard let r = p.range(of: "/Documents/") ?? (p.hasSuffix("/Documents") ? p.range(of: "/Documents", options: .backwards) : nil),
                  let app = p[..<r.lowerBound].split(separator: "/").last else { return nil }
            return String(app) + String(p[r.lowerBound...])
        }
        guard let a = tail(path), let b = tail(docs.hasSuffix("/") ? docs : docs + "/") else { return false }
        return a.hasPrefix(b.hasSuffix("/") ? b : b + "/") || a + "/" == b
    }

    nonisolated private static func repair(documents docs: URL, testFolderSeen: Bool) -> AppFolderRepair {
        var r = AppFolderRepair()
        let fm = FileManager.default
        let uid = getuid()
        // 1. Rechte: alles, was der App gehört, muss für sie les- und schreibbar sein (Ordner u+rwx, Dateien u+rw)
        func fix(_ path: String, rel: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            let type = st.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { return }
            let need: mode_t = type == S_IFDIR ? S_IRWXU : (S_IRUSR | S_IWUSR)
            if st.st_uid == uid {
                if st.st_mode & need != need, changeMode(path, (st.st_mode & 0o7777) | need) { r.fixedPermissions += 1 }
            } else if Darwin.access(path, W_OK) != 0 {
                r.foreign.append(rel)
            }
        }
        fix(docs.path, rel: "")
        if let en = fm.enumerator(at: docs, includingPropertiesForKeys: nil, options: []) {
            let base = docs.standardizedFileURL.path + "/"
            for case let u as URL in en {
                autoreleasepool {
                    let p = u.standardizedFileURL.path
                    fix(p, rel: p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p)
                }
            }
        }
        // 2. Testordner vom Gerätetest: nur löschen, wenn er ausschließlich unsere Testdateien enthält
        let test = docs.appending(path: testFolderName, directoryHint: .isDirectory)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: test.path, isDirectory: &isDir), isDir.boolValue else { return r }
        var files: [String] = [], dirs: [String] = []
        let base = test.standardizedFileURL.path + "/"
        if let en = fm.enumerator(at: test, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            for case let u as URL in en {
                let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.append(rel) }
                else if u.lastPathComponent != ".DS_Store" { files.append(rel) }
            }
        }
        let ours = files.allSatisfy { rel in
            guard let known = testFolderFiles[rel],
                  let size = (try? fm.attributesOfItem(atPath: test.appending(path: rel).path))?[.size] as? Int, size == known.size,
                  let data = try? Data(contentsOf: test.appending(path: rel)) else { return false }
            return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined() == known.sha
        }
        // Leerer Rest nur, wenn wir ihn früher schon als Testordner erkannt haben
        guard ours && (!files.isEmpty || testFolderSeen) else { return r }
        for rel in files {
            if (try? fm.removeItem(at: test.appending(path: rel))) != nil { r.removedTestFiles += 1 }
            else { r.testLeftovers.append(testFolderName + "/" + rel) }
        }
        try? fm.removeItem(at: test.appending(path: ".DS_Store"))
        for rel in dirs.sorted(by: { $0.count > $1.count }) { try? fm.removeItem(at: test.appending(path: rel)) }
        if (try? fm.removeItem(at: test)) != nil { r.removedTestFolder = true }
        return r
    }

    // MARK: Neu einlesen

    /// Ordner erneut durchsuchen: neue Dateien aufnehmen, gelöschte entfernen, Unverändertes behalten.
    @discardableResult
    func rescan(_ rootID: String) async -> LocalScanSummary {
        guard let root = root(rootID) else { return .init() }
        if root.kind == .copied { return await scan(rootID: rootID, url: importedDirectory) }
        if root.kind == .appFolder { return await scan(rootID: rootID, url: documentsDirectory) }
        guard let url = resolve(root) else {
            unreachable.insert(rootID)
            return LocalScanSummary(unreachable: 1)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return await scan(rootID: rootID, url: url)
    }

    @discardableResult
    func rescanAll() async -> LocalScanSummary {
        var total = LocalScanSummary()
        for r in allRoots { total = total + (await rescan(r.id)) }
        return total
    }

    // MARK: HomeTune-Ordner beobachten

    /// Fingerabdruck des HomeTune-Ordners beim letzten Einlesen (gleiches Format wie `fingerprint`)
    @ObservationIgnored private var appFolderStamp: String?

    /// Ein Eintrag im Fingerabdruck
    nonisolated static func stampPart(_ url: URL, size: Int?, modified: Date?) -> String {
        "\(url.path)|\(size ?? 0)|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    /// Kurzer Fingerabdruck (Namen, Größen, Änderungszeiten der Musik- und Playlist-Dateien) – billig genug für
    /// Abfragen alle paar Sekunden, solange die App offen ist.
    nonisolated static func fingerprint(of dir: URL, skipping inbox: URL) -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return "" }
        var parts: [String] = []
        let inboxPath = inbox.standardizedFileURL.path
        for case let f as URL in en {
            if f.standardizedFileURL.path == inboxPath { en.skipDescendants(); continue }
            guard TagReader.isAudio(f) || PlaylistFile.isPlaylist(f) else { continue }
            let v = try? f.resourceValues(forKeys: Set(keys))
            parts.append(stampPart(f, size: v?.fileSize, modified: v?.contentModificationDate))
        }
        return parts.sorted().joined(separator: "\n")
    }

    /// HomeTune-Ordner neu einlesen, wenn sich dort etwas geändert hat (beim Start, im Vordergrund, Beobachter).
    @discardableResult
    func refreshAppFolderIfChanged() async -> LocalScanSummary? {
        let dir = documentsDirectory, inbox = inboxDirectory
        let stamp = await Task.detached(priority: .utility) { Self.fingerprint(of: dir, skipping: inbox) }.value
        guard stamp != appFolderStamp else { return nil }
        let s = await rescan(Self.appFolderRootID)
        // Das Einlesen hat seinen eigenen Stand gemerkt; fehlt er (Ordner nicht lesbar), diesen nehmen
        if appFolderStamp == nil { appFolderStamp = stamp }
        return s
    }

    /// Laufende Einlesevorgänge je Ordner – ein Ordner wird nie zweimal gleichzeitig durchsucht
    @ObservationIgnored private var scanChains: [String: Task<LocalScanSummary, Never>] = [:]

    /// Durchsucht einen Ordner (bzw. eine Datei) im Hintergrund und übernimmt das Ergebnis.
    private func scan(rootID: String, url: URL) async -> LocalScanSummary {
        let previous = scanChains[rootID]
        let task = Task { @MainActor [weak self] () -> LocalScanSummary in
            _ = await previous?.value
            guard let self else { return .init() }
            return await self.performScan(rootID: rootID, url: url)
        }
        scanChains[rootID] = task
        let r = await task.value
        if scanChains[rootID] == task { scanChains[rootID] = nil }
        return r
    }

    private func performScan(rootID: String, url: URL) async -> LocalScanSummary {
        guard let root = root(rootID) else { return .init() }
        scanning += 1
        scanPhase = .reading
        defer {
            scanning -= 1
            if scanning == 0 { scanPhase = .idle; scanDone = 0; scanTotal = 0; importing = false }
        }
        let existing = Dictionary(tracks.values.filter { $0.root == rootID }.map { ($0.rel, $0) }, uniquingKeysWith: { a, _ in a })
        let coversDir = coversDirectory
        let skip = root.kind == .appFolder ? inboxDirectory : nil
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self else { return }
                if total > 0 { self.importing = true }
                self.scanDone = done
                self.scanTotal = total
            }
        }
        // Zwischenstände: frisch gelesene Titel gleich übernehmen und sichern – ein Abbruch verwirft nicht alles
        let checkpoint: @Sendable ([LocalTrack]) async -> Void = { [weak self] batch in
            await self?.mergeCheckpoint(batch)
        }
        let every = Self.checkpointEvery
        let result = await Task.detached(priority: .userInitiated) {
            await Self.scanFiles(rootID: root.id, kind: root.kind, url: url, excluded: root.excluded, existing: existing,
                                 coversDir: coversDir, skip: skip, checkpointEvery: every, progress: progress, checkpoint: checkpoint)
        }.value
        guard result.reachable else {
            // Ordner nicht lesbar (Zugriff verweigert/verschoben): Titel behalten, nichts löschen
            unreachable.insert(rootID)
            return LocalScanSummary(unreachable: 1)
        }
        // Fertigstellen: Alben/Künstler:innen bilden, Playlists zuordnen, Cover aufräumen, speichern – alles
        // Schwere im Hintergrund, hier nur Zuweisungen
        scanPhase = .finishing
        unreachable.remove(rootID)
        var all = tracks.filter { $0.value.root != rootID }
        for t in result.tracks { all[t.song.id] = t }
        tracks = all
        if rootID == Self.appFolderRootID, let stamp = result.stamp { appFolderStamp = stamp }
        updateRoot(rootID) { $0.lastScan = Date() }
        starred = starred.filter { tracks[$0] != nil || !$0.hasPrefix("local:") }
        await rebuildInBackground()
        var summary = result.summary
        summary.playlists = await syncPlaylists(rootID: rootID, files: result.playlists)
        await cleanupCoversInBackground()
        save()
        return summary
    }

    /// Zwischenstand nach so vielen neu gelesenen Titeln (bzw. spätestens alle 4 s)
    static var checkpointEvery = 250
    /// Nur Tests: nach jedem gespeicherten Zwischenstand
    static var afterCheckpoint: (@MainActor () -> Void)?
    @ObservationIgnored private(set) var checkpoints = 0

    /// Zwischenstand während des Einlesens übernehmen (neue Titel erscheinen schon, Speichern im Hintergrund).
    private func mergeCheckpoint(_ batch: [LocalTrack]) {
        guard !batch.isEmpty else { return }
        for t in batch { tracks[t.song.id] = t }
        Task { await rebuildInBackground() }
        save()
        checkpoints += 1
        Self.afterCheckpoint?()
    }

    private struct ScanResult: Sendable {
        var tracks: [LocalTrack]
        var summary: LocalScanSummary
        var reachable: Bool
        /// Playlist-Dateien im Ordner (relativer Pfad, Inhalt)
        var playlists: [(rel: String, data: Data)] = []
        /// Fingerabdruck aus demselben Durchlauf (nur Ordner)
        var stamp: String?
    }

    /// Eine Datei im durchsuchten Ordner
    private struct FileItem: Sendable {
        var url: URL
        var rel: String
        var size: Int64
        var modified: Date?
    }

    /// So viele Dateien werden gleichzeitig gelesen (Tags, Cover)
    nonisolated static var readWidth: Int { max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 1)) }

    nonisolated private static func scanFiles(rootID: String, kind: LocalRoot.Kind, url: URL, excluded: Set<String>,
                                              existing: [String: LocalTrack], coversDir: URL, skip: URL?, checkpointEvery: Int,
                                              progress: @escaping @Sendable (Int, Int) -> Void,
                                              checkpoint: @escaping @Sendable ([LocalTrack]) async -> Void) async -> ScanResult {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                         .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var files: [FileItem] = []
        var playlistFiles: [(rel: String, data: Data)] = []
        var stampParts: [String] = []
        var summary = LocalScanSummary()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return ScanResult(tracks: [], summary: .init(), reachable: false) }
        if isDir.boolValue {
            guard (try? fm.contentsOfDirectory(atPath: url.path)) != nil,
                  let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                return ScanResult(tracks: [], summary: .init(), reachable: false)
            }
            let base = url.standardizedFileURL.path.hasSuffix("/") ? url.standardizedFileURL.path : url.standardizedFileURL.path + "/"
            let skipPath = skip?.standardizedFileURL.path
            while let f = en.nextObject() as? URL {
                autoreleasepool {
                    let path = f.standardizedFileURL.path
                    if let skipPath, path == skipPath { en.skipDescendants(); return }
                    var rel = path
                    if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
                    let playlist = PlaylistFile.isPlaylist(f)
                    guard playlist || TagReader.isAudio(f) else { return }
                    let rv = try? f.resourceValues(forKeys: keys)
                    stampParts.append(stampPart(f, size: rv?.fileSize, modified: rv?.contentModificationDate))
                    if playlist {
                        if let d = try? Data(contentsOf: f), d.count < 4_000_000 { playlistFiles.append((rel, d)) }
                        return
                    }
                    if excluded.contains(rel) { return }
                    // iCloud-Platzhalter: noch nicht auf dem iPhone → laden anstoßen, Bekanntes behalten
                    if rv?.isUbiquitousItem == true, let st = rv?.ubiquitousItemDownloadingStatus, st != .current {
                        try? fm.startDownloadingUbiquitousItem(at: f)
                        summary.inCloud += 1
                        files.append(FileItem(url: f, rel: rel, size: -1, modified: nil))
                        return
                    }
                    files.append(FileItem(url: f, rel: rel, size: Int64(rv?.fileSize ?? 0), modified: rv?.contentModificationDate))
                }
            }
            // Feste Reihenfolge (einfacher Vergleich – lokalisiertes Sortieren kostet bei Tausenden Dateien spürbar Zeit)
            files.sort { $0.rel < $1.rel }
        } else {
            guard fm.isReadableFile(atPath: url.path) else { return ScanResult(tracks: [], summary: .init(), reachable: false) }
            if TagReader.isAudio(url) {
                let rv = try? url.resourceValues(forKeys: keys)
                files = [FileItem(url: url, rel: "", size: Int64(rv?.fileSize ?? 0), modified: rv?.contentModificationDate)]
            }
        }

        // 1. Bekanntes übernehmen. Verschobene Dateien (gleicher Name, gleiche Größe und Änderungszeit, alter Pfad
        //    verschwunden) behalten Tags, Cover und ihre ID – Playlists und Favoriten bleiben gültig, nichts wird neu gelesen.
        let present = Set(files.map(\.rel))
        var movedCandidates: [String: [LocalTrack]] = [:]
        for t in existing.values where !present.contains(t.rel) {
            movedCandidates[identity(name: (t.rel as NSString).lastPathComponent, size: t.size, modified: t.modified), default: []].append(t)
        }
        var out: [LocalTrack] = []
        var todo: [FileItem] = []
        var usedIDs = Set<String>()
        for f in files {
            if f.size < 0 {
                if let old = existing[f.rel] { out.append(old); usedIDs.insert(old.song.id) }
                continue
            }
            if let old = existing[f.rel], old.size == f.size, old.modified == f.modified {
                out.append(old)
                usedIDs.insert(old.song.id)
                summary.unchanged += 1
                continue
            }
            let key = identity(name: f.url.lastPathComponent, size: f.size, modified: f.modified)
            if existing[f.rel] == nil, var list = movedCandidates[key], !list.isEmpty {
                var t = list.removeFirst()
                movedCandidates[key] = list
                t.rel = f.rel
                t.dir = trackDir(kind: kind, rootID: rootID, rel: f.rel, file: f.url)
                out.append(t)
                usedIDs.insert(t.song.id)
                summary.unchanged += 1
                summary.moved += 1
                continue
            }
            todo.append(f)
        }

        // 2. Neue und geänderte Dateien lesen – mehrere gleichzeitig, jede in eigenem Autorelease-Pool (Speicher bleibt flach)
        let total = todo.count
        // IDs vorab festlegen: an eine verschobene Datei vergebene ID nicht doppelt verwenden
        let ids: [String] = todo.map { f in
            let id = "local:" + hash(rootID + "\n" + f.rel)
            return usedIDs.contains(id) ? "local:" + hash(rootID + "\n" + f.rel + "\n2") : id
        }
        progress(0, total)
        let now = Date()
        let folderCovers = FolderCoverCache()
        var fresh: [LocalTrack?] = Array(repeating: nil, count: total)
        if total > 0 {
            var batch: [LocalTrack] = []
            var lastCheckpoint = Date()
            await withTaskGroup(of: (Int, LocalTrack?).self) { group in
                var next = 0
                func enqueue() {
                    guard next < total else { return }
                    let i = next, f = todo[i], id = ids[i]
                    let old = existing[f.rel]
                    next += 1
                    group.addTask(priority: .userInitiated) {
                        (i, await readTrack(f, id: id, rootID: rootID, kind: kind, coversDir: coversDir, added: old?.added ?? now,
                                            folderCovers: folderCovers))
                    }
                }
                for _ in 0..<min(readWidth, total) { enqueue() }
                var done = 0
                for await (i, t) in group {
                    done += 1
                    fresh[i] = t
                    if let t { batch.append(t) }
                    if done % 5 == 0 || done == total { progress(done, total) }
                    if batch.count >= checkpointEvery || (!batch.isEmpty && Date().timeIntervalSince(lastCheckpoint) > 4) {
                        await checkpoint(batch)
                        batch.removeAll()
                        lastCheckpoint = Date()
                    }
                    enqueue()
                }
            }
        }
        for (i, f) in todo.enumerated() {
            guard let t = fresh[i] else { summary.skipped += 1; continue }
            out.append(t)
            if existing[f.rel] == nil { summary.added += 1 } else { summary.unchanged += 1 }
        }
        let kept = Set(out.map(\.song.id))
        summary.removed = existing.values.filter { !kept.contains($0.song.id) }.count
        return ScanResult(tracks: out, summary: summary, reachable: true, playlists: playlistFiles,
                          stamp: isDir.boolValue ? stampParts.sorted().joined(separator: "\n") : nil)
    }

    nonisolated private static func identity(name: String, size: Int64, modified: Date?) -> String {
        "\(name)|\(size)|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    nonisolated private static func trackDir(kind: LocalRoot.Kind, rootID: String, rel: String, file: URL) -> String {
        switch kind {
        case .folder, .appFolder: rootID + "/" + (rel as NSString).deletingLastPathComponent
        case .file: file.deletingLastPathComponent().standardizedFileURL.path
        case .copied: rootID
        }
    }

    /// Eine Datei lesen: Tags, Cover (verkleinert, einmal je Bild), Titel bauen.
    nonisolated private static func readTrack(_ f: FileItem, id: String, rootID: String, kind: LocalRoot.Kind, coversDir: URL, added: Date,
                                              folderCovers: FolderCoverCache) async -> LocalTrack? {
        guard var tags = await TagReader.read(f.url) else { return nil }
        let artwork = tags.artwork
        tags.artwork = nil
        return autoreleasepool {
            let parentDir = f.url.deletingLastPathComponent()
            var cover: String?
            if let artwork { cover = storeCover(artwork, in: coversDir) }
            if cover == nil, kind != .file {
                // Ordner-Cover (cover.jpg, folder.jpg …) einmal je Ordner suchen
                cover = folderCovers.cover(for: parentDir.path) {
                    folderCover(in: parentDir).flatMap { storeCover($0, in: coversDir) }
                }
            }
            return makeTrack(tags: tags, file: f.url, id: id, rootID: rootID, rel: f.rel, kind: kind, size: f.size, modified: f.modified,
                             dir: trackDir(kind: kind, rootID: rootID, rel: f.rel, file: f.url), cover: cover, added: added)
        }
    }

    /// ISO8601DateFormatter ist threadsicher; einmal anlegen statt je Titel (teuer)
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    nonisolated private static func makeTrack(tags: LocalTags, file: URL, id: String, rootID: String, rel: String, kind: LocalRoot.Kind,
                                              size: Int64, modified: Date?, dir: String, cover: String?, added: Date) -> LocalTrack {
        let name = TagReader.fromFilename(file.lastPathComponent)
        var album = tags.album
        // Ganz ungetaggte Datei im Ordner → Ordnername als Album (getaggte Einzeltitel ohne Album bleiben „Single“)
        if album == nil, tags.title == nil, tags.artist == nil, kind == .folder || (kind == .appFolder && rel.contains("/")) {
            album = TagReader.clean(file.deletingLastPathComponent().lastPathComponent)
        }
        var song = Song(id: id, title: tags.title ?? name.title, album: album,
                        artist: tags.artist, track: tags.track ?? name.track,
                        duration: Int(tags.duration.rounded()), suffix: file.pathExtension.lowercased())
        song.discNumber = tags.discNumber
        song.year = tags.year
        song.genre = tags.genre
        song.coverArt = cover
        song.size = Int(size)
        song.samplingRate = tags.sampleRate
        song.bitDepth = tags.bitDepth
        song.channelCount = tags.channels
        song.bitRate = tags.bitRate
        song.displayComposer = tags.composer
        song.created = isoFormatter.string(from: added)
        return LocalTrack(song: song, root: rootID, rel: rel, size: size, modified: modified, dir: dir,
                          albumArtist: tags.albumArtist, added: added)
    }

    nonisolated static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func folderCover(in dir: URL) -> Data? {
        for name in ["cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "front.png", "album.jpg"] {
            if let d = try? Data(contentsOf: dir.appending(path: name)), !d.isEmpty { return d }
        }
        return nil
    }

    /// Cover verkleinert (max. 600 px) unter seinem Inhalts-Hash ablegen – gleiche Bilder nur einmal.
    /// ImageIO dekodiert gleich verkleinert (kein Vollbild im Speicher, auch bei 3000-px-Covern).
    nonisolated static func storeCover(_ data: Data, in dir: URL) -> String? {
        let h = SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined()
        let file = dir.appending(path: h + ".jpg")
        if FileManager.default.fileExists(atPath: file.path) { return "local-cover:" + h }
        // Gleiches Cover wird gerade von einer parallel gelesenen Datei (gleiches Album) verkleinert → nicht doppelt
        // rechnen und nicht warten: die ID steht schon fest, die Datei kommt gleich
        guard coversInProgress.begin(h) else { return "local-cover:" + h }
        defer { coversInProgress.end(h) }
        return makeCover(data, file: file, dir: dir, hash: h)
    }

    nonisolated private static let coversInProgress = InProgressSet()

    nonisolated private static func makeCover(_ data: Data, file: URL, dir: URL, hash h: String) -> String? {
        autoreleasepool { () -> String? in
            guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(src) > 0 else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceShouldCacheImmediately: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 600]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), img.width > 0 else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? (out as Data).write(to: file, options: .atomic)
            return "local-cover:" + h
        }
    }

    private var usedCovers: Set<String> {
        Set(tracks.values.compactMap { $0.song.coverArt?.replacingOccurrences(of: "local-cover:", with: "") })
    }

    /// Nicht mehr benutzte Cover löschen (sofort; bei Entfernen-Aktionen).
    private func cleanupCovers() {
        Self.removeUnusedCovers(in: coversDirectory, used: usedCovers, olderThan: Date())
    }

    /// Wie `cleanupCovers`, aber im Hintergrund (nach dem Einlesen).
    private func cleanupCoversInBackground() async {
        let used = usedCovers, dir = coversDirectory, now = Date()
        await Task.detached(priority: .utility) { Self.removeUnusedCovers(in: dir, used: used, olderThan: now) }.value
    }

    /// Cover, die erst nach `olderThan` entstanden sind (paralleles Einlesen), bleiben.
    nonisolated private static func removeUnusedCovers(in dir: URL, used: Set<String>, olderThan: Date) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        for f in files where !used.contains(f.deletingPathExtension().lastPathComponent) {
            let m = (try? f.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if m <= olderThan { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: Bookmarks und Zugriff

    /// Bookmark auflösen; ist es veraltet („stale“, z. B. Ordner verschoben/umbenannt), wird es erneuert.
    func resolve(_ root: LocalRoot) -> URL? {
        if root.kind == .copied { return importedDirectory }
        if root.kind == .appFolder { return documentsDirectory }
        guard let bm = root.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { renewBookmark(root.id, url) }
        return url
    }

    private func renewBookmark(_ id: String, _ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let i = roots.firstIndex(where: { $0.id == id }),
              let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        roots[i].bookmark = bm
        roots[i].path = url.standardizedFileURL.path
        save()
    }

    /// Originaldatei eines Titels zum Abspielen. Öffnet den security-scoped Zugriff auf den Ordner; er bleibt
    /// offen, bis `keepAccess(for:)` ihn nicht mehr braucht (Engine öffnet die Datei beim Springen neu).
    func fileURL(for song: Song) throws -> URL {
        guard let t = tracks[song.id], let root = root(t.root) else { throw LocalError.missing }
        let base: URL
        if root.kind == .copied {
            base = importedDirectory
        } else if root.kind == .appFolder {
            base = documentsDirectory
        } else if let o = open[root.id] {
            base = o.url
        } else {
            guard let url = resolve(root) else { throw LocalError.noAccess }
            let scoped = url.startAccessingSecurityScopedResource()
            open[root.id] = (url, scoped)
            base = url
        }
        let url = t.rel.isEmpty ? base : base.appending(path: t.rel)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalError.missing }
        return url
    }

    /// Zugriff nur für die Ordner dieser Titel offen halten (laufender + vorgeladener), alle anderen beenden.
    func keepAccess(for songs: [Song]) {
        let needed = Set(songs.compactMap { tracks[$0.id]?.root })
        for (id, o) in open where !needed.contains(id) {
            if o.scoped { o.url.stopAccessingSecurityScopedResource() }
            open[id] = nil
        }
    }

    // MARK: Entfernen (Originaldateien bleiben immer unangetastet)

    /// Titel aus der Mediathek nehmen. Bei Ordnern wird die Datei gemerkt, damit sie beim Neu-Einlesen nicht
    /// zurückkommt; nur bei empfangenen Kopien wird die App-eigene Kopie gelöscht. Im HomeTune-Ordner auf
    /// Wunsch (`deleteAppFolderFiles`) auch die Datei selbst – sie gehört der App.
    func remove(songs: [Song], deleteAppFolderFiles: Bool = false) {
        for s in songs {
            guard let t = tracks[s.id], let root = root(t.root) else { continue }
            switch root.kind {
            case .folder: updateRoot(root.id) { $0.excluded.insert(t.rel) }
            case .file: closeAccess(root.id); roots.removeAll { $0.id == root.id }
            case .copied: AppPaths.removeItem(importedDirectory.appending(path: t.rel), inside: importedDirectory)
            case .appFolder:
                if deleteAppFolderFiles {
                    // nur innerhalb des eigenen HomeTune-Ordners, nie außerhalb
                    AppPaths.removeItem(documentsDirectory.appending(path: t.rel), inside: documentsDirectory)
                } else {
                    appFolder.excluded.insert(t.rel)
                }
            }
            tracks[s.id] = nil
            starred.remove(s.id)
        }
        rebuild()
        cleanupCovers()
        save()
    }

    /// Ordner/Datei-Eintrag samt Titeln entfernen.
    func removeRoot(_ id: String) {
        // Der HomeTune-Ordner ist ein fester Eintrag
        guard id != Self.appFolderRootID, let root = roots.first(where: { $0.id == id }) else { return }
        closeAccess(id)
        if root.kind == .copied { AppPaths.removeItem(importedDirectory, inside: directory) }
        let gone = Set(tracks.values.filter { $0.root == id }.map(\.song.id))
        tracks = tracks.filter { !gone.contains($0.key) }
        starred.subtract(gone)
        roots.removeAll { $0.id == id }
        playlists.removeAll { $0.source?.hasPrefix(id + "/") == true && !$0.edited }
        unreachable.remove(id)
        rebuild()
        cleanupCovers()
        save()
    }

    func removeAll() {
        for r in roots { removeRoot(r.id) }
        tracks = [:]
        playlists = []
        appFolder.excluded = []
        rebuild()
        save()
    }

    private func closeAccess(_ id: String) {
        if let o = open.removeValue(forKey: id), o.scoped { o.url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Playlists (nur auf dem Gerät)

    func playlist(_ id: String) -> LocalPlaylist? { playlists.first { $0.id == id } }

    @discardableResult
    func createPlaylist(name: String, comment: String? = nil, songIDs: [String] = []) -> LocalPlaylist {
        let p = LocalPlaylist(name: name, comment: TagReader.clean(comment), songIDs: songIDs)
        playlists.append(p)
        save()
        return p
    }

    /// Name, Beschreibung und komplette Reihenfolge speichern. Eine aus einer Datei importierte Playlist folgt der
    /// Datei danach nicht mehr (die Änderung soll bleiben).
    func updatePlaylist(_ id: String, name: String? = nil, comment: String? = nil, songIDs: [String]? = nil) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        if let name { playlists[i].name = name }
        if let comment { playlists[i].comment = TagReader.clean(comment) }
        if let songIDs { playlists[i].songIDs = songIDs }
        playlists[i].changed = Date()
        playlists[i].edited = true
        save()
    }

    func addToPlaylist(_ id: String, songIDs: [String]) {
        guard let p = playlist(id) else { return }
        updatePlaylist(id, songIDs: p.songIDs + songIDs)
    }

    func removeFromPlaylist(_ id: String, at indexes: IndexSet) {
        guard var ids = playlist(id)?.songIDs else { return }
        ids.remove(atOffsets: IndexSet(indexes.filter { $0 < ids.count }))
        updatePlaylist(id, songIDs: ids)
    }

    func deletePlaylist(_ id: String) {
        if let src = playlist(id)?.source { dismissedSources.insert(src) }
        playlists.removeAll { $0.id == id }
        save()
    }

    /// Zuordnung über alle Titel auf diesem iPhone (Dateiname, Ordnernamen, Tags).
    private func matcher() -> PlaylistMatcher { PlaylistMatcher(matcherInputs().map(Self.candidate)) }

    /// Rohdaten für die Zuordnung (billig, auf dem Hauptthread); das Normalisieren passiert in `candidate`.
    private func matcherInputs() -> [(id: String, path: String, title: String, artist: String?)] {
        tracks.values.map { t in
            let r = root(t.root)
            let path: String = switch r?.kind {
            case .file: r?.path ?? t.song.title
            case .folder, .appFolder: (r?.name ?? "") + "/" + t.rel
            default: t.rel
            }
            return (t.song.id, path, t.song.title, t.song.artist)
        }
    }

    nonisolated private static func candidate(_ i: (id: String, path: String, title: String, artist: String?)) -> PlaylistMatcher.Candidate {
        PlaylistMatcher.Candidate(songID: i.id, components: PlaylistMatcher.components(of: i.path), title: i.title, artist: i.artist)
    }

    /// Wie `rematchPlaylists`, aber Zuordnen im Hintergrund (Tausende Titel × alle Playlist-Einträge).
    private func rematchPlaylistsInBackground() async {
        let open = playlists.filter { $0.entries != nil && !$0.edited }.map { ($0.id, $0.entries!) }
        guard !open.isEmpty else { return }
        let inputs = matcherInputs()
        let matched = await Task.detached(priority: .userInitiated) { () -> [String: [String]] in
            let m = PlaylistMatcher(inputs.map(Self.candidate))
            var out: [String: [String]] = [:]
            for (id, entries) in open { out[id] = m.match(PlaylistFile.Parsed(name: nil, entries: entries)).ids }
            return out
        }.value
        for i in playlists.indices where !playlists[i].edited {
            guard let ids = matched[playlists[i].id] else { continue }
            if ids != playlists[i].songIDs { playlists[i].songIDs = ids; playlists[i].changed = Date() }
        }
    }

    /// .m3u/.m3u8/.pls (Dateien-Dialog, „Öffnen in“) einlesen und als Playlist anlegen bzw. aktualisieren.
    func importPlaylist(at url: URL) -> PlaylistImportResult? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parsed = PlaylistFile.parse(data, ext: url.pathExtension)
        guard !parsed.entries.isEmpty else { return nil }
        let name = parsed.name ?? TagReader.clean(url.deletingPathExtension().lastPathComponent) ?? url.lastPathComponent
        let ids = matcher().match(parsed).ids
        let source = "file:" + url.standardizedFileURL.path
        if let i = playlists.firstIndex(where: { $0.source == source && !$0.edited }) {
            playlists[i].songIDs = ids
            playlists[i].entries = parsed.entries
            playlists[i].changed = Date()
        } else {
            var p = LocalPlaylist(name: name, songIDs: ids, source: source)
            p.entries = parsed.entries
            playlists.append(p)
        }
        save()
        return PlaylistImportResult(name: name, found: ids.count, total: parsed.entries.count)
    }

    /// Playlist-Dateien eines Ordners übernehmen: neue anlegen, geänderte neu zuordnen, verschwundene entfernen
    /// (außer hier bearbeitete). Liefert die neu angelegten. Lesen und Zuordnen laufen im Hintergrund.
    private func syncPlaylists(rootID: String, files: [(rel: String, data: Data)]) async -> [PlaylistImportResult] {
        var created: [String] = []
        let prefix = rootID + "/"
        var seen = Set<String>()
        let parsedFiles = await Task.detached(priority: .userInitiated) {
            files.map { f in (rel: f.rel, parsed: PlaylistFile.parse(f.data, ext: (f.rel as NSString).pathExtension)) }
        }.value
        for f in parsedFiles {
            let source = prefix + f.rel
            seen.insert(source)
            guard !dismissedSources.contains(source) else { continue }
            let parsed = f.parsed
            guard !parsed.entries.isEmpty else { continue }
            if let i = playlists.firstIndex(where: { $0.source == source }) {
                if !playlists[i].edited { playlists[i].entries = parsed.entries }
            } else {
                let base = ((f.rel as NSString).lastPathComponent as NSString).deletingPathExtension
                var p = LocalPlaylist(name: parsed.name ?? base, source: source)
                p.entries = parsed.entries
                playlists.append(p)
                created.append(p.id)
            }
        }
        playlists.removeAll { p in
            guard let src = p.source, src.hasPrefix(prefix), !p.edited else { return false }
            return !seen.contains(src)
        }
        await rematchPlaylistsInBackground()
        return created.compactMap { id in
            playlist(id).map { PlaylistImportResult(name: $0.name, found: $0.songIDs.count, total: $0.entries?.count ?? 0) }
        }
    }

    // MARK: Favoriten (nur auf dem Gerät)

    func isStarred(_ id: String) -> Bool { starred.contains(id) }

    @discardableResult
    func toggleStar(_ id: String) -> Bool {
        let on = !starred.contains(id)
        if on { starred.insert(id) } else { starred.remove(id) }
        save()
        return on
    }

    // MARK: Abfragen

    func album(_ id: String) -> Album? { albums.first { $0.id == id } }
    func artist(_ id: String) -> Artist? { artists.first { $0.id == id } }

    func songs(ofAlbum id: String) -> [Song] {
        songs.filter { $0.albumId == id }.sorted {
            ($0.discNumber ?? 1, $0.track ?? 0, $0.title) < ($1.discNumber ?? 1, $1.track ?? 0, $1.title)
        }
    }

    func songs(ofRoot id: String) -> [Song] {
        let ids = Set(tracks.values.filter { $0.root == id }.map(\.song.id))
        return songs.filter { ids.contains($0.id) }
    }

    func trackCount(root id: String) -> Int { tracks.values.reduce(0) { $0 + ($1.root == id ? 1 : 0) } }

    /// Neueste Alben zuerst (für „Zuletzt hinzugefügt“).
    var recentAlbums: [Album] { albums.sorted { ($0.created ?? "", $0.name) > ($1.created ?? "", $1.name) } }

    var importedBytes: Int64 {
        tracks.values.filter { $0.root == Self.importedRootID }.reduce(0) { $0 + $1.size }
    }

    func search(_ q: String) -> SubsonicClient.SearchResult {
        guard !q.isEmpty else { return .init() }
        return .init(artists: artists.filter { $0.name.localizedStandardContains(q) },
                     albums: albums.filter { $0.name.localizedStandardContains(q) || ($0.artist ?? "").localizedStandardContains(q) },
                     songs: songs.filter {
                         $0.title.localizedStandardContains(q) || ($0.artist ?? "").localizedStandardContains(q)
                             || ($0.album ?? "").localizedStandardContains(q)
                     })
    }

    // MARK: Alben, Künstler:innen, Genres bilden

    nonisolated private static func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func artistID(_ name: String) -> String { "local-artist:" + hash(norm(name)) }

    /// Ergebnis von `buildIndex`
    private struct Index: Sendable {
        var songs: [Song], albums: [Album], artists: [Artist], genres: [Genre]
    }
    @ObservationIgnored private var indexGeneration = 0

    /// Sofort (kleine Änderungen wie Entfernen)
    private func rebuild() {
        indexGeneration += 1
        apply(Self.buildIndex(Array(tracks.values), starred: starred))
    }

    /// Im Hintergrund (Einlesen); ein späterer Aufruf gewinnt
    private func rebuildInBackground() async {
        indexGeneration += 1
        let gen = indexGeneration
        let list = Array(tracks.values), st = starred
        let idx = await Task.detached(priority: .userInitiated) { Self.buildIndex(list, starred: st) }.value
        guard gen == indexGeneration else { return }
        apply(idx)
    }

    private func apply(_ idx: Index) {
        songs = idx.songs
        albums = idx.albums
        artists = idx.artists
        genres = idx.genres
    }

    nonisolated private static func buildIndex(_ tracks: [LocalTrack], starred: Set<String>) -> Index {
        var list = tracks
        list.sort { ($0.song.discNumber ?? 1, $0.song.track ?? 0, $0.song.title) < ($1.song.discNumber ?? 1, $1.song.track ?? 0, $1.song.title) }
        let iso = isoFormatter
        // Alben: gleicher Name + gleiche:r Albuminterpret:in, sonst gleicher Ordner (Sampler ohne Albuminterpret:in)
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        // Ungetaggte Titel im selben Ordner gehören zum gleichnamigen Album mit Albuminterpret:in
        var dirArtist: [String: String] = [:]
        for t in list {
            if let a = t.song.album, let aa = t.albumArtist { dirArtist[Self.norm(a) + "|" + t.dir] = dirArtist[Self.norm(a) + "|" + t.dir] ?? aa }
        }
        for (i, t) in list.enumerated() {
            guard let a = t.song.album else { continue }
            if t.albumArtist == nil, t.song.artist == nil, let aa = dirArtist[Self.norm(a) + "|" + t.dir] { list[i].albumArtist = aa }
            let key = Self.norm(a) + "|" + (list[i].albumArtist.map { "a:" + Self.norm($0) } ?? "d:" + t.dir)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }
        var newAlbums: [Album] = []
        for key in order {
            let idx = groups[key] ?? []
            let ts = idx.map { list[$0] }
            guard let first = ts.first, let name = first.song.album else { continue }
            let id = "local-album:" + Self.hash(key)
            let names = Set(ts.compactMap(\.song.artist))
            let display = first.albumArtist ?? (names.count <= 1 ? first.song.artist : String(localized: "Verschiedene Interpret:innen"))
            let multi = first.albumArtist == nil && names.count > 1
            var album = Album(id: id, name: name, artist: display, artistId: multi ? nil : display.map(Self.artistID),
                              coverArt: ts.lazy.compactMap(\.song.coverArt).first, year: ts.compactMap(\.song.year).max())
            album.songCount = ts.count
            album.duration = ts.reduce(0) { $0 + ($1.song.duration ?? 0) }
            album.genre = ts.lazy.compactMap(\.song.genre).first
            album.created = ts.map(\.added).min().map { iso.string(from: $0) }
            album.isCompilation = multi
            if starred.contains(id) { album.starred = album.created }
            newAlbums.append(album)
            for i in idx { list[i].song.albumId = id }
        }
        // Titel: Künstler:in-Seite = Albuminterpret:in (sonst Interpret:in)
        var artistNames: [String: (name: String, cover: String?, albums: Set<String>)] = [:]
        for i in list.indices {
            let t = list[i]
            guard let name = t.albumArtist ?? t.song.artist else { continue }
            let id = Self.artistID(name)
            list[i].song.artistId = id
            var e = artistNames[id] ?? (name, nil, [])
            if e.cover == nil { e.cover = t.song.coverArt }
            if let al = list[i].song.albumId { e.albums.insert(al) }
            artistNames[id] = e
            if starred.contains(t.song.id) { list[i].song.starred = t.song.created }
        }
        let songs = list.map(\.song).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let albums = newAlbums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let artists: [Artist] = artistNames.map { id, e in
            var a = Artist(id: id, name: e.name, coverArt: e.cover, albumCount: e.albums.count, starred: nil, album: nil)
            if starred.contains(id) { a.starred = "" }
            return a
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var g: [String: (songs: Int, albums: Set<String>)] = [:]
        for s in songs {
            guard let genre = s.genre else { continue }
            var e = g[genre] ?? (0, [])
            e.songs += 1
            if let a = s.albumId { e.albums.insert(a) }
            g[genre] = e
        }
        let genres = g.map { Genre(value: $0.key, songCount: $0.value.songs, albumCount: $0.value.albums.count) }
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
        return Index(songs: songs, albums: albums, artists: artists, genres: genres)
    }
}

/// Cover von Musik auf diesem iPhone (aus den Tags oder cover.jpg), im Speicher zwischengespeichert.
actor LocalCovers {
    static let shared = LocalCovers()
    private let memory = NSCache<NSString, PlatformImage>()
    var directory = AppPaths.applicationSupport.appending(path: "Local/Covers", directoryHint: .isDirectory)

    init() { memory.countLimit = 300 }

    func image(id: String, size: Int) -> PlatformImage? {
        let step = size <= 120 ? 120 : size <= 300 ? 300 : 600
        let key = "\(id)-\(step)" as NSString
        if let m = memory.object(forKey: key) { return m }
        let h = id.replacingOccurrences(of: "local-cover:", with: "")
        #if os(iOS)
        guard let img = UIImage(contentsOfFile: directory.appending(path: h + ".jpg").path) else { return nil }
        let scale = min(1, CGFloat(step) / max(img.size.width, img.size.height))
        let out = scale < 1 ? (img.preparingThumbnail(of: CGSize(width: img.size.width * scale, height: img.size.height * scale)) ?? img) : img
        #else
        guard let d = try? Data(contentsOf: directory.appending(path: h + ".jpg")),
              let cg = PlatformImage.thumbnail(d, maxPixel: step) else { return nil }
        let out = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
        memory.setObject(out, forKey: key)
        return out
    }
}

/// Ordner-Cover (cover.jpg …) je Ordner nur einmal suchen – auch wenn mehrere Dateien gleichzeitig gelesen werden.
final class FolderCoverCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String?] = [:]

    func cover(for dir: String, compute: () -> String?) -> String? {
        if let c = lock.withLock({ map[dir] }) { return c }
        let c = compute()
        lock.withLock { map[dir] = c }
        return c
    }
}

/// Schlüssel, an denen gerade gearbeitet wird (z. B. Cover-Hash) – gleiche Arbeit läuft nicht parallel doppelt.
final class InProgressSet: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()

    /// false = läuft schon woanders
    func begin(_ key: String) -> Bool { lock.withLock { keys.insert(key).inserted } }
    func end(_ key: String) { _ = lock.withLock { keys.remove(key) } }
}
