import Foundation
import ImageIO
import CoreGraphics

/// 缩略图加载：**必须**在解码阶段降采样。
///
/// 素材库里出现过 8000×4500 的 preview，整图解码一次约 130MB；
/// `CGImageSourceCreateThumbnailAtIndex` 让 JPEG 走 DCT 缩放，内存峰值≈缩略图大小。
public enum ThumbnailLoader {
    private static let cache = ThumbnailCache()

    public static func thumbnail(for url: URL, maxPixel: Int = 320) -> CGImage? {
        let key = "\(url.path)|\(maxPixel)|\(modificationStamp(of: url))" as NSString
        if let cached = cache.value(for: key) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        cache.store(image, for: key)
        return image
    }

    private static func modificationStamp(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let time = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return Int(time) ^ size
    }
}

final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CGImageBox>()

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 256
    }

    func value(for key: NSString) -> CGImage? {
        cache.object(forKey: key)?.image
    }

    func store(_ image: CGImage, for key: NSString) {
        let cost = image.width * image.height * 4
        cache.setObject(CGImageBox(image: image), forKey: key, cost: cost)
    }
}

final class CGImageBox {
    let image: CGImage
    init(image: CGImage) { self.image = image }
}
