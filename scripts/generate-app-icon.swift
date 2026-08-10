import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate-app-icon.swift <source.png> <output.iconset>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard outputURL.pathExtension == "iconset" else {
    fputs("Output directory must use the .iconset extension\n", stderr)
    exit(64)
}
guard !FileManager.default.fileExists(atPath: outputURL.path) else {
    fputs("Output directory already exists: \(outputURL.path)\n", stderr)
    exit(1)
}

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

guard let source = NSImage(contentsOf: sourceURL),
      let sourceRep = source.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
      let sourceCGImage = sourceRep.cgImage else {
    fputs("Unable to decode source image: \(sourceURL.path)\n", stderr)
    exit(1)
}
guard sourceCGImage.width == sourceCGImage.height else {
    fputs("Source image must be square\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for iconSize in iconSizes {
    let size = CGFloat(iconSize.pixels)
    guard let context = CGContext(
        data: nil,
        width: iconSize.pixels,
        height: iconSize.pixels,
        bitsPerComponent: 8,
        bytesPerRow: iconSize.pixels * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Unable to allocate image context\n", stderr)
        exit(1)
    }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    // Keep the artwork inside the macOS icon safe area instead of filling the canvas.
    let artworkSize = size * 0.82
    let artworkRect = CGRect(
        x: (size - artworkSize) / 2,
        y: (size - artworkSize) / 2,
        width: artworkSize,
        height: artworkSize
    )
    context.interpolationQuality = .high
    context.draw(sourceCGImage, in: artworkRect)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              outputURL.appendingPathComponent(iconSize.name) as CFURL,
              "public.png" as CFString,
              1,
              nil
          ) else {
        fputs("Unable to encode \(iconSize.name)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("Unable to finalize \(iconSize.name)\n", stderr)
        exit(1)
    }
}
