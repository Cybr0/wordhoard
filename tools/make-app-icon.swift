// Draws Wordhoard's placeholder app icon (plan 6.3, #52): a 1024 × 1024 opaque sRGB PNG, the accent colour
// as background and a white glyph of three rounded bars of decreasing width (a word list), from paths only.
// No SF Symbol and no font: their terms exclude use in app icons. macOS Core Graphics + ImageIO, no
// dependencies. The owner replaces the icon by overwriting the PNG.
//
//   swift tools/make-app-icon.swift Wordhoard/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `#1F6F5F`, the same value as `AccentColor.colorset`.
let accent = (red: 0x1F, green: 0x6F, blue: 0x5F)
let size = 1024

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <output.png>\n".utf8))
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
          data: nil,
          width: size,
          height: size,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: space,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
else {
    FileHandle.standardError.write(Data("could not create the drawing context\n".utf8))
    exit(1)
}

context.setFillColor(CGColor(
    srgbRed: CGFloat(accent.red) / 255,
    green: CGFloat(accent.green) / 255,
    blue: CGFloat(accent.blue) / 255,
    alpha: 1
))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Three bars, top to bottom, left-aligned on one edge and centred as a block.
let barHeight: CGFloat = 112
let gap: CGFloat = 88
let widths: [CGFloat] = [600, 470, 340]
let left = (CGFloat(size) - widths[0]) / 2
let blockHeight = barHeight * 3 + gap * 2
let top = (CGFloat(size) + blockHeight) / 2
context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
for (index, width) in widths.enumerated() {
    let originY = top - barHeight - CGFloat(index) * (barHeight + gap)
    let bar = CGRect(x: left, y: originY, width: width, height: barHeight)
    context.addPath(CGPath(roundedRect: bar, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
    context.fillPath()
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("could not create the PNG\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(output.path)\n".utf8))
    exit(1)
}
