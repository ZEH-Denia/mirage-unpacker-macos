import AppKit
import ApplicationServices

// Example: swift tools/dev/ax-audit.swift <pid> tree
// Only operates on the isolated development application, never the installed app.
guard CommandLine.arguments.count >= 3, let pid = Int32(CommandLine.arguments[1]),
      let running = NSRunningApplication(processIdentifier: pid),
      running.bundleIdentifier == "com.zeh.pkd.development" else {
    fatalError("Expected a running PKD development application PID")
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)
func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, key as CFString, &result)
    return status == .success ? result : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func node(_ path: String) -> AXUIElement {
    var current = app
    for part in path.split(separator: "/") {
        if ["main", "panel"].contains(part), let window = children(app).first(where: {
            value($0, kAXRoleAttribute) as? String == kAXWindowRole
                && value($0, kAXTitleAttribute) as? String == (part == "main" ? "PKD 开发预览" : "打开")
        }) {
            current = window
            continue
        }
        guard let index = Int(part), children(current).indices.contains(index) else {
            fatalError("Element path no longer exists: \(path)")
        }
        current = children(current)[index]
    }
    return current
}
func check(_ result: AXError) {
    guard result == .success else {
        FileHandle.standardError.write(Data("AX operation returned \(result.rawValue); inspect current state before retrying.\n".utf8))
        exit(1)
    }
}
func tree(_ element: AXUIElement, _ path: String, _ depth: Int = 0) {
    guard depth <= 20 else { return }
    let role = value(element, kAXRoleAttribute) as? String ?? ""
    let title = value(element, kAXTitleAttribute) as? String
        ?? value(element, kAXDescriptionAttribute) as? String ?? ""
    let text = value(element, kAXValueAttribute).map { String(describing: $0) } ?? ""
    print("\(path) \(role) \(title) \(text.prefix(180))")
    for (index, child) in children(element).enumerated() {
        tree(child, "\(path)/\(index)", depth + 1)
    }
}
func findChoice(_ element: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
    guard depth <= 22 else { return nil }
    if value(element, kAXRoleAttribute) as? String == kAXMenuItemRole,
       value(element, kAXTitleAttribute) as? String == title { return element }
    for child in children(element) {
        if let found = findChoice(child, title: title, depth: depth + 1) { return found }
    }
    return nil
}
let args = CommandLine.arguments
switch args[2] {
case "tree": tree(node(args.count > 3 ? args[3] : "main"), args.count > 3 ? args[3] : "main")
case "press": check(AXUIElementPerformAction(node(args[3]), kAXPressAction as CFString))
case "menu": check(AXUIElementPerformAction(node(args[3]), kAXShowMenuAction as CFString))
case "context":
    let status = AXUIElementPerformAction(node(args[3]), kAXShowMenuAction as CFString)
    // Native menus can keep the AX action pending until a menu item is chosen.
    // Inspect the resulting menu after a timeout instead of sending the action twice.
    if status != .cannotComplete { check(status) }
    usleep(150_000)
    guard let choice = findChoice(app, title: args[4]) else { fatalError("Context choice is no longer available") }
    check(AXUIElementPerformAction(choice, kAXPressAction as CFString))
case "choose":
    let popup = node(args[3])
    check(AXUIElementPerformAction(popup, kAXPressAction as CFString))
    usleep(150_000)
    guard let choice = findChoice(popup, title: args[4]) else { fatalError("Menu choice is no longer available") }
    check(AXUIElementPerformAction(choice, kAXPressAction as CFString))
case "select": check(AXUIElementSetAttributeValue(node(args[3]), kAXSelectedAttribute as CFString, kCFBooleanTrue))
case "text": check(AXUIElementSetAttributeValue(node(args[3]), kAXValueAttribute as CFString, args[4] as CFString))
case "resize":
    var size = CGSize(width: Double(args[3])!, height: Double(args[4])!)
    check(AXUIElementSetAttributeValue(node("main"), kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!))
case "activate":
    running.activate(options: [.activateAllWindows])
default: fatalError("Commands: tree, press, menu, context, choose, select, text, resize, activate")
}
