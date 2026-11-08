import Foundation
import CryptoKit

/// Ein Konto auf einem Navidrome-/Subsonic-Server. Das Passwort liegt nur im Schlüsselbund.
struct ServerAccount: Codable, Hashable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var server: URL
    var username: String

    var displayName: String { "\(username) @ \(server.host() ?? server.absoluteString)" }
}

enum SubsonicError: LocalizedError, Equatable {
    case server(code: Int, message: String)
    case badResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .server(let code, let message):
            if code == 40 { return String(localized: "Benutzername oder Passwort falsch.") }
            return message.isEmpty ? String(localized: "Serverfehler \(code)") : message
        case .badResponse: return String(localized: "Unerwartete Antwort vom Server.")
        case .http(let s): return String(localized: "HTTP-Fehler \(s)")
        }
    }
}

/// Typ für getAlbumList2.
enum AlbumListType: String, Sendable {
    case newest, recent, frequent, random, starred, alphabeticalByName, alphabeticalByArtist, byGenre, byYear, highest
}

/// Subsonic-Client mit Token-Anmeldung (t = md5(Passwort + Salz)).
/// Alle Aufrufe gehen per POST (OpenSubsonic `formPost`), damit Zugangsdaten nie in URLs/Logs stehen.
final class SubsonicClient: Sendable {
    let account: ServerAccount
    private let password: String
    let session: URLSession
    static let clientName = "HomeSpin"
    static let apiVersion = "1.16.1"

    init(account: ServerAccount, password: String, session: URLSession = .shared) {
        self.account = account
        self.password = password
        self.session = session
    }

    // MARK: Anfragen bauen

    private func authParams() -> [URLQueryItem] {
        let salt = Self.randomSalt()
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        return [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    static func randomSalt() -> String {
        (0..<12).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
    }

    func endpointURL(_ endpoint: String) -> URL {
        account.server.appending(path: "rest").appending(path: endpoint)
    }

    /// POST-Anfrage mit Formular-Körper (Zugangsdaten im Körper, nicht in der URL).
    func request(_ endpoint: String, _ params: [(String, String)] = []) -> URLRequest {
        var req = URLRequest(url: endpointURL(endpoint))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = authParams() + params.map { URLQueryItem(name: $0.0, value: $0.1) }
        // „+“ in Werten würde sonst als Leerzeichen gelesen
        let body = (comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        req.httpBody = Data(body.utf8)
        req.timeoutInterval = 30
        return req
    }

    func call<T: Decodable>(_ endpoint: String, _ params: [(String, String)] = [], as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: request(endpoint, params))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw SubsonicError.http(http.statusCode) }
        return try Self.decode(data, as: T.self)
    }

    static func decode<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        let dec = JSONDecoder()
        guard let status = try? dec.decode(SubsonicEnvelope<SubsonicStatus>.self, from: data).response else {
            throw SubsonicError.badResponse
        }
        if status.status != "ok" {
            throw SubsonicError.server(code: status.error?.code ?? 0, message: status.error?.message ?? "")
        }
        return try dec.decode(SubsonicEnvelope<T>.self, from: data).response
    }

    private func perform(_ endpoint: String, _ params: [(String, String)] = []) async throws {
        _ = try await call(endpoint, params, as: EmptyResponse.self)
    }

    private static func folder(_ id: Int?) -> [(String, String)] { id.map { [("musicFolderId", String($0))] } ?? [] }

    // MARK: System

    func ping() async throws -> SubsonicStatus {
        try await call("ping", as: SubsonicStatus.self)
    }

    func openSubsonicExtensions() async throws -> [OpenSubsonicExtension] {
        try await call("getOpenSubsonicExtensions", as: ExtensionsResponse.self).openSubsonicExtensions ?? []
    }

    func musicFolders() async throws -> [MusicFolder] {
        try await call("getMusicFolders", as: MusicFoldersResponse.self).musicFolders?.musicFolder ?? []
    }

    func startScan() async throws -> ScanStatus {
        try await call("startScan", as: ScanStatusResponse.self).scanStatus
    }

    func scanStatus() async throws -> ScanStatus {
        try await call("getScanStatus", as: ScanStatusResponse.self).scanStatus
    }

    // MARK: Mediathek

    func artists(folder: Int? = nil) async throws -> [Artist] {
        let r = try await call("getArtists", Self.folder(folder), as: ArtistsResponse.self)
        return (r.artists?.index ?? []).flatMap { $0.artist ?? [] }
    }

    func artist(id: String) async throws -> Artist {
        try await call("getArtist", [("id", id)], as: ArtistResponse.self).artist
    }

    func album(id: String) async throws -> Album {
        try await call("getAlbum", [("id", id)], as: AlbumResponse.self).album
    }

    func song(id: String) async throws -> Song {
        try await call("getSong", [("id", id)], as: SongResponse.self).song
    }

    func albumList(_ type: AlbumListType, size: Int = 50, offset: Int = 0, genre: String? = nil,
                   fromYear: Int? = nil, toYear: Int? = nil, folder: Int? = nil) async throws -> [Album] {
        var p: [(String, String)] = [("type", type.rawValue), ("size", String(size)), ("offset", String(offset))]
        if let genre { p.append(("genre", genre)) }
        if let fromYear { p.append(("fromYear", String(fromYear))) }
        if let toYear { p.append(("toYear", String(toYear))) }
        p += Self.folder(folder)
        return try await call("getAlbumList2", p, as: AlbumList2Response.self).albumList2?.album ?? []
    }

    /// Alle Alben seitenweise.
    func allAlbums(folder: Int? = nil) async throws -> [Album] {
        var out: [Album] = []
        while true {
            let page = try await albumList(.alphabeticalByName, size: 500, offset: out.count, folder: folder)
            out += page
            if page.count < 500 { break }
        }
        return out
    }

    struct SearchResult: Sendable { var artists: [Artist] = []; var albums: [Album] = []; var songs: [Song] = [] }

    func search(_ query: String, artistCount: Int = 20, albumCount: Int = 20, songCount: Int = 50,
                songOffset: Int = 0, folder: Int? = nil) async throws -> SearchResult {
        let p: [(String, String)] = [("query", query), ("artistCount", String(artistCount)), ("albumCount", String(albumCount)),
                                     ("songCount", String(songCount)), ("songOffset", String(songOffset))] + Self.folder(folder)
        let r = try await call("search3", p, as: Search3Response.self).searchResult3
        return SearchResult(artists: r?.artist ?? [], albums: r?.album ?? [], songs: r?.song ?? [])
    }

    /// Alle Titel (Navidrome erlaubt die leere Suche) seitenweise.
    func allSongs(folder: Int? = nil) async throws -> [Song] {
        var out: [Song] = []
        while true {
            let page = try await search("", artistCount: 0, albumCount: 0, songCount: 500, songOffset: out.count, folder: folder).songs
            out += page
            if page.count < 500 { break }
        }
        return out
    }

    func genres() async throws -> [Genre] {
        try await call("getGenres", as: GenresResponse.self).genres?.genre ?? []
    }

    func songsByGenre(_ genre: String, count: Int = 500, folder: Int? = nil) async throws -> [Song] {
        try await call("getSongsByGenre", [("genre", genre), ("count", String(count))] + Self.folder(folder),
                       as: SongsByGenreResponse.self).songsByGenre?.song ?? []
    }

    func randomSongs(size: Int = 100, genre: String? = nil, folder: Int? = nil) async throws -> [Song] {
        var p: [(String, String)] = [("size", String(size))]
        if let genre { p.append(("genre", genre)) }
        return try await call("getRandomSongs", p + Self.folder(folder), as: RandomSongsResponse.self).randomSongs?.song ?? []
    }

    func topSongs(artist: String, count: Int = 10) async throws -> [Song] {
        try await call("getTopSongs", [("artist", artist), ("count", String(count))], as: TopSongsResponse.self).topSongs?.song ?? []
    }

    func similarSongs(id: String, count: Int = 50) async throws -> [Song] {
        try await call("getSimilarSongs2", [("id", id), ("count", String(count))], as: SimilarSongs2Response.self).similarSongs2?.song ?? []
    }

    // MARK: Favoriten

    func starred(folder: Int? = nil) async throws -> Starred2Response.Body {
        try await call("getStarred2", Self.folder(folder), as: Starred2Response.self).starred2
            ?? Starred2Response.Body(artist: nil, album: nil, song: nil)
    }

    enum StarTarget: Sendable { case song(String), album(String), artist(String) }

    func setStar(_ target: StarTarget, starred: Bool) async throws {
        let p: (String, String)
        switch target {
        case .song(let id): p = ("id", id)
        case .album(let id): p = ("albumId", id)
        case .artist(let id): p = ("artistId", id)
        }
        try await perform(starred ? "star" : "unstar", [p])
    }

    func setRating(id: String, rating: Int) async throws {
        try await perform("setRating", [("id", id), ("rating", String(rating))])
    }

    // MARK: Playlists

    func playlists() async throws -> [Playlist] {
        try await call("getPlaylists", as: PlaylistsResponse.self).playlists?.playlist ?? []
    }

    func playlist(id: String) async throws -> Playlist {
        try await call("getPlaylist", [("id", id)], as: PlaylistResponse.self).playlist
    }

    @discardableResult
    func createPlaylist(name: String, songIds: [String]) async throws -> Playlist {
        try await call("createPlaylist", [("name", name)] + songIds.map { ("songId", $0) }, as: PlaylistResponse.self).playlist
    }

    /// Ersetzt die komplette Titelreihenfolge einer Playlist (Subsonic: createPlaylist mit playlistId).
    func replacePlaylistSongs(id: String, songIds: [String]) async throws {
        try await perform("createPlaylist", [("playlistId", id)] + songIds.map { ("songId", $0) })
    }

    func updatePlaylist(id: String, name: String? = nil, comment: String? = nil, isPublic: Bool? = nil,
                        add: [String] = [], removeIndexes: [Int] = []) async throws {
        var p: [(String, String)] = [("playlistId", id)]
        if let name { p.append(("name", name)) }
        if let comment { p.append(("comment", comment)) }
        if let isPublic { p.append(("public", isPublic ? "true" : "false")) }
        p += add.map { ("songIdToAdd", $0) }
        p += removeIndexes.map { ("songIndexToRemove", String($0)) }
        try await perform("updatePlaylist", p)
    }

    func deletePlaylist(id: String) async throws {
        try await perform("deletePlaylist", [("id", id)])
    }

    // MARK: Liedtexte

    func lyrics(songId: String) async throws -> [StructuredLyrics] {
        try await call("getLyricsBySongId", [("id", songId)], as: LyricsListResponse.self).lyricsList?.structuredLyrics ?? []
    }

    func legacyLyrics(artist: String, title: String) async throws -> String? {
        let v = try await call("getLyrics", [("artist", artist), ("title", title)], as: LyricsResponse.self).lyrics?.value
        return (v?.isEmpty ?? true) ? nil : v
    }

    // MARK: Wiedergabe

    func scrobble(id: String, submission: Bool) async throws {
        var p: [(String, String)] = [("id", id), ("submission", submission ? "true" : "false")]
        if submission { p.append(("time", String(Int(Date().timeIntervalSince1970 * 1000)))) }
        try await perform("scrobble", p)
    }

    /// Originaldatei (keine Transkodierung) – Grundlage für verlustfreie 432-Hz-Wiedergabe.
    func streamRequest(id: String, format: String = "raw") -> URLRequest {
        var r = request("stream", [("id", id), ("format", format)])
        r.timeoutInterval = 120
        return r
    }

    func downloadRequest(id: String) -> URLRequest {
        var r = request("download", [("id", id)])
        r.timeoutInterval = 300
        return r
    }

    func coverArtRequest(id: String, size: Int?) -> URLRequest {
        var p = [("id", id)]
        if let size { p.append(("size", String(size))) }
        return request("getCoverArt", p)
    }
}
