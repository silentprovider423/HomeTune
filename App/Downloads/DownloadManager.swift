import Foundation
import UIKit

/// Offline-Downloads („Geladen“): Originaldateien (`download`) im App-Speicher, je Konto getrennt.
@MainActor @Observable
final class DownloadManager {
    struct Item: Codable, Hashable, Sendable {
        var song: Song
        var file: String
        var bytes: Int64
        var added: Date
    }
    enum State: Equatable { case none, waiting, downloading(Double), done, failed }

    private(set) var items: [String: Item] = [:]
    private(set) var active: [String: Double] = [:]
    private(set) var waiting: [Song] = []
    private(set) var failed: Set<String> = []
    private var client: SubsonicClient?
    private var running = 0
    private let parallel = 2

    private var folder: URL? {
        guard let id = client?.account.id else { return nil }
        let d = URL.applicationSupportDirectory.appending(path: "Downloads/\(id)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func attach(_ client: SubsonicClient?) {
        self.client = client
        items = [:]; active = [:]; waiting = []; failed = []
        guard let f = folder, let d = try? Data(contentsOf: f.appending(path: "manifest.json")),
              let m = try? JSONDecoder().decode([String: Item].self, from: d) else { return }
        // Nur Einträge behalten, deren Datei noch da ist
        items = m.filter { FileManager.default.fileExists(atPath: f.appending(path: $0.value.file).path) }
    }

    private func save() {
        guard let f = folder, let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: f.appending(path: "manifest.json"), options: .atomic)
    }

    func state(_ id: String) -> State {
        if items[id] != nil { return .done }
        if let p = active[id] { return .downloading(p) }
        if waiting.contains(where: { $0.id == id }) { return .waiting }
        if failed.contains(id) { return .failed }
        return .none
    }

    func isDownloaded(_ id: String) -> Bool { items[id] != nil }
    func allDownloaded(_ songs: [Song]) -> Bool { !songs.isEmpty && songs.allSatisfy { items[$0.id] != nil } }
    func anyDownloaded(_ songs: [Song]) -> Bool { songs.contains { items[$0.id] != nil } }

    func localFile(_ id: String) -> URL? {
        guard let item = items[id], let f = folder else { return nil }
        return f.appending(path: item.file)
    }

    var downloadedSongs: [Song] {
        items.values.sorted { $0.added > $1.added }.map(\.song)
    }

    var totalBytes: Int64 { items.values.reduce(0) { $0 + $1.bytes } }

    func download(_ songs: [Song]) {
        for s in songs where items[s.id] == nil && active[s.id] == nil && !waiting.contains(where: { $0.id == s.id }) {
            failed.remove(s.id)
            waiting.append(s)
        }
        startNext()
    }

    func remove(_ songs: [Song]) {
        guard let f = folder else { return }
        for s in songs {
            waiting.removeAll { $0.id == s.id }
            if let item = items.removeValue(forKey: s.id) { try? FileManager.default.removeItem(at: f.appending(path: item.file)) }
        }
        save()
    }

    func removeAll() { remove(items.values.map(\.song)) }

    private func startNext() {
        while running < parallel, !waiting.isEmpty, let client, let f = folder {
            let song = waiting.removeFirst()
            running += 1
            active[song.id] = 0
            Task {
                let bg = UIApplication.shared.beginBackgroundTask(withName: "download")
                defer { UIApplication.shared.endBackgroundTask(bg) }
                do {
                    let name = "\(TrackCache.safe(song.id)).\(TrackCache.ext(song))"
                    let target = f.appending(path: name)
                    try await TrackCache.fetch(client.downloadRequest(id: song.id), client: client, to: target)
                    let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
                    self.items[song.id] = Item(song: song, file: name, bytes: size, added: Date())
                    self.save()
                } catch {
                    self.failed.insert(song.id)
                }
                self.active[song.id] = nil
                self.running -= 1
                self.startNext()
            }
        }
    }
}
