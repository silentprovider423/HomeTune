import SwiftUI
import ImageIO

#if os(macOS)
import AppKit
/// Bildtyp der Plattform (Mac: NSImage, iPhone: UIImage)
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    /// Bild aus Daten, auf dem Mac schon entpackt (sonst ruckelt das Scrollen in großen Rastern).
    static func decoded(_ data: Data) -> PlatformImage? {
        #if os(macOS)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return NSImage(data: data) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(data: data)
        #endif
    }

    /// Verkleinert auf höchstens `side` Pixel an der längeren Kante (ImageIO, plattformneutral).
    static func thumbnail(_ data: Data, maxPixel side: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    #if os(macOS)
    var cgImageValue: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
    #else
    var cgImageValue: CGImage? { cgImage }
    #endif
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
