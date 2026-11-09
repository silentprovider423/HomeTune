import Foundation

/// Cover vom Server (`getCoverArt`), im Speicher und auf der Platte zwischengespeichert.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSString, PlatformImage>()
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]

    init() { memory.countLimit = 400 }

    private func diskURL(_ key: String) -> URL {
        let d = AppPaths.caches.appending(path: "Covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appending(path: key.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    func image(id: String, size: Int, client: SubsonicClient) async -> PlatformImage? {
        // Größe auf Stufen runden, damit wenige Varianten im Cache liegen
        let step = size <= 120 ? 120 : size <= 300 ? 300 : 600
        let key = "\(client.account.id)-\(id)-\(step)"
        if let m = memory.object(forKey: key as NSString) { return m }
        if let t = inflight[key] { return await t.value }
        let url = diskURL(key)
        let task = Task<PlatformImage?, Never> {
            if let d = try? Data(contentsOf: url), let img = PlatformImage.decoded(d) { return img }
            guard let (data, resp) = try? await client.session.data(for: client.coverArtRequest(id: id, size: step)),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let img = PlatformImage.decoded(data) else { return nil }
            try? data.write(to: url)
            return img
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString) }
        return img
    }
}

/// Cover vom Server oder von Musik auf diesem iPhone (dann ohne Server, auch offline).
enum Artwork {
    static func image(id: String, size: Int, client: SubsonicClient?) async -> PlatformImage? {
        if id.isLocalID { return await LocalCovers.shared.image(id: id, size: size) }
        guard let client else { return nil }
        return await ArtworkCache.shared.image(id: id, size: size, client: client)
    }
}
