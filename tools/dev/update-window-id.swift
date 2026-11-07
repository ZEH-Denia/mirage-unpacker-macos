// update-window-id.swift — print CGWindowID list for one PID (for screencapture -l).
import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int(args[1]) else {
    FileHandle.standardError.write(Data("usage: update-window-id <pid>\n".utf8))
    exit(64)
}
let opts: CGWindowListOption = [.optionAll]
guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for info in infos {
    guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == pid else { continue }
    let num = info[kCGWindowNumber as String] as? Int ?? -1
    let name = info[kCGWindowName as String] as? String ?? ""
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    var bounds = ""
    if let b = info[kCGWindowBounds as String] as? [String: Any] {
        bounds = "\(b["X"] ?? "")x\(b["Y"] ?? "") \(b["Width"] ?? "")x\(b["Height"] ?? "")"
    }
    print("id=\(num) layer=\(layer) name=\"\(name)\" bounds=\(bounds)")
}
