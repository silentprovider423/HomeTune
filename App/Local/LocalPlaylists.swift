import Foundation

/// Eigene Playlist auf diesem iPhone (wie in der Frequenz-App). Enthält Titel-IDs – lokale Titel und, wenn ein
/// Server verbunden ist, auch Server-Titel. `source` = importierte Datei in einem gemerkten Ordner
/// („<Ordner-ID>/<relativer Pfad>“); solche Playlists folgen der Datei, bis sie hier bearbeitet werden.
struct LocalPlaylist: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var comment: String?
    var songIDs: [String]
    var created: Date
    var changed: Date
    var source: String?
    /// Einträge der Quelldatei (für erneutes Zuordnen, wenn neue Titel dazukommen)
    var entries: [PlaylistFile.Entry]?
    /// Hier bearbeitet → folgt der Datei nicht mehr
    var edited = false

    static let idPrefix = "local-playlist:"

    init(name: String, comment: String? = nil, songIDs: [String] = [], source: String? = nil) {
        id = Self.idPrefix + UUID().uuidString
        self.name = name
        self.comment = comment
        self.songIDs = songIDs
        created = Date()
        changed = created
        self.source = source
    }
}

extension String {
    var isLocalPlaylistID: Bool { hasPrefix(LocalPlaylist.idPrefix) }
}

/// Liest .m3u/.m3u8 (auch #EXTM3U/#EXTINF/#PLAYLIST) und .pls – z. B. Exporte aus Apple Music/iTunes am Mac.
enum PlaylistFile {
    static let extensions: Set<String> = ["m3u", "m3u8", "pls"]

    static func isPlaylist(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    struct Entry: Codable, Hashable, Sendable {
        /// Pfad oder URL wie in der Datei (bereinigt: file://, %-Kodierung, Backslashes)
        var path: String
        /// Anzeigename aus #EXTINF bzw. TitleN= („Interpret – Titel“ oder nur Titel)
        var display: String?
    }

    struct Parsed: Equatable, Sendable {
        var name: String?
        var entries: [Entry]
    }

    /// Text-Kodierung: UTF-8 (mit/ohne BOM), UTF-16 mit BOM, sonst Windows-1252 (ältere iTunes-.m3u).
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func parse(_ data: Data, ext: String) -> Parsed {
        let text = decode(data)
        return ext.lowercased() == "pls" ? parsePLS(text) : parseM3U(text)
    }

    static func parseM3U(_ text: String) -> Parsed {
        var out = Parsed(name: nil, entries: [])
        var pending: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.uppercased().hasPrefix("#EXTINF:"), let comma = line.firstIndex(of: ",") {
                    pending = TagReader.clean(String(line[line.index(after: comma)...]))
                } else if line.uppercased().hasPrefix("#PLAYLIST:") {
                    out.name = TagReader.clean(String(line.dropFirst(10)))
                }
                continue
            }
            out.entries.append(Entry(path: cleanPath(line), display: pending))
            pending = nil
        }
        return out
    }

    static func parsePLS(_ text: String) -> Parsed {
        var files: [Int: String] = [:], titles: [Int: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].lowercased(), value = String(line[line.index(after: eq)...])
            if key.hasPrefix("file"), let n = Int(key.dropFirst(4)) { files[n] = cleanPath(value) }
            if key.hasPrefix("title"), let n = Int(key.dropFirst(5)) { titles[n] = TagReader.clean(value) }
        }
        return Parsed(name: nil, entries: files.keys.sorted().compactMap { n in files[n].map { Entry(path: $0, display: titles[n]) } })
    }

    static func cleanPath(_ s: String) -> String {
        var p = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.lowercased().hasPrefix("file://") {
            p = URL(string: p)?.path ?? String(p.dropFirst(7))
        } else if p.contains("%"), let d = p.removingPercentEncoding {
            p = d
        }
        return p.replacingOccurrences(of: "\\", with: "/")
    }
}

/// Ordnet Playlist-Einträge den Titeln auf diesem iPhone zu: über den Dateinamen (ohne Endung und Pfad,
/// Groß-/Kleinschreibung egal; bei Gleichstand zählt, wie viele Ordnernamen von hinten übereinstimmen),
/// zur Not über den #EXTINF-Anzeigenamen („Interpret – Titel“ oder Titel).
struct PlaylistMatcher {
    struct Candidate: Sendable {
        var songID: String
        /// Pfad-Bestandteile (klein), letzter = Dateiname ohne Endung
        var components: [String]
        var title: String
        var artist: String?
    }

    private var byName: [String: [Candidate]] = [:]
    private var byDisplay: [String: [String]] = [:]
    private var byTitle: [String: [String]] = [:]

    init(_ candidates: [Candidate]) {
        for c in candidates {
            if let last = c.components.last { byName[last, default: []].append(c) }
            let t = Self.key(c.title)
            byTitle[t, default: []].append(c.songID)
            if let a = c.artist {
                for sep in [" - ", " – "] { byDisplay[Self.key(a + sep + c.title), default: []].append(c.songID) }
            }
        }
    }

    static func key(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespaces)
    }

    /// „Musik/Album/01 Titel.m4a“ → ["musik", "album", "01 titel"]
    static func components(of path: String) -> [String] {
        var parts = path.split(separator: "/").map { key(String($0)) }
        if let last = parts.popLast() { parts.append(key((last as NSString).deletingPathExtension)) }
        return parts
    }

    func match(_ entry: PlaylistFile.Entry) -> String? {
        let parts = Self.components(of: entry.path)
        if let name = parts.last, let list = byName[name], !list.isEmpty {
            if list.count == 1 { return list[0].songID }
            // gleichnamige Dateien: die mit den meisten passenden Ordnernamen von hinten
            func score(_ c: Candidate) -> Int {
                var n = 0
                for (a, b) in zip(parts.reversed(), c.components.reversed()) { if a == b { n += 1 } else { break } }
                return n
            }
            return list.max { score($0) < score($1) }?.songID
        }
        if let d = entry.display {
            let k = Self.key(d)
            if let ids = byDisplay[k], let id = ids.first { return id }
            if let ids = byTitle[k], ids.count == 1 { return ids[0] }
        }
        return nil
    }

    /// Alle Einträge zuordnen; Ergebnis: gefundene IDs (Reihenfolge der Datei) und Anzahl der Einträge.
    func match(_ parsed: PlaylistFile.Parsed) -> (ids: [String], total: Int) {
        (parsed.entries.compactMap { match($0) }, parsed.entries.count)
    }
}

/// Ergebnis eines Playlist-Imports („x von y Titeln gefunden“).
struct PlaylistImportResult: Sendable, Equatable {
    var name: String
    var found: Int
    var total: Int
}
