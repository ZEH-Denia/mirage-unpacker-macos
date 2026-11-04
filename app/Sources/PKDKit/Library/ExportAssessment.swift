import Foundation

/// 包目录的保守分析：不把文件列表当成完整场景渲染能力证明。
public struct ExportAssessment: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case model, layered, singleTexture, unknown
        public var title: String {
            switch self {
            case .model: return "需要检查场景模型"
            case .layered: return "可能包含分层或动态效果"
            case .singleTexture: return "单张纹理素材"
            case .unknown: return "暂无法判断"
            }
        }
    }
    public let kind: Kind
    public let modelCount: Int
    public let textureCount: Int
    public let effectCount: Int
    public var title: String { kind.title }
    public var explanation: String {
        switch kind {
        case .model:
            return "发现 \(modelCount) 个模型。导出时会检查实际引用并尝试静态预览；未支持的结构会保留图片素材并说明原因。"
        case .layered:
            return "发现 \(textureCount) 张纹理及 \(effectCount) 个效果资源。图片可能是图集、遮罩或分层素材，不能保证直接导出就是完整壁纸。"
        case .singleTexture:
            return "包内只有一张纹理，将按原有流程导出。仅凭目录无法确认是否存在裁切、变形或其他场景处理。"
        case .unknown:
            return "未找到足够的纹理信息。导出时仍会检查实际产物，未知状态不代表可以还原完整画面。"
        }
    }
    public init(info: PkgInfo) {
        let paths = Set(info.entries.map { $0.path.lowercased().replacingOccurrences(of: "\\", with: "/") })
        modelCount = paths.filter { $0.hasSuffix(".mdl") }.count
        textureCount = paths.filter { $0.hasSuffix(".tex") }.count
        effectCount = paths.filter { $0.hasPrefix("effects/") || $0.hasPrefix("particles/") || $0.hasSuffix(".js") }.count
        if modelCount > 0 { kind = .model }
        else if textureCount > 1 || effectCount > 0 { kind = .layered }
        else if textureCount == 1 { kind = .singleTexture }
        else { kind = .unknown }
    }
}
