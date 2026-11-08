import AppKit
import ApplicationServices
import Carbon
import KeySwitcherCore

// End-to-end check of the running WE KeySwitcher: types real key events into a
// TextEdit document and compares what lands in the document.
// Needs Accessibility for the process that runs it. Do not type while it runs.

setvbuf(stdout, nil, _IONBF, 0)
guard let layouts = LayoutSet.loadSystem() else { fatalError("layouts missing") }

func source(_ k: LayoutKind) -> TISInputSource? {
    let f = [kTISPropertyInputSourceID as String: k.inputSourceID!] as CFDictionary
    return (TISCreateInputSourceList(f, false)?.takeRetainedValue() as? [TISInputSource])?.first
}

func currentLayout() -> LayoutKind? {
    // TIS caches the current source until the run loop sees the change.
    CFRunLoopRunInMode(.defaultMode, 0.05, false)
    guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
    return LayoutKind(inputSourceID: Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String)
}

func pause(_ ms: Int) { CFRunLoopRunInMode(.defaultMode, Double(ms) / 1000, false) }

func select(_ k: LayoutKind) {
    for _ in 0..<20 {
        if currentLayout() == k { break }
        if let s = source(k) { TISSelectInputSource(s) }
        pause(100)
    }
    pause(100)
}

let src = CGEventSource(stateID: .hidSystemState)

func key(_ code: UInt16, flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        pause(12)
    }
    pause(18)
}

func modifierTap(_ codes: [UInt16], _ flags: [CGEventFlags]) {
    // Press the modifiers one by one, then release them in reverse order.
    var acc: CGEventFlags = []
    for (c, f) in zip(codes, flags) {
        acc.insert(f)
        let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: true)!
        e.type = .flagsChanged
        e.flags = acc
        e.post(tap: .cghidEventTap)
        pause(40)
    }
    for (c, f) in zip(codes, flags).reversed() {
        acc.remove(f)
        let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: false)!
        e.type = .flagsChanged
        e.flags = acc
        e.post(tap: .cghidEventTap)
        pause(40)
    }
    pause(250)
}

func option() { modifierTap([UInt16(kVK_Option)], [.maskAlternate]) }
func optionShift() { modifierTap([UInt16(kVK_Option), UInt16(kVK_Shift)], [.maskAlternate, .maskShift]) }

/// Types `text` with the keys it has in layout `intended`, whatever layout is on.
func shiftState(_ down: Bool) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: UInt16(kVK_Shift), keyDown: down)!
    e.type = .flagsChanged
    e.flags = down ? .maskShift : []
    e.post(tap: .cghidEventTap)
    pause(15)
}

/// Types `text` with the keys it has in layout `intended`, whatever layout is
/// on. Shift is pressed and released around capitals, like a person does.
func type(_ text: String, as intended: LayoutKind) {
    guard let strokes = layouts[intended].strokes(for: text) else { fatalError("cannot type \(text)") }
    var shiftDown = false
    for s in strokes {
        if s.shift != shiftDown { shiftState(s.shift); shiftDown = s.shift }
        key(s.keyCode, flags: s.shift ? .maskShift : [])
    }
    if shiftDown { shiftState(false) }
    pause(150)
}

func focusedValue() -> String {
    let sys = AXUIElementCreateSystemWide()
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v else { return "<no focus>" }
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(v as! AXUIElement, kAXValueAttribute as CFString, &t)
    return (t as? String) ?? "<no value>"
}

func clear() {
    key(UInt16(kVK_ANSI_A), flags: .maskCommand)
    key(UInt16(kVK_Delete))
    pause(150)
}

var passed = 0, failed = 0
func check(_ name: String, _ expected: String, layout: LayoutKind? = nil) {
    pause(350)
    let got = focusedValue()
    let lay = currentLayout()
    let ok = got == expected && (layout == nil || lay == layout)
    if ok { passed += 1 } else { failed += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got '\(got)' layout \(lay?.rawValue ?? "?")" + (ok ? "" : " expected '\(expected)' \(layout?.rawValue ?? "")"))
}

func defaultsWrite(_ key: String, _ on: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["write", "sk.whiteeagles.keyswitcher", key, "-bool", on ? "true" : "false"]
    try? p.run(); p.waitUntilExit()
    pause(1200)
}
// Undo tests below must not teach the app anything.
defaultsWrite("learnFromUndo", false)

// Open a plain text document in TextEdit.
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
let file = dir.appendingPathComponent("keyswitcher-e2e.txt")
try? "".write(to: file, atomically: true, encoding: .utf8)
let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = true
let te = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
let sem = DispatchSemaphore(value: 0)
NSWorkspace.shared.open([file], withApplicationAt: te, configuration: cfg) { _, _ in sem.signal() }
sem.wait()
pause(2500)
clear()

// 1. Russian typed in the U.S. layout switches at the space.
select(.us); type("привет ", as: .ru)
check("ru typed in US", "привет ", layout: .ru)
clear()

// 2. English typed in the Russian layout.
select(.ru); type("hello ", as: .us)
check("en typed in RU", "hello ", layout: .us)
clear()

// 3. English in English stays.
select(.us); type("hello world ", as: .us)
check("en stays", "hello world ", layout: .us)
clear()

// 4. Slovak in the Slovak layout stays, also without diacritics in U.S.
select(.sk); type("ďakujem pekne ", as: .sk)
check("sk stays", "ďakujem pekne ", layout: .sk)
clear()
select(.us); type("dakujem ", as: .us)
check("sk without diacritics stays", "dakujem ", layout: .us)
clear()

// 5. Slovak typed in the Russian layout goes to Slovak (last Latin layout).
select(.sk); type("a ", as: .sk); clear()
select(.ru); type("účet ", as: .sk)
check("sk typed in RU", "účet ", layout: .sk)
clear()

// 6. Comma typed on the Russian comma key goes with the word.
select(.us); type("привет, ", as: .ru)
check("ru with comma", "привет, ", layout: .ru)
clear()

// 7. Option converts the last word typed so far.
select(.us); type("слово", as: .ru); option()
check("Option on word", "слово", layout: .ru)
type(" ", as: .ru)
check("no auto switch after manual", "слово ", layout: .ru)
clear()

// 8. Option right after an automatic switch undoes it.
select(.us); type("ghbdtn ", as: .us)
check("auto before undo", "привет ", layout: .ru)
option()
check("undo auto", "ghbdtn ", layout: .us)
clear()

// 9. Repeated Option takes one more word each time (automatic switching off).
func setAuto(_ on: Bool) { defaultsWrite("autoSwitch", on) }
setAuto(false)
select(.us); type("ghbdtn vbh", as: .us)
check("auto off keeps text", "ghbdtn vbh", layout: .us)
option()
check("Option once", "ghbdtn мир", layout: .ru)
option()
check("Option twice", "привет мир", layout: .ru)
clear()
setAuto(true)

// 10. Option+Shift inverts case of the last word.
select(.ru); type("пРИВЕТ", as: .ru); optionShift()
check("Option+Shift", "Привет", layout: .ru)
clear()

// 11. Two capitals at the start are fixed.
select(.ru); type("ПРивет ", as: .ru)
check("two capitals", "Привет ", layout: .ru)
clear()

// 12. Selection: select all, Option converts it and switches the layout.
select(.ru); type("руддщ цщкдв", as: .ru)
clear()
select(.us); type("hello world", as: .us)
key(UInt16(kVK_ANSI_A), flags: .maskCommand); pause(150)
option()
check("selection converted", "руддщ цщкдв", layout: .ru)
key(UInt16(kVK_RightArrow)); clear()

// 13. Option alone after clicking away: word before the caret.
select(.us); type("ghbdtn", as: .us)
key(UInt16(kVK_LeftArrow)); key(UInt16(kVK_RightArrow)) // buffer reset, caret stays
option()
check("word before caret", "привет", layout: .ru)
clear()

// 14. Words and abbreviations that must stay as typed.
select(.us); type("USA HTML git npm docker www.google.com user@mail.sk ", as: .us)
check("latin specials stay", "USA HTML git npm docker www.google.com user@mail.sk ", layout: .us)
clear()

// 15. A remembered word (imported from Punto) stays.
select(.us); type("petdoctor ", as: .us)
check("remembered word stays", "petdoctor ", layout: .us)
clear()

// 16. A longer sentence typed in the wrong layout.
select(.us); type("ghbdtn rfr ltkf ", as: .us)
check("sentence", "привет как дела ", layout: .ru)
clear()

// 17. Option while a menu is open does nothing (Finder's "Copy as Pathname"
// and other alternate menu items rely on Option).
func pressMenuBarItem(_ title: String) {
    guard let app = NSWorkspace.shared.frontmostApplication else { return }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var bar: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, kAXMenuBarAttribute as CFString, &bar)
    guard let bar else { return }
    var kids: CFTypeRef?
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
    for item in (kids as? [AXUIElement]) ?? [] {
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &t)
        if let t = t as? String, t == title || t == "Правка" || t == "Úpravy" {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            return
        }
    }
}
setAuto(false)
select(.us); type("ghbdtn", as: .us)
pressMenuBarItem("Edit"); pause(600)
option()
key(UInt16(kVK_Escape)); pause(300)
check("Option ignored with menu open", "ghbdtn", layout: .us)
clear()
setAuto(true)

// 17b. The same with a context menu opened by a right click, as in Finder.
func focusedCenter() -> CGPoint? {
    let sys = AXUIElementCreateSystemWide()
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v else { return nil }
    var p: CFTypeRef?, sz: CFTypeRef?
    AXUIElementCopyAttributeValue(v as! AXUIElement, kAXPositionAttribute as CFString, &p)
    AXUIElementCopyAttributeValue(v as! AXUIElement, kAXSizeAttribute as CFString, &sz)
    var pt = CGPoint.zero, size = CGSize.zero
    guard let p, let sz, AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(sz as! AXValue, .cgSize, &size) else { return nil }
    return CGPoint(x: pt.x + min(size.width / 2, 200), y: pt.y + min(size.height / 2, 120))
}
setAuto(false)
select(.us); type("ghbdtn", as: .us)
if let c = focusedCenter() {
    for t in [CGEventType.rightMouseDown, .rightMouseUp] {
        CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: c, mouseButton: .right)!.post(tap: .cghidEventTap)
        pause(60)
    }
    pause(600)
    option()
    key(UInt16(kVK_Escape)); pause(300)
    check("Option ignored with context menu open", "ghbdtn", layout: .us)
} else {
    failed += 1; print("FAIL context menu: no text area position")
}
clear()
setAuto(true)

// 18. Excluded application: nothing happens.
let prefs = UserDefaults(suiteName: "sk.whiteeagles.keyswitcher")!
let excludedBefore = prefs.stringArray(forKey: "excludedApps") ?? ["com.microsoft.VSCode"]
prefs.set(excludedBefore + ["com.apple.TextEdit"], forKey: "excludedApps"); prefs.synchronize(); pause(1200)
select(.us); type("ghbdtn ", as: .us)
check("excluded app untouched", "ghbdtn ", layout: .us)
option()
check("excluded app: Option ignored", "ghbdtn ", layout: .us)
prefs.set(excludedBefore, forKey: "excludedApps"); prefs.synchronize(); pause(1200)
clear()

print("\n\(passed) passed, \(failed) failed")
defaultsWrite("learnFromUndo", true)
exit(failed == 0 ? 0 : 1)
