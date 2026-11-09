import SwiftUI
import UIKit

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
