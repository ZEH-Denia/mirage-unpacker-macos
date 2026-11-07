// update-ax.swift — PID/window-scoped Accessibility inspector & presser for the
// Mirage Unpacker update-flow E2E harness. Read-only except for `press`.
//
// Usage:
//   swift update-ax.swift <pid> windows
//   swift update-ax.swift <pid> dump [--max-depth N] [--window-title SUBSTR]
//   swift update-ax.swift <pid> press <role-or-any> <title-substring> [--window-title SUBSTR]
//   swift update-ax.swift <pid> alert        # dump only alert/sheet contents
//
// Only elements inside the given PID are touched; never a global UI scan.
import Foundation
import ApplicationServices

func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return err == .success ? value : nil
}

func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = copyAttr(el, name) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func boolAttr(_ el: AXUIElement, _ name: String) -> Bool? {
    guard let v = copyAttr(el, name) else { return nil }
    return (v as? NSNumber)?.boolValue
}

func frameString(_ el: AXUIElement) -> String {
    var out = ""
    if let posV = copyAttr(el, kAXPositionAttribute) {
        var p = CGPoint.zero
        if AXValueGetValue(posV as! AXValue, .cgPoint, &p) {
            out += String(format: "pos=(%.0f,%.0f) ", p.x, p.y)
        }
    }
    if let sizeV = copyAttr(el, kAXSizeAttribute) {
        var s = CGSize.zero
        if AXValueGetValue(sizeV as! AXValue, .cgSize, &s) {
            out += String(format: "size=(%.0f,%.0f)", s.width, s.height)
        }
    }
    return out
}

func describe(_ el: AXUIElement, depth: Int) -> String {
    let role = stringAttr(el, kAXRoleAttribute) ?? "?"
    var parts: [String] = []
    parts.append(String(repeating: "  ", count: depth) + role)
    if let sub = stringAttr(el, kAXSubroleAttribute) { parts.append("sub=\(sub)") }
    if let title = stringAttr(el, kAXTitleAttribute), !title.isEmpty { parts.append("title=\(q(title))") }
    if let val = stringAttr(el, kAXValueAttribute), !val.isEmpty { parts.append("value=\(q(val))") }
    if let desc = stringAttr(el, kAXDescriptionAttribute), !desc.isEmpty { parts.append("desc=\(q(desc))") }
    if let ident = stringAttr(el, kAXIdentifierAttribute), !ident.isEmpty { parts.append("id=\(ident)") }
    if let help = stringAttr(el, kAXHelpAttribute), !help.isEmpty { parts.append("help=\(q(help))") }
    if let enabled = boolAttr(el, kAXEnabledAttribute), !enabled { parts.append("disabled") }
    let fr = frameString(el)
    if !fr.isEmpty { parts.append(fr) }
    return parts.joined(separator: " ")
}

func q(_ s: String) -> String {
    let oneLine = s.replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(oneLine)\""
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    guard let v = copyAttr(el, kAXChildrenAttribute) else { return [] }
    return (v as? [AXUIElement]) ?? []
}

func windows(_ app: AXUIElement) -> [AXUIElement] {
    guard let v = copyAttr(app, kAXWindowsAttribute) else { return [] }
    return (v as? [AXUIElement]) ?? []
}

func dumpTree(_ el: AXUIElement, depth: Int, maxDepth: Int, into out: inout [String]) {
    out.append(describe(el, depth: depth))
    if depth >= maxDepth { return }
    for c in children(el) {
        dumpTree(c, depth: depth + 1, maxDepth: maxDepth, into: &out)
    }
}

/// Collect (element, role, title-ish string) for every descendant.
func collect(_ el: AXUIElement, depth: Int, maxDepth: Int, into out: inout [(AXUIElement, String, String)]) {
    let role = stringAttr(el, kAXRoleAttribute) ?? "?"
    var labels: [String] = []
    for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
        if let s = stringAttr(el, key), !s.isEmpty { labels.append(s) }
    }
    out.append((el, role, labels.joined(separator: " | ")))
    if depth >= maxDepth { return }
    for c in children(el) {
        collect(c, depth: depth + 1, maxDepth: maxDepth, into: &out)
    }
}

func findWindows(_ app: AXUIElement, titleSubstr: String?) -> [AXUIElement] {
    let all = windows(app)
    guard let sub = titleSubstr else { return all }
    return all.filter { w in
        let t = stringAttr(w, kAXTitleAttribute) ?? ""
        return t.contains(sub)
    }
}

func main() {
    let args = CommandLine.arguments
    guard args.count >= 3, let pid = pid_t(args[1]) else {
        FileHandle.standardError.write(Data("usage: update-ax <pid> windows|dump|press|alert\n".utf8))
        exit(64)
    }
    let command = args[2]
    var rest = Array(args.dropFirst(3))
    var maxDepth = 12
    var windowTitle: String? = nil
    var positional: [String] = []
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--max-depth":
            i += 1
            if i < rest.count { maxDepth = Int(rest[i]) ?? maxDepth }
        case "--window-title":
            i += 1
            if i < rest.count { windowTitle = rest[i] }
        default:
            positional.append(rest[i])
        }
        i += 1
    }

    guard AXIsProcessTrusted() else {
        FileHandle.standardError.write(Data("AX_NOT_TRUSTED\n".utf8))
        exit(77)
    }

    let app = AXUIElementCreateApplication(pid)
    var out: [String] = []

    switch command {
    case "windows":
        for (idx, w) in windows(app).enumerated() {
            let role = stringAttr(w, kAXRoleAttribute) ?? "?"
            let sub = stringAttr(w, kAXSubroleAttribute) ?? ""
            let title = stringAttr(w, kAXTitleAttribute) ?? "<no-title>"
            out.append("win[\(idx)] title=\(q(title)) role=\(role) sub=\(sub) \(frameString(w))")
        }
        if out.isEmpty { out.append("NO_WINDOWS") }

    case "dump", "alert":
        var ws = findWindows(app, titleSubstr: windowTitle)
        if command == "alert" {
            // Prefer sheets / modal alert-ish windows.
            let sheets = ws.filter { (stringAttr($0, kAXRoleAttribute) ?? "").contains("Sheet") }
            if !sheets.isEmpty { ws = sheets }
        }
        if ws.isEmpty {
            out.append("NO_MATCHING_WINDOW (titleFilter=\(windowTitle ?? "<none>"))")
        }
        for (idx, w) in ws.enumerated() {
            out.append("=== window[\(idx)] ===")
            dumpTree(w, depth: 0, maxDepth: maxDepth, into: &out)
        }

    case "press":
        guard positional.count >= 2 else {
            FileHandle.standardError.write(Data("press requires <role-prefix|any> <title-substring>\n".utf8))
            exit(64)
        }
        let wantRole = positional[0].lowercased()
        let wantText = positional[1]
        var candidates: [(AXUIElement, String, String)] = []
        for w in findWindows(app, titleSubstr: windowTitle) {
            collect(w, depth: 0, maxDepth: maxDepth, into: &candidates)
        }
        if windowTitle == nil {
            // also allow app-level menu / dialog elements outside windows
            collect(app, depth: 0, maxDepth: 4, into: &candidates)
        }
        var pressed = false
        // Exact title/label match first, then substring; role filter always applies.
        // Exactness matters: "安装更新" is a substring of "以后自动下载并安装更新".
        for pass in ["exact", "substring"] {
            if pressed { break }
            for (el, role, labels) in candidates {
                if wantRole != "any" && !role.lowercased().contains(wantRole) { continue }
                let fields = labels.components(separatedBy: " | ")
                let matches = pass == "exact" ? fields.contains(wantText) : labels.contains(wantText)
                if !matches { continue }
                let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
                out.append("PRESS(\(pass)) role=\(role) labels=\(labels) result=\(err.rawValue)")
                if err == .success { pressed = true; break }
            }
        }
        if !pressed {
            out.append("NO_PRESSABLE_MATCH role=\(wantRole) text=\(q(wantText))")
            out.append("--- candidates ---")
            for (_, role, labels) in candidates where !labels.isEmpty {
                out.append("  \(role): \(labels)")
            }
        }

    default:
        FileHandle.standardError.write(Data("unknown command \(command)\n".utf8))
        exit(64)
    }

    print(out.joined(separator: "\n"))
}

main()
