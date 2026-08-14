import AppKit
import Foundation

/// WeChatMover 图标离屏绘制（无第三方依赖）：
/// 微信绿（#07C160）圆角方形底 + 白色聊天气泡 + 穿透气泡的绿色右箭头
/// （气泡=微信，箭头向右穿出=数据迁出到外置盘）。输出到 Resources/AppIcon.iconset。

let wechatGreen = NSColor(srgbRed: 0x07 / 255, green: 0xC1 / 255, blue: 0x60 / 255, alpha: 1)

func draw(size s: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    // 背景：微信绿 squircle（连续圆角近似 22.5% 半径）
    wechatGreen.setFill()
    NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225).fill()

    // 白色聊天气泡（圆角矩形 + 左下小尾巴）
    NSColor.white.setFill()
    let bubble = NSRect(x: s * 0.17, y: s * 0.28, width: s * 0.66, height: s * 0.46)
    NSBezierPath(roundedRect: bubble, xRadius: s * 0.16, yRadius: s * 0.16).fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: s * 0.30, y: s * 0.31))
    tail.line(to: NSPoint(x: s * 0.23, y: s * 0.15))
    tail.line(to: NSPoint(x: s * 0.44, y: s * 0.28))
    tail.close()
    tail.fill()

    // 气泡内的绿色右箭头（数据从微信"穿出"）
    wechatGreen.setFill()
    let shaft = NSRect(x: s * 0.30, y: s * 0.472, width: s * 0.26, height: s * 0.076)
    NSBezierPath(roundedRect: shaft, xRadius: s * 0.038, yRadius: s * 0.038).fill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: s * 0.52, y: s * 0.60))
    head.line(to: NSPoint(x: s * 0.70, y: s * 0.51))
    head.line(to: NSPoint(x: s * 0.52, y: s * 0.42))
    head.close()
    head.fill()
}

func render(px: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconset 标准命名：点尺寸 + @2x 像素文件
let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for entry in entries {
    try render(px: entry.px, to: iconset.appendingPathComponent(entry.name))
}
print("iconset 已生成：\(iconset.path)")
