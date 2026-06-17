#!/usr/bin/env swift

import AppKit
import Foundation

struct IconSlot {
    let pointSize: Int
    let scale: Int

    var pixelSize: Int {
        pointSize * scale
    }

    var filename: String {
        if scale == 1 {
            "AppIcon-\(pointSize).png"
        } else {
            "AppIcon-\(pointSize)@\(scale)x.png"
        }
    }
}

let slots = [
    IconSlot(pointSize: 16, scale: 1),
    IconSlot(pointSize: 16, scale: 2),
    IconSlot(pointSize: 32, scale: 1),
    IconSlot(pointSize: 32, scale: 2),
    IconSlot(pointSize: 128, scale: 1),
    IconSlot(pointSize: 128, scale: 2),
    IconSlot(pointSize: 256, scale: 1),
    IconSlot(pointSize: 256, scale: 2),
    IconSlot(pointSize: 512, scale: 1),
    IconSlot(pointSize: 512, scale: 2),
]

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repositoryRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconSetURL = repositoryRoot
    .appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    var value: UInt64 = 0
    let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
    scanner.scanHexInt64(&value)

    return CGColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: alpha
    )
}

func fillRoundedRect(
    _ context: CGContext,
    _ rect: CGRect,
    radius: CGFloat,
    fillColor: CGColor
) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(fillColor)
    context.fillPath()
}

func drawNeumeAccent(in context: CGContext) {
    context.saveGState()
    context.translateBy(x: 698, y: 714)
    context.rotate(by: -0.17)
    fillRoundedRect(
        context,
        CGRect(x: -72, y: -48, width: 144, height: 96),
        radius: 48,
        fillColor: color("#5EEAD4")
    )
    fillRoundedRect(
        context,
        CGRect(x: 28, y: -162, width: 34, height: 178),
        radius: 17,
        fillColor: color("#0F766E")
    )
    context.restoreGState()
}

func drawIcon(pixelSize: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext
    let scale = CGFloat(pixelSize) / 1024
    context.scaleBy(x: scale, y: scale)
    context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    context.setShadow(
        offset: CGSize(width: 0, height: -20),
        blur: 42,
        color: color("#111827", alpha: 0.24)
    )
    fillRoundedRect(
        context,
        CGRect(x: 64, y: 64, width: 896, height: 896),
        radius: 200,
        fillColor: color("#F7F4EA")
    )
    context.setShadow(offset: .zero, blur: 0, color: nil)

    fillRoundedRect(
        context,
        CGRect(x: 88, y: 88, width: 848, height: 848),
        radius: 178,
        fillColor: color("#FEFCF5", alpha: 0.42)
    )

    for y in [342, 446, 550, 654] {
        fillRoundedRect(
            context,
            CGRect(x: 180, y: y, width: 664, height: 22),
            radius: 11,
            fillColor: color("#D8D2C7")
        )
    }

    let inkColor = color("#172033")
    fillRoundedRect(
        context,
        CGRect(x: 342, y: 286, width: 76, height: 462),
        radius: 32,
        fillColor: inkColor
    )
    fillRoundedRect(
        context,
        CGRect(x: 540, y: 270, width: 76, height: 462),
        radius: 32,
        fillColor: inkColor
    )
    fillRoundedRect(
        context,
        CGRect(x: 252, y: 412, width: 520, height: 78),
        radius: 36,
        fillColor: inkColor
    )
    fillRoundedRect(
        context,
        CGRect(x: 224, y: 566, width: 520, height: 78),
        radius: 36,
        fillColor: inkColor
    )

    drawNeumeAccent(in: context)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }

    return data
}

func writeContentsJSON() throws {
    let entries = slots
        .map { slot in
            let size = "\(slot.pointSize)x\(slot.pointSize)"
            return """
                { "filename" : "\(slot.filename)", "idiom" : "mac", "scale" : "\(slot.scale)x", "size" : "\(size)" }
            """
        }
        .joined(separator: ",\n")

    let contents = """
    {
      "images" : [
    \(entries)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """

    try contents.write(
        to: iconSetURL.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8
    )
}

try FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

for slot in slots {
    let data = try drawIcon(pixelSize: slot.pixelSize)
    let outputURL = iconSetURL.appendingPathComponent(slot.filename)
    try data.write(to: outputURL, options: .atomic)
    print("Wrote \(outputURL.path)")
}

try writeContentsJSON()
