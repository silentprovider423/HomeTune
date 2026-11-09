// Erzeugt das Mac-App-Symbol aus dem iPhone-Symbol (gleiches Motiv, im macOS-Raster: abgerundete Kachel mit Schatten):
//   swift tools/make-mac-icon.swift Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png Mac/Assets.xcassets/AppIcon.appiconset
import AppKit

let args = CommandLine.arguments
guard args.count > 2, let src = NSImage(contentsOfFile: args[1]),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("Aufruf: make-mac-icon.swift <AppIcon.png> <Ausgabeordner>"); exit(1)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high
    // macOS-Raster: Kachel 824×824 mit Rand 100, abgerundet, leichter Schatten
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path); ctx.clip()
    ctx.draw(srcCG, in: tile)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)@\(scale)x.png"
        try! render(base * scale).write(to: out.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)"])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("Mac-Symbol geschrieben nach \(out.path)")
