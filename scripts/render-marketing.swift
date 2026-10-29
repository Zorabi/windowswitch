// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit

// Editable promotional artwork. All window labels below are fictional examples.
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = project.appendingPathComponent("Assets/marketing")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let blue = NSColor(srgbRed: 0.27, green: 0.36, blue: 0.78, alpha: 1)
let ink = NSColor(srgbRed: 0.10, green: 0.14, blue: 0.23, alpha: 1)
let muted = NSColor(srgbRed: 0.40, green: 0.44, blue: 0.51, alpha: 1)
let paper = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.94, alpha: 1)
let icon = NSImage(contentsOf: project.appendingPathComponent("Assets/AppIcon.png"))!

func box(_ rect: NSRect, color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor = ink,
          weight: NSFont.Weight = .regular, width: CGFloat = 1400) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = 7
    let font = NSFont(name: weight == .semibold || weight == .bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size)
        ?? NSFont.systemFont(ofSize: size, weight: weight)
    string.draw(in: NSRect(x: x, y: y, width: width, height: size * 4), withAttributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: style
    ])
}
func picture(_ image: NSImage, _ rect: NSRect) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}
func symbol(_ name: String, _ rect: NSRect, color: NSColor = blue) {
    if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color])) {
        picture(image, rect)
    }
}
func key(_ string: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat, dark: Bool = false) {
    box(NSRect(x: x, y: y, width: width, height: 60), color: dark ? NSColor.white.withAlphaComponent(0.10) : .white, radius: 12)
    let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dark ? NSColor.white : blue]
    let size = string.size(withAttributes: attributes)
    string.draw(at: NSPoint(x: x + (width - size.width) / 2, y: y + (60 - size.height) / 2), withAttributes: attributes)
}

final class Artwork: NSView {
    let social: Bool
    init(size: NSSize, social: Bool) { self.social = social; super.init(frame: NSRect(origin: .zero, size: size)) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if social { drawSocial() } else { drawHero() }
    }
    private func drawHero() {
        box(bounds, color: paper)
        picture(icon, NSRect(x: 76, y: 55, width: 80, height: 80))
        text("窗序", 167, 71, size: 35, weight: .semibold)
        text("macOS 窗口切换工具", 1400, 83, size: 19, color: muted, width: 320)
        box(NSRect(x: 90, y: 170, width: 1620, height: 1), color: ink.withAlphaComponent(0.12))
        text("切换到\n你要的窗口。", 90, 249, size: 80, weight: .semibold, width: 780)
        text("按窗口选择，让焦点回到当前。", 95, 493, size: 26, color: muted, width: 720)
        key("⌥ Tab", 95, 585, width: 158)
        text("切换窗口", 273, 598, size: 22, color: muted, width: 280)
        key("⌥ Space", 95, 665, width: 158)
        text("固定搜索", 273, 678, size: 22, color: muted, width: 280)
        text("支持自定义与清除快捷键", 95, 762, size: 18, color: muted)

        box(NSRect(x: 1000, y: 213, width: 672, height: 490), color: blue.withAlphaComponent(0.08), radius: 22)
        box(NSRect(x: 963, y: 242, width: 696, height: 490), color: blue.withAlphaComponent(0.13), radius: 22)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = ink.withAlphaComponent(0.10)
        shadow.shadowBlurRadius = 35
        shadow.shadowOffset = NSSize(width: 0, height: 12)
        shadow.set()
        box(NSRect(x: 910, y: 274, width: 742, height: 490), color: .white, radius: 22)
        NSGraphicsContext.restoreGraphicsState()
        symbol("rectangle.on.rectangle", NSRect(x: 942, y: 301, width: 26, height: 26))
        text("切换窗口", 981, 298, size: 21, weight: .semibold, width: 370)
        text("共 3 项", 1542, 302, size: 16, color: muted, width: 100)
        box(NSRect(x: 938, y: 346, width: 686, height: 58), color: paper, radius: 10)
        symbol("magnifyingglass", NSRect(x: 956, y: 364, width: 23, height: 23), color: muted)
        text("搜索窗口或应用", 994, 357, size: 22, color: muted, width: 550)
        let rows: [(String, String, String, NSColor)] = [
            ("项目笔记", "备忘录", "note.text", blue),
            ("微信", "主窗口", "bubble.left.and.bubble.right.fill", NSColor(srgbRed: 0.12, green: 0.60, blue: 0.36, alpha: 1)),
            ("阅读清单", "小程序", "square.stack", blue)
        ]
        for (index, row) in rows.enumerated() {
            let y = CGFloat(427 + index * 87)
            if index == 0 { box(NSRect(x: 931, y: y, width: 700, height: 79), color: blue.withAlphaComponent(0.10), radius: 12) }
            symbol(row.2, NSRect(x: 954, y: y + 24, width: 31, height: 31), color: row.3)
            text(row.0, 1008, y + 10, size: 23, weight: .semibold, width: 520)
            text(row.1, 1008, y + 44, size: 16, color: muted, width: 520)
        }
        text("F / 空格 固定搜索    ↩ 切换    Esc 取消", 944, 716, size: 16, color: muted, width: 680)
        text("界面示意 · 示例窗口名称", 1406, 788, size: 15, color: muted, width: 310)
        box(NSRect(x: 90, y: 873, width: 1620, height: 1), color: ink.withAlphaComponent(0.12))
        text("窗口级切换", 95, 912, size: 22, weight: .semibold)
        text("键入搜索", 430, 912, size: 22, weight: .semibold)
        text("仅需辅助功能权限", 730, 912, size: 22, weight: .semibold)
        text("AGPL-3.0-only", 1462, 915, size: 17, color: muted, width: 280)
    }
    private func drawSocial() {
        box(bounds, color: ink)
        picture(icon, NSRect(x: 75, y: 60, width: 105, height: 105))
        text("窗序", 198, 84, size: 44, color: .white, weight: .semibold)
        text("按窗口切换。\n把注意力，留给当前。", 90, 257, size: 64, color: .white, weight: .semibold, width: 1070)
        box(NSRect(x: 1130, y: 120, width: 1, height: 610), color: NSColor.white.withAlphaComponent(0.18))
        text("切换窗口", 1205, 255, size: 23, color: .white)
        key("⌥ Tab", 1205, 303, width: 245, dark: true)
        text("固定搜索", 1205, 428, size: 23, color: .white)
        key("⌥ Space", 1205, 476, width: 245, dark: true)
        text("支持自定义与清除快捷键", 1205, 565, size: 17, color: NSColor.white.withAlphaComponent(0.65), width: 300)
        box(NSRect(x: 90, y: 745, width: 1420, height: 1), color: NSColor.white.withAlphaComponent(0.18))
        text("macOS 窗口切换工具", 90, 793, size: 22, color: NSColor.white.withAlphaComponent(0.72))
        text("本地处理 · 仅需辅助功能", 700, 793, size: 22, color: NSColor.white.withAlphaComponent(0.72))
        text("AGPL-3.0-only", 1280, 800, size: 16, color: NSColor.white.withAlphaComponent(0.6), width: 250)
    }
}
for (name, size, social) in [("hero", NSSize(width: 1800, height: 1000), false), ("social-card", NSSize(width: 1600, height: 900), true)] {
    let view = Artwork(size: size, social: social)
    view.appearance = NSAppearance(named: .aqua)
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
    print("Rendered \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
}
