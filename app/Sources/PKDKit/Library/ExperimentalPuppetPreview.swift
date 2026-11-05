import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 场景文件顺序下的 2D 图层与多个 puppet 默认静态姿态；不执行脚本、粒子或动画。
public enum ExperimentalPuppetPreview {
    public static let outputName = "场景预览-实验.png"

    public static func render(in directory: URL) throws -> Bool {
        func safeURL(_ path: String) throws -> URL {
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains("..") else { throw PreviewError.unsupportedScene }
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/") else { throw PreviewError.unsupportedScene }
            return url
        }
        func readJSON(_ path: String) throws -> [String: Any] {
            let url = try safeURL(path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= 10_000_000,
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw PreviewError.unsupportedScene }
            return json
        }
        let json = try readJSON("scene.json")
        // 目录里多张纹理只是预检线索；没有实际图片层引用时保持普通导出。
        guard let objects = json["objects"] as? [[String: Any]], objects.contains(where: { $0["image"] is String }) else { return false }
        guard let general = json["general"] as? [String: Any],
              let projection = general["orthogonalprojection"] as? [String: Any],
              let w = projection["width"] as? Int, let h = projection["height"] as? Int,
              (1...8192).contains(w), (1...8192).contains(h),
              objects.count <= 1000 else { throw PreviewError.unsupportedScene }
        let outputScale = min(4.0, 4096.0 / CGFloat(max(w, h)))
        let width = max(1, Int((CGFloat(w) * outputScale).rounded()))
        let height = max(1, Int((CGFloat(h) * outputScale).rounded()))
        let bg = try numbers(general["clearcolor"], fallback: [0, 0, 0])
        var byID: [Int: [String: Any]] = [:]
        for object in objects {
            if let id = object["id"] as? Int {
                guard byID[id] == nil else { throw PreviewError.unsupportedScene }
                byID[id] = object
            }
        }
        func parentChain(_ object: [String: Any]) throws -> [[String: Any]]? {
            var chain: [[String: Any]] = []
            var current = object
            var visited = Set<Int>()
            while let reference = current["parent"] {
                guard let id = reference as? Int, visited.insert(id).inserted,
                      visited.count <= 64, let parent = byID[id] else { throw PreviewError.unsupportedScene }
                if let rawVisible = parent["visible"] {
                    guard let visible = try defaultValue(rawVisible) as? Bool else { throw PreviewError.unsupportedScene }
                    if !visible { return nil }
                }
                if let alpha = parent["alpha"] {
                    guard let value = alpha as? Double, value == 1 else { throw PreviewError.unsupportedScene }
                }
                chain.append(parent)
                current = parent
            }
            return chain.reversed()
        }
        struct Layer { let object: [String: Any]; let parents: [[String: Any]]; let model: URL?; let texture: URL }
        var layers: [Layer] = []
        for object in objects {
            if let rawVisible = object["visible"] {
                let visible = try defaultValue(rawVisible)
                guard let visible = visible as? Bool else { throw PreviewError.unsupportedScene }
                if !visible { continue }
            }
            if let path = object["image"] as? String, path.lowercased().hasSuffix(".mdl") { throw PreviewError.unsupportedScene }
            guard let imagePath = object["image"] as? String, imagePath.hasSuffix(".json") else { continue }
            let url = try safeURL(imagePath)
            if !FileManager.default.fileExists(atPath: url.path) {
                if imagePath.hasPrefix("models/util/") { continue }
                throw PreviewError.unsupportedScene
            }
            guard let parents = try parentChain(object) else { continue }
            let descriptor = try readJSON(imagePath)
            // The scene object's origin places the cropped image. cropoffset records
            // editor crop metadata; applying it a second time would move the layer.
            _ = try numbers(descriptor["cropoffset"], fallback: [0, 0])
            guard let materialPath = descriptor["material"] as? String else { throw PreviewError.unsupportedScene }
            let material = try readJSON(materialPath)
            guard let passes = material["passes"] as? [[String: Any]], passes.count == 1,
                  let textures = passes[0]["textures"] as? [Any], textures.count == 1,
                  let textureName = textures.first as? String,
                  let shader = passes[0]["shader"] as? String,
                  ["genericimage", "genericimage2", "genericimage3", "genericimage4"].contains(shader),
                  ["translucent", "normal"].contains(passes[0]["blending"] as? String ?? "translucent") else { throw PreviewError.unsupportedScene }
            let texturePath = textureName.hasPrefix("materials/") ? textureName : "materials/" + textureName
            let puppet = try (descriptor["puppet"] as? String).map { try safeURL($0) }
            guard descriptor["puppet"] == nil || puppet != nil else { throw PreviewError.unsupportedScene }
            let textureURLs = try ["png", "jpg", "jpeg", "webp"].map { try safeURL(texturePath + "." + $0) }
            guard let texture = textureURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw PreviewError.invalidTexture }
            layers.append(Layer(object: object, parents: parents, model: puppet, texture: texture))
        }
        guard !layers.isEmpty else { return false }
        if objects.count == 1, layers.count == 1, layers[0].model == nil, layers[0].parents.isEmpty {
            let object = layers[0].object
            let origin = try numbers(object["origin"], fallback: [0, 0, 0])
            let size = try numbers(object["size"], fallback: [0, 0])
            let scale = try numbers(object["scale"], fallback: [1, 1, 1])
            let angles = try numbers(object["angles"], fallback: [0, 0, 0])
            let effects = object["effects"] as? [Any]
            let source = CGImageSourceCreateWithURL(layers[0].texture as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            let metadata = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let imageWidth = metadata?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let imageHeight = metadata?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if abs(origin[0] - Double(w) / 2) < 0.00001,
               abs(origin[1] - Double(h) / 2) < 0.00001,
               abs(size[0] - Double(w)) < 0.00001, abs(size[1] - Double(h)) < 0.00001,
               scale.allSatisfy({ abs($0 - 1) < 0.00001 }),
               angles.allSatisfy({ abs($0) < 0.00001 }),
               (object["alpha"] as? Double ?? 1) == 1,
               (1...8192).contains(imageWidth), (1...8192).contains(imageHeight),
               Int64(imageWidth) * Int64(h) == Int64(imageHeight) * Int64(w),
               object["color"] == nil, object["brightness"] == nil,
               object["effects"] == nil || effects?.isEmpty == true {
                return false
            }
        }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PreviewError.writeFailed }
        ctx.setFillColor(red: max(0, min(1, bg[0])), green: max(0, min(1, bg[1])), blue: max(0, min(1, bg[2])), alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(false) // 分别裁切的三角形边缘不可半透明，否则出现网格裂缝。
        ctx.scaleBy(x: outputScale, y: outputScale)
        for layer in layers {
            try Task.checkCancellation()
            try autoreleasepool {
                let origin = try numbers(layer.object["origin"], fallback: [0, 0, 0])
                let scale = try numbers(layer.object["scale"], fallback: [1, 1, 1])
                let angles = try numbers(layer.object["angles"], fallback: [0, 0, 0])
                let color = try numbers(layer.object["color"], fallback: [1, 1, 1])
                guard layer.object["alpha"] == nil || layer.object["alpha"] is NSNumber,
                      layer.object["brightness"] == nil || layer.object["brightness"] is NSNumber else { throw PreviewError.unsupportedScene }
                guard abs(angles[0]) < 0.00001, abs(angles[1]) < 0.00001,
                      color.allSatisfy({ abs($0-1) < 0.00001 }),
                      (layer.object["brightness"] as? Double ?? 1) == 1 else { throw PreviewError.unsupportedScene }
                let alpha = layer.object["alpha"] as? Double ?? 1
                guard alpha.isFinite, (0...1).contains(alpha), !(layer.object["alpha"] is [String: Any]) else { throw PreviewError.unsupportedScene }
                guard let source = CGImageSourceCreateWithURL(layer.texture as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let iw = metadata[kCGImagePropertyPixelWidth] as? Int, let ih = metadata[kCGImagePropertyPixelHeight] as? Int,
                      (1...8192).contains(iw), (1...8192).contains(ih),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PreviewError.invalidTexture }
                ctx.saveGState()
                defer { ctx.restoreGState() }
                for parent in layer.parents {
                    let position = try numbers(parent["origin"], fallback: [0, 0, 0])
                    let rotation = try numbers(parent["angles"], fallback: [0, 0, 0])
                    let parentScale = try numbers(parent["scale"], fallback: [1, 1, 1])
                    guard abs(rotation[0]) < 0.00001, abs(rotation[1]) < 0.00001 else { throw PreviewError.unsupportedScene }
                    ctx.translateBy(x: position[0], y: position[1])
                    ctx.rotate(by: rotation[2] * .pi / 180)
                    ctx.scaleBy(x: parentScale[0], y: parentScale[1])
                }
                ctx.translateBy(x: origin[0], y: origin[1])
                ctx.rotate(by: angles[2] * .pi / 180)
                ctx.scaleBy(x: scale[0], y: scale[1])
                ctx.setAlpha(alpha)
                // 透明度应用于整层，不能逐三角形重复叠加共享边缘。
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                defer { ctx.endTransparencyLayer() }
                if let model = layer.model {
                    try drawMesh(model: model, image: image, context: ctx)
                } else {
                    let size = try numbers(layer.object["size"], fallback: [CGFloat(iw), CGFloat(ih)])
                    guard size[0] > 0, size[1] > 0 else { throw PreviewError.unsupportedScene }
                    ctx.draw(image, in: CGRect(x: -size[0]/2, y: -size[1]/2, width: size[0], height: size[1]))
                }
            }
        }
        try Task.checkCancellation()
        let encoded = NSMutableData()
        guard let output = ctx.makeImage(), let dest = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw PreviewError.writeFailed }
        CGImageDestinationAddImage(dest, output, nil)
        guard CGImageDestinationFinalize(dest) else { throw PreviewError.writeFailed }
        try (encoded as Data).write(to: directory.appendingPathComponent(outputName), options: .atomic)
        return true
    }

    private static func numbers(_ value: Any?, fallback: [CGFloat]) throws -> [CGFloat] {
        guard let value else { return fallback }
        guard let text = try defaultValue(value) as? String else { throw PreviewError.unsupportedScene }
        let pieces = text.split(whereSeparator: { $0.isWhitespace })
        let parts = pieces.compactMap { Double($0) }
        guard parts.count == pieces.count, parts.count == fallback.count,
              parts.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) else { throw PreviewError.unsupportedScene }
        return parts.map { CGFloat($0) }
    }

    private static func defaultValue(_ value: Any) throws -> Any {
        guard let wrapped = value as? [String: Any] else { return value }
        // User-property bindings have an explicit static default; scripts and
        // animation bindings need a runtime and remain unsupported.
        guard Set(wrapped.keys).isSubset(of: ["user", "value"]),
              wrapped["user"] != nil, let fallback = wrapped["value"],
              !(fallback is [String: Any]) else { throw PreviewError.unsupportedScene }
        return fallback
    }

    private static func drawMesh(model: URL, image: CGImage, context ctx: CGContext) throws {
        let values = try model.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, (128...50_000_000).contains(size) else { throw PreviewError.invalidModel }
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
        guard indexBytes > 0, indexBytes % 6 == 0, indexBytes <= data.count - indexOffset - 4, count <= 100_000 else { throw PreviewError.invalidModel }
        struct Vertex { let x: CGFloat; let y: CGFloat; let u: CGFloat; let v: CGFloat }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(count)
        for i in 0..<count {
            let p = start + i * 80
            guard abs(try f32(p+8)) < 0.00001 else { throw PreviewError.unsupportedScene }
            vertices.append(try Vertex(x: f32(p), y: f32(p+4), u: f32(p+72), v: f32(p+76)))
        }
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for p in stride(from: indexOffset + 4, to: indexOffset + 4 + indexBytes, by: 6) {
            if (p - indexOffset) % 6000 == 4 { try Task.checkCancellation() }
            let ids = (0..<3).map { Int(data[p+$0*2]) | Int(data[p+$0*2+1]) << 8 }
            guard ids.allSatisfy({ $0 < count }) else { throw PreviewError.invalidModel }
            let vs = ids.map { vertices[$0] }
            let s = vs.map { CGPoint(x: $0.u * CGFloat(image.width), y: (1 - $0.v) * CGFloat(image.height)) }
            let d = vs.map { CGPoint(x: $0.x, y: $0.y) }
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
