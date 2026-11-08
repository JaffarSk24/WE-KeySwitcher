import AppKit
import Carbon
import KeySwitcherCore

/// One key press remembered since the last caret move.
struct TypedItem {
    var stroke: KeyStroke
    var text: String
    var isWord: Bool
    var layout: LayoutKind
}

enum LastAction {
    case none
    /// Automatic switch of the word that starts at `start`; `original` is the
    /// text as it was typed.
    case autoSwitch(original: String, start: Int)
    /// Manual conversion of the last `count` words into `target`.
    case convert(count: Int, target: LayoutKind)
    case caseChange
}

/// Watches the keyboard through a CGEventTap: tracks the words being typed,
/// switches them automatically and handles the single-Option gestures.
@MainActor
final class KeyboardMonitor {
    let layouts: LayoutSet
    let classifier: Classifier
    let inputs: InputSources
    private let settings = Settings.shared
    private let learned = LearnedWords.shared

    private(set) var items: [TypedItem] = []
    /// Start of a word that the user converted by hand: no automatic switch for it.
    private var lockedFrom: Int?
    private(set) var lastAction: LastAction = .none
    private var tap: CFMachPort?
    private var frontBundleID: String?
    var onLearned: ((String) -> Void)?
    var onLayoutSwitched: ((LayoutKind) -> Void)?

    // Option gesture state.
    private var gestureActive = false
    private var gestureCancelled = false
    private var gestureShift = false
    private var gestureStart: CFAbsoluteTime = 0

    private static let maxItems = 400
    private static let resetKeys: Set<Int> = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_ForwardDelete,
                                              kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                              kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help]

    init(layouts: LayoutSet, classifier: Classifier, inputs: InputSources) {
        self.layouts = layouts
        self.classifier = classifier
        self.inputs = inputs
        frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontBundleID = app?.bundleIdentifier
                self?.reset()
            }
        }
    }

    var isRunning: Bool { tap != nil }

    /// Creates the event tap. Fails without the Accessibility permission.
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { proxy, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(info).takeUnretainedValue()
            return MainActor.assumeIsolated { monitor.handle(proxy: proxy, type: type, event: event) }
        }, userInfo: me) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func reset() {
        items.removeAll()
        lockedFrom = nil
        lastAction = .none
    }

    private var isEnabledHere: Bool {
        if IsSecureEventInputEnabled() { return false }
        if let id = frontBundleID, settings.excludedApps.contains(id) { return false }
        return true
    }

    // MARK: event handling

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default: break
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            gestureCancelled = true
            reset()
        case .flagsChanged:
            handleFlags(event, proxy: proxy)
        case .keyDown:
            gestureCancelled = true
            if handleKeyDown(event, proxy: proxy) { return nil }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Returns true when the event was replaced and must be dropped.
    private func handleKeyDown(_ event: CGEvent, proxy: CGEventTapProxy) -> Bool {
        lastAction = .none
        guard isEnabledHere else { reset(); return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            reset()
            return false
        }
        if code == kVK_Delete {
            if !items.isEmpty { items.removeLast() }
            if let l = lockedFrom, l >= items.count { lockedFrom = nil }
            return false
        }
        if Self.resetKeys.contains(code) { reset(); return false }
        let keyCode = UInt16(code)
        guard code == kVK_Space || KeyboardLayout.typingKeyCodes.contains(keyCode) else { reset(); return false }

        let stroke = KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift), capsLock: flags.contains(.maskAlphaShift))
        // A layout that plays no role (for example a third Latin one): stay out.
        guard let layout = inputs.current else { reset(); return false }
        // The text is computed from the key and the layout, the way the
        // application does it; the string carried by the event can lag behind
        // the modifier state.
        var text = layouts[layout].character(for: stroke)
        if text.isEmpty && code == kVK_Space { text = " " }

        if code == kVK_Space || !layouts.isWordStroke(stroke) {
            return finishWord(separator: stroke, separatorText: text, layout: layout, proxy: proxy)
        }
        items.append(TypedItem(stroke: stroke, text: text, isWord: true, layout: layout))
        if items.count > Self.maxItems {
            let drop = items.count - Self.maxItems / 2
            items.removeFirst(drop)
            if let l = lockedFrom { lockedFrom = l >= drop ? l - drop : nil }
        }
        return false
    }

    /// Trailing run of word keys (the word being typed).
    private func currentWordRange() -> Range<Int>? {
        var start = items.count
        while start > 0, items[start - 1].isWord { start -= 1 }
        return start < items.count ? start..<items.count : nil
    }

    /// All runs of word keys.
    private func wordRanges() -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < items.count {
            if items[i].isWord {
                var j = i
                while j < items.count, items[j].isWord { j += 1 }
                out.append(i..<j)
                i = j
            } else { i += 1 }
        }
        return out
    }

    /// Called on a separator key. Decides about the finished word and, if it has
    /// to change, replaces word and separator. Returns true when the separator
    /// event must be dropped (it was re-typed by us).
    private func finishWord(separator: KeyStroke, separatorText: String, layout: LayoutKind, proxy: CGEventTapProxy) -> Bool {
        defer { lockedFrom = nil }
        guard let range = currentWordRange() else {
            items.append(TypedItem(stroke: separator, text: separatorText, isWord: false, layout: layout))
            return false
        }
        let locked = lockedFrom.map { range.lowerBound >= $0 } ?? false
        let word = Array(items[range])
        let wordLayout = word[0].layout
        let sameLayout = word.allSatisfy { $0.layout == wordLayout }
        let typed = sameLayout ? layouts[wordLayout].translate(word.map(\.stroke)) : word.map(\.text).joined()
        let typedCount = word.map(\.text).joined().count
        var newText: String?
        var target: LayoutKind?

        if !locked && sameLayout && settings.autoSwitch {
            let d = classifier.decide(strokes: word.map(\.stroke), typed: typed, current: wordLayout,
                                      latin: latinTarget, remembered: learned.matchSet)
            if case .switchTo(let k) = d.action {
                target = k
                newText = d.convertedText
            }
        }
        var fixedCase = false
        if !locked && settings.fixTwoCapitals, let f = TextTools.fixTwoCapitals(newText ?? typed) {
            newText = f
            fixedCase = true
        }
        DebugLog.write("word '\(typed)' \(wordLayout.rawValue) strokes \(word.map { "\($0.stroke.keyCode)\($0.stroke.shift ? "S" : "")" }) -> '\(newText ?? "-")'")
        guard let replacement = newText, replacement != typed else {
            items.append(TypedItem(stroke: separator, text: separatorText, isWord: false, layout: layout))
            return false
        }
        var sepOut = separatorText
        if let target {
            let s = layouts[target].character(for: separator)
            if !s.isEmpty { sepOut = s }
        }
        Typist.post(Typist.replacementEvents(deleting: typedCount, typing: replacement + sepOut), proxy: proxy)

        // Keep the history in step with what is on screen now.
        let newLayout = target ?? wordLayout
        for i in range {
            items[i].layout = newLayout
            if target != nil { items[i].text = layouts[newLayout].character(for: items[i].stroke) }
        }
        if fixedCase, range.count > 1 {
            let i = range.lowerBound + 1
            items[i].text = items[i].text.lowercased()
            items[i].stroke.shift = false
            items[i].stroke.capsLock = false
        }
        items.append(TypedItem(stroke: separator, text: sepOut, isWord: false, layout: newLayout))
        if let target {
            switchLayout(to: target)
            lastAction = .autoSwitch(original: TextTools.trimNonLetters(typed), start: range.lowerBound)
            if settings.sound { Sound.play() }
        }
        return true
    }

    /// The Latin layout used last, if it is still available.
    private var latinTarget: LayoutKind {
        let l = settings.lastLatin
        return layouts.has(l) ? l : .us
    }

    private func switchLayout(to kind: LayoutKind) {
        inputs.select(kind)
        if kind.isLatin { settings.lastLatin = kind }
        onLayoutSwitched?(kind)
    }

    // MARK: Option gestures

    private func handleFlags(_ event: CGEvent, proxy: CGEventTapProxy) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let f = event.flags
        let option = f.contains(.maskAlternate)
        let shift = f.contains(.maskShift)
        let others = !f.intersection([.maskCommand, .maskControl, .maskSecondaryFn]).isEmpty
        let isOptionKey = code == kVK_Option || code == kVK_RightOption

        if !gestureActive {
            if isOptionKey && option && !others {
                gestureActive = true
                gestureCancelled = !isEnabledHere
                gestureShift = shift
                gestureStart = CFAbsoluteTimeGetCurrent()
            }
            return
        }
        if others { gestureCancelled = true }
        if shift { gestureShift = true }
        if !option && !shift && !others {
            gestureActive = false
            let quick = CFAbsoluteTimeGetCurrent() - gestureStart < 0.6
            guard !gestureCancelled, quick, NSEvent.pressedMouseButtons == 0, !Self.isMenuOpen() else { return }
            if gestureShift { changeCase(proxy: proxy) } else { convertLast(proxy: proxy) }
        }
    }

    /// True while any menu (context menu, menu bar menu, pop-up) is on screen.
    static func isMenuOpen() -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    /// Single Option: converts the last word; repeated presses take one more
    /// word each time. Without typed history works on the selection or on the
    /// word before the caret.
    private func convertLast(proxy: CGEventTapProxy) {
        let previous = lastAction
        var count = 1
        var target: LayoutKind?
        if case .convert(let n, let t) = previous { count = n + 1; target = t }
        let words = wordRanges()
        guard !words.isEmpty else {
            if count == 1 { Task { await self.transformSelection(caseOnly: false) } }
            return
        }
        guard count <= words.count else { return }
        let start = words[words.count - count].lowerBound
        let region = start..<items.count
        if target == nil {
            let lastWordLayout = items[words.last!.lowerBound].layout
            target = lastWordLayout == .ru ? latinTarget : .ru
        }
        let t = target!
        let oldText = items[region].map(\.text).joined()
        var newTexts: [String] = []
        for i in region {
            let r = layouts[t].character(for: items[i].stroke)
            newTexts.append(items[i].isWord || !r.isEmpty ? r : items[i].text)
        }
        Typist.post(Typist.replacementEvents(deleting: oldText.count, typing: newTexts.joined()), proxy: proxy)
        for (k, i) in region.enumerated() {
            items[i].text = newTexts[k]
            items[i].layout = t
        }
        if let cw = currentWordRange() { lockedFrom = cw.lowerBound }
        switchLayout(to: t)
        if case .autoSwitch(let original, _) = previous, count == 1, settings.learnFromUndo {
            if learned.registerUndo(of: original) { onLearned?(original) }
        }
        lastAction = .convert(count: count, target: t)
    }

    /// Option+Shift: inverts the case of the last word or of the selection.
    private func changeCase(proxy: CGEventTapProxy) {
        let words = wordRanges()
        guard let last = words.last else {
            Task { await self.transformSelection(caseOnly: true) }
            return
        }
        let region = last.lowerBound..<items.count
        let oldText = items[region].map(\.text).joined()
        var newText = ""
        for i in region where items[i].isWord {
            let inv = TextTools.invertCase(items[i].text)
            if inv != items[i].text, let ch = inv.first, ch.isLetter {
                items[i].stroke.shift = ch.isUppercase
                items[i].stroke.capsLock = false
            }
            items[i].text = inv
        }
        newText = items[region].map(\.text).joined()
        DebugLog.write("case '\(oldText)' -> '\(newText)'")
        guard newText != oldText else { return }
        Typist.post(Typist.replacementEvents(deleting: oldText.count, typing: newText), proxy: proxy)
        if let cw = currentWordRange() { lockedFrom = cw.lowerBound }
        lastAction = .caseChange
    }

    // MARK: selection

    private func convert(_ text: String, caseOnly: Bool) -> (String, LayoutKind?) {
        if caseOnly { return (TextTools.invertCase(text), nil) }
        let (src, dst) = TextTools.direction(of: text, lastLatin: latinTarget, available: Set(layouts.layouts.keys))
        return (layouts.convert(text, from: src, to: dst), dst)
    }

    private func transformSelection(caseOnly: Bool) async {
        let el = Selection.focusedElement()
        var target: LayoutKind?
        switch Selection.selectedText(el) {
        case .text(let s):
            let (n, t) = convert(s, caseOnly: caseOnly)
            target = t
            if n != s, !Selection.replaceSelectionAX(el!, old: s, new: n) {
                await Selection.paste(n)
            }
        case .empty:
            target = await transformWordBeforeCaret(el!, caseOnly: caseOnly)
        case .unsupported:
            if let s = await Selection.copySelection() {
                let (n, t) = convert(s, caseOnly: caseOnly)
                target = t
                if n != s { await Selection.paste(n) }
            } else {
                // Select the previous word with Option+Shift+Left and try again.
                Typist.shortcut(kVK_LeftArrow, flags: [.maskAlternate, .maskShift])
                try? await Task.sleep(nanoseconds: 40_000_000)
                if let s = await Selection.copySelection() {
                    let (n, t) = convert(s, caseOnly: caseOnly)
                    target = t
                    if n != s { await Selection.paste(n) } else { Typist.shortcut(kVK_RightArrow, flags: []) }
                } else {
                    Typist.shortcut(kVK_RightArrow, flags: [])
                }
            }
        }
        if let target { switchLayout(to: target) }
        reset()
    }

    /// No selection: takes the word right before the caret through AX.
    private func transformWordBeforeCaret(_ el: AXUIElement, caseOnly: Bool) async -> LayoutKind? {
        guard let value = Selection.value(el), let caret = Selection.selectedRange(el) else { return nil }
        let ns = value as NSString
        var end = min(caret.location, ns.length)
        let ws = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool {
            guard let u = UnicodeScalar(ns.character(at: i)) else { return false }
            return ws.contains(u)
        }
        while end > 0, isSpace(end - 1), ns.character(at: end - 1) != 10 { end -= 1 }
        var start = end
        while start > 0, !isSpace(start - 1) { start -= 1 }
        guard start < end else { return nil }
        let word = ns.substring(with: NSRange(location: start, length: end - start))
        let (n, t) = convert(word, caseOnly: caseOnly)
        guard n != word else { return t }
        guard Selection.setSelectedRange(el, CFRange(location: start, length: end - start)) else { return nil }
        if !Selection.replaceSelectionAX(el, old: word, new: n) {
            await Selection.paste(n)
        }
        let newCaret = caret.location + (n as NSString).length - (word as NSString).length
        _ = Selection.setSelectedRange(el, CFRange(location: newCaret, length: 0))
        return t
    }
}

enum Sound {
    @MainActor private static let sound: NSSound? = {
        let s = NSSound(named: "Tink")
        s?.volume = 0.25
        return s
    }()

    @MainActor static func play() {
        sound?.stop()
        sound?.play()
    }
}
