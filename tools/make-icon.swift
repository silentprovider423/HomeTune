// Erzeugt das App-Symbol von HomeSpin (Schallplatte mit Haus-Etikett und Stimmgabel-Akzent):
//   swift tools/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Hintergrund: warmer Verlauf (iOS rundet die Ecken selbst ab)
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0xFF5A5F), rgb(0xC2185B), rgb(0x4A148C)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 120, y: 1024), end: CGPoint(x: 900, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Schallplatte
    let c = CGPoint(x: 512, y: 500)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x000000, 0.45))
    ctx.addEllipse(in: CGRect(x: c.x - 380, y: c.y - 380, width: 760, height: 760))
    ctx.setFillColor(rgb(0x15151C)); ctx.fillPath()
    ctx.restoreGState()
    // Rillen
    ctx.setLineWidth(3)
    for r in stride(from: 360.0, through: 175.0, by: -18.0) {
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setStrokeColor(rgb(0xFFFFFF, r.truncatingRemainder(dividingBy: 36) == 0 ? 0.07 : 0.035)); ctx.strokePath()
    }
    // Glanz
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 380, y: c.y - 380, width: 760, height: 760)); ctx.clip()
    let shine = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)] as CFArray, locations: [0.3, 0.5, 0.7])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 150, y: 860), end: CGPoint(x: 870, y: 140), options: [])
    ctx.restoreGState()
    // Etikett
    let lr: CGFloat = 165
    let label = CGGradient(colorsSpace: nil, colors: [rgb(0xFFD166), rgb(0xFF8A3D)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - lr, y: c.y - lr, width: 2 * lr, height: 2 * lr)); ctx.clip()
    ctx.drawLinearGradient(label, start: CGPoint(x: c.x, y: c.y + lr), end: CGPoint(x: c.x, y: c.y - lr), options: [])
    ctx.restoreGState()
    // Haus auf dem Etikett
    let house = CGMutablePath()
    house.move(to: CGPoint(x: c.x - 82, y: c.y - 70))
    house.addLine(to: CGPoint(x: c.x - 82, y: c.y + 12))
    house.addLine(to: CGPoint(x: c.x, y: c.y + 88))
    house.addLine(to: CGPoint(x: c.x + 82, y: c.y + 12))
    house.addLine(to: CGPoint(x: c.x + 82, y: c.y - 70))
    house.closeSubpath()
    ctx.addPath(house); ctx.setFillColor(rgb(0x2B1036)); ctx.fillPath()
    // Mittelloch als Tür
    ctx.addPath(CGPath(roundedRect: CGRect(x: c.x - 18, y: c.y - 70, width: 36, height: 64), cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.setFillColor(rgb(0xFFD166)); ctx.fillPath()
    // Tonarm
    ctx.setLineCap(.round)
    ctx.setLineWidth(26)
    ctx.setStrokeColor(rgb(0xF4F1F8))
    ctx.move(to: CGPoint(x: 880, y: 905)); ctx.addLine(to: CGPoint(x: 845, y: 560)); ctx.addLine(to: CGPoint(x: 735, y: 420))
    ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: 840, y: 865, width: 80, height: 80)); ctx.setFillColor(rgb(0xF4F1F8)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 700, y: 380, width: 70, height: 56), cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let rep = render(1024)
// Ohne Alphakanal speichern (App-Symbole dürfen keine Transparenz haben)
let flatCtx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
flatCtx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let flat = NSBitmapImageRep(cgImage: flatCtx.makeImage()!)
try! flat.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("AppIcon.png"))
print("Symbol geschrieben nach \(out.path)")
