import AVFoundation
import os

/// Holt die Originaldatei eines Titels (`stream?format=raw`) in den Cache, damit AVAudioEngine sie
/// lückenlos und verlustfrei lesen kann. Formate, die iOS nicht öffnen kann, werden verlustfrei als FLAC
/// vom Server umgewandelt geholt.
///
/// Wiedergabe startet nicht erst nach dem kompletten Download: `source(for:)` liefert die Datei, während sie
/// noch geladen wird (`TrackSource`); die Engine beginnt, sobald einige Sekunden da sind, und der Rest lädt
/// mit voller Geschwindigkeit im Hintergrund weiter. Bricht die Verbindung kurz ab, geht es per HTTP-Range
/// an derselben Stelle weiter.
actor TrackCache {
    static let shared = TrackCache()
    private var inflight: [String: Task<URL, Error>] = [:]
    private var streams: [String: StreamDownload] = [:]
    private let limitBytes: Int64 = 3 * 1024 * 1024 * 1024
    private var cleaned = false

    /// Verbindungseinstellungen für das fortlaufende Laden (Tests hängen hier eine gedrosselte Leitung ein)
    nonisolated(unsafe) static var makeStreamConfiguration: @Sendable () -> URLSessionConfiguration = {
        let c = URLSessionConfiguration.default
        // Hängt die Leitung länger, neu ansetzen (Range) statt ewig zu warten
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return c
    }

    private func dir(for account: String) -> URL {
        let d = AppPaths.caches.appending(path: "Tracks/\(account)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        if !cleaned {
            // Liegengebliebene Teil-Dateien (App beendet mitten im Laden) wegräumen
            cleaned = true
            let root = AppPaths.caches.appending(path: "Tracks")
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.pathExtension == "part" { try? FileManager.default.removeItem(at: u) }
            }
        }
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

    /// Datei zum Abspielen: fertig aus dem Cache oder fortlaufend ladend (kehrt zurück, sobald der Server
    /// geantwortet hat; Fehler wie „nicht gefunden“ kommen also hier).
    func source(for song: Song, client: SubsonicClient) async throws -> TrackSource {
        let account = client.account.id
        // Gewählte Höchst-Datenrate (Mac): die umgewandelte Datei kommt am Stück
        if Self.maxBitRate > 0, (song.bitRate ?? Int.max) > Self.maxBitRate { return .file(try await file(for: song, client: client)) }
        if let u = cachedFile(for: song, account: account) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
            return .file(u)
        }
        let key = account + "/" + song.id
        if let s = streams[key] {
            if s.source.snapshot.error == nil {
                try await s.responded()
                return s.source
            }
            streams[key] = nil
        }
        let ext = Self.ext(song)
        // Formate, die iOS nicht öffnen kann (Ogg, WMA, APE …), kommen als FLAC vom Server – erst komplett laden
        guard Self.iosReadable.contains(ext) else { return .file(try await file(for: song, client: client)) }
        let d = dir(for: account)
        let target = d.appending(path: "\(Self.safe(song.id)).\(ext)")
        let id = song.id
        let dl = StreamDownload(target: target, progressive: TrackSource.progressiveSuffixes.contains(ext),
                                configuration: Self.makeStreamConfiguration()) { offset in
            var r = client.streamRequest(id: id, format: "raw")
            if offset > 0 { r.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            return r
        }
        streams[key] = dl
        dl.onFinish = { [weak self, weak dl] ok in
            Task { await self?.streamFinished(key: key, download: dl, account: account, ok: ok) }
        }
        dl.start()
        do {
            try await dl.responded()
        } catch {
            dl.cancel()
            streams[key] = nil
            throw error
        }
        return dl.source
    }

    private func streamFinished(key: String, download: StreamDownload?, account: String, ok: Bool) {
        if let download, streams[key] === download { streams[key] = nil }
        if ok { trim(account: account) }
    }

    /// Nur noch diese Titel laden (laufender + nächster); andere angefangene Downloads abbrechen,
    /// damit sie dem laufenden Titel keine Bandbreite wegnehmen.
    func keepLoading(only songIDs: Set<String>) {
        for (key, dl) in streams {
            let id = String(key.split(separator: "/", maxSplits: 1).last ?? "")
            if !songIDs.contains(id) {
                dl.cancel()
                streams[key] = nil
            }
        }
    }

    /// Lokale Datei für einen Titel, vollständig geladen (Tests, Formate mit FLAC-Umwandlung).
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
        if let s = streams[key] { return try await s.source.waitUntilComplete() }
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

    /// Endungen, die Core Audio direkt öffnet
    static let iosReadable: Set<String> = ["mp3", "m4a", "mp4", "aac", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf", "alac"]

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
        var items = files.filter { $0.pathExtension != "part" }.compactMap { u -> (URL, Int64, Date)? in
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
        for dl in streams.values { dl.cancel() }
        streams.removeAll()
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

/// Lädt eine Datei fortlaufend in `<ziel>.part` (Fortschritt in `source`), setzt nach Abbrüchen per Range fort
/// und benennt sie am Ende in die fertige Cache-Datei um.
final class StreamDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let source: TrackSource
    var onFinish: (@Sendable (Bool) -> Void)?
    private let target: URL
    private let part: URL
    private let makeRequest: @Sendable (Int64) -> URLRequest
    private let queue = OperationQueue()
    private var session: URLSession!
    // Nur auf `queue`
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var total: Int64?
    private var failures = 0
    private var lastProgress = Date()
    private var cancelled = false
    private var finished = false
    /// Erste Antwort des Servers (Status/Fehler) – darauf wartet `responded()`
    private let firstResponse = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)

    /// So lange ohne jeden Fortschritt neu versuchen, dann aufgeben
    static let giveUpAfter: TimeInterval = 90

    init(target: URL, progressive: Bool, configuration: URLSessionConfiguration, makeRequest: @escaping @Sendable (Int64) -> URLRequest) {
        self.target = target
        part = target.appendingPathExtension("part")
        self.makeRequest = makeRequest
        source = TrackSource(url: part, progressive: progressive, complete: false)
        super.init()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func start() {
        queue.addOperation { [self] in
            try? FileManager.default.removeItem(at: part)
            FileManager.default.createFile(atPath: part.path, contents: nil)
            handle = try? FileHandle(forWritingTo: part)
            begin()
        }
    }

    /// Wartet auf die erste Antwort des Servers.
    func responded() async throws {
        while true {
            if let r = firstResponse.withLock({ $0 }) { return try r.get() }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func cancel() {
        queue.addOperation { [self] in
            guard !finished else { return }
            cancelled = true
            finish(ok: false, error: CancellationError())
        }
    }

    // MARK: auf `queue`

    private func begin() {
        guard !cancelled, !finished else { return }
        session.dataTask(with: makeRequest(written)).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true {
            // Subsonic-Fehler (Status 200 mit JSON)
            completionHandler(.cancel)
            fail(SubsonicError.badResponse)
            return
        }
        switch http.statusCode {
        case 206:
            // Content-Range: bytes a-b/total
            if let cr = http.value(forHTTPHeaderField: "Content-Range"), let t = cr.split(separator: "/").last.flatMap({ Int64($0) }) { total = t }
        case 200:
            if written > 0 {
                // Server kennt kein Range → von vorn
                try? handle?.truncate(atOffset: 0)
                try? handle?.seek(toOffset: 0)
                written = 0
                source.update { $0.bytes = 0 }
            }
            total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        case 416 where total != nil && written >= total!:
            completionHandler(.cancel)
            complete()
            return
        default:
            completionHandler(.cancel)
            fail(SubsonicError.http(http.statusCode))
            return
        }
        let t = total
        source.update { $0.total = t }
        firstResponse.withLock { if $0 == nil { $0 = .success(()) } }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled, !finished, let handle else { return }
        do { try handle.write(contentsOf: data) } catch { fail(error); return }
        written += Int64(data.count)
        failures = 0
        lastProgress = Date()
        let w = written
        source.update { $0.bytes = w }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled, !finished else { return }
        if error == nil, total == nil || written >= total! {
            complete()
            return
        }
        // Verbindung abgerissen/zu langsam: an derselben Stelle weiter (Range), mit wachsender Pause
        if firstResponse.withLock({ $0 }) == nil, let error, (error as? URLError)?.code != .networkConnectionLost,
           (error as? URLError)?.code != .timedOut, failures >= 2 {
            fail(error)
            return
        }
        failures += 1
        if Date().timeIntervalSince(lastProgress) > Self.giveUpAfter {
            fail(error ?? URLError(.networkConnectionLost))
            return
        }
        let delay = min(5.0, 0.25 * pow(2, Double(failures - 1)))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.queue.addOperation { self.begin() }
        }
    }

    private func complete() {
        try? handle?.close()
        handle = nil
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: part, to: target)
        } catch {
            fail(error)
            return
        }
        let size = written
        source.update { $0.url = self.target; $0.bytes = size; $0.total = size; $0.complete = true }
        firstResponse.withLock { if $0 == nil { $0 = .success(()) } }
        finished = true
        session.finishTasksAndInvalidate()
        onFinish?(true)
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finish(ok: false, error: error)
    }

    private func finish(ok: Bool, error: Error) {
        finished = true
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: part)
        source.update { $0.error = error }
        firstResponse.withLock { if $0 == nil { $0 = .failure(error) } }
        session.invalidateAndCancel()
        onFinish?(ok)
    }
}
