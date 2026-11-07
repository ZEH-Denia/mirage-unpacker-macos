import AppKit
import ApplicationServices

// Fault-injection AX driver for the isolated test copy only.
//
// Safety: the target process path must contain the fault evidence directory
// marker supplied on the command line ("fault-..."), so this can never press
// buttons in the installed app or another agent's development copy.
//
// Usage:
//   swift tools/dev/fault-ax.swift <pid> <marker> tree [window-title]
//   swift tools/dev/fault-ax.swift <pid> <marker> press <index-path>
//   swift tools/dev/fault-ax.swift <pid> <marker> find <role|title-substring>
//   swift tools/dev/fault-ax.swift <pid> <marker> findall <role|title-substring>
//   swift tools/dev/fault-ax.swift <pid> <marker> select <index-path>
//   swift tools/dev/fault-ax.swift <pid> <marker> text <index-path> <value>
//   swift tools/dev/fault-ax.swift <pid> <marker> choose <index-path> <title>

guard CommandLine.arguments.count >= 4, let pid = Int32(CommandLine.arguments[1]) else {
    fatalError("usage: fault-ax.swift <pid> <marker> <command> [...]")
}
let marker = CommandLine.arguments[2]
guard let running = NSRunningApplication(processIdentifier: pid) else {
    fatalError("no running application with pid \(pid)")
}
let executablePath = running.executableURL?.path ?? ""
guard executablePath.contains(marker) else {
    fatalError("refusing to drive pid \(pid): executable \(executablePath) does not contain marker \(marker)")
}

let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, key as CFString, &result)
    return status == .success ? result : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func title(_ element: AXUIElement) -> String {
    (attr(element, kAXTitleAttribute) as? String) ?? (attr(element, kAXDescriptionAttribute) as? String) ?? ""
}

func valueText(_ element: AXUIElement) -> String {
    guard let value = attr(element, kAXValueAttribute) else { return "" }
    return String(describing: value)
}

func role(_ element: AXUIElement) -> String {
    (attr(element, kAXRoleAttribute) as? String) ?? ""
}

func windows() -> [AXUIElement] {
    (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

func mainWindow(_ titleHint: String? = nil) -> AXUIElement {
    let all = windows()
    if let hint = titleHint, let match = all.first(where: { title($0) == hint }) { return match }
    guard let first = all.first else { fatalError("no windows") }
    return first
}

func node(_ path: String, windowTitleHint: String? = nil) -> AXUIElement {
    var current = path.hasPrefix("win") ? mainWindow(windowTitleHint) : app
    for rawPart in path.split(separator: "/") {
        let part = String(rawPart)
        if part == "win" { continue }
        guard let index = Int(part), children(current).indices.contains(index) else {
            fatalError("element path no longer exists: \(path) (failed at \(part))")
        }
        current = children(current)[index]
    }
    return current
}

func find(_ element: AXUIElement, role wanted: String?, titleNeedle: String?, depth: Int = 0) -> [AXUIElement] {
    guard depth <= 30 else { return [] }
    var hits: [AXUIElement] = []
    let elementRole = role(element)
    let elementTitle = title(element) + " " + valueText(element)
    let roleOK = wanted.map { elementRole == $0 } ?? true
    let titleOK = titleNeedle.map { elementTitle.contains($0) } ?? true
    if roleOK && titleOK && (wanted != nil || titleNeedle != nil) {
        hits.append(element)
        if wanted == kAXWindowRole { return hits }
    }
    for child in children(element) {
        hits.append(contentsOf: find(child, role: wanted, titleNeedle: titleNeedle, depth: depth + 1))
    }
    return hits
}

func describe(_ element: AXUIElement, _ path: String, _ depth: Int) {
    let tabs = String(repeating: "  ", count: min(depth, 12))
    print("\(tabs)\(path) \(role(element)) | \(title(element).prefix(80)) | \(valueText(element).prefix(160))")
}

func tree(_ element: AXUIElement, _ path: String, _ depth: Int = 0, _ maxDepth: Int = 24) {
    describe(element, path, depth)
    guard depth < maxDepth else { return }
    for (index, child) in children(element).enumerated() {
        tree(child, "\(path)/\(index)", depth + 1, maxDepth)
    }
}

func press(_ element: AXUIElement) {
    let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard status == .success else { fatalError("press failed: \(status.rawValue)") }
}

let args = CommandLine.arguments
let command = args[3]
let windowHint = ProcessInfo.processInfo.environment["FAULT_AX_WINDOW"]
switch command {
case "tree":
    let root = windowHint != nil ? mainWindow(windowHint) : mainWindow()
    tree(root, "win")
case "press":
    press(node(args[4], windowTitleHint: windowHint))
case "find":
    let needle = args.count > 4 ? args[4] : ""
    for hit in find(app, role: nil, titleNeedle: needle) {
        describe(hit, "match", 0)
    }
case "close":
    let win = mainWindow(windowHint)
    guard let raw = attr(win, kAXCloseButtonAttribute) else { fatalError("no close button") }
    press(unsafeBitCast(raw, to: AXUIElement.self))
case "key":
    // e.g. key 23 cmd   (keycode 23 = "5"); modifiers: cmd, shift, opt, ctrl
    let keyCode = CGKeyCode(Int(args[4])!)
    let modifiers = Set(args.dropFirst(5))
    var flags: CGEventFlags = []
    if modifiers.contains("cmd") { flags.insert(.maskCommand) }
    if modifiers.contains("shift") { flags.insert(.maskShift) }
    if modifiers.contains("opt") { flags.insert(.maskAlternate) }
    if modifiers.contains("ctrl") { flags.insert(.maskControl) }
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { fatalError("event") }
        event.flags = flags
        event.postToPid(pid)
        usleep(30_000)
    }
    print("key sent \(keyCode) \(modifiers)")
case "front":
    let status = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    print("frontmost=\(status.rawValue)")
case "pressmatch":
    // press the first button-like element whose title/value contains the needle
    let needle = args[4]
    let candidates = [kAXButtonRole, kAXRadioButtonRole, kAXMenuButtonRole, kAXMenuItemRole, kAXCheckBoxRole]
    var hit: AXUIElement?
    for candidateRole in candidates {
        if let found = find(app, role: candidateRole, titleNeedle: needle).first { hit = found; break }
    }
    guard let target = hit else { fatalError("no pressable element containing \(needle)") }
    press(target)
    describe(target, "pressed", 0)
case "listmatches":
    // list match index + role + title for a needle
    let needle = args[4]
    for (index, hit) in find(app, role: nil, titleNeedle: needle).enumerated() {
        print("\(index) \(role(hit)) | \(title(hit))")
    }
case "pressbutton":
    let needle = args[4]
    let hits = find(app, role: kAXButtonRole, titleNeedle: needle).filter { !title($0).isEmpty }
    guard let hit = hits.first else { fatalError("no titled AXButton containing \(needle)") }
    press(hit)
    describe(hit, "pressed", 0)
case "pressnth":
    let needle = args[4]
    let nth = Int(args[5]) ?? 0
    let hits = find(app, role: nil, titleNeedle: needle).filter {
        [kAXButtonRole, kAXRadioButtonRole, kAXMenuItemRole, kAXMenuButtonRole].contains(role($0))
    }
    guard hits.indices.contains(nth) else { fatalError("match \(nth) not available for \(needle) (count \(hits.count))") }
    press(hits[nth])
    describe(hits[nth], "pressed", 0)
case "menu":
    // press menubar item, then its menu item (both by exact/substring title)
    let barTitle = args[4]
    let itemTitle = args[5]
    guard let rawBar = attr(app, kAXMenuBarAttribute) else { fatalError("no menubar") }
    let bar = unsafeBitCast(rawBar, to: AXUIElement.self)
    guard let barItem = find(bar, role: kAXMenuBarItemRole, titleNeedle: barTitle).first else {
        fatalError("menubar item not found: \(barTitle)")
    }
    AXUIElementPerformAction(barItem, kAXPressAction as CFString)
    usleep(300_000)
    guard let item = find(app, role: kAXMenuItemRole, titleNeedle: itemTitle).first else {
        fatalError("menu item not found: \(itemTitle)")
    }
    press(item)
case "findrole":
    let wantedRole = args[4]
    let needle = args.count > 5 ? args[5] : nil
    for hit in find(app, role: wantedRole, titleNeedle: needle) {
        describe(hit, "match", 0)
    }
case "select":
    let element = node(args[4], windowTitleHint: windowHint)
    let status = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    guard status == .success else { fatalError("select failed: \(status.rawValue)") }
case "text":
    let element = node(args[4], windowTitleHint: windowHint)
    let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, args[5] as CFString)
    guard status == .success else { fatalError("set text failed: \(status.rawValue)") }
case "choose":
    let element = node(args[4], windowTitleHint: windowHint)
    press(element)
    usleep(200_000)
    let needle = args[5]
    guard let hit = find(app, role: kAXMenuItemRole, titleNeedle: needle).first else {
        fatalError("menu choice not available: \(needle)")
    }
    press(hit)
default:
    fatalError("unknown command \(command)")
}
