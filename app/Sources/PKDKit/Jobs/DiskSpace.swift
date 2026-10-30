import Foundation

public enum DiskSpace {
    /// 目标卷可用空间（字节）。
    public static func availableBytes(at url: URL) -> Int64? {
        var probe = url
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            probe = url.deletingLastPathComponent()
        }

        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }

        let fallback = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity.map(Int64.init)
    }

    /// 产物大小估算。实测 40MB 包 → 65MB 产物（1.6×），转换纹理时取 3× 留余量。
    public static func estimateOutputBytes(pkgSize: Int64, convertsTextures: Bool) -> Int64 {
        convertsTextures ? pkgSize * 3 : pkgSize * 11 / 10
    }
}
