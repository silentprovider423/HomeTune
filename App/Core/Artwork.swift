import SwiftUI
import UIKit

/// Cover vom Server (`getCoverArt`), im Speicher und auf der Platte zwischengespeichert.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() { memory.countLimit = 400 }

    private func diskURL(_ key: String) -> URL {
        let d = URL.cachesDirectory.appending(path: "Covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appending(path: key.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    func image(id: String, size: Int, client: SubsonicClient) async -> UIImage? {
        // Größe auf Stufen runden, damit wenige Varianten im Cache liegen
        let step = size <= 120 ? 120 : size <= 300 ? 300 : 600
        let key = "\(client.account.id)-\(id)-\(step)"
        if let m = memory.object(forKey: key as NSString) { return m }
        if let t = inflight[key] { return await t.value }
        let url = diskURL(key)
        let task = Task<UIImage?, Never> {
            if let d = try? Data(contentsOf: url), let img = UIImage(data: d) { return img }
            guard let (data, resp) = try? await client.session.data(for: client.coverArtRequest(id: id, size: step)),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
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
    static func image(id: String, size: Int, client: SubsonicClient?) async -> UIImage? {
        if id.isLocalID { return await LocalCovers.shared.image(id: id, size: size) }
        guard let client else { return nil }
        return await ArtworkCache.shared.image(id: id, size: size, client: client)
    }
}

/// Coverbild mit Platzhalter (Note auf grauem Grund wie bei Apple).
struct CoverArt: View {
    @Environment(AppModel.self) private var app
    let id: String?
    var size: CGFloat = 160
    var corner: CGFloat = 8
    var circle = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
                    .overlay(Image(systemName: circle ? "music.microphone" : "music.note")
                        .font(.system(size: max(12, size * 0.32)))
                        .foregroundStyle(.secondary))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
        .overlay {
            if !circle {
                RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .task(id: id) {
            image = nil
            guard let id else { return }
            image = await Artwork.image(id: id, size: Int(size * 2), client: app.client)
        }
    }
}

extension UIImage {
    /// Mittlere Farbe (für den Hintergrund von „Jetzt läuft“, wie Apples Coverfarben-Verlauf).
    func dominantColors() -> (Color, Color) {
        guard let cg = cgImage else { return (.gray, .black) }
        let w = 2, h = 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (.gray, .black) }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func c(_ i: Int, _ dark: Double) -> Color {
            Color(red: Double(px[i]) / 255 * dark, green: Double(px[i + 1]) / 255 * dark, blue: Double(px[i + 2]) / 255 * dark)
        }
        return (c(0, 0.85), c(12, 0.45))
    }
}
