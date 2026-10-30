#!/usr/bin/env swift
// 生成 1024×1024 应用图标母图（无 Xcode/actool 环境下的替代方案）
import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("无法创建位图\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

// 圆角底板 + 渐变
let plate = NSBezierPath(roundedRect: canvas.insetBy(dx: 48, dy: 48), xRadius: 190, yRadius: 190)
if let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.24, green: 0.32, blue: 0.86, alpha: 1.0),
    NSColor(calibratedRed: 0.53, green: 0.26, blue: 0.82, alpha: 1.0),
]) {
    gradient.draw(in: plate, angle: -50)
}

// 中央符号
let configuration = NSImage.SymbolConfiguration(pointSize: 460, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    let symbolSize = symbol.size
    let target = NSRect(
        x: (CGFloat(size) - symbolSize.width) / 2,
        y: (CGFloat(size) - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.96)
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}

do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("已生成 \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("写入失败：\(error)\n".utf8))
    exit(1)
}
