// Renders the Jev Voice app icon (squircle + waveform/mic glyph) at every
// size iconutil needs. Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let inset = size * 0.1
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225

    // shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0.28, green: 0.22, blue: 0.85, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // gradient body
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.44, green: 0.37, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.22, green: 0.16, blue: 0.80, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY), options: [])
    // gloss
    let gloss = CGGradient(colorsSpace: space, colors: [
        CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.midY), options: [])
    ctx.restoreGState()

    // glyph: five bars + mic cradle
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    let cx = rect.midX
    let cy = rect.midY + rect.height * 0.05
    let barW = rect.width * 0.085
    let gap = rect.width * 0.045
    let heights: [CGFloat] = [0.18, 0.30, 0.44, 0.30, 0.18].map { $0 * rect.height }
    for (i, h) in heights.enumerated() {
        let x = cx + CGFloat(i - 2) * (barW + gap) - barW / 2
        let bar = CGRect(x: x, y: cy - h / 2, width: barW, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
    }
    let cradleR = (barW + gap) * 1.6
    let cradleY = cy - heights[1] / 2 + barW * 0.2
    ctx.setLineWidth(barW * 0.6)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: cx, y: cradleY), radius: cradleR,
               startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: cx, y: cradleY - cradleR))
    ctx.addLine(to: CGPoint(x: cx, y: cradleY - cradleR - barW * 0.7))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: cx - barW * 0.9, y: cradleY - cradleR - barW * 0.7))
    ctx.addLine(to: CGPoint(x: cx + barW * 0.9, y: cradleY - cradleR - barW * 0.7))
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

for base in [16, 32, 128, 256, 512] {
    write(draw(size: CGFloat(base)), to: "\(outDir)/icon_\(base)x\(base).png")
    write(draw(size: CGFloat(base * 2)), to: "\(outDir)/icon_\(base)x\(base)@2x.png")
}
