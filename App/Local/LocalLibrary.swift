import Foundation
import UIKit
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
/// `copied` = über „Öffnen in“/„Teilen“ empfangene Dateien; dafür gibt es kein Bookmark, sie liegen als
/// Kopie im App-Speicher.
struct LocalRoot: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case folder, file, copied }
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

    static func + (a: Self, b: Self) -> Self {
        Self(added: a.added + b.added, removed: a.removed + b.removed, unchanged: a.unchanged + b.unchanged,
             skipped: a.skipped + b.skipped, inCloud: a.inCloud + b.inCloud, unreachable: a.unreachable + b.unreachable)
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

/// „Auf diesem iPhone“: Musik aus dem Dateien-Dialog (Ordner/Dateien per Bookmark) und über „Öffnen in“
/// empfangene Dateien. Liest Tags lokal, bildet Alben/Künstler:innen wie die Server-Mediathek und liefert der
/// PlaybackEngine die Originaldatei – also ebenfalls in 432 Hz, offline und ohne Server-Anmeldung.
@MainActor @Observable
final class LocalLibrary {
    private(set) var roots: [LocalRoot] = []
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

    let directory: URL
    var coversDirectory: URL { directory.appending(path: "Covers", directoryHint: .isDirectory) }
    var importedDirectory: URL { directory.appending(path: "Imported", directoryHint: .isDirectory) }
    static let importedRootID = "imported"

    /// Offene security-scoped Zugriffe (Ordner des laufenden und des vorgeladenen Titels)
    @ObservationIgnored private var open: [String: (url: URL, scoped: Bool)] = [:]

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Local", directoryHint: .isDirectory)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        load()
    }

    var isEmpty: Bool { tracks.isEmpty }
    var isScanning: Bool { scanning > 0 }
    var openRootIDs: Set<String> { Set(open.keys) }

    // MARK: Speichern

    private struct Stored: Codable {
        var roots: [LocalRoot]
        var tracks: [LocalTrack]
        var starred: Set<String>
    }

    private var storeURL: URL { directory.appending(path: "library.json") }

    private func load() {
        guard let d = try? Data(contentsOf: storeURL), let s = try? JSONDecoder().decode(Stored.self, from: d) else { return }
        roots = s.roots
        tracks = Dictionary(s.tracks.map { ($0.song.id, $0) }, uniquingKeysWith: { a, _ in a })
        starred = s.starred
        rebuild()
    }

    private func save() {
        let s = Stored(roots: roots, tracks: Array(tracks.values), starred: starred)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: storeURL, options: .atomic) }
    }

    // MARK: Hinzufügen (Dateien-Dialog)

    /// Ordner und/oder Dateien aus dem Dateien-Dialog übernehmen: je Auswahl ein Bookmark, Ordner rekursiv.
    /// Wird ein schon bekannter Ordner erneut gewählt, wird er neu eingelesen (Bookmark erneuert).
    @discardableResult
    func add(_ urls: [URL]) async -> LocalScanSummary {
        var total = LocalScanSummary()
        for url in urls {
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
            let inbox = url.path.contains("/Inbox/")
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

    // MARK: Neu einlesen

    /// Ordner erneut durchsuchen: neue Dateien aufnehmen, gelöschte entfernen, Unverändertes behalten.
    @discardableResult
    func rescan(_ rootID: String) async -> LocalScanSummary {
        guard let root = roots.first(where: { $0.id == rootID }) else { return .init() }
        if root.kind == .copied { return await scan(rootID: rootID, url: importedDirectory) }
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
        for r in roots { total = total + (await rescan(r.id)) }
        return total
    }

    /// Durchsucht einen Ordner (bzw. eine Datei) im Hintergrund und übernimmt das Ergebnis.
    private func scan(rootID: String, url: URL) async -> LocalScanSummary {
        guard let root = roots.first(where: { $0.id == rootID }) else { return .init() }
        scanning += 1
        defer { scanning -= 1 }
        let existing = Dictionary(tracks.values.filter { $0.root == rootID }.map { ($0.rel, $0) }, uniquingKeysWith: { a, _ in a })
        let coversDir = coversDirectory
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.scanDone = done; self?.scanTotal = total }
        }
        let result = await Task.detached(priority: .userInitiated) {
            await Self.scanFiles(rootID: root.id, kind: root.kind, url: url, excluded: root.excluded,
                                 existing: existing, coversDir: coversDir, progress: progress)
        }.value
        guard result.reachable else {
            // Ordner nicht lesbar (Zugriff verweigert/verschoben): Titel behalten, nichts löschen
            unreachable.insert(rootID)
            return LocalScanSummary(unreachable: 1)
        }
        unreachable.remove(rootID)
        tracks = tracks.filter { $0.value.root != rootID }
        for t in result.tracks { tracks[t.song.id] = t }
        if let i = roots.firstIndex(where: { $0.id == rootID }) { roots[i].lastScan = Date() }
        starred = starred.filter { tracks[$0] != nil || !$0.hasPrefix("local:") }
        rebuild()
        cleanupCovers()
        save()
        return result.summary
    }

    private struct ScanResult: Sendable {
        var tracks: [LocalTrack]
        var summary: LocalScanSummary
        var reachable: Bool
    }

    nonisolated private static func scanFiles(rootID: String, kind: LocalRoot.Kind, url: URL, excluded: Set<String>,
                                              existing: [String: LocalTrack], coversDir: URL,
                                              progress: @Sendable (Int, Int) -> Void) async -> ScanResult {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                         .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var files: [(url: URL, rel: String)] = []
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return ScanResult(tracks: [], summary: .init(), reachable: false) }
        if isDir.boolValue {
            guard (try? fm.contentsOfDirectory(atPath: url.path)) != nil,
                  let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                return ScanResult(tracks: [], summary: .init(), reachable: false)
            }
            let base = url.standardizedFileURL.path.hasSuffix("/") ? url.standardizedFileURL.path : url.standardizedFileURL.path + "/"
            for case let f as URL in en.allObjects where TagReader.isAudio(f) {
                var rel = f.standardizedFileURL.path
                if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
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
            case .folder: rootID + "/" + (f.rel as NSString).deletingLastPathComponent
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
        return ScanResult(tracks: out, summary: summary, reachable: true)
    }

    nonisolated private static func makeTrack(tags: LocalTags, file: URL, rootID: String, rel: String, kind: LocalRoot.Kind,
                                              size: Int64, modified: Date?, dir: String, cover: String?, added: Date) -> LocalTrack {
        let name = TagReader.fromFilename(file.lastPathComponent)
        var album = tags.album
        // Ganz ungetaggte Datei im Ordner → Ordnername als Album (getaggte Einzeltitel ohne Album bleiben „Single“)
        if album == nil, tags.title == nil, tags.artist == nil, kind == .folder {
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
        guard let img = UIImage(data: data), img.size.width > 0 else { return nil }
        let side: CGFloat = 600
        let scale = min(1, side / max(img.size.width, img.size.height))
        let target = CGSize(width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
        let small = scale < 1 ? (img.preparingThumbnail(of: target) ?? img) : img
        guard let jpg = small.jpegData(compressionQuality: 0.85) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jpg.write(to: file, options: .atomic)
        return "local-cover:" + h
    }

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
        guard let t = tracks[song.id], let root = roots.first(where: { $0.id == t.root }) else { throw LocalError.missing }
        let base: URL
        if root.kind == .copied {
            base = importedDirectory
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
    /// zurückkommt; nur bei empfangenen Kopien wird die App-eigene Kopie gelöscht.
    func remove(songs: [Song]) {
        for s in songs {
            guard let t = tracks[s.id], let i = roots.firstIndex(where: { $0.id == t.root }) else { continue }
            switch roots[i].kind {
            case .folder: roots[i].excluded.insert(t.rel)
            case .file: closeAccess(roots[i].id); roots.remove(at: i)
            case .copied: try? FileManager.default.removeItem(at: importedDirectory.appending(path: t.rel))
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
        guard let root = roots.first(where: { $0.id == id }) else { return }
        closeAccess(id)
        if root.kind == .copied { try? FileManager.default.removeItem(at: importedDirectory) }
        let gone = Set(tracks.values.filter { $0.root == id }.map(\.song.id))
        tracks = tracks.filter { !gone.contains($0.key) }
        starred.subtract(gone)
        roots.removeAll { $0.id == id }
        unreachable.remove(id)
        rebuild()
        cleanupCovers()
        save()
    }

    func removeAll() {
        for r in roots { removeRoot(r.id) }
        tracks = [:]
        rebuild()
        save()
    }

    private func closeAccess(_ id: String) {
        if let o = open.removeValue(forKey: id), o.scoped { o.url.stopAccessingSecurityScopedResource() }
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
    private let memory = NSCache<NSString, UIImage>()
    var directory = URL.applicationSupportDirectory.appending(path: "Local/Covers", directoryHint: .isDirectory)

    init() { memory.countLimit = 300 }

    func image(id: String, size: Int) -> UIImage? {
        let step = size <= 120 ? 120 : size <= 300 ? 300 : 600
        let key = "\(id)-\(step)" as NSString
        if let m = memory.object(forKey: key) { return m }
        let h = id.replacingOccurrences(of: "local-cover:", with: "")
        guard let img = UIImage(contentsOfFile: directory.appending(path: h + ".jpg").path) else { return nil }
        let scale = min(1, CGFloat(step) / max(img.size.width, img.size.height))
        let out = scale < 1 ? (img.preparingThumbnail(of: CGSize(width: img.size.width * scale, height: img.size.height * scale)) ?? img) : img
        memory.setObject(out, forKey: key)
        return out
    }
}
