import CoreGraphics
import Foundation
import ImageIO

let sizes = [16, 32, 128, 256, 512]
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

func makeImage(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    let tile = CGPath(roundedRect: CGRect(x: 82, y: 82, width: 860, height: 860),
                      cornerWidth: 190, cornerHeight: 190, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x2a184f, alpha: 0.25))
    context.setFillColor(color(0x503083))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(0x573590), color(0x855cc6), color(0xb89bef)] as CFArray,
                              locations: [0, 0.61, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 170, y: 100),
                               end: CGPoint(x: 845, y: 950), options: [])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(color(0xffffff, alpha: 0.18))
    context.setLineWidth(9)
    context.strokePath()

    // Five rounded bars form a single sound pulse and stay legible at Dock sizes.
    let bars: [(CGFloat, CGFloat)] = [(292, 124), (402, 248), (512, 408), (622, 306), (732, 160)]
    context.setFillColor(color(0xfdf8ff))
    for (center, height) in bars {
        let bar = CGRect(x: center - 33, y: 512 - height / 2, width: 66, height: height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 33, cornerHeight: 33, transform: nil))
        context.fillPath()
    }
    return context.makeImage()!
}

guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.apple.icns" as CFString,
                                                        sizes.count * 2, nil) else {
    throw CocoaError(.fileWriteUnknown)
}
for size in sizes {
    for scale in 1...2 {
        let dpi = 72 * scale
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, makeImage(size: size * scale), properties)
    }
}
guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
