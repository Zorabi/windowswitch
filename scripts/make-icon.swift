// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit

// Original, resolution-independent artwork. Layered windows + a forward gesture.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        // Match the visual size of macOS Dock icons while keeping the plate fully filled.
        context.translateBy(x: 92, y: 92)
        context.scaleBy(x: 0.82, y: 0.82)
        func shape(_ rect: CGRect, radius: CGFloat, color: CGColor) {
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        let background = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerWidth: 224, cornerHeight: 224, transform: nil)
        context.saveGState()
        context.addPath(background)
        context.clip()
        let colors = [CGColor(red: 0.12, green: 0.19, blue: 0.53, alpha: 1), CGColor(red: 0.43, green: 0.52, blue: 0.98, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 850, y: 160), end: CGPoint(x: 200, y: 900), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
        context.translateBy(x: 512, y: 512)
        context.scaleBy(x: 1.2, y: 1.2)
        context.translateBy(x: -512, y: -512)
        shape(CGRect(x: 386, y: 477, width: 394, height: 288), radius: 44,
              color: CGColor(red: 0.80, green: 0.86, blue: 1, alpha: 0.52))
        shape(CGRect(x: 322, y: 413, width: 394, height: 288), radius: 44,
              color: CGColor(red: 0.83, green: 0.89, blue: 1, alpha: 0.79))
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 25, color: CGColor(red: 0.06, green: 0.10, blue: 0.35, alpha: 0.3))
        shape(CGRect(x: 244, y: 282, width: 458, height: 344), radius: 48,
              color: CGColor(red: 0.98, green: 0.99, blue: 1, alpha: 1))
        context.restoreGState()
        shape(CGRect(x: 274, y: 542, width: 398, height: 3), radius: 1.5,
              color: CGColor(red: 0.80, green: 0.85, blue: 0.98, alpha: 1))
        context.setFillColor(CGColor(red: 0.44, green: 0.51, blue: 0.86, alpha: 1))
        for x in [285, 312, 339] { context.fillEllipse(in: CGRect(x: x, y: 573, width: 13, height: 13)) }
        context.setLineWidth(32)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(red: 0.28, green: 0.38, blue: 0.81, alpha: 1))
        context.move(to: CGPoint(x: 372, y: 418))
        context.addLine(to: CGPoint(x: 568, y: 418))
        context.strokePath()
        context.move(to: CGPoint(x: 511, y: 475))
        context.addLine(to: CGPoint(x: 568, y: 418))
        context.addLine(to: CGPoint(x: 511, y: 361))
        context.strokePath()
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        let png = image.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if pixels == 1024, CommandLine.arguments.count > 2 {
            let destination = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination)
        }
    }
}
