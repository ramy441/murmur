import AppKit

// Renders the Murmur app icon: gradient squircle + waveform bars.
// usage: swift makeicon.swift <output-iconset-dir>

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size S: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // macOS icons sit inset inside their canvas
    let inset = S * 0.0977
    let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = rect.width * 0.2237

    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                  blur: S * 0.028,
                  color: NSColor.black.withAlphaComponent(0.30).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // indigo -> violet body
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [
                            NSColor(srgbRed: 0.36, green: 0.34, blue: 0.92, alpha: 1).cgColor,
                            NSColor(srgbRed: 0.55, green: 0.28, blue: 0.90, alpha: 1).cgColor,
                            NSColor(srgbRed: 0.72, green: 0.26, blue: 0.80, alpha: 1).cgColor,
                          ] as CFArray,
                          locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

    // top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [
                            NSColor.white.withAlphaComponent(0.22).cgColor,
                            NSColor.white.withAlphaComponent(0.0).cgColor,
                           ] as CFArray,
                           locations: [0.0, 1.0])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY),
                           options: [])
    ctx.restoreGState()

    // waveform: symmetric rounded bars, tallest in the middle
    let heights: [CGFloat] = [0.26, 0.46, 0.72, 1.0, 0.72, 0.46, 0.26]
    let barW = rect.width * 0.072
    let gap = rect.width * 0.055
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    let maxH = rect.height * 0.50
    var x = rect.midX - total / 2

    ctx.setFillColor(NSColor.white.cgColor)
    for h in heights {
        let barH = max(maxH * h, barW)
        let bar = CGRect(x: x, y: rect.midY - barH / 2, width: barW, height: barH)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
        x += barW + gap
    }

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: S, height: S)
    return rep.representation(using: .png, properties: [:])!
}

// the exact set iconutil expects
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    let data = draw(size: size)
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("wrote \(name)")
}
