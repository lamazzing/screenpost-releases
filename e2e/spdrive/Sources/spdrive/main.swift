// spdrive: drive a running macOS app through the Accessibility API (AXUIElement).
// Presses controls without moving the mouse (except `drag`, which posts CGEvents).
// No third-party dependencies. See e2e/README.md for the command list.
import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Options

struct Options {
    var bundle = "com.luca.screenpost"
    var timeout: Double = 10
    var window: String?
    var role: String?
    var json = false
    var global = false
    var depth = 40
    var positional: [String] = []
}

func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(flag)", code: 2) }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--bundle": o.bundle = value(a)
        case "--timeout": o.timeout = Double(value(a)) ?? 10
        case "--window": o.window = value(a)
        case "--role": o.role = value(a).lowercased()
        case "--depth": o.depth = Int(value(a)) ?? 40
        case "--json": o.json = true
        case "--global": o.global = true
        default: o.positional.append(a)
        }
        i += 1
    }
    return o
}

// MARK: - Output

var jsonMode = false

func emit(_ text: String, json: [String: Any]? = nil) {
    if jsonMode, let json {
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) { print(s); return }
    }
    print(text)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    if jsonMode {
        emit("", json: ["ok": false, "error": message])
    } else {
        FileHandle.standardError.write(Data(("spdrive: " + message + "\n").utf8))
    }
    exit(code)
}

// MARK: - AX helpers

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    if let s = attr(el, name) as? String, !s.isEmpty { return s }
    return nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String] else { return [] }
    return a
}

func role(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute) ?? "?" }

func valueString(_ el: AXUIElement) -> String? {
    guard let v = attr(el, kAXValueAttribute) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

/// Labels an element answers to, most specific first.
func primaryLabels(_ el: AXUIElement) -> [String] {
    var out: [String] = []
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute] {
        if let s = str(el, name) { out.append(s) }
    }
    if let v = valueString(el) { out.append(v) }
    return out
}

func isEnabled(_ el: AXUIElement) -> Bool {
    (attr(el, kAXEnabledAttribute) as? Bool) ?? true
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}

func windowID(_ el: AXUIElement) -> Int? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? Int(id) : nil
}

let roleMap: [String: [String]] = [
    "button": ["AXButton", "AXMenuButton", "AXPopUpButton"],
    "link": ["AXLink"],
    "checkbox": ["AXCheckBox", "AXSwitch"],
    "radio": ["AXRadioButton"],
    "menuitem": ["AXMenuItem", "AXMenuBarItem"],
]

func roleAllowed(_ el: AXUIElement, _ wanted: String?) -> Bool {
    guard let wanted else { return true }
    guard let roles = roleMap[wanted] else { fail("unknown --role '\(wanted)' (button|link|checkbox|radio|menuitem)", code: 2) }
    return roles.contains(role(el))
}

// MARK: - App lookup

func sleepSeconds(_ s: Double) { Thread.sleep(forTimeInterval: s) }

func deadline(_ timeout: Double) -> Date { Date().addingTimeInterval(timeout) }

func runningApp(_ bundle: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { !$0.isTerminated }
}

func appElement(_ o: Options) -> (NSRunningApplication, AXUIElement) {
    let end = deadline(o.timeout)
    var app = runningApp(o.bundle)
    while app == nil && Date() < end { sleepSeconds(0.25); app = runningApp(o.bundle) }
    guard let app else { fail("app \(o.bundle) is not running", code: 3) }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 3)
    // SwiftUI exposes its tree only when an assistive client asks for it.
    AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    return (app, el)
}

/// Top-level windows: AXWindows plus any window-like child of the app element (floating panels).
func topWindows(_ app: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    for c in children(app) {
        let r = role(c)
        if (r == "AXWindow" || r == "AXSheet" || r == "AXDrawer") && !out.contains(where: { CFEqual($0, c) }) { out.append(c) }
    }
    return out
}

func windowTitle(_ w: AXUIElement) -> String { str(w, kAXTitleAttribute) ?? "" }

func windowsMatching(_ app: AXUIElement, _ title: String?) -> [AXUIElement] {
    let all = topWindows(app)
    guard let title else { return all }
    let alts = alternates(title)
    return all.filter { w in
        let t = windowTitle(w).lowercased()
        return alts.contains { t.contains($0.lowercased()) }
    }
}

/// `a|b|c` means "any of these labels", in order of preference.
func alternates(_ label: String) -> [String] {
    label.split(separator: "|", omittingEmptySubsequences: true).map { String($0) }
}

// MARK: - Tree walking and matching

struct Found {
    let el: AXUIElement
    let rank: Int      // 0 exact, 1 contains, 2 help
    let alt: Int
    let order: Int
}

func walk(_ root: AXUIElement, depth: Int, _ visit: (AXUIElement, Int) -> Bool) {
    func rec(_ el: AXUIElement, _ d: Int) -> Bool {
        if !visit(el, d) { return false }
        if d >= depth { return true }
        for c in children(el) { if !rec(c, d + 1) { return false } }
        return true
    }
    _ = rec(root, 0)
}

func matchRank(_ el: AXUIElement, _ label: String) -> Int? {
    let labels = primaryLabels(el)
    if labels.contains(label) { return 0 }
    let l = label.lowercased()
    if labels.contains(where: { $0.lowercased() == l }) { return 0 }
    if labels.contains(where: { $0.lowercased().contains(l) }) { return 1 }
    if let h = str(el, kAXHelpAttribute) {
        if h.lowercased() == l { return 2 }
        if h.lowercased().contains(l) { return 3 }
    }
    return nil
}

func searchRoots(_ app: AXUIElement, _ o: Options) -> [AXUIElement] {
    if let w = o.window { return windowsMatching(app, w) }
    let wins = topWindows(app)
    return wins.isEmpty ? [app] : wins
}

func findAll(_ app: AXUIElement, _ label: String, _ o: Options, pressable: Bool) -> [Found] {
    let alts = alternates(label)
    var found: [Found] = []
    var order = 0
    for root in searchRoots(app, o) {
        walk(root, depth: o.depth) { el, _ in
            order += 1
            for (i, a) in alts.enumerated() {
                guard let rank = matchRank(el, a) else { continue }
                if pressable {
                    if !roleAllowed(el, o.role) { continue }
                    found.append(Found(el: el, rank: rank, alt: i, order: order))
                } else {
                    found.append(Found(el: el, rank: rank, alt: i, order: order))
                }
                break
            }
            return true
        }
    }
    return found.sorted { ($0.alt, $0.rank, $0.order) < ($1.alt, $1.rank, $1.order) }
}

/// A match may be the static text inside a button; climb to the element that can be pressed.
func pressableTarget(_ el: AXUIElement) -> AXUIElement? {
    var cur: AXUIElement? = el
    var hops = 0
    while let c = cur, hops < 5 {
        if actions(c).contains(kAXPressAction) { return c }
        cur = attr(c, kAXParentAttribute) as! AXUIElement?
        hops += 1
    }
    return nil
}

func visibleLabels(_ app: AXUIElement, _ o: Options) -> [String] {
    var seen: [String] = []
    for root in searchRoots(app, o) {
        walk(root, depth: o.depth) { el, _ in
            let r = role(el)
            if r == "AXButton" || r == "AXLink" || r == "AXCheckBox" || r == "AXRadioButton" || r == "AXMenuItem" || r == "AXMenuButton" || r == "AXPopUpButton" {
                var parts = primaryLabels(el)
                if let h = str(el, kAXHelpAttribute) { parts.append("help:" + h) }
                let line = "\(r) \(parts.joined(separator: " | "))\(isEnabled(el) ? "" : " [disabled]")"
                if !seen.contains(line) { seen.append(line) }
            }
            return true
        }
    }
    return seen
}

func describeFailure(_ app: AXUIElement, _ o: Options, what: String) -> Never {
    let labels = visibleLabels(app, o)
    let wins = topWindows(app).map { "'\(windowTitle($0))'" }.joined(separator: ", ")
    var msg = "\(what)\nwindows: \(wins.isEmpty ? "(none)" : wins)\nvisible controls:"
    for l in labels { msg += "\n  - \(l)" }
    if labels.isEmpty { msg += " (none; is Accessibility granted and the app showing a window?)" }
    fail(msg)
}

// MARK: - Commands

func requireTrust() {
    if !AXIsProcessTrusted() {
        fail("this process is not trusted for Accessibility. Grant it in System Settings > Privacy & Security > Accessibility (the CI script writes a TCC entry).", code: 3)
    }
}

func cmdWindows(_ o: Options) {
    let (_, app) = appElement(o)
    let wins = topWindows(app)
    var rows: [[String: Any]] = []
    for w in wins {
        rows.append(["title": windowTitle(w), "id": windowID(w) ?? 0, "role": role(w), "subrole": str(w, kAXSubroleAttribute) ?? ""])
    }
    if jsonMode {
        emit("", json: ["ok": true, "windows": rows])
    } else {
        for r in rows { print("\(r["id"]!)\t\(r["title"]!)\t\(r["subrole"]!)") }
    }
}

func cmdWaitWindow(_ o: Options) {
    guard let title = o.positional.first else { fail("usage: wait-window <title-substring>", code: 2) }
    let (_, app) = appElement(o)
    let end = deadline(o.timeout)
    repeat {
        let m = windowsMatching(app, title)
        if let w = m.first {
            emit("window '\(windowTitle(w))' id=\(windowID(w) ?? 0)", json: ["ok": true, "title": windowTitle(w), "id": windowID(w) ?? 0])
            return
        }
        sleepSeconds(0.25)
    } while Date() < end
    describeFailure(app, o, what: "timed out after \(o.timeout)s waiting for a window matching '\(title)'")
}

func cmdPress(_ o: Options) {
    guard let label = o.positional.first else { fail("usage: press <label> [--window t] [--role r]", code: 2) }
    let (_, app) = appElement(o)
    let end = deadline(o.timeout)
    var lastProblem = "no element labelled '\(label)'"
    repeat {
        for f in findAll(app, label, o, pressable: true) {
            guard let target = pressableTarget(f.el) else { lastProblem = "'\(label)' found but not pressable"; continue }
            if !isEnabled(target) { lastProblem = "'\(label)' found but disabled"; continue }
            let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
            if err == .success {
                emit("pressed '\(label)'", json: ["ok": true, "pressed": label])
                return
            }
            lastProblem = "AXPress on '\(label)' failed (AXError \(err.rawValue))"
        }
        sleepSeconds(0.25)
    } while Date() < end
    describeFailure(app, o, what: "press '\(label)' failed after \(o.timeout)s: \(lastProblem)")
}

func cmdAssert(_ o: Options, mode: String) {
    guard let label = o.positional.first else { fail("usage: assert-\(mode) <label>", code: 2) }
    let (_, app) = appElement(o)
    let end = deadline(o.timeout)
    var lastProblem = "no element labelled '\(label)'"
    repeat {
        for f in findAll(app, label, o, pressable: false) {
            let target = pressableTarget(f.el) ?? f.el
            let en = isEnabled(target)
            if mode == "exists" || (mode == "enabled" && en) || (mode == "disabled" && !en) {
                emit("ok: '\(label)' \(mode)", json: ["ok": true, "label": label, "assert": mode])
                return
            }
            lastProblem = "'\(label)' exists but is \(en ? "enabled" : "disabled")"
        }
        sleepSeconds(0.25)
    } while Date() < end
    describeFailure(app, o, what: "assert-\(mode) '\(label)' failed after \(o.timeout)s: \(lastProblem)")
}

func cmdWaitText(_ o: Options) {
    guard let text = o.positional.first else { fail("usage: wait-text <text>", code: 2) }
    let (_, app) = appElement(o)
    let end = deadline(o.timeout)
    let alts = alternates(text).map { $0.lowercased() }
    repeat {
        var hit: String?
        for root in searchRoots(app, o) {
            walk(root, depth: o.depth) { el, _ in
                var texts = primaryLabels(el)
                if let h = str(el, kAXHelpAttribute) { texts.append(h) }
                for t in texts where alts.contains(where: { t.lowercased().contains($0) }) { hit = t; return false }
                return true
            }
            if hit != nil { break }
        }
        if let hit { emit("found text: \(hit)", json: ["ok": true, "text": hit]); return }
        sleepSeconds(0.25)
    } while Date() < end
    describeFailure(app, o, what: "timed out after \(o.timeout)s waiting for text '\(text)'")
}

func cmdType(_ o: Options) {
    guard o.positional.count >= 2 else { fail("usage: type <field-label-or-placeholder> <text>", code: 2) }
    let label = o.positional[0], text = o.positional[1]
    let (_, app) = appElement(o)
    let end = deadline(o.timeout)
    repeat {
        for f in findAll(app, label, o, pressable: false) {
            var target = f.el
            let fieldRoles = ["AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox"]
            if !fieldRoles.contains(role(target)) {
                // The label may sit on a sibling/parent; look for a field underneath or beside it.
                if let parent = attr(target, kAXParentAttribute) as! AXUIElement?, let field = firstField(parent) { target = field } else { continue }
            }
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let err = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text as CFString)
            if err == .success {
                _ = AXUIElementPerformAction(target, kAXConfirmAction as CFString)
                emit("typed into '\(label)'", json: ["ok": true, "field": label])
                return
            }
        }
        sleepSeconds(0.25)
    } while Date() < end
    describeFailure(app, o, what: "type into '\(label)' failed after \(o.timeout)s")
}

func firstField(_ root: AXUIElement) -> AXUIElement? {
    var out: AXUIElement?
    walk(root, depth: 4) { el, _ in
        if ["AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox"].contains(role(el)) { out = el; return false }
        return true
    }
    return out
}

func cmdSetValue(_ o: Options) {
    guard o.positional.count >= 2, let number = Double(o.positional[1]) else { fail("usage: set-value <label> <number>", code: 2) }
    let label = o.positional[0]
    let (_, app) = appElement(o)
    let end = deadline(o.timeout)
    repeat {
        for f in findAll(app, label, o, pressable: false) {
            var target = f.el
            if role(target) != "AXSlider" {
                if let parent = attr(target, kAXParentAttribute) as! AXUIElement?, let s = firstOfRole(parent, "AXSlider") { target = s } else { continue }
            }
            if AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, NSNumber(value: number)) == .success {
                emit("set '\(label)' = \(number)", json: ["ok": true, "label": label, "value": number])
                return
            }
        }
        sleepSeconds(0.25)
    } while Date() < end
    describeFailure(app, o, what: "set-value '\(label)' failed after \(o.timeout)s")
}

func firstOfRole(_ root: AXUIElement, _ r: String) -> AXUIElement? {
    var out: AXUIElement?
    walk(root, depth: 4) { el, _ in if role(el) == r { out = el; return false }; return true }
    return out
}

// Menus

func menuItems(of container: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    for c in children(container) {
        let r = role(c)
        if r == "AXMenuItem" || r == "AXMenuBarItem" { out.append(c) }
        else if r == "AXMenu" { out.append(contentsOf: menuItems(of: c)) }
    }
    return out
}

func itemTitle(_ el: AXUIElement) -> String { str(el, kAXTitleAttribute) ?? str(el, kAXDescriptionAttribute) ?? "" }

func pickItem(_ items: [AXUIElement], _ label: String) -> AXUIElement? {
    for a in alternates(label) {
        if let e = items.first(where: { itemTitle($0) == a }) { return e }
        let l = a.lowercased()
        if let e = items.first(where: { itemTitle($0).lowercased() == l }) { return e }
        if let e = items.first(where: { itemTitle($0).lowercased().contains(l) }) { return e }
    }
    return nil
}

/// Press without blocking forever: opening a menu can keep AXPress busy while the menu is tracking.
func pressAsync(_ el: AXUIElement, wait: Double = 1.5) -> AXError {
    var result: AXError = .success
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        AXUIElementSetMessagingTimeout(el, 1)
        result = AXUIElementPerformAction(el, kAXPressAction as CFString)
        sem.signal()
    }
    if sem.wait(timeout: .now() + wait) == .timedOut { return .success }
    // A timeout while a menu is tracking is expected and not an error for our purposes.
    return result == .cannotComplete ? .success : result
}

func walkMenuPath(start: AXUIElement, path: [String], o: Options, app: AXUIElement, what: String) {
    var container = start
    for (i, comp) in path.enumerated() {
        var item: AXUIElement?
        let end = deadline(min(o.timeout, 5))
        repeat {
            item = pickItem(menuItems(of: container), comp)
            if item == nil { sleepSeconds(0.2) }
        } while item == nil && Date() < end
        guard let item else {
            let avail = menuItems(of: container).map { "'\(itemTitle($0))'" }.joined(separator: ", ")
            fail("\(what): menu item '\(comp)' not found. available: \(avail.isEmpty ? "(none)" : avail)")
        }
        if !isEnabled(item) { fail("\(what): menu item '\(comp)' is disabled") }
        let err = pressAsync(item)
        if err != .success { fail("\(what): AXPress on '\(comp)' failed (AXError \(err.rawValue))") }
        if i < path.count - 1 { sleepSeconds(0.4); container = item }
    }
    emit("menu: \(path.joined(separator: " > "))", json: ["ok": true, "path": path])
}

func splitPath(_ positional: [String]) -> [String] {
    if positional.count == 1 { return positional[0].components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    return positional
}

func statusItemCandidates(_ appPID: pid_t, _ appName: String, _ bundle: String) -> [AXUIElement] {
    var out: [AXUIElement] = []
    func extras(_ el: AXUIElement) -> [AXUIElement] {
        guard let bar = attr(el, "AXExtrasMenuBar") else { return [] }
        return children(bar as! AXUIElement)
    }
    out.append(contentsOf: extras(AXUIElementCreateApplication(appPID)))
    if !out.isEmpty { return out }
    // Fallback: status items hosted by the system (SystemUIServer / Control Center), matched by name.
    for sys in ["com.apple.systemuiserver", "com.apple.controlcenter"] {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: sys) {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            for item in extras(el) {
                let labels = primaryLabels(item).map { $0.lowercased() }
                if labels.contains(where: { $0.contains(appName.lowercased()) || $0.contains(bundle.lowercased()) }) { out.append(item) }
            }
        }
    }
    return out
}

func cmdMenuExtra(_ o: Options) {
    let path = splitPath(o.positional)
    guard !path.isEmpty else { fail("usage: menu-extra <item> [> <submenu item>...]", code: 2) }
    let (running, app) = appElement(o)
    let end = deadline(o.timeout)
    var items: [AXUIElement] = []
    repeat {
        items = statusItemCandidates(running.processIdentifier, running.localizedName ?? "ScreenPost", o.bundle)
        if items.isEmpty { sleepSeconds(0.3) }
    } while items.isEmpty && Date() < end
    guard let statusItem = items.first else { describeFailure(app, o, what: "no menu bar status item found for \(o.bundle) (AXExtrasMenuBar empty)") }
    let err = pressAsync(statusItem, wait: 0.8)
    if err != .success { fail("could not open status item menu (AXError \(err.rawValue))") }
    sleepSeconds(0.5)
    walkMenuPath(start: statusItem, path: path, o: o, app: app, what: "menu-extra")
}

func cmdMenu(_ o: Options) {
    guard o.positional.count >= 2 else { fail("usage: menu <Menu> <Item> [<Subitem>...]", code: 2) }
    let (running, app) = appElement(o)
    running.activate(options: [])
    sleepSeconds(0.3)
    guard let bar = attr(app, kAXMenuBarAttribute) as! AXUIElement? else { fail("app has no menu bar (is it active?)") }
    guard let top = pickItem(children(bar), o.positional[0]) else {
        fail("menu '\(o.positional[0])' not found. available: \(children(bar).map { "'\(itemTitle($0))'" }.joined(separator: ", "))")
    }
    _ = pressAsync(top, wait: 0.8)
    sleepSeconds(0.4)
    walkMenuPath(start: top, path: Array(o.positional.dropFirst()), o: o, app: app, what: "menu")
}

// Keys and mouse

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
    "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
]

func cmdKey(_ o: Options) {
    guard let combo = o.positional.first else { fail("usage: key <combo> [--global]  e.g. cmd+shift+4", code: 2) }
    let (running, _) = appElement(o)
    var flags: CGEventFlags = []
    var keyName = ""
    for part in combo.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: keyName = part
        }
    }
    guard let code = keyCodes[keyName] else { fail("unknown key '\(keyName)' in '\(combo)'", code: 2) }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { fail("could not create key event") }
    down.flags = flags; up.flags = flags
    if o.global {
        down.post(tap: .cghidEventTap); sleepSeconds(0.05); up.post(tap: .cghidEventTap)
    } else {
        down.postToPid(running.processIdentifier); sleepSeconds(0.05); up.postToPid(running.processIdentifier)
    }
    emit("key \(combo)", json: ["ok": true, "key": combo])
}

func cmdDrag(_ o: Options) {
    let n = o.positional.compactMap { Double($0) }
    guard n.count == 4 else { fail("usage: drag x1 y1 x2 y2", code: 2) }
    let a = CGPoint(x: n[0], y: n[1]), b = CGPoint(x: n[2], y: n[3])
    func post(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    post(.mouseMoved, a); sleepSeconds(0.2)
    post(.leftMouseDown, a); sleepSeconds(0.2)
    let steps = 12
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        sleepSeconds(0.03)
    }
    sleepSeconds(0.2)
    post(.leftMouseUp, b)
    emit("drag \(a) -> \(b)", json: ["ok": true])
}

func cmdDump(_ o: Options) {
    let (_, app) = appElement(o)
    var lines: [[String: Any]] = []
    func rec(_ el: AXUIElement, _ d: Int) {
        let r = role(el)
        var parts: [String] = [r]
        if let s = str(el, kAXSubroleAttribute) { parts.append("(\(s))") }
        if let t = str(el, kAXTitleAttribute) { parts.append("title=\"\(t)\"") }
        if let t = str(el, kAXDescriptionAttribute) { parts.append("desc=\"\(t)\"") }
        if let t = str(el, kAXIdentifierAttribute) { parts.append("id=\"\(t)\"") }
        if let t = valueString(el) { parts.append("value=\"\(t.prefix(80))\"") }
        if let t = str(el, kAXHelpAttribute) { parts.append("help=\"\(t)\"") }
        if let t = str(el, kAXPlaceholderValueAttribute) { parts.append("placeholder=\"\(t)\"") }
        if !isEnabled(el) { parts.append("[disabled]") }
        let acts = actions(el).map { $0.replacingOccurrences(of: "AX", with: "") }
        if !acts.isEmpty { parts.append("actions=\(acts.joined(separator: ","))") }
        if let f = frame(el) { parts.append("frame=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.size.width))x\(Int(f.size.height))") }
        let line = String(repeating: "  ", count: d) + parts.joined(separator: " ")
        if jsonMode { lines.append(["depth": d, "text": line.trimmingCharacters(in: .whitespaces)]) } else { print(line) }
        if d < o.depth { for c in children(el) { rec(c, d + 1) } }
    }
    let roots = o.window != nil ? windowsMatching(app, o.window) : [app]
    if roots.isEmpty { fail("no window matching '\(o.window ?? "")'") }
    for r in roots { rec(r, 0) }
    if jsonMode { emit("", json: ["ok": true, "tree": lines]) }
}

func cmdCheck(_ o: Options) {
    let trusted = AXIsProcessTrusted()
    let screen = CGPreflightScreenCaptureAccess()
    emit("accessibility trusted: \(trusted)\nscreen recording: \(screen)", json: ["ok": trusted, "accessibility": trusted, "screenRecording": screen])
    if !trusted { exit(3) }
}

let usage = """
spdrive: drive a macOS app through the Accessibility API.

usage: spdrive <command> [args] [--bundle id] [--timeout S] [--window title] [--role r] [--json]

  check                                 report Accessibility / Screen Recording trust of this process
  windows                               list windows (id, title, subrole)
  wait-window <title> [--timeout S]     wait for a window whose title contains <title>
  press <label> [--window t] [--role button|link|checkbox|radio|menuitem]
  wait-text <text>                      wait for any element whose label/value contains <text>
  assert-enabled|assert-disabled|assert-exists <label>
  type <field-label-or-placeholder> <text>
  set-value <label> <number>            sliders
  menu-extra <item> [> <subitem>...]    app's menu bar status item menu
  menu <Menu> <Item> [<Subitem>...]     app's main menu
  key <combo> [--global]                e.g. cmd+shift+4 (posted to the app's pid; --global posts to the HID tap)
  drag x1 y1 x2 y2                      moves the real mouse (CI only)
  dump [--window title] [--depth N]     print the accessibility tree

Labels match AXTitle/AXDescription/AXIdentifier/AXValue, exact then case-insensitive contains,
then AXHelp. 'a|b' means either label. Default --bundle com.luca.screenpost, --timeout 10.
Exit codes: 0 ok, 1 failed, 2 usage, 3 not trusted / app not running.
"""

// MARK: - Main

var argv = Array(CommandLine.arguments.dropFirst())
if argv.isEmpty { print(usage); exit(2) }
let command = argv.removeFirst()
if ["-h", "--help", "help"].contains(command) { print(usage); exit(0) }
let opts = parseOptions(argv)
jsonMode = opts.json

if command != "check" { requireTrust() }

switch command {
case "check": cmdCheck(opts)
case "windows": cmdWindows(opts)
case "wait-window": cmdWaitWindow(opts)
case "press": cmdPress(opts)
case "wait-text": cmdWaitText(opts)
case "assert-enabled": cmdAssert(opts, mode: "enabled")
case "assert-disabled": cmdAssert(opts, mode: "disabled")
case "assert-exists": cmdAssert(opts, mode: "exists")
case "type": cmdType(opts)
case "set-value": cmdSetValue(opts)
case "menu-extra": cmdMenuExtra(opts)
case "menu": cmdMenu(opts)
case "key": cmdKey(opts)
case "drag": cmdDrag(opts)
case "dump": cmdDump(opts)
default: fail("unknown command '\(command)'\n\n\(usage)", code: 2)
}
