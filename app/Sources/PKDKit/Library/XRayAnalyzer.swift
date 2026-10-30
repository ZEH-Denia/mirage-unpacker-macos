import Foundation

/// 一处 X-Ray 效果：挂在某个对象上的 effect，把第二张纹理按鼠标位置透出来。
public struct XRayLayer: Sendable, Equatable {
    public let objectName: String
    /// 正常层纹理名（对象自身的材质纹理）
    public let baseTexture: String?
    /// X-Ray 层纹理名（effect pass 里引用的纹理）
    public let xrayTextures: [String]
    public let effectFile: String
}

public struct XRayLabelSummary: Sendable, Equatable {
    public var layers: [XRayLayer] = []
    public var cleanFiles: [String] = []
    public var xrayFiles: [String] = []

    public var isEmpty: Bool { layers.isEmpty }

    public var shortDescription: String? {
        guard !xrayFiles.isEmpty else { return nil }
        let clean = cleanFiles.first ?? "—"
        let xray = xrayFiles.first ?? "—"
        return "正常层 \(clean) · X-Ray 层 \(xray)"
    }
}

/// 从解包结果里识别 X-Ray 图层。
///
/// 判定依据：`scene.json` 的 `objects[].effects[]` 中 `file` 含 "xray" 的节点，
/// 其 `passes[].textures[]` 引用的就是被透出来的那张纹理；
/// 对象自身的纹理则通过 `image → models/*.json → material → materials/*.json` 解析。
public enum XRayAnalyzer {
    public static func analyze(outputDirectory: URL) -> [XRayLayer] {
        let sceneURL = outputDirectory.appendingPathComponent("scene.json")
        guard let data = try? Data(contentsOf: sceneURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]] else {
            return []
        }

        var layers: [XRayLayer] = []
        for object in objects {
            guard let effects = object["effects"] as? [[String: Any]] else { continue }

            for effect in effects {
                guard let file = effect["file"] as? String,
                      file.lowercased().contains("xray") else { continue }

                let textures = effectTextures(effect)
                guard !textures.isEmpty else { continue }

                layers.append(XRayLayer(
                    objectName: (object["name"] as? String) ?? "未命名对象",
                    baseTexture: resolveObjectTexture(object, in: outputDirectory),
                    xrayTextures: textures,
                    effectFile: file
                ))
            }
        }

        return layers
    }

    private static func effectTextures(_ effect: [String: Any]) -> [String] {
        guard let passes = effect["passes"] as? [[String: Any]] else { return [] }

        var names: [String] = []
        for pass in passes {
            guard let textures = pass["textures"] as? [Any] else { continue }
            for item in textures {
                if let name = item as? String, !name.isEmpty, !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// 对象 → models/<名>.json → material → materials/<名>.json → passes[0].textures[0]
    private static func resolveObjectTexture(_ object: [String: Any], in directory: URL) -> String? {
        guard let image = object["image"] as? String else { return nil }

        if let modelJSON = loadJSON(directory.appendingPathComponent(image)),
           let materialPath = modelJSON["material"] as? String,
           let materialJSON = loadJSON(directory.appendingPathComponent(materialPath)),
           let passes = materialJSON["passes"] as? [[String: Any]],
           let textures = passes.first?["textures"] as? [Any],
           let first = textures.first as? String {
            return first
        }

        // 兜底：models/<名>.json → <名>
        return (image as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "")
    }

    private static func loadJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// 把导出的图片按图层含义改名，让「正常层」和「X-Ray 层」一眼可辨。
/// 只改转换出来的图片副本，`.tex` 原始文件保持不动。
public enum XRayLabeler {
    public static let cleanSuffix = " [正常]"
    public static let xraySuffix = " [X-Ray]"
    private static let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "mp4"]

    public static func label(_ layers: [XRayLayer], in directory: URL) -> XRayLabelSummary {
        var summary = XRayLabelSummary(layers: layers)
        guard !layers.isEmpty else { return summary }

        var renamed: Set<String> = []

        for layer in layers {
            if let base = layer.baseTexture, renamed.insert(base).inserted {
                if let name = applySuffix(cleanSuffix, to: base, in: directory) {
                    summary.cleanFiles.append(name)
                }
            }

            for texture in layer.xrayTextures where texture != layer.baseTexture {
                guard renamed.insert(texture).inserted else { continue }
                if let name = applySuffix(xraySuffix, to: texture, in: directory) {
                    summary.xrayFiles.append(name)
                }
            }
        }

        return summary
    }

    /// 在 materials/ 下找到 `<纹理名>.<ext>`，改名为 `<纹理名><后缀>.<ext>`
    private static func applySuffix(_ suffix: String, to texture: String, in directory: URL) -> String? {
        let materials = directory.appendingPathComponent("materials", isDirectory: true)
        let fileManager = FileManager.default
        let baseName = (texture as NSString).lastPathComponent

        // 纹理名可能带子目录（如 effects/xxx），优先按原样找，再退回 materials/ 下
        let candidates: [URL] = [
            directory.appendingPathComponent(texture),
            materials.appendingPathComponent(baseName),
        ]

        for candidate in candidates {
            for ext in imageExtensions {
                let source = candidate.appendingPathExtension(ext)
                guard fileManager.fileExists(atPath: source.path) else { continue }

                let targetPath = source.deletingPathExtension().path + suffix + "." + ext
                let targetURL = URL(fileURLWithPath: targetPath)

                if fileManager.fileExists(atPath: targetURL.path) {
                    try? fileManager.removeItem(at: targetURL)
                }
                do {
                    try fileManager.moveItem(at: source, to: targetURL)
                    return targetURL.lastPathComponent
                } catch {
                    continue
                }
            }
        }

        return nil
    }
}
