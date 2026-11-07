import Foundation
import CoreGraphics

/// MDLV0023 骨骼/蒙皮解析与默认静态姿态。
///
/// 格式参考（仅参考**格式事实**，实现为本项目独立编写，未复制上游代码）：
/// - 字段顺序 / 顶点位标志与 stride / 段落布局 / 姿态与四元数约定，参考公开实现
///   `laobamac/MirageWallpaper`（GPL-3.0）中的两个文件：
///   `SceneRenderer/Sources/SceneRenderer/Wallpaper/Compiler/ModelCompiler.cpp`
///   （MDLV/MDLS/MDLA 解析与顶点布局）、
///   `SceneRenderer/Sources/SceneRenderer/Wallpaper/Compiler/PuppetRig.cpp`
///   （局部 TRS、世界矩阵、inverse bind 与蒙皮约定）。
///   本项目只采用其中的格式与数学约定事实，不含其任何代码；上游项目与许可说明
///   见 THIRD-PARTY-NOTICES.md 的"相关但未使用"段落。
/// - 公开的 MDLV 段落布局：`MDLV<ver>` 头 → 材质/网格（顶点按 flag 位组合 stride，
///   含 SKIN_BLEND 的 4×u32 骨骼索引与 SKIN_WEIGHT 的 4×float 权重）→ `MDLS` 骨骼
///   （名称、父索引、4×4 列主序 local bind 矩阵）→ `MDLA` 动画（每骨每帧 9 个 float：
///   position/angle/scale）→ 其它段落。
/// - 姿态约定：局部变换 = T(position) · Rz·Ry·Rx(angle) · Diag(scale)；
///   世界矩阵沿父链相乘；蒙皮矩阵 = world · inverse(world_bind)；
///   顶点 = Σ 权重 · 蒙皮矩阵 · 顶点位置。
///
/// 设计原则：任何无法确认的结构（多网格、additive 图层、权重异常、索引越界、
/// 父子循环、截断、超限）都返回 nil，由调用方回退到原始顶点——绝不猜测坐标。
public enum PuppetSkinning {
    public struct Geometry {
        public var positions: [CGPoint]      // 蒙皮后的顶点位置（puppet 局部坐标）
        public var texcoords: [CGPoint]      // 0…1
        public var indices: [UInt16]
    }

    public struct Info: Equatable {
        public var boneCount = 0
        public var animationCount = 0
        public var appliedAnimation: Int32?
        public var appliedBlend: Double = 0
        public var note: String?
    }

    /// 解析 + 以 t=0 的默认姿态蒙皮。失败时返回 nil（调用方用原始顶点）。
    public static func pose(data: Data, layers: [[String: Any]]?) throws -> (Geometry, Info)? {
        var reader = Reader(data: data)
        guard let parsed = try parse(reader: &reader) else { return nil }
        var info = Info(boneCount: parsed.bones.count, animationCount: parsed.animations.count)
        guard let layer = try singleAnimationLayer(layers, animations: parsed.animations, info: &info) else {
            info.note = "no usable animation layer; bind pose"
            return (bindGeometry(parsed), info)
        }
        info.appliedAnimation = layer.id
        info.appliedBlend = layer.blend
        guard let posed = try skinned(parsed, layer: layer) else { return nil }
        if layer.blend < 0.999 { info.note = "blend < 1: linear approximation" }
        return (posed, info)
    }

    // MARK: - 数据结构

    struct Bone {
        var name: String
        var parent: Int?          // nil = 根
        var localBind: Mat4
    }

    struct Vertex {
        var position: CGPoint
        var uv: CGPoint
        var boneIDs: [UInt32]
        var weights: [Double]
    }

    struct Frame {
        var position: Vec3
        var angle: Vec3
        var scale: Vec3
    }

    struct Animation {
        var id: Int32
        var name: String
        var fps: Double
        var length: Int
        var boneFrames: [[Frame]]   // [bone][frame]
    }

    struct ParsedModel {
        var vertices: [Vertex]
        var indices: [UInt16]
        var bones: [Bone]
        var animations: [Animation]
    }

    // MARK: - 解析

    private static let noParent: UInt32 = 0xFFFF_FFFF
    private static let maxBones = 4096
    private static let maxVertices = 200_000
    private static let maxFrames = 200_000

    private struct Reader {
        let data: Data
        var offset = 0
        init(data: Data) { self.data = data }
        var remaining: Int { data.count - offset }
        mutating func u8() throws -> UInt8 {
            guard remaining >= 1 else { throw FormatError.truncated }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func u16() throws -> UInt16 {
            guard remaining >= 2 else { throw FormatError.truncated }
            let value = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            offset += 2
            return value
        }
        mutating func u32() throws -> UInt32 {
            guard remaining >= 4 else { throw FormatError.truncated }
            let value = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
            offset += 4
            return value
        }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func f32() throws -> Double {
            let value = Double(Float(bitPattern: try u32()))
            guard value.isFinite, abs(value) < 1_000_000 else { throw FormatError.invalid }
            return value
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, remaining >= count else { throw FormatError.truncated }
            offset += count
        }
        mutating func cstring(maxLength: Int = 4096) throws -> String {
            guard remaining > 0 else { throw FormatError.truncated }
            let start = offset
            var end = start
            while end < data.count, data[end] != 0 {
                end += 1
                if end - start > maxLength { throw FormatError.invalid }
            }
            guard end < data.count else { throw FormatError.truncated }
            offset = end + 1
            return String(decoding: data[start..<end], as: UTF8.self)
        }
        mutating func tag() throws -> String {
            guard remaining >= 8 else { throw FormatError.truncated }
            let start = offset
            offset += 8
            return String(decoding: data[start..<start + 8], as: UTF8.self)
        }
    }

    private enum FormatError: Error { case truncated, invalid, unsupported }

    private static func parse(reader: inout Reader) throws -> ParsedModel? {
        let tag = try reader.tag()
        guard tag.hasPrefix("MDLV"), let version = Int(tag.suffix(4)), version >= 21, version <= 23 else {
            return nil
        }
        try reader.skip(1)                       // 头部的 0x00 占位
        let mdlFlag = try reader.u32()
        let skinCount = try reader.u32()
        let meshCount = try reader.u32()
        guard skinCount >= 1, skinCount <= 16, meshCount == 1 else { return nil }

        var materials: [String] = []
        for _ in 0..<Int(skinCount) { materials.append(try reader.cstring()) }
        _ = materials

        let flagA = try reader.u32()
        if flagA == 2 { _ = try reader.u32() }
        if version >= 17 { try reader.skip(24) }  // aabb min/max
        let meshFlag = try reader.u32()
        _ = mdlFlag
        let vertexBytes = try reader.u32()
        let stride = vertexStride(meshFlag)
        guard stride > 0, vertexBytes % UInt32(stride) == 0 else { return nil }
        let vertexCount = Int(vertexBytes) / stride
        guard vertexCount > 0, vertexCount <= maxVertices, vertexCount <= reader.remaining / stride else {
            return nil
        }
        let hasNormal = meshFlag & 0x2 != 0
        let hasTangent = meshFlag & 0x4 != 0
        let hasExtra4 = meshFlag & 0x10000 != 0
        let hasSkinBlend = meshFlag & 0x800000 != 0
        let hasSkinWeight = meshFlag & 0x1_000000 != 0
        let hasUV = meshFlag & (0x8 | 0x20) != 0
        let hasUV2 = meshFlag & 0x20 != 0

        var vertices: [Vertex] = []
        vertices.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let position = CGPoint(x: CGFloat(try reader.f32()), y: CGFloat(try reader.f32()))
            _ = try reader.f32()                                   // z
            if hasNormal { try reader.skip(12) }
            if hasTangent { try reader.skip(16) }
            if hasExtra4 { try reader.skip(4) }
            var ids: [UInt32] = []
            if hasSkinBlend {
                for _ in 0..<4 { ids.append(try reader.u32()) }
            }
            var weights: [Double] = []
            if hasSkinWeight {
                for _ in 0..<4 { weights.append(Double(try reader.f32())) }
            }
            var uv = CGPoint.zero
            if hasUV {
                uv = CGPoint(x: CGFloat(try reader.f32()), y: CGFloat(try reader.f32()))
            }
            if hasUV2 { try reader.skip(8) }
            vertices.append(Vertex(position: position, uv: uv, boneIDs: ids, weights: weights))
        }

        let indexBytes = try reader.u32()
        // 本实现用 UInt16 索引栅格化；超大顶点集保守回退。
        guard vertexCount <= Int(UInt16.max) else { return nil }
        let indexStride = 6
        guard indexBytes % UInt32(indexStride) == 0,
              Int(indexBytes) <= reader.remaining else { return nil }
        let triangleCount = Int(indexBytes) / indexStride
        guard triangleCount > 0, triangleCount <= 500_000 else { return nil }
        var indices: [UInt16] = []
        indices.reserveCapacity(triangleCount * 3)
        for _ in 0..<triangleCount {
            for _ in 0..<3 {
                let value = UInt32(try reader.u16())
                guard value < UInt32(vertexCount) else { return nil }
                indices.append(UInt16(value))
            }
        }

        // 网格尾部：Parts（mdlv≥21）与 Masks（mdlv>21）。格式参考公开的段落布局。
        if version >= 21 {
            let unkA = try reader.u8()
            if unkA == 1 {
                let unkB = try reader.u8()
                if unkB != 0 {
                    _ = try reader.u16()
                    _ = try reader.u8()
                    let payload = Int(try reader.u32())
                    guard payload >= 0, payload == 12 * vertexCount, payload <= reader.remaining else {
                        return nil
                    }
                    try reader.skip(payload)
                }
            } else if unkA != 0 {
                return nil
            }
            let hasParts = try reader.u8()
            if hasParts == 1 {
                let partsBytes = Int(try reader.u32())
                guard partsBytes >= 0, partsBytes % 16 == 0, partsBytes <= reader.remaining else {
                    return nil
                }
                try reader.skip(partsBytes)
            } else if hasParts != 0 {
                return nil
            }
            if version > 21 {
                let maskCount = Int(try reader.u32())
                guard maskCount >= 0, maskCount <= 1024, maskCount <= reader.remaining / 16 else {
                    return nil
                }
                for _ in 0..<maskCount {
                    _ = try reader.u32()
                    _ = try reader.u32()
                    _ = try reader.cstring()
                    _ = try reader.u32()
                    let aCount = Int(try reader.u32())
                    guard aCount >= 0, aCount <= reader.remaining / 4 else { return nil }
                    try reader.skip(aCount * 4)
                    let bCount = Int(try reader.u32())
                    guard bCount >= 0, bCount <= reader.remaining / 4 else { return nil }
                    try reader.skip(bCount * 4)
                }
            }
        }

        // 后续段落：按 8 字节标签分派，使用各段的 end 偏移做保守跳跃。
        var bones: [Bone] = []
        var animations: [Animation] = []
        while reader.remaining >= 8 {
            let sectionTag = try reader.tag()
            let sectionStart = reader.offset - 8
            if sectionTag.hasPrefix("MDLS") {
                try reader.skip(1)
                let end = try reader.u32()
                bones = try parseBones(reader: &reader)
                guard end >= UInt32(reader.offset), Int(end) <= reader.data.count else { return nil }
                reader.offset = Int(end)
            } else if sectionTag.hasPrefix("MDLA") {
                guard let version = Int(sectionTag.suffix(4)) else { return nil }
                try reader.skip(1)
                let end = try reader.u32()
                animations = try parseAnimations(reader: &reader, version: version,
                                                  bones: bones.count, end: end)
                if end >= UInt32(reader.offset), Int(end) <= reader.data.count {
                    reader.offset = Int(end)
                } else {
                    break
                }
            } else {
                // 未知段落：无法得知长度，停止解析（已解析到的部分仍可用）。
                _ = sectionStart
                break
            }
            if reader.remaining < 8 { break }
        }
        return ParsedModel(vertices: vertices, indices: indices, bones: bones, animations: animations)
    }

    private static func vertexStride(_ flag: UInt32) -> Int {
        var stride = 12
        if flag & 0x2 != 0 { stride += 12 }
        if flag & 0x4 != 0 { stride += 16 }
        if flag & 0x10000 != 0 { stride += 4 }
        if flag & 0x800000 != 0 { stride += 16 }
        if flag & 0x1_000000 != 0 { stride += 16 }
        if flag & (0x8 | 0x20) != 0 { stride += 8 }
        if flag & 0x20 != 0 { stride += 8 }
        return stride
    }

    private static func parseBones(reader: inout Reader) throws -> [Bone] {
        let count = Int(try reader.u16())
        try reader.skip(2)
        guard count > 0, count <= maxBones else { throw FormatError.unsupported }
        var bones: [Bone] = []
        bones.reserveCapacity(count)
        for index in 0..<count {
            let name = try reader.cstring()
            _ = try reader.i32()                       // sim_type
            let parent = try reader.u32()
            let size = try reader.u32()
            guard size == 64 else { throw FormatError.unsupported }
            var matrix: [Double] = []
            matrix.reserveCapacity(16)
            for _ in 0..<16 { matrix.append(try reader.f32()) }
            _ = try reader.cstring()                   // simulation json
            // 父索引必须严格小于自身；出现前向引用（含 0↔1 循环）说明拓扑不可信，
            // 按“无法确认就回退”处理，避免静默套用错误姿态。
            if parent != noParent && Int(parent) >= index {
                throw FormatError.unsupported
            }
            let parentIndex = parent == noParent ? nil : Int(parent)
            bones.append(Bone(name: name, parent: parentIndex, localBind: Mat4(columns: matrix)))
        }
        return bones
    }

    private static func parseAnimations(reader: inout Reader, version: Int, bones: Int,
                                        end: UInt32) throws -> [Animation] {
        let count = Int(try reader.u32())
        guard count >= 0, count <= 4096, count <= reader.remaining / 16 else {
            throw FormatError.unsupported
        }
        var animations: [Animation] = []
        for _ in 0..<count {
            let id = try reader.i32()
            _ = try reader.u32()                        // unk
            var name = try reader.cstring()
            if name.isEmpty { name = try reader.cstring() }
            _ = try reader.cstring()                    // mode
            let fps = Double(try reader.f32())
            let length = Int(try reader.i32())
            _ = try reader.i32()                        // zero
            let boneCount = Int(try reader.u32())
            guard boneCount <= maxBones, length >= 0, length <= 1_000_000 else {
                throw FormatError.unsupported
            }
            var boneFrames: [[Frame]] = []
            boneFrames.reserveCapacity(boneCount)
            for _ in 0..<boneCount {
                _ = try reader.i32()                    // unk
                let byteSize = Int(try reader.u32())
                guard byteSize % 36 == 0 else { throw FormatError.unsupported }
                let frameCount = byteSize / 36
                guard frameCount <= maxFrames, frameCount <= reader.remaining / 36 else {
                    throw FormatError.truncated
                }
                var frames: [Frame] = []
                frames.reserveCapacity(frameCount)
                for _ in 0..<frameCount {
                    let position = Vec3(try reader.f32(), try reader.f32(), try reader.f32())
                    let angle = Vec3(try reader.f32(), try reader.f32(), try reader.f32())
                    let scale = Vec3(try reader.f32(), try reader.f32(), try reader.f32())
                    frames.append(Frame(position: position, angle: angle, scale: scale))
                }
                boneFrames.append(frames)
            }
            try skipAnimationTail(reader: &reader, version: version, boneCount: boneCount,
                                  length: length, end: end)
            animations.append(Animation(id: id, name: name, fps: fps, length: length,
                                        boneFrames: boneFrames))
        }
        return animations
    }

    /// 跳过单个动画记录的尾部（与位置无关的元数据），使后续动画仍可解析。
    private static func skipAnimationTail(reader: inout Reader, version: Int, boneCount: Int,
                                          length: Int, end: UInt32) throws {
        if version >= 3 {
            let flag = try reader.u32()
            if flag == 1 {
                let extra = Int(try reader.u32())
                guard extra >= 0, extra % 4 == 0, extra <= reader.remaining else {
                    throw FormatError.truncated
                }
                try reader.skip(extra)
                if extra > 0 { _ = try reader.u32() }
                let main = Int(try reader.u32())
                guard main >= 0, main % 4 == 0, main <= reader.remaining else {
                    throw FormatError.truncated
                }
                try reader.skip(main)
                if extra > 0 { _ = try reader.u32() }
            } else if flag == 0 {
                let expected = (length + 1) * 36
                if reader.remaining >= 4 {
                    let size = Int(try reader.u32())
                    if size == expected || size == (length + 1) * 4 {
                        guard size <= reader.remaining else { throw FormatError.truncated }
                        try reader.skip(size)
                        // 可能跟随若干 (0, size) 尾部轨道；保守跳过一层
                        while reader.remaining >= 8 {
                            let mark = reader.offset
                            let zero = try reader.u32()
                            let next = Int(try reader.u32())
                            if zero == 0, (next == expected || next == (length + 1) * 4),
                               next <= reader.remaining {
                                try reader.skip(next)
                            } else {
                                reader.offset = mark
                                break
                            }
                        }
                    } else {
                        reader.offset -= 4
                    }
                }
            } else {
                throw FormatError.unsupported
            }
            try skipBoneCurves(reader: &reader, boneCount: boneCount)
        }
        if version >= 4 {
            let hasEvents = try reader.u8()
            if hasEvents == 1 {
                let eventCount = Int(try reader.u32())
                guard eventCount <= 4096 else { throw FormatError.unsupported }
                for _ in 0..<eventCount {
                    try reader.skip(4)                     // time
                    let curveCount = Int(try reader.u16())
                    try reader.skip(2)                     // flags
                    guard curveCount > 0, curveCount <= 1024 else { throw FormatError.unsupported }
                    for curveIndex in 0..<curveCount {
                        if curveIndex > 0 { try reader.skip(2) }
                        let size = Int(try reader.u32())
                        guard size % 4 == 0, size <= reader.remaining else {
                            throw FormatError.truncated
                        }
                        try reader.skip(size)
                    }
                }
            } else if hasEvents != 0 {
                throw FormatError.unsupported
            }
        }
        if version >= 5 { try reader.skip(24) }
        if version >= 6 {
            // 可选的标量曲线块：只有下一个字节为 1 且后续长度自洽时才消费。
            let mark = reader.offset
            do {
                try skipBoneCurves(reader: &reader, boneCount: boneCount)
            } catch {
                reader.offset = mark
            }
        }
        // 事件列表（所有版本）
        let eventCount = Int(try reader.u32())
        guard eventCount <= 4096 else { throw FormatError.unsupported }
        for _ in 0..<eventCount {
            _ = try reader.u32()
            _ = try reader.cstring()
        }
        // 记录尾部可能有 4 字节 0 填充
        if Int(end) == reader.offset + 4 { _ = try reader.u32() }
    }

    private static func skipBoneCurves(reader: inout Reader, boneCount: Int) throws {
        let hasCurves = try reader.u8()
        guard hasCurves == 1 else {
            if hasCurves == 0 { return }
            throw FormatError.unsupported
        }
        for _ in 0..<boneCount {
            _ = try reader.u32()
            let size = Int(try reader.u32())
            guard size % 4 == 0, size <= reader.remaining else { throw FormatError.truncated }
            try reader.skip(size)
        }
    }

    // MARK: - 姿态

    private struct LayerSelection {
        var id: Int32
        var blend: Double
        var animation: Animation
    }

    private static func singleAnimationLayer(_ layers: [[String: Any]]?,
                                             animations: [Animation],
                                             info: inout Info) throws -> LayerSelection? {
        guard let layers, !layers.isEmpty else { return nil }
        var chosen: LayerSelection?
        for layer in layers {
            guard let rawID = layer["animation"] as? Int else { continue }
            guard layer["visible"] as? Bool ?? true else { continue }
            if layer["additive"] as? Bool == true {
                info.note = "additive layer unsupported"
                return nil
            }
            guard let animation = animations.first(where: { $0.id == Int32(rawID) }) else {
                info.note = "referenced animation \(rawID) not found"
                return nil
            }
            guard chosen == nil else {
                info.note = "multiple animation layers"
                return nil
            }
            let blend = min(1, max(0, (layer["blend"] as? Double) ?? 1))
            chosen = LayerSelection(id: Int32(rawID), blend: blend, animation: animation)
        }
        return chosen
    }

    private static func bindGeometry(_ model: ParsedModel) -> Geometry {
        Geometry(positions: model.vertices.map(\.position),
                 texcoords: model.vertices.map(\.uv), indices: model.indices)
    }

    private static func skinned(_ model: ParsedModel, layer: LayerSelection) throws -> Geometry? {
        let boneCount = model.bones.count
        guard boneCount > 0, model.vertices.contains(where: { !$0.boneIDs.isEmpty }) else { return nil }
        // 绑定世界矩阵
        var worldBind: [Mat4] = []
        worldBind.reserveCapacity(boneCount)
        for index in 0..<boneCount {
            if let parent = model.bones[index].parent {
                worldBind.append(worldBind[parent] * model.bones[index].localBind)
            } else {
                worldBind.append(model.bones[index].localBind)
            }
        }
        // t=0 → 第 0 帧
        let frames = layer.animation.boneFrames
        guard !frames.isEmpty else { return nil }
        var localAnim: [Mat4] = []
        localAnim.reserveCapacity(boneCount)
        for index in 0..<boneCount {
            let bind = model.bones[index].localBind
            let frame: Frame? = (index < frames.count ? frames[index].first : nil)
            guard let frame, layer.blend > 0 else {
                localAnim.append(bind)
                continue
            }
            let frameMatrix = Mat4.trs(position: frame.position, angle: frame.angle, scale: frame.scale)
            localAnim.append(Mat4.blend(bind, frameMatrix, t: layer.blend))
        }
        var worldAnim: [Mat4] = []
        worldAnim.reserveCapacity(boneCount)
        for index in 0..<boneCount {
            if let parent = model.bones[index].parent {
                worldAnim.append(worldAnim[parent] * localAnim[index])
            } else {
                worldAnim.append(localAnim[index])
            }
        }
        var skins: [Mat4] = []
        skins.reserveCapacity(boneCount)
        for index in 0..<boneCount {
            guard let inverse = worldBind[index].inverted() else { return nil }
            skins.append(worldAnim[index] * inverse)
        }
        var positions: [CGPoint] = []
        positions.reserveCapacity(model.vertices.count)
        for vertex in model.vertices {
            guard vertex.weights.count == 4, vertex.boneIDs.count == 4 else {
                positions.append(vertex.position)
                continue
            }
            var accumulated = Vec3(0, 0, 0)
            var total: Double = 0
            for slot in 0..<4 {
                let weight = vertex.weights[slot]
                guard weight.isFinite, weight > 0.000001 else { continue }
                let boneIndex = Int(vertex.boneIDs[slot])
                guard boneIndex >= 0, boneIndex < boneCount else { return nil }
                let transformed = skins[boneIndex].apply(vertex.position)
                accumulated = accumulated + transformed * weight
                total += weight
            }
            guard total > 0.000001 else {
                positions.append(vertex.position)
                continue
            }
            let point = accumulated * (1.0 / total)   // 权重归一化
            positions.append(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
        }
        for value in positions {
            guard value.x.isFinite, value.y.isFinite, abs(value.x) < 1_000_000, abs(value.y) < 1_000_000 else {
                return nil
            }
        }
        return Geometry(positions: positions, texcoords: model.vertices.map(\.uv),
                        indices: model.indices)
    }
}

// MARK: - 小型线性代数（独立实现）

struct Vec3 {
    var x: Double, y: Double, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (lhs: Vec3, rhs: Vec3) -> Vec3 { Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z) }
    static func - (lhs: Vec3, rhs: Vec3) -> Vec3 { Vec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z) }
    static func * (lhs: Vec3, rhs: Double) -> Vec3 { Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs) }
}

/// 列主序 4×4 矩阵（与 MDLV 存储顺序一致）。
struct Mat4 {
    var m: [Double]   // 16，列主序

    init(columns: [Double]) {
        m = columns
    }
    init(_ m: [Double]) { self.m = m }

    static let identity = Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    subscript(row: Int, col: Int) -> Double {
        get { m[col * 4 + row] }
        set { m[col * 4 + row] = newValue }
    }

    static func * (lhs: Mat4, rhs: Mat4) -> Mat4 {
        var result = [Double](repeating: 0, count: 16)
        for col in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += lhs[row, k] * rhs[k, col] }
                result[col * 4 + row] = sum
            }
        }
        return Mat4(result)
    }

    func apply(_ point: CGPoint) -> Vec3 {
        let x = Double(point.x), y = Double(point.y)
        let rx = m[0] * x + m[4] * y + m[8] * 0 + m[12]
        let ry = m[1] * x + m[5] * y + m[9] * 0 + m[13]
        let rz = m[2] * x + m[6] * y + m[10] * 0 + m[14]
        let rw = m[3] * x + m[7] * y + m[11] * 0 + m[15]
        if abs(rw) > 0.000001, abs(rw - 1) > 0.000001 {
            return Vec3(rx / rw, ry / rw, rz / rw)
        }
        return Vec3(rx, ry, rz)
    }

    func inverted() -> Mat4? {
        // 高斯-约当消元（4×4，双精度）
        var a = (0..<4).map { row in (0..<8).map { col -> Double in
            if col < 4 { return self[row, col] }
            return col - 4 == row ? 1 : 0
        } }
        for pivot in 0..<4 {
            var best = pivot
            for row in pivot..<4 where abs(a[row][pivot]) > abs(a[best][pivot]) { best = row }
            guard abs(a[best][pivot]) > 1e-12 else { return nil }
            if best != pivot { a.swapAt(best, pivot) }
            let divisor = a[pivot][pivot]
            for col in 0..<8 { a[pivot][col] /= divisor }
            for row in 0..<4 where row != pivot {
                let factor = a[row][pivot]
                if abs(factor) < 1e-18 { continue }
                for col in 0..<8 { a[row][col] -= factor * a[pivot][col] }
            }
        }
        var result = [Double](repeating: 0, count: 16)
        for row in 0..<4 { for col in 0..<4 { result[col * 4 + row] = a[row][col + 4] } }
        return Mat4(result)
    }

    /// 由帧数据构造 TRS：T(position) · Rz·Ry·Rx(angle) · Diag(scale)
    static func trs(position: Vec3, angle: Vec3, scale: Vec3) -> Mat4 {
        let cz = cos(angle.z), sz = sin(angle.z)
        let cy = cos(angle.y), sy = sin(angle.y)
        let cx = cos(angle.x), sx = sin(angle.x)
        // R = Rz · Ry · Rx
        let r00 = cz * cy
        let r01 = cz * sy * sx - sz * cx
        let r02 = cz * sy * cx + sz * sx
        let r10 = sz * cy
        let r11 = sz * sy * sx + cz * cx
        let r12 = sz * sy * cx - cz * sx
        let r20 = -sy
        let r21 = cy * sx
        let r22 = cy * cx
        let scaleX = scale.x == 0 ? 1 : scale.x
        let scaleY = scale.y == 0 ? 1 : scale.y
        let scaleZ = scale.z == 0 ? 1 : scale.z
        return Mat4([
            r00 * scaleX, r10 * scaleX, r20 * scaleX, 0,
            r01 * scaleY, r11 * scaleY, r21 * scaleY, 0,
            r02 * scaleZ, r12 * scaleZ, r22 * scaleZ, 0,
            position.x, position.y, position.z, 1,
        ])
    }

    /// 两个 TRS 之间的线性插值（位置/缩放线性，旋转用四元数插值近似）。
    static func blend(_ a: Mat4, _ b: Mat4, t: Double) -> Mat4 {
        guard t > 0.0001 else { return a }
        guard t < 0.9999 else { return b }
        // 分解：取平移与列长（缩放）+ 旋转矩阵
        let pa = Vec3(a[0, 3], a[1, 3], a[2, 3])
        let pb = Vec3(b[0, 3], b[1, 3], b[2, 3])
        let sa = Vec3(length(a, 0), length(a, 1), length(a, 2))
        let sb = Vec3(length(b, 0), length(b, 1), length(b, 2))
        let qa = quaternion(a, scale: sa)
        let qb = quaternion(b, scale: sb)
        let q = slerp(qa, qb, t)
        let position = Vec3(pa.x + (pb.x - pa.x) * t, pa.y + (pb.y - pa.y) * t, pa.z + (pb.z - pa.z) * t)
        let scale = Vec3(sa.x + (sb.x - sa.x) * t, sa.y + (sb.y - sa.y) * t, sa.z + (sb.z - sa.z) * t)
        return fromQuaternion(q, position: position, scale: scale)
    }

    private static func length(_ m: Mat4, _ col: Int) -> Double {
        let x = m[0, col], y = m[1, col], z = m[2, col]
        let value = (x * x + y * y + z * z).squareRoot()
        return value > 1e-9 ? value : 1
    }

    private static func quaternion(_ m: Mat4, scale: Vec3) -> (Double, Double, Double, Double) {
        let r00 = m[0, 0] / scale.x, r01 = m[0, 1] / scale.y, r02 = m[0, 2] / scale.z
        let r10 = m[1, 0] / scale.x, r11 = m[1, 1] / scale.y, r12 = m[1, 2] / scale.z
        let r20 = m[2, 0] / scale.x, r21 = m[2, 1] / scale.y, r22 = m[2, 2] / scale.z
        let trace = r00 + r11 + r22
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            return (0.25 * s, (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s)
        } else if r00 > r11 && r00 > r22 {
            let s = (1 + r00 - r11 - r22).squareRoot() * 2
            return ((r21 - r12) / s, 0.25 * s, (r01 + r10) / s, (r02 + r20) / s)
        } else if r11 > r22 {
            let s = (1 + r11 - r00 - r22).squareRoot() * 2
            return ((r02 - r20) / s, (r01 + r10) / s, 0.25 * s, (r12 + r21) / s)
        } else {
            let s = (1 + r22 - r00 - r11).squareRoot() * 2
            return ((r10 - r01) / s, (r02 + r20) / s, (r12 + r21) / s, 0.25 * s)
        }
    }

    private static func slerp(_ a: (Double, Double, Double, Double),
                              _ b: (Double, Double, Double, Double),
                              _ t: Double) -> (Double, Double, Double, Double) {
        var dot = a.0 * b.0 + a.1 * b.1 + a.2 * b.2 + a.3 * b.3
        var bb = b
        if dot < 0 {
            dot = -dot
            bb = (-b.0, -b.1, -b.2, -b.3)
        }
        if dot > 0.9995 {
            let result = (a.0 + (bb.0 - a.0) * t, a.1 + (bb.1 - a.1) * t,
                          a.2 + (bb.2 - a.2) * t, a.3 + (bb.3 - a.3) * t)
            let norm = (result.0 * result.0 + result.1 * result.1
                + result.2 * result.2 + result.3 * result.3).squareRoot()
            return (result.0 / norm, result.1 / norm, result.2 / norm, result.3 / norm)
        }
        let theta = acos(max(-1, min(1, dot)))
        let sinTheta = sin(theta)
        let wa = sin((1 - t) * theta) / sinTheta
        let wb = sin(t * theta) / sinTheta
        return (a.0 * wa + bb.0 * wb, a.1 * wa + bb.1 * wb,
                a.2 * wa + bb.2 * wb, a.3 * wa + bb.3 * wb)
    }

    private static func fromQuaternion(_ q: (Double, Double, Double, Double),
                                       position: Vec3, scale: Vec3) -> Mat4 {
        let (w, x, y, z) = q
        let xx = x * x, yy = y * y, zz = z * z
        let xy = x * y, xz = x * z, yz = y * z
        let wx = w * x, wy = w * y, wz = w * z
        return Mat4([
            (1 - 2 * (yy + zz)) * scale.x, (2 * (xy + wz)) * scale.x, (2 * (xz - wy)) * scale.x, 0,
            (2 * (xy - wz)) * scale.y, (1 - 2 * (xx + zz)) * scale.y, (2 * (yz + wx)) * scale.y, 0,
            (2 * (xz + wy)) * scale.z, (2 * (yz - wx)) * scale.z, (1 - 2 * (xx + yy)) * scale.z, 0,
            position.x, position.y, position.z, 1,
        ])
    }
}
