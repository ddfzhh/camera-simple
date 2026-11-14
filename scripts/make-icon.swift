// Draws the Camera Simple app icon with CoreGraphics and writes a .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
// Then:  iconutil -c icns <output.iconset> -o AppIcon.icns

import CoreGraphics
import Foundation
import ImageIO

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ a: CGColor, _ b: CGColor) -> CGGradient {
    CGGradient(colorsSpace: space, colors: [a, b] as CFArray, locations: [0, 1])!
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw in a 1024-point canvas, origin bottom-left.
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let center = CGPoint(x: 512, y: 512)

    // Rounded-rect body (standard macOS icon grid: 824 pt square, 100 pt margin).
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.3))
    ctx.addPath(body)
    ctx.setFillColor(color(0x2C2C2E))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient(color(0x48484A), color(0x1C1C1E)),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Lens barrel.
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, 270))
    ctx.clip()
    ctx.drawLinearGradient(gradient(color(0xF2F2F7), color(0xAEAEB2)),
                           start: CGPoint(x: 512, y: 782), end: CGPoint(x: 512, y: 242), options: [])
    ctx.restoreGState()

    // Glass.
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, 222))
    ctx.clip()
    ctx.drawRadialGradient(gradient(color(0x3A3A3C), color(0x050506)),
                           startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: center, endRadius: 222, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // Aperture ring.
    ctx.setStrokeColor(color(0x636366))
    ctx.setLineWidth(8)
    ctx.strokeEllipse(in: circle(center, 132))

    // The pinhole: a small bright point with a soft glow.
    ctx.drawRadialGradient(gradient(color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: 96, options: [])
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: circle(center, 30))

    // Glass highlight.
    ctx.saveGState()
    ctx.translateBy(x: 432, y: 618)
    ctx.rotate(by: .pi / 5)
    ctx.setFillColor(color(0xFFFFFF, 0.16))
    ctx.fillEllipse(in: CGRect(x: -70, y: -28, width: 140, height: 56))
    ctx.restoreGState()

    return ctx.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let url = out.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(pixels: points * scale), nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(name)") }
    }
}
