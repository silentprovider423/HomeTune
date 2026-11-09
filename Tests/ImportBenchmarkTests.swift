import XCTest
import Darwin
#if os(iOS)
@testable import HomeTune
#endif

/// Messung „Auf diesem iPhone“ mit einer großen Sammlung (tools/make-bulk-library.sh, 2.000+ Dateien):
/// Gesamtzeit, längste Blockade des Hauptthreads, Speicherspitze; dazu Neu-Einlesen ohne Änderung und nach dem
/// Verschieben eines Ordners. Läuft nur mit HOMETUNE_BULK_DIR (Ordner auf dem Mac, der Simulator liest ihn direkt).
@MainActor
final class ImportBenchmarkTests: XCTestCase {
    private static var keepAlive: [LocalLibrary] = []
    func testBulkImport() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOMETUNE_BULK_DIR"], !path.isEmpty else {
            throw XCTSkip("HOMETUNE_BULK_DIR nicht gesetzt")
        }
        let docs = URL(fileURLWithPath: path, isDirectory: true)
        let dir = FileManager.default.temporaryDirectory.appending(path: "bulk-lib-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = HangProbe()
        probe.start()
        let lib = LocalLibrary(directory: dir, documents: docs)
        var t0 = Date()
        _ = await lib.rescan(LocalLibrary.appFolderRootID)
        let first = Date().timeIntervalSince(t0)
        let r1 = probe.take()
        let count = lib.songs.count
        print("BULK Erst-Import: \(count) Titel, \(lib.albums.count) Alben, \(lib.playlists.count) Playlists in \(String(format: "%.1f", first)) s; Hauptthread max. blockiert \(Int(r1.maxHang * 1000)) ms (\(r1.hangsOver100) × > 100 ms); Speicher Spitze \(r1.peakMB) MB (Start \(r1.startMB) MB)")

        LocalLibrary.flushSaves()
        t0 = Date()
        let reopened = LocalLibrary(directory: dir, documents: docs)
        let open = Date().timeIntervalSince(t0)
        Self.keepAlive.append(reopened)
        try await Task.sleep(for: .milliseconds(200))
        _ = probe.take()
        print("BULK Start mit gespeicherter Mediathek (Laden auf dem Hauptthread): \(Int(open * 1000)) ms, \(reopened.songs.count) Titel")

        t0 = Date()
        _ = await lib.rescan(LocalLibrary.appFolderRootID)
        let second = Date().timeIntervalSince(t0)
        let r2 = probe.take()
        print("BULK Neu-Einlesen ohne Änderung: \(String(format: "%.2f", second)) s; Hauptthread max. \(Int(r2.maxHang * 1000)) ms")

        // Ordner verschieben (wie in der Dateien-App) und neu einlesen
        let src = docs.appending(path: "Collection 1/Album 1"), dst = docs.appending(path: "Collection 2/Album 1 (moved)")
        try FileManager.default.moveItem(at: src, to: dst)
        defer { try? FileManager.default.moveItem(at: dst, to: src) }
        let before = Set(lib.songs.filter { $0.album == "Album 1" }.map(\.id))
        t0 = Date()
        let s = await lib.refreshAppFolderIfChanged()
        let moved = Date().timeIntervalSince(t0)
        let r3 = probe.take()
        let after = Set(lib.songs.filter { $0.album == "Album 1" }.map(\.id))
        print("BULK Neu-Einlesen nach Ordner-Verschieben: \(String(format: "%.2f", moved)) s, +\(s?.added ?? -1)/−\(s?.removed ?? -1), Titel-IDs behalten: \(before == after); Hauptthread max. \(Int(r3.maxHang * 1000)) ms")
        probe.stop()
        XCTAssertGreaterThanOrEqual(count, 2000)
        XCTAssertEqual(lib.songs.count, count)
    }
}

/// Misst, wie lange der Hauptthread nicht reagiert (alle 10 ms angestupst), und die Speicherspitze (phys_footprint).
final class HangProbe: @unchecked Sendable {
    struct Report { var maxHang: Double; var hangsOver100: Int; var peakMB: Int; var startMB: Int }
    private let lock = NSLock()
    private var maxHang = 0.0, over = 0, peak: UInt64 = 0, startFootprint: UInt64 = 0
    private var running = false

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        startFootprint = Self.footprint()
        running = true
        Thread.detachNewThread { [self] in
            let sem = DispatchSemaphore(value: 0)
            while lock.withLock({ running }) {
                let t = Date()
                DispatchQueue.main.async { sem.signal() }
                sem.wait()
                let lat = Date().timeIntervalSince(t)
                let fp = Self.footprint()
                lock.withLock {
                    maxHang = max(maxHang, lat)
                    if lat > 0.1 { over += 1 }
                    peak = max(peak, fp)
                }
                usleep(10_000)
            }
        }
    }

    /// Werte seit dem letzten Abruf
    func take() -> Report {
        lock.withLock {
            let r = Report(maxHang: maxHang, hangsOver100: over, peakMB: Int(peak / 1_048_576), startMB: Int(startFootprint / 1_048_576))
            maxHang = 0; over = 0; peak = Self.footprint(); startFootprint = peak
            return r
        }
    }

    func stop() { lock.withLock { running = false } }
}
