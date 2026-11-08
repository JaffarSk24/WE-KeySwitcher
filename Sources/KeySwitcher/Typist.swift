import AppKit
import ApplicationServices
import Carbon

/// Marker in kCGEventSourceUserData of events we post ourselves, so the tap
/// lets them through untouched.
let syntheticMarker: Int64 = 0x5745_4B53 // "WEKS"

/// Posts key events: deletions and text.
enum Typist {
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = syntheticMarker
        return s
    }()

    private static func keyEvents(_ code: CGKeyCode, flags: CGEventFlags = []) -> [CGEvent] {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return [] }
        for e in [down, up] {
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        }
        return [down, up]
    }

    private static func textEvents(_ text: String) -> [CGEvent] {
        var out: [CGEvent] = []
        for ch in text {
            let units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            for e in [down, up] {
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            }
            out += [down, up]
        }
        return out
    }

    /// Events that delete `count` characters before the caret and type `text`.
    static func replacementEvents(deleting count: Int, typing text: String) -> [CGEvent] {
        var evs: [CGEvent] = []
        for _ in 0..<count { evs += keyEvents(CGKeyCode(kVK_Delete)) }
        evs += textEvents(text)
        return evs
    }

    /// Inserts events right after the event being processed by the tap, so
    /// they keep their place among keys the user is still typing.
    static func post(_ events: [CGEvent], proxy: CGEventTapProxy) {
        for e in events { e.tapPostEvent(proxy) }
    }

    /// Posts events from outside the tap callback.
    static func post(_ events: [CGEvent]) {
        for e in events { e.post(tap: .cgSessionEventTap) }
    }

    static func replace(deleting count: Int, typing text: String) {
        post(replacementEvents(deleting: count, typing: text))
    }

    static func shortcut(_ code: Int, flags: CGEventFlags) {
        post(keyEvents(CGKeyCode(code), flags: flags))
    }

    static func type(_ text: String) {
        post(textEvents(text))
    }
}

/// Reads and replaces selected text through Accessibility, with a clipboard
/// fallback for applications that do not expose their text.
@MainActor
enum Selection {
    private static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }()

    static func focusedElement() -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    enum Read {
        case text(String)
        case empty
        case unsupported
    }

    static func selectedText(_ el: AXUIElement?) -> Read {
        guard let el else { return .unsupported }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &v) == .success else { return .unsupported }
        guard let s = v as? String else { return .unsupported }
        return s.isEmpty ? .empty : .text(s)
    }

    static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return r
    }

    static func setSelectedRange(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    static func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Replaces the selection through AX and selects the new text. False when
    /// the application ignored the request.
    static func replaceSelectionAX(_ el: AXUIElement, old: String, new: String) -> Bool {
        let range = selectedRange(el)
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, new as CFString) == .success else { return false }
        if case .text(let now) = selectedText(el), now == old, old != new { return false }
        if let range {
            _ = setSelectedRange(el, CFRange(location: range.location, length: (new as NSString).length))
        }
        return true
    }

    // MARK: clipboard fallback

    private struct SavedPasteboard {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func savePasteboard() -> SavedPasteboard {
        let pb = NSPasteboard.general
        let items = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        return SavedPasteboard(items: items)
    }

    private static func restore(_ saved: SavedPasteboard) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = saved.items.map { dict -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, data) in dict { it.setData(data, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Copies the selection with Cmd+C. Returns nil when nothing was copied.
    /// The previous clipboard is restored before returning.
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = savePasteboard()
        let before = pb.changeCount
        Typist.shortcut(kVK_ANSI_C, flags: .maskCommand)
        var copied: String?
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 15_000_000)
            if pb.changeCount != before {
                copied = pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before { restore(saved) }
        return (copied?.isEmpty ?? true) ? nil : copied
    }

    /// Pastes text in place of the selection, then restores the clipboard.
    static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = savePasteboard()
        pb.clearContents()
        pb.setString(text, forType: .string)
        Typist.shortcut(kVK_ANSI_V, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 350_000_000)
        restore(saved)
    }
}
