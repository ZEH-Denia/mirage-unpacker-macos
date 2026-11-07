import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 一次静态预览的组成说明，供界面如实告知限制，避免“成功但画面不完整”无从察觉。
public struct ScenePreviewReport: Sendable, Equatable {
    /// 实际绘制的图层数量。
    public var drawnLayers = 0
    /// 使用了脚本/动画绑定属性的静态默认值（脚本与动画不执行）。
    public var approximatedBindings = 0
    /// 带条件的用户属性绑定：条件未求值，只用了保存的默认值。
    public var conditionalBindings = 0
    /// 非图片对象（文本、粒子、音频、分组等），静态预览不渲染。
    public var undrawnObjects = 0
    /// 带效果但未应用效果的图层数量。
    public var ignoredEffects = 0
    /// 引用了引擎内建、包内不存在的模型而跳过的图层数量。
    public var skippedBuiltinLayers = 0
    /// 应用了色调（color）的图层数量。
    public var tintedLayers = 0
    /// 以内建纯色模型（solidlayer*）绘制的图层数量。
    public var solidLayers = 0
    /// 纯色层带 colorBlendMode（BLENDMODE 混合语义未实现）而跳过的数量。
    public var skippedBlendLayers = 0
    /// 按动画首帧姿态蒙皮绘制的 puppet 数量。
    public var posedPuppets = 0

    public var summary: String {
        var parts = ["已组合 \(drawnLayers) 个图层"]
        if approximatedBindings > 0 { parts.append("\(approximatedBindings) 处脚本/动画绑定按静态默认值") }
        if conditionalBindings > 0 { parts.append("\(conditionalBindings) 处条件绑定未求值") }
        if undrawnObjects > 0 { parts.append("\(undrawnObjects) 个非图片对象未渲染") }
        if ignoredEffects > 0 { parts.append("\(ignoredEffects) 个图层效果未包含") }
        if skippedBuiltinLayers > 0 { parts.append("跳过 \(skippedBuiltinLayers) 个引擎内建图层") }
        if tintedLayers > 0 { parts.append("\(tintedLayers) 个图层应用了色调") }
        if solidLayers > 0 { parts.append("\(solidLayers) 个内建纯色图层") }
        if skippedBlendLayers > 0 { parts.append("\(skippedBlendLayers) 个纯色层因混合模式未支持而跳过") }
        if posedPuppets > 0 { parts.append("\(posedPuppets) 个 puppet 按动画首帧姿态") }
        return parts.joined(separator: "；")
    }
}

public struct SceneRenderOutcome: Sendable {
    public let rendered: Bool
    public let report: ScenePreviewReport
}

/// 场景文件顺序下的 2D 图层与多个 puppet 默认静态姿态；不执行脚本、粒子或动画。
public enum ExperimentalPuppetPreview {
    public static let outputName = "场景预览-实验.png"

    public static func render(in directory: URL) throws -> Bool {
        try renderDetailed(in: directory).rendered
    }

    public static func renderDetailed(in directory: URL) throws -> SceneRenderOutcome {
        func safeURL(_ path: String) throws -> URL {
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains("..") else {
                throw PreviewError.unsupportedScene
            }
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/") else { throw PreviewError.unsupportedScene }
            return url
        }
        func readJSON(_ path: String) throws -> [String: Any] {
            let url = try safeURL(path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= 10_000_000,
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw PreviewError.unsupportedScene
            }
            return json
        }
        var report = ScenePreviewReport()
        let json = try readJSON("scene.json")
        // 目录里多张纹理只是预检线索；没有实际图片层引用时保持普通导出。
        guard let objects = json["objects"] as? [[String: Any]],
              objects.contains(where: { $0["image"] is String }) else {
            return SceneRenderOutcome(rendered: false, report: report)
        }
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
        // 返回父链（外→内）。层级只用于变换；不透明度与色调是逐层属性，不沿父子链相乘
        // （可检查的场景渲染实现里 CImage::getAlpha/getColor 只读取对象自身的值）。
        func parentChain(_ object: [String: Any]) throws -> [[String: Any]]? {
            var chain: [[String: Any]] = []
            var current = object
            var visited = Set<Int>()
            while let reference = current["parent"] {
                guard let id = reference as? Int, visited.insert(id).inserted,
                      visited.count <= 64, let parent = byID[id] else { throw PreviewError.unsupportedScene }
                if let rawVisible = parent["visible"] {
                    guard let visible = try resolve(rawVisible) as? Bool else { throw PreviewError.unsupportedScene }
                    if !visible { return nil }
                }
                chain.append(parent)
                current = parent
            }
            return chain.reversed()
        }
        struct Layer {
            let object: [String: Any]
            let parents: [[String: Any]]
            let model: URL?
            let texture: URL?
            /// 引擎内建纯色层（flat 着色器只输出 color 与 alpha）的填充色。
            let solid: [CGFloat]?
            let tint: [CGFloat]
            let alpha: CGFloat
            let animationLayers: [[String: Any]]
        }
        var layers: [Layer] = []
        for object in objects {
            if let rawVisible = object["visible"] {
                guard let visible = try resolve(rawVisible) as? Bool else { throw PreviewError.unsupportedScene }
                if !visible { continue }
            }
            if let path = object["image"] as? String, path.lowercased().hasSuffix(".mdl") {
                throw PreviewError.unsupportedScene
            }
            guard let imagePath = object["image"] as? String, imagePath.hasSuffix(".json") else {
                report.undrawnObjects += 1
                continue
            }
            let url = try safeURL(imagePath)
            // 引擎内建 util 模型不在包内，语义由引擎 assets 定义（已核对 assets/models/util/*.json
            // 与其材质/着色器）：
            //   solidlayer* → flat 着色器输出 vec4(g_Color, g_Alpha)，即纯色矩形；
            //   composelayer*/projectlayer/fullscreenlayer → 全屏 copy（passthrough），
            //   自身不产生内容，子层照常绘制。
            var paint: Paint = .texture
            if !FileManager.default.fileExists(atPath: url.path) {
                guard imagePath.hasPrefix("models/util/") else { throw PreviewError.unsupportedScene }
                switch builtinLayerKind(imagePath) {
                case .solid: paint = .solid
                case .container, .unknown:
                    report.skippedBuiltinLayers += 1
                    continue
                }
            }
            guard let parents = try parentChain(object) else { continue }
            if paint == .texture {
                let descriptor = try readJSON(imagePath)
                // 场景对象的 origin 决定裁剪后图片的位置。cropoffset 记录编辑期裁剪元数据，
                // 再次叠加会移动图层；本机真实样本中纹理像素与对象尺寸一一对应。
                _ = try numbers(descriptor["cropoffset"], fallback: [0, 0])
                if declaresTrue(descriptor["solidlayer"]) {
                    paint = .solid
                } else if declaresTrue(descriptor["composelayer"]) {
                    report.skippedBuiltinLayers += 1
                    continue
                }
                if paint == .texture {
                    guard let materialPath = descriptor["material"] as? String else {
                        throw PreviewError.unsupportedScene
                    }
                    let material = try readJSON(materialPath)
                    guard let passes = material["passes"] as? [[String: Any]], passes.count == 1,
                          let textures = passes[0]["textures"] as? [Any], textures.count == 1,
                          let textureName = textures.first as? String,
                          let shader = passes[0]["shader"] as? String,
                          ["genericimage", "genericimage2", "genericimage3", "genericimage4"].contains(shader),
                          ["translucent", "normal"].contains(passes[0]["blending"] as? String ?? "translucent") else {
                        throw PreviewError.unsupportedScene
                    }
                    let texturePath = textureName.hasPrefix("materials/") ? textureName : "materials/" + textureName
                    let puppet = try (descriptor["puppet"] as? String).map { try safeURL($0) }
                    guard descriptor["puppet"] == nil || puppet != nil else { throw PreviewError.unsupportedScene }
                    let textureURLs = try ["png", "jpg", "jpeg", "webp"].map { try safeURL(texturePath + "." + $0) }
                    guard let texture = textureURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                        throw PreviewError.invalidTexture
                    }
                    // 先判断是否真的会绘制；不可见图层不应因外观属性而回退整张预览。
                    let alpha = try normalizedAlpha(object["alpha"])
                    guard alpha > 0 else { continue }
                    try requireUnmodifiedAppearance(object)
                    let tint = try colorTint(object)
                    if tint.contains(where: { abs($0 - 1) > 0.00001 }) { report.tintedLayers += 1 }
                    record(object, report: &report)
                    layers.append(Layer(object: object, parents: parents, model: puppet, texture: texture,
                                        solid: nil, tint: tint, alpha: alpha,
                                        animationLayers: object["animationlayers"] as? [[String: Any]] ?? []))
                    continue
                }
            }
            // 内建纯色层：flat 着色器直接用对象颜色与 alpha。
            let alpha = try normalizedAlpha(object["alpha"])
            guard alpha > 0 else {
                report.skippedBuiltinLayers += 1
                continue
            }
            // flat 自身不含 BLENDMODE；带 colorBlendMode 的纯色层需要引擎的混合 pass，
            // 语义未实现时按跳过处理并计数，避免按 source-over 画出错误画面。
            if object["colorBlendMode"] != nil {
                report.skippedBlendLayers += 1
                continue
            }
            try requireUnmodifiedAppearance(object)
            let fill = try solidFill(object)
            record(object, report: &report)
            report.solidLayers += 1
            layers.append(Layer(object: object, parents: parents, model: nil, texture: nil,
                                solid: fill, tint: [1, 1, 1], alpha: alpha, animationLayers: []))
        }
        guard !layers.isEmpty else { return SceneRenderOutcome(rendered: false, report: report) }
        if objects.count == 1, layers.count == 1, layers[0].model == nil, layers[0].parents.isEmpty,
           let texture = layers[0].texture {
            let object = layers[0].object
            let origin = try numbers(object["origin"], fallback: [0, 0, 0])
            let size = try objectSize(object, texture: texture)
            let scale = try numbers(object["scale"], fallback: [1, 1, 1])
            let angles = try numbers(object["angles"], fallback: [0, 0, 0])
            let effects = object["effects"] as? [Any]
            let source = CGImageSourceCreateWithURL(texture as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            let metadata = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let imageWidth = metadata?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let imageHeight = metadata?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if abs(origin[0] - CGFloat(w) / 2) < 0.00001,
               abs(origin[1] - CGFloat(h) / 2) < 0.00001,
               abs(size[0] - CGFloat(w)) < 0.00001, abs(size[1] - CGFloat(h)) < 0.00001,
               scale.allSatisfy({ abs($0 - 1) < 0.00001 }),
               angles.allSatisfy({ abs($0) < 0.00001 }),
               layers[0].alpha == 1, layers[0].tint.allSatisfy({ abs($0 - 1) < 0.00001 }),
               (1...8192).contains(imageWidth), (1...8192).contains(imageHeight),
               Int64(imageWidth) * Int64(h) == Int64(imageHeight) * Int64(w),
               object["color"] == nil, object["brightness"] == nil,
               object["colorBlendMode"] == nil,
               object["effects"] == nil || effects?.isEmpty == true {
                return SceneRenderOutcome(rendered: false, report: report)
            }
        }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreviewError.writeFailed
        }
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
                // 静态 scene.json 的 angles 以弧度保存（脚本 API 才是角度制）。
                let angles = try numbers(layer.object["angles"], fallback: [0, 0, 0])
                guard abs(angles[0]) < 0.00001, abs(angles[1]) < 0.00001 else {
                    throw PreviewError.unsupportedScene
                }
                var tinted: CGImage?
                if let texture = layer.texture {
                    guard let source = CGImageSourceCreateWithURL(texture as CFURL,
                                                                  [kCGImageSourceShouldCache: false] as CFDictionary),
                          let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let iw = metadata[kCGImagePropertyPixelWidth] as? Int,
                          let ih = metadata[kCGImagePropertyPixelHeight] as? Int,
                          (1...8192).contains(iw), (1...8192).contains(ih),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw PreviewError.invalidTexture
                    }
                    tinted = try tintedImage(image, tint: layer.tint)
                }
                ctx.saveGState()
                defer { ctx.restoreGState() }
                for parent in layer.parents {
                    let position = try numbers(parent["origin"], fallback: [0, 0, 0])
                    let rotation = try numbers(parent["angles"], fallback: [0, 0, 0])
                    let parentScale = try numbers(parent["scale"], fallback: [1, 1, 1])
                    guard abs(rotation[0]) < 0.00001, abs(rotation[1]) < 0.00001 else {
                        throw PreviewError.unsupportedScene
                    }
                    ctx.translateBy(x: position[0], y: position[1])
                    ctx.rotate(by: rotation[2])
                    ctx.scaleBy(x: parentScale[0], y: parentScale[1])
                }
                ctx.translateBy(x: origin[0], y: origin[1])
                ctx.rotate(by: angles[2])
                ctx.scaleBy(x: scale[0], y: scale[1])
                ctx.setAlpha(layer.alpha)
                // 透明度应用于整层，不能逐三角形重复叠加共享边缘。
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                defer { ctx.endTransparencyLayer() }
                if let solid = layer.solid {
                    let size = try objectSize(layer.object, texture: nil)
                    guard size[0] > 0, size[1] > 0 else { throw PreviewError.unsupportedScene }
                    ctx.setFillColor(red: max(0, min(1, solid[0])), green: max(0, min(1, solid[1])),
                                     blue: max(0, min(1, solid[2])), alpha: 1)
                    ctx.fill(CGRect(x: -size[0]/2, y: -size[1]/2, width: size[0], height: size[1]))
                } else if let model = layer.model, let tinted {
                    if try drawMesh(model: model, image: tinted, context: ctx,
                                    animationLayers: layer.animationLayers) {
                        report.posedPuppets += 1
                    }
                } else if let tinted {
                    let size = try objectSize(layer.object, texture: layer.texture)
                    guard size[0] > 0, size[1] > 0 else { throw PreviewError.unsupportedScene }
                    ctx.draw(tinted, in: CGRect(x: -size[0]/2, y: -size[1]/2, width: size[0], height: size[1]))
                } else {
                    throw PreviewError.unsupportedScene
                }
                report.drawnLayers += 1
            }
        }
        try Task.checkCancellation()
        let encoded = NSMutableData()
        guard let output = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw PreviewError.writeFailed
        }
        CGImageDestinationAddImage(dest, output, nil)
        guard CGImageDestinationFinalize(dest) else { throw PreviewError.writeFailed }
        try (encoded as Data).write(to: directory.appendingPathComponent(outputName), options: .atomic)
        return SceneRenderOutcome(rendered: true, report: report)
    }

    /// 图层尺寸：对象 size 优先，缺失时用纹理像素尺寸。模型 JSON 的 width/height 与对象 size
    /// 冲突时，两种可检查实现的优先顺序互相矛盾，本机真实样本两者始终一致，因此保持既有行为。
    private static func objectSize(_ object: [String: Any], texture: URL?) throws -> [CGFloat] {
        if object["size"] != nil {
            return try numbers(object["size"], fallback: [0, 0])
        }
        guard let texture, let source = CGImageSourceCreateWithURL(texture as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let iw = metadata[kCGImagePropertyPixelWidth] as? Int,
              let ih = metadata[kCGImagePropertyPixelHeight] as? Int else {
            throw PreviewError.invalidTexture
        }
        return [CGFloat(iw), CGFloat(ih)]
    }

    private static func numbers(_ value: Any?, fallback: [CGFloat]) throws -> [CGFloat] {
        guard let value else { return fallback }
        guard let text = try resolve(value) as? String else { throw PreviewError.unsupportedScene }
        let pieces = text.split(whereSeparator: { $0.isWhitespace })
        let parts = pieces.compactMap { Double($0) }
        guard parts.count == pieces.count, parts.count == fallback.count,
              parts.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) else {
            throw PreviewError.unsupportedScene
        }
        return parts.map { CGFloat($0) }
    }

    /// 绑定属性的静态取值：`value` 是作者保存的默认值。用户属性用它就是当前值；
    /// 脚本与动画绑定缺少运行时会绕开，这里按默认值近似并在报告里计入。
    private static func resolve(_ value: Any) throws -> Any {
        guard let wrapped = value as? [String: Any] else { return value }
        guard let fallback = wrapped["value"], !(fallback is [String: Any]), !(fallback is [Any]) else {
            throw PreviewError.unsupportedScene
        }
        return fallback
    }

    /// 只统计真正参与绘制的字段：脚本/动画绑定按保存值近似，条件型用户绑定未求值。
    private static func bindingUsage(_ object: [String: Any]) -> (approximated: Int, conditional: Int) {
        var approximated = 0, conditional = 0
        for key in ["origin", "scale", "angles", "alpha", "color", "visible"] {
            guard let raw = object[key] as? [String: Any] else { continue }
            if raw["script"] != nil || raw["animation"] != nil {
                approximated += 1
            } else if let user = raw["user"] as? [String: Any], user["condition"] != nil {
                conditional += 1
            }
        }
        return (approximated, conditional)
    }

    /// 旧版场景可能把不透明度写成 0…100 的百分比，统一到 0…1。
    private static func normalizedAlpha(_ value: Any?) throws -> CGFloat {
        guard let value else { return 1 }
        let resolved = try resolve(value)
        guard let number = resolved as? NSNumber, !isBoolean(number) else {
            throw PreviewError.unsupportedScene
        }
        var alpha = number.doubleValue
        if alpha > 1, alpha <= 100 { alpha /= 100 }
        guard alpha.isFinite, (0...1).contains(alpha) else { throw PreviewError.unsupportedScene }
        return CGFloat(alpha)
    }

    private enum Paint { case texture, solid }

    /// 引擎内建 util 模型的类别（依据引擎 assets 与 flat/composelayer 着色器）。
    private enum BuiltinLayerKind { case solid, container, unknown }

    private static func builtinLayerKind(_ path: String) -> BuiltinLayerKind {
        let name = path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        if name.hasPrefix("solidlayer") { return .solid }
        if name.hasPrefix("composelayer") || name == "projectlayer.json" || name == "fullscreenlayer.json" {
            return .container
        }
        return .unknown
    }

    private static func record(_ object: [String: Any], report: inout ScenePreviewReport) {
        if let effects = object["effects"] as? [Any], !effects.isEmpty { report.ignoredEffects += 1 }
        let usage = bindingUsage(object)
        report.approximatedBindings += usage.approximated
        report.conditionalBindings += usage.conditional
    }

    /// 语义未确认、且会影响画面外观的属性一律回退，避免“成功但画面错误”。
    /// `disablepropagation` 在真实场景里几乎每个对象都出现，属于默认标志，不做拒绝。
    private static func requireUnmodifiedAppearance(_ object: [String: Any]) throws {
        if let rawBrightness = object["brightness"] {
            guard let number = try resolve(rawBrightness) as? NSNumber, !isBoolean(number),
                  abs(number.doubleValue - 1) < 0.00001 else { throw PreviewError.unsupportedScene }
        }
        for key in ["reflected", "perspective"] {
            guard let raw = object[key] else { continue }
            guard let flag = try resolve(raw) as? Bool else { throw PreviewError.unsupportedScene }
            if flag { throw PreviewError.unsupportedScene }
        }
        if let rawAttachment = object["attachment"] {
            guard let text = try resolve(rawAttachment) as? String, text.isEmpty else {
                throw PreviewError.unsupportedScene
            }
        }
    }

    /// 内建层标记：缺省或显式 false 都不算。
    private static func declaresTrue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let flag = value as? Bool { return flag }
        if let wrapped = value as? [String: Any], let flag = wrapped["value"] as? Bool { return flag }
        return false
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// 内建纯色层的填充色：flat 着色器直接输出 g_Color。
    /// 注意 colorBlendMode（BLENDMODE）语义未实现，带该字段的纯色层在调用处
    /// 会被跳过并计数（见 skippedBlendLayers），这里只负责取颜色。
    private static func solidFill(_ object: [String: Any]) throws -> [CGFloat] {
        guard let raw = object["color"] else { return [1, 1, 1] }
        let fill = try numbers(raw, fallback: [1, 1, 1])
        guard fill.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { throw PreviewError.unsupportedScene }
        return fill
    }

    /// 图层的 color 是 RGB 乘性色调；colorBlendMode 变体语义未确认，遇到时仍然回退。
    private static func colorTint(_ object: [String: Any]) throws -> [CGFloat] {
        guard object["colorBlendMode"] == nil else { throw PreviewError.unsupportedScene }
        guard let raw = object["color"] else { return [1, 1, 1] }
        let tint = try numbers(raw, fallback: [1, 1, 1])
        guard tint.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { throw PreviewError.unsupportedScene }
        return tint
    }

    private static func tintedImage(_ image: CGImage, tint: [CGFloat]) throws -> CGImage {
        guard tint.contains(where: { abs($0 - 1) > 0.00001 }) else { return image }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 16_000_000 else { throw PreviewError.unsupportedScene }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreviewError.writeFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { throw PreviewError.writeFailed }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // 预乘 alpha 下把 RGB 乘以色调即可，颜色不会超过 alpha。
        let factors = tint.prefix(3).map { UInt16((max(0, min(1, $0)) * 255).rounded()) }
        let count = width * height * 4
        for index in stride(from: 0, to: count, by: 4) {
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(UInt16(bytes[index + channel]) * factors[channel] / 255)
            }
        }
        guard let output = ctx.makeImage() else { throw PreviewError.writeFailed }
        return output
    }

    /// 绘制 puppet 网格。优先按动画首帧姿态蒙皮；解析失败或不支持时回退到原始顶点。
    /// 返回是否应用了蒙皮姿态。
    @discardableResult
    private static func drawMesh(model: URL, image: CGImage, context ctx: CGContext,
                                animationLayers: [[String: Any]]) throws -> Bool {
        let values = try model.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, (128...50_000_000).contains(size) else { throw PreviewError.invalidModel }
        let data = try Data(contentsOf: model)
        guard data.count >= 128, data.count <= 50_000_000,
              data.prefix(8) == Data("MDLV0023".utf8) || data.prefix(8) == Data("MDLV0021".utf8) else {
            throw PreviewError.invalidModel
        }
        // 1) 骨骼 + 动画首帧姿态（保守：任何异常都回退到原始顶点）
        if !animationLayers.isEmpty,
           let posed = try? PuppetSkinning.pose(data: data, layers: animationLayers) {
            try rasterize(positions: posed.0.positions, texcoords: posed.0.texcoords,
                          indices: posed.0.indices, image: image, context: ctx)
            return posed.1.appliedAnimation != nil
        }
        // 2) 回退：直接使用文件中的顶点位置
        guard let end = data[21...].firstIndex(of: 0) else { throw PreviewError.invalidModel }
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
        guard indexBytes > 0, indexBytes % 6 == 0, indexBytes <= data.count - indexOffset - 4, count <= 100_000 else {
            throw PreviewError.invalidModel
        }
        struct Vertex { let x: CGFloat; let y: CGFloat; let u: CGFloat; let v: CGFloat }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(count)
        for i in 0..<count {
            let p = start + i * 80
            guard abs(try f32(p+8)) < 0.00001 else { throw PreviewError.unsupportedScene }
            vertices.append(try Vertex(x: f32(p), y: f32(p+4), u: f32(p+72), v: f32(p+76)))
        }
        var indices: [UInt16] = []
        indices.reserveCapacity(indexBytes / 2)
        for p in stride(from: indexOffset + 4, to: indexOffset + 4 + indexBytes, by: 6) {
            if (p - indexOffset) % 6000 == 4 { try Task.checkCancellation() }
            let ids = (0..<3).map { Int(data[p+$0*2]) | Int(data[p+$0*2+1]) << 8 }
            guard ids.allSatisfy({ $0 < count }) else { throw PreviewError.invalidModel }
            indices.append(contentsOf: ids.map { UInt16($0) })
        }
        try rasterize(positions: vertices.map { CGPoint(x: $0.x, y: $0.y) },
                      texcoords: vertices.map { CGPoint(x: $0.u, y: $0.v) },
                      indices: indices, image: image, context: ctx)
        return false
    }

    /// 逐三角形做仿射贴图；顶点位置/ UV 由调用方提供（原始或蒙皮后）。
    private static func rasterize(positions: [CGPoint], texcoords: [CGPoint], indices: [UInt16],
                                  image: CGImage, context ctx: CGContext) throws {
        guard positions.count == texcoords.count, !indices.isEmpty,
              indices.count % 3 == 0 else { throw PreviewError.invalidModel }
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        for index in stride(from: 0, to: indices.count, by: 3) {
            if index % 3000 == 0 { try Task.checkCancellation() }
            let ids = (0..<3).map { Int(indices[index + $0]) }
            guard ids.allSatisfy({ $0 >= 0 && $0 < positions.count }) else { throw PreviewError.invalidModel }
            let s = ids.map { CGPoint(x: texcoords[$0].x * width, y: (1 - texcoords[$0].y) * height) }
            let d = ids.map { positions[$0] }
            let sx1 = s[1].x-s[0].x, sy1 = s[1].y-s[0].y, sx2 = s[2].x-s[0].x, sy2 = s[2].y-s[0].y
            let det = sx1*sy2-sx2*sy1
            guard abs(det) > 0.00001 else { continue }
            let dx1 = d[1].x-d[0].x, dy1 = d[1].y-d[0].y, dx2 = d[2].x-d[0].x, dy2 = d[2].y-d[0].y
            let a = (dx1*sy2-dx2*sy1)/det, c = (dx2*sx1-dx1*sx2)/det
            let b = (dy1*sy2-dy2*sy1)/det, e = (dy2*sx1-dy1*sx2)/det
            let transform = CGAffineTransform(a: a, b: b, c: c, d: e,
                                              tx: d[0].x-a*s[0].x-c*s[0].y, ty: d[0].y-b*s[0].x-e*s[0].y)
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
