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

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw in a 1024-point canvas, origin bottom-left.
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let center = CGPoint(x: 512, y: 512)

    // Ink Line style: white body, black outlines, one red-orange spot colour.
    let ink = color(0x111111), red = color(0xFF5A36), white = color(0xFFFFFF)

    // Rounded-rect body. The outline's outer edge sits on the standard macOS icon grid
    // (824 pt square, 100 pt margin): a 794 pt rect with a 30 pt stroke.
    let body = CGPath(roundedRect: CGRect(x: 115, y: 115, width: 794, height: 794),
                      cornerWidth: 170, cornerHeight: 170, transform: nil)
    ctx.addPath(body)
    ctx.setFillColor(white)
    ctx.fillPath()
    ctx.addPath(body)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(30)
    ctx.strokePath()

    // Lens: a red disc with a black outline.
    ctx.setFillColor(red)
    ctx.fillEllipse(in: circle(center, 290))
    ctx.setLineWidth(30)
    ctx.strokeEllipse(in: circle(center, 290))

    // Highlight: a short white arc inside the lens, upper left.
    ctx.setStrokeColor(white)
    ctx.setLineCap(.round)
    ctx.setLineWidth(28)
    ctx.addArc(center: center, radius: 224, startAngle: .pi * 0.62, endAngle: .pi * 0.88, clockwise: false)
    ctx.strokePath()

    // Inner ring, white.
    ctx.setLineWidth(32)
    ctx.strokeEllipse(in: circle(center, 150))

    // Centre dot, black.
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: circle(center, 60))

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
