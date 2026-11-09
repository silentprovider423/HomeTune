import Foundation
#if os(iOS)
import UIKit
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
    /// Neu importierte Playlists („x von y Titeln gefunden“)
    var playlists: [PlaylistImportResult] = []

    static func + (a: Self, b: Self) -> Self {
        Self(added: a.added + b.added, removed: a.removed + b.removed, unchanged: a.unchanged + b.unchanged,
             skipped: a.skipped + b.skipped, inCloud: a.inCloud + b.inCloud, unreachable: a.unreachable + b.unreachable,
             playlists: a.playlists + b.playlists)
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
    private(set) var scanDone = 0
    private(set) var scanTotal = 0

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

    private struct Stored: Codable {
        var roots: [LocalRoot]
        var tracks: [LocalTrack]
        var starred: Set<String>
        var playlists: [LocalPlaylist]?
        var appFolder: LocalRoot?
        var dismissedPlaylistSources: Set<String>?
    }

    private var storeURL: URL { directory.appending(path: "library.json") }

    private func load() {
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
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: storeURL, options: .atomic) }
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
            let inbox = url.path.contains("/Inbox/") || url.path.contains("-Inbox/")
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

    @ObservationIgnored private var appFolderStamp: String?

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
            parts.append("\(f.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
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
        appFolderStamp = stamp
        return s
    }

    /// Durchsucht einen Ordner (bzw. eine Datei) im Hintergrund und übernimmt das Ergebnis.
    private func scan(rootID: String, url: URL) async -> LocalScanSummary {
        guard let root = root(rootID) else { return .init() }
        scanning += 1
        defer { scanning -= 1 }
        let existing = Dictionary(tracks.values.filter { $0.root == rootID }.map { ($0.rel, $0) }, uniquingKeysWith: { a, _ in a })
        let coversDir = coversDirectory
        let skip = root.kind == .appFolder ? inboxDirectory : nil
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.scanDone = done; self?.scanTotal = total }
        }
        let result = await Task.detached(priority: .userInitiated) {
            await Self.scanFiles(rootID: root.id, kind: root.kind, url: url, excluded: root.excluded,
                                 existing: existing, coversDir: coversDir, skip: skip, progress: progress)
        }.value
        guard result.reachable else {
            // Ordner nicht lesbar (Zugriff verweigert/verschoben): Titel behalten, nichts löschen
            unreachable.insert(rootID)
            return LocalScanSummary(unreachable: 1)
        }
        unreachable.remove(rootID)
        tracks = tracks.filter { $0.value.root != rootID }
        for t in result.tracks { tracks[t.song.id] = t }
        updateRoot(rootID) { $0.lastScan = Date() }
        starred = starred.filter { tracks[$0] != nil || !$0.hasPrefix("local:") }
        rebuild()
        var summary = result.summary
        summary.playlists = syncPlaylists(rootID: rootID, files: result.playlists)
        cleanupCovers()
        save()
        return summary
    }

    private struct ScanResult: Sendable {
        var tracks: [LocalTrack]
        var summary: LocalScanSummary
        var reachable: Bool
        /// Playlist-Dateien im Ordner (relativer Pfad, Inhalt)
        var playlists: [(rel: String, data: Data)] = []
    }

    nonisolated private static func scanFiles(rootID: String, kind: LocalRoot.Kind, url: URL, excluded: Set<String>,
                                              existing: [String: LocalTrack], coversDir: URL, skip: URL?,
                                              progress: @Sendable (Int, Int) -> Void) async -> ScanResult {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                         .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var files: [(url: URL, rel: String)] = []
        var playlistFiles: [(rel: String, data: Data)] = []
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
                if let skipPath, f.standardizedFileURL.path == skipPath { en.skipDescendants(); continue }
                var rel = f.standardizedFileURL.path
                if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
                if PlaylistFile.isPlaylist(f) {
                    if let d = try? Data(contentsOf: f), d.count < 4_000_000 { playlistFiles.append((rel, d)) }
                    continue
                }
                guard TagReader.isAudio(f) else { continue }
                if !excluded.contains(rel) { files.append((f, rel)) }
            }
            files.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        } else {
            guard fm.isReadableFile(atPath: url.path) else { return ScanResult(tracks: [], summary: .init(), reachable: false) }
            files = TagReader.isAudio(url) ? [(url, "")] : []
        }

        var out: [LocalTrack] = []
        var summary = LocalScanSummary()
        var folderCovers: [String: String?] = [:]
        let now = Date()
        for (i, f) in files.enumerated() {
            if i % 10 == 0 { progress(i, files.count) }
            let rv = try? f.url.resourceValues(forKeys: keys)
            let size = Int64(rv?.fileSize ?? 0)
            let modified = rv?.contentModificationDate
            // iCloud-Platzhalter: noch nicht auf dem iPhone → laden anstoßen, Bekanntes behalten
            if rv?.isUbiquitousItem == true, let st = rv?.ubiquitousItemDownloadingStatus, st != .current {
                try? fm.startDownloadingUbiquitousItem(at: f.url)
                summary.inCloud += 1
                if let old = existing[f.rel] { out.append(old) }
                continue
            }
            if let old = existing[f.rel], old.size == size, old.modified == modified {
                out.append(old)
                summary.unchanged += 1
                continue
            }
            guard let tags = await TagReader.read(f.url) else { summary.skipped += 1; continue }
            let parentDir = f.url.deletingLastPathComponent()
            var cover: String?
            if let art = tags.artwork { cover = storeCover(art, in: coversDir) }
            if cover == nil, kind != .file {
                // Ordner-Cover (cover.jpg, folder.jpg …) einmal je Ordner suchen
                let key = parentDir.path
                if let c = folderCovers[key] { cover = c } else {
                    let c = folderCover(in: parentDir).flatMap { storeCover($0, in: coversDir) }
                    folderCovers[key] = c
                    cover = c
                }
            }
            let dir: String = switch kind {
            case .folder, .appFolder: rootID + "/" + (f.rel as NSString).deletingLastPathComponent
            case .file: parentDir.standardizedFileURL.path
            case .copied: rootID
            }
            let old = existing[f.rel]
            out.append(makeTrack(tags: tags, file: f.url, rootID: rootID, rel: f.rel, kind: kind, size: size, modified: modified,
                                 dir: dir, cover: cover, added: old?.added ?? now))
            if old == nil { summary.added += 1 } else { summary.unchanged += 1 }
        }
        progress(files.count, files.count)
        let found = Set(files.map(\.rel))
        summary.removed = existing.keys.filter { !found.contains($0) }.count
        return ScanResult(tracks: out, summary: summary, reachable: true, playlists: playlistFiles)
    }

    nonisolated private static func makeTrack(tags: LocalTags, file: URL, rootID: String, rel: String, kind: LocalRoot.Kind,
                                              size: Int64, modified: Date?, dir: String, cover: String?, added: Date) -> LocalTrack {
        let name = TagReader.fromFilename(file.lastPathComponent)
        var album = tags.album
        // Ganz ungetaggte Datei im Ordner → Ordnername als Album (getaggte Einzeltitel ohne Album bleiben „Single“)
        if album == nil, tags.title == nil, tags.artist == nil, kind == .folder || (kind == .appFolder && rel.contains("/")) {
            album = TagReader.clean(file.deletingLastPathComponent().lastPathComponent)
        }
        var song = Song(id: "local:" + hash(rootID + "\n" + rel), title: tags.title ?? name.title, album: album,
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
        song.created = ISO8601DateFormatter().string(from: added)
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
    nonisolated static func storeCover(_ data: Data, in dir: URL) -> String? {
        let h = SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined()
        let file = dir.appending(path: h + ".jpg")
        if FileManager.default.fileExists(atPath: file.path) { return "local-cover:" + h }
        #if os(iOS)
        guard let img = UIImage(data: data), img.size.width > 0 else { return nil }
        let side: CGFloat = 600
        let scale = min(1, side / max(img.size.width, img.size.height))
        let target = CGSize(width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
        let small = scale < 1 ? (img.preparingThumbnail(of: target) ?? img) : img
        guard let jpg = small.jpegData(compressionQuality: 0.85) else { return nil }
        #else
        guard let cg = PlatformImage.thumbnail(data, maxPixel: 600), let jpg = jpegData(cg, quality: 0.85) else { return nil }
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jpg.write(to: file, options: .atomic)
        return "local-cover:" + h
    }

    #if os(macOS)
    nonisolated private static func jpegData(_ cg: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
    #endif

    private func cleanupCovers() {
        let used = Set(tracks.values.compactMap { $0.song.coverArt?.replacingOccurrences(of: "local-cover:", with: "") })
        guard let files = try? FileManager.default.contentsOfDirectory(at: coversDirectory, includingPropertiesForKeys: nil) else { return }
        for f in files where !used.contains(f.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
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
    private func matcher() -> PlaylistMatcher {
        PlaylistMatcher(tracks.values.map { t in
            let r = root(t.root)
            let path: String = switch r?.kind {
            case .file: r?.path ?? t.song.title
            case .folder, .appFolder: (r?.name ?? "") + "/" + t.rel
            default: t.rel
            }
            return PlaylistMatcher.Candidate(songID: t.song.id, components: PlaylistMatcher.components(of: path),
                                             title: t.song.title, artist: t.song.artist)
        })
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
    /// (außer hier bearbeitete). Liefert die neu angelegten.
    private func syncPlaylists(rootID: String, files: [(rel: String, data: Data)]) -> [PlaylistImportResult] {
        var created: [String] = []
        let prefix = rootID + "/"
        var seen = Set<String>()
        for f in files {
            let source = prefix + f.rel
            seen.insert(source)
            guard !dismissedSources.contains(source) else { continue }
            let parsed = PlaylistFile.parse(f.data, ext: (f.rel as NSString).pathExtension)
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
        rematchPlaylists()
        return created.compactMap { id in
            playlist(id).map { PlaylistImportResult(name: $0.name, found: $0.songIDs.count, total: $0.entries?.count ?? 0) }
        }
    }

    /// Importierte (nicht bearbeitete) Playlists neu zuordnen – z. B. wenn inzwischen mehr Titel da sind.
    private func rematchPlaylists() {
        guard playlists.contains(where: { $0.entries != nil && !$0.edited }) else { return }
        let m = matcher()
        for i in playlists.indices where !playlists[i].edited {
            guard let entries = playlists[i].entries else { continue }
            let ids = m.match(PlaylistFile.Parsed(name: nil, entries: entries)).ids
            if ids != playlists[i].songIDs { playlists[i].songIDs = ids; playlists[i].changed = Date() }
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

    private static func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    static func artistID(_ name: String) -> String { "local-artist:" + hash(norm(name)) }

    private func rebuild() {
        var list = Array(tracks.values)
        list.sort { ($0.song.discNumber ?? 1, $0.song.track ?? 0, $0.song.title) < ($1.song.discNumber ?? 1, $1.song.track ?? 0, $1.song.title) }
        let iso = ISO8601DateFormatter()
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
        songs = list.map(\.song).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        albums = newAlbums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artists = artistNames.map { id, e in
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
        genres = g.map { Genre(value: $0.key, songCount: $0.value.songs, albumCount: $0.value.albums.count) }
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
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
