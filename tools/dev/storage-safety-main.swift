import Foundation
#if canImport(PKDKit)
import PKDKit
#endif

// 独立回归入口：与 pkd-selftest 的 main.swift 解耦，便于主代理自行接线或单独运行。
let ok = StorageSafetyTests.run(verbose: true)
if !ok {
    FileHandle.standardError.write(Data("存储安全回归失败\n".utf8))
}
exit(ok ? 0 : 1)
