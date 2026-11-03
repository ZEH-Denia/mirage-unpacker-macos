import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 从场景实际引用中识别单个 puppet，绘制实验性的默认静态姿态。
/// 其他对象和动态效果暂不渲染；不支持的结构显式失败并保留素材。
public enum ExperimentalPuppetPreview {
    public static let outputName = "场景预览-实验.png"

    /// Returns false when no visible puppet is referenced by the scene.
    public static func render(in directory: URL) throws -> Bool {
        func safeURL(_ path: String) throws -> URL {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw PreviewError.unsupportedScene }
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/") else { throw PreviewError.unsupportedScene }
            return url
        }
        func readJSON(_ path: String) throws -> [String: Any] {
            let url = try safeURL(path)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10_000_000,
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw PreviewError.unsupportedScene }
            return json
        }
        func numbers(_ value: Any?, fallback: [CGFloat]) throws -> [CGFloat] {
            guard let value else { return fallback }
            guard let text = value as? String else { throw PreviewError.unsupportedScene }
            let parts = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
            guard parts.count >= fallback.count, parts.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) else { throw PreviewError.unsupportedScene }
            return parts.map { CGFloat($0) }
        }
        let json = try readJSON("scene.json")
        guard let general = json["general"] as? [String: Any],
              let projection = general["orthogonalprojection"] as? [String: Any],
              let w = projection["width"] as? Int, let h = projection["height"] as? Int,
              (1...8192).contains(w), (1...8192).contains(h),
              let objects = json["objects"] as? [[String: Any]] else { throw PreviewError.unsupportedScene }
        // 小画布渲染至最多 4 倍；长边上限控制内存，避免并发导出时分配过大。
        let outputScale = min(4.0, 4096.0 / CGFloat(max(w, h)))
        let width = max(1, Int((CGFloat(w) * outputScale).rounded()))
        let height = max(1, Int((CGFloat(h) * outputScale).rounded()))
        let bg = try numbers(general["clearcolor"], fallback: [0, 0, 0])
        var candidates: [(object: [String: Any], model: URL, texture: URL)] = []
        for object in objects {
            if let visible = object["visible"] as? Bool, !visible { continue }
            if let path = object["image"] as? String, path.lowercased().hasSuffix(".mdl") { throw PreviewError.unsupportedScene }
            guard let imagePath = object["image"] as? String, imagePath.hasSuffix(".json") else { continue }
            let url = try safeURL(imagePath)
            if !FileManager.default.fileExists(atPath: url.path) {
                if imagePath.hasPrefix("models/util/") { continue }
                throw PreviewError.unsupportedScene
            }
            let descriptor = try readJSON(imagePath)
            guard let puppet = descriptor["puppet"] as? String else { continue }
            guard let materialPath = descriptor["material"] as? String else { throw PreviewError.unsupportedScene }
            let material = try readJSON(materialPath)
            guard let passes = material["passes"] as? [[String: Any]], passes.count == 1,
                  let textures = passes[0]["textures"] as? [Any], let textureName = textures.first as? String else { throw PreviewError.unsupportedScene }
            let texturePath = textureName.hasPrefix("materials/") ? textureName : "materials/" + textureName
            candidates.append((object, try safeURL(puppet), try safeURL(texturePath + ".png")))
        }
        guard !candidates.isEmpty else { return false }
        guard candidates.count == 1 else { throw PreviewError.unsupportedScene }
        let candidate = candidates[0], model = candidate.model, texture = candidate.texture
        guard !(candidate.object["visible"] is [String: Any]) else { throw PreviewError.unsupportedScene }
        let origin = try numbers(candidate.object["origin"], fallback: [0, 0, 0])
        let scale = try numbers(candidate.object["scale"], fallback: [1, 1, 1])
        let angles = try numbers(candidate.object["angles"], fallback: [0, 0, 0])
        guard angles.allSatisfy({ abs($0) < 0.00001 }) else { throw PreviewError.unsupportedScene }
        let data = try Data(contentsOf: model)
        guard data.count >= 128, data.count <= 50_000_000,
              (data.prefix(8) == Data("MDLV0023".utf8) || data.prefix(8) == Data("MDLV0021".utf8)),
              let end = data[21...].firstIndex(of: 0) else { throw PreviewError.invalidModel }
        let offset = end + 29
        func u32(_ i: Int) throws -> Int {
            guard i >= 0, i <= data.count - 4 else { throw PreviewError.invalidModel }
            return Int(UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24)
        }
        func f32(_ i: Int) throws -> CGFloat {
            let f = Float(bitPattern: UInt32(try u32(i)))
            guard f.isFinite, abs(f) < 1_000_000 else { throw PreviewError.invalidModel }
            return CGFloat(f)
        }
        guard try u32(offset) == 0x0180000f else { throw PreviewError.invalidModel }
        let length = try u32(offset + 4)
        guard length > 0, length % 80 == 0, length <= data.count - offset - 12 else { throw PreviewError.invalidModel }
        let start = offset + 8, count = length / 80, indexOffset = start + length
        let indexBytes = try u32(indexOffset)
        guard indexBytes % 6 == 0, indexBytes <= data.count - indexOffset - 4, count <= 100_000 else { throw PreviewError.invalidModel }
        struct Vertex { let x: CGFloat; let y: CGFloat; let u: CGFloat; let v: CGFloat }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(count)
        for i in 0..<count {
            let p = start + i * 80
            vertices.append(try Vertex(x: f32(p), y: f32(p+4), u: f32(p+72), v: f32(p+76)))
        }
        guard let source = CGImageSourceCreateWithURL(texture as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PreviewError.invalidTexture }
        ctx.setFillColor(red: max(0, min(1, bg[0])), green: max(0, min(1, bg[1])), blue: max(0, min(1, bg[2])), alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .medium
        // 相邻三角形分别裁切时，抗锯齿会让边缘半透明并产生网格裂缝。
        ctx.setShouldAntialias(false)
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for p in stride(from: indexOffset + 4, to: indexOffset + 4 + indexBytes, by: 6) {
            if (p - indexOffset) % 6000 == 4 { try Task.checkCancellation() }
            let ids = (0..<3).map { Int(data[p+$0*2]) | Int(data[p+$0*2+1]) << 8 }
            guard ids.allSatisfy({ $0 < count }) else { throw PreviewError.invalidModel }
            let vs = ids.map { vertices[$0] }
            let s = vs.map { CGPoint(x: $0.u * CGFloat(image.width), y: (1 - $0.v) * CGFloat(image.height)) }
            let d = vs.map { CGPoint(x: (origin[0] + scale[0] * $0.x) * outputScale, y: (origin[1] + scale[1] * $0.y) * outputScale) }
            let sx1 = s[1].x-s[0].x, sy1 = s[1].y-s[0].y, sx2 = s[2].x-s[0].x, sy2 = s[2].y-s[0].y
            let det = sx1*sy2-sx2*sy1
            guard abs(det) > 0.00001 else { continue }
            let dx1 = d[1].x-d[0].x, dy1 = d[1].y-d[0].y, dx2 = d[2].x-d[0].x, dy2 = d[2].y-d[0].y
            let a = (dx1*sy2-dx2*sy1)/det, c = (dx2*sx1-dx1*sx2)/det
            let b = (dy1*sy2-dy2*sy1)/det, e = (dy2*sx1-dy1*sx2)/det
            let transform = CGAffineTransform(a: a, b: b, c: c, d: e, tx: d[0].x-a*s[0].x-c*s[0].y, ty: d[0].y-b*s[0].x-e*s[0].y)
            ctx.saveGState()
            ctx.beginPath(); ctx.move(to: d[0]); ctx.addLine(to: d[1]); ctx.addLine(to: d[2]); ctx.closePath(); ctx.clip()
            ctx.concatenate(transform); ctx.draw(image, in: imageRect); ctx.restoreGState()
        }
        try Task.checkCancellation()
        guard let output = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(directory.appendingPathComponent(outputName) as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw PreviewError.writeFailed }
        CGImageDestinationAddImage(dest, output, nil)
        guard CGImageDestinationFinalize(dest) else { throw PreviewError.writeFailed }
        return true
    }
    private enum PreviewError: LocalizedError {
        case unsupportedScene, invalidModel, invalidTexture, writeFailed
        var errorDescription: String? {
            switch self {
            case .unsupportedScene: return "场景结构或引用暂不支持静态预览"
            case .invalidModel: return "puppet 模型格式无效或暂不支持"
            case .invalidTexture: return "图集不存在或尺寸不匹配，请启用 TEX 转换"
            case .writeFailed: return "无法写入场景预览"
            }
        }
    }
}
