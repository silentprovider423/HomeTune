import Foundation

// Datenmodell der Subsonic-/OpenSubsonic-API (nur die Felder, die die App braucht).
// Alle Felder optional, weil Server unterschiedlich viel liefern.

struct Song: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var title: String
    var album: String?
    var artist: String?
    var albumId: String?
    var artistId: String?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var coverArt: String?
    var size: Int?
    var contentType: String?
    var suffix: String?
    var duration: Int?
    var bitRate: Int?
    var samplingRate: Int?
    var bitDepth: Int?
    var channelCount: Int?
    var starred: String?
    var userRating: Int?
    var playCount: Int?
    var created: String?
    var played: String?
    var displayComposer: String?
    var contributors: [Contributor]?
    var path: String?

    struct Contributor: Codable, Hashable, Sendable {
        var role: String?
        var artist: ArtistRef?
    }
    struct ArtistRef: Codable, Hashable, Sendable {
        var id: String?
        var name: String?
    }

    init(id: String, title: String, album: String? = nil, artist: String? = nil, albumId: String? = nil,
         artistId: String? = nil, track: Int? = nil, duration: Int? = nil, suffix: String? = nil) {
        self.id = id; self.title = title; self.album = album; self.artist = artist
        self.albumId = albumId; self.artistId = artistId; self.track = track
        self.duration = duration; self.suffix = suffix
    }

    var isStarred: Bool { starred != nil }
    var durationSeconds: TimeInterval { TimeInterval(duration ?? 0) }

    /// Komponist:innen aus OpenSubsonic `contributors` (Rolle „composer“), sonst `displayComposer`.
    var composers: [String] {
        let c = (contributors ?? []).filter { $0.role == "composer" }.compactMap { $0.artist?.name }
        if !c.isEmpty { return c }
        guard let d = displayComposer, !d.isEmpty else { return [] }
        return d.split(whereSeparator: { $0 == ";" || $0 == "/" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Kurzform für das Audio-Abzeichen, z. B. „FLAC 24/96“ oder „MP3 320“.
    var formatBadge: String? {
        guard let s = suffix?.uppercased(), !s.isEmpty else { return nil }
        let lossless = ["FLAC", "ALAC", "WAV", "AIFF", "AIF", "APE", "WV", "DSF"].contains(s)
            || (s == "M4A" && (bitDepth ?? 0) > 0)
        if lossless, let rate = samplingRate, rate > 0 {
            let khz = Double(rate) / 1000
            let khzText = khz.rounded() == khz ? String(Int(khz)) : String(format: "%.1f", khz)
            let depth = (bitDepth ?? 0) > 0 ? "\(bitDepth!)/" : ""
            return "\(s == "M4A" ? "ALAC" : s) \(depth)\(khzText)"
        }
        if let b = bitRate, b > 0 { return "\(s) \(b)" }
        return s
    }
}

struct Album: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var created: String?
    var starred: String?
    var playCount: Int?
    var played: String?
    var isCompilation: Bool?
    var song: [Song]?
    var recordLabels: [Named]?

    struct Named: Codable, Hashable, Sendable { var name: String? }

    init(id: String, name: String, artist: String? = nil, artistId: String? = nil, coverArt: String? = nil, year: Int? = nil) {
        self.id = id; self.name = name; self.artist = artist; self.artistId = artistId; self.coverArt = coverArt; self.year = year
    }

    var isStarred: Bool { starred != nil }
}

struct Artist: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var coverArt: String?
    var albumCount: Int?
    var starred: String?
    var album: [Album]?

    var isStarred: Bool { starred != nil }
}

struct Playlist: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var comment: String?
    var owner: String?
    var `public`: Bool?
    var songCount: Int?
    var duration: Int?
    var created: String?
    var changed: String?
    var coverArt: String?
    var readonly: Bool?
    var entry: [Song]?
}

struct Genre: Codable, Hashable, Identifiable, Sendable {
    var value: String
    var songCount: Int?
    var albumCount: Int?
    var id: String { value }
}

struct StructuredLyrics: Codable, Hashable, Sendable {
    var lang: String?
    var synced: Bool?
    var offset: Int?
    var displayArtist: String?
    var displayTitle: String?
    var line: [Line]?

    struct Line: Codable, Hashable, Sendable {
        var start: Int?
        var value: String
    }
}

struct MusicFolder: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String?
}

struct ScanStatus: Codable, Sendable {
    var scanning: Bool
    var count: Int?
    var lastScan: String?
}

struct OpenSubsonicExtension: Codable, Sendable {
    var name: String
    var versions: [Int]?
}

// MARK: - Antwort-Hüllen

struct SubsonicEnvelope<T: Decodable>: Decodable {
    let response: T
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicStatus: Decodable {
    let status: String
    let version: String?
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: SubsonicErrorBody?
}

struct SubsonicErrorBody: Decodable, Sendable {
    let code: Int
    let message: String?
}

struct ArtistsResponse: Decodable { struct Body: Decodable { struct Index: Decodable { let name: String?; let artist: [Artist]? }; let index: [Index]? }; let artists: Body? }
struct ArtistResponse: Decodable { let artist: Artist }
struct AlbumResponse: Decodable { let album: Album }
struct SongResponse: Decodable { let song: Song }
struct AlbumList2Response: Decodable { struct Body: Decodable { let album: [Album]? }; let albumList2: Body? }
struct Search3Response: Decodable { struct Body: Decodable { let artist: [Artist]?; let album: [Album]?; let song: [Song]? }; let searchResult3: Body? }
struct PlaylistsResponse: Decodable { struct Body: Decodable { let playlist: [Playlist]? }; let playlists: Body? }
struct PlaylistResponse: Decodable { let playlist: Playlist }
struct Starred2Response: Decodable { struct Body: Decodable { let artist: [Artist]?; let album: [Album]?; let song: [Song]? }; let starred2: Body? }
struct GenresResponse: Decodable { struct Body: Decodable { let genre: [Genre]? }; let genres: Body? }
struct SongsByGenreResponse: Decodable { struct Body: Decodable { let song: [Song]? }; let songsByGenre: Body? }
struct RandomSongsResponse: Decodable { struct Body: Decodable { let song: [Song]? }; let randomSongs: Body? }
struct TopSongsResponse: Decodable { struct Body: Decodable { let song: [Song]? }; let topSongs: Body? }
struct SimilarSongs2Response: Decodable { struct Body: Decodable { let song: [Song]? }; let similarSongs2: Body? }
struct LyricsListResponse: Decodable { struct Body: Decodable { let structuredLyrics: [StructuredLyrics]? }; let lyricsList: Body? }
struct LyricsResponse: Decodable { struct Body: Decodable { let artist: String?; let title: String?; let value: String? }; let lyrics: Body? }
struct MusicFoldersResponse: Decodable { struct Body: Decodable { let musicFolder: [MusicFolder]? }; let musicFolders: Body? }
struct ScanStatusResponse: Decodable { let scanStatus: ScanStatus }
struct ExtensionsResponse: Decodable { let openSubsonicExtensions: [OpenSubsonicExtension]? }
struct EmptyResponse: Decodable {}
