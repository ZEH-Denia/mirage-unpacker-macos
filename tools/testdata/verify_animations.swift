import Foundation
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count == 2 else { fatalError("Expected extracted materials directory") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for name in ["encoded.gif", "raw.gif"] {
    let url = root.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 2 else {
        fatalError("Missing two-frame GIF: \(name)")
    }
    for (index, expected) in [[255, 0, 0], [0, 255, 0]].enumerated() {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width == 8, image.height == 8 else {
            fatalError("Invalid frame dimensions: \(name) frame \(index)")
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let correct = pixel.withUnsafeMutableBytes { data -> Bool in
            guard let ctx = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = data.bindMemory(to: UInt8.self)
            return (0..<3).allSatisfy { abs(Int(bytes[$0]) - expected[$0]) <= 5 }
        }
        guard correct else { fatalError("Wrong frame pixels: \(name) frame \(index)") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        guard abs(delay - (index == 0 ? 0.1 : 0.2)) < 0.02 else { fatalError("Wrong frame duration: \(name)") }
    }
}
print("✅ PNG-backed and raw animations: frames, pixels, dimensions and durations verified")
