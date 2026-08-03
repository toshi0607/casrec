#!/usr/bin/env swift

// Regenerate the app icon from the repository root:
//   swift scripts/generate-icon.swift /tmp/CasRec.iconset/icon_512x512@2x.png
//   for size in 16 32 128 256 512; do sips -z "$size" "$size" /tmp/CasRec.iconset/icon_512x512@2x.png --out "/tmp/CasRec.iconset/icon_${size}x${size}.png"; done
//   for size in 16 32 128 256 512; do doubled=$((size * 2)); sips -z "$doubled" "$doubled" /tmp/CasRec.iconset/icon_512x512@2x.png --out "/tmp/CasRec.iconset/icon_${size}x${size}@2x.png"; done
//   /usr/bin/iconutil -c icns /tmp/CasRec.iconset -o Resources/AppIcon.icns

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvasSize = 1_024
let outputPath = CommandLine.arguments.dropFirst().first
    ?? "AppIcon-1024.png"
let outputURL = URL(filePath: outputPath)

guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create bitmap context.\n", stderr)
    exit(1)
}

let bounds = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
context.setFillColor(CGColor(gray: 0, alpha: 0))
context.fill(bounds)

let backgroundInset: CGFloat = 88
let background = bounds.insetBy(dx: backgroundInset, dy: backgroundInset)
context.setFillColor(CGColor(red: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1))
context.addPath(CGPath(
    roundedRect: background,
    cornerWidth: 200,
    cornerHeight: 200,
    transform: nil
))
context.fillPath()

let selection = background.insetBy(dx: 185, dy: 220)
context.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
context.setLineWidth(24)
context.setLineCap(.round)
context.setLineDash(phase: 0, lengths: [36, 30])
context.stroke(selection)
context.setLineDash(phase: 0, lengths: [])

let recordDiameter: CGFloat = 280
let recordCircle = CGRect(
    x: bounds.midX - recordDiameter / 2,
    y: bounds.midY - recordDiameter / 2,
    width: recordDiameter,
    height: recordDiameter
)
context.setFillColor(CGColor(red: 1, green: 69 / 255, blue: 58 / 255, alpha: 1))
context.fillEllipse(in: recordCircle)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
else {
    fputs("Could not create PNG destination.\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Could not write PNG to \(outputURL.path).\n", stderr)
    exit(1)
}
