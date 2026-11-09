import AVFoundation

/// Holt die Originaldatei eines Titels (`stream?format=raw`) in den Cache, damit AVAudioEngine sie
/// lückenlos und verlustfrei lesen kann. Formate, die iOS nicht öffnen kann, werden verlustfrei als FLAC
/// vom Server umgewandelt geholt.
actor TrackCache {
    static let shared = TrackCache()
    private var inflight: [String: Task<URL, Error>] = [:]
    private let limitBytes: Int64 = 3 * 1024 * 1024 * 1024

    private func dir(for account: String) -> URL {
        let d = AppPaths.caches.appending(path: "Tracks/\(account)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func cachedFile(for song: Song, account: String) -> URL? {
        let d = dir(for: account)
        for ext in [Self.ext(song), "flac"] {
            let u = d.appending(path: "\(Self.safe(song.id)).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Streaming-Qualität in kbit/s (0 = Original, verlustfrei). Nur am Mac einstellbar; das iPhone nutzt immer 0.
    static var maxBitRate: Int { UserDefaults.standard.integer(forKey: "streamMaxBitRate") }

    /// Lokale Datei für einen Titel (lädt bei Bedarf; parallele Anfragen werden zusammengelegt).
    func file(for song: Song, client: SubsonicClient) async throws -> URL {
        let account = client.account.id
        let rate = Self.maxBitRate
        // Gewählte Höchst-Datenrate: nur wenn das Original darüber liegt, umgewandelt als MP3 holen
        if rate > 0, (song.bitRate ?? Int.max) > rate {
            let d = dir(for: account)
            let target = d.appending(path: "\(Self.safe(song.id)).q\(rate).mp3")
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                return target
            }
            try await Self.fetch(client.streamRequest(id: song.id, format: "mp3", maxBitRate: rate), client: client, to: target)
            guard Self.canOpen(target) else { try? FileManager.default.removeItem(at: target); throw CocoaError(.fileReadCorruptFile) }
            trim(account: account)
            return target
        }
        if let u = cachedFile(for: song, account: account) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
            return u
        }
        let key = account + "/" + song.id
        if let t = inflight[key] { return try await t.value }
        let d = dir(for: account)
        let task = Task<URL, Error> {
            let target = d.appending(path: "\(Self.safe(song.id)).\(Self.ext(song))")
            try await Self.fetch(client.streamRequest(id: song.id, format: "raw"), client: client, to: target)
            if Self.canOpen(target) { return target }
            // iOS kann das Original nicht lesen (z. B. Ogg/WMA/APE) → verlustfrei als FLAC holen
            try? FileManager.default.removeItem(at: target)
            let flac = d.appending(path: "\(Self.safe(song.id)).flac")
            try await Self.fetch(client.streamRequest(id: song.id, format: "flac"), client: client, to: flac)
            guard Self.canOpen(flac) else {
                try? FileManager.default.removeItem(at: flac)
                throw CocoaError(.fileReadCorruptFile)
            }
            return flac
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        let url = try await task.value
        trim(account: account)
        return url
    }

    static func fetch(_ req: URLRequest, client: SubsonicClient, to target: URL) async throws {
        let (tmp, resp) = try await client.session.download(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw SubsonicError.http(http.statusCode) }
        // Subsonic meldet Fehler als JSON mit Status 200
        if let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), type.contains("json") {
            let data = try Data(contentsOf: tmp)
            _ = try SubsonicClient.decode(data, as: EmptyResponse.self)
            throw SubsonicError.badResponse
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    static func canOpen(_ url: URL) -> Bool {
        guard let f = try? AVAudioFile(forReading: url) else { return false }
        return f.length > 0
    }

    static func ext(_ song: Song) -> String {
        let s = (song.suffix ?? "").lowercased()
        return s.isEmpty ? "mp3" : s
    }

    static func safe(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    /// Älteste Dateien löschen, wenn der Cache zu groß wird.
    private func trim(account: String) {
        let d = dir(for: account)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: keys) else { return }
        var items = files.compactMap { u -> (URL, Int64, Date)? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = items.reduce(0) { $0 + $1.1 }
        guard total > limitBytes else { return }
        items.sort { $0.2 < $1.2 }
        for item in items where total > limitBytes {
            try? FileManager.default.removeItem(at: item.0)
            total -= item.1
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: AppPaths.caches.appending(path: "Tracks"))
    }

    func sizeBytes() -> Int64 {
        let root = AppPaths.caches.appending(path: "Tracks")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
