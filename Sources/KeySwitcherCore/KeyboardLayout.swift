import Carbon
import Foundation

/// One physical key press: which key and which modifiers changed its character.
public struct KeyStroke: Hashable, Sendable {
    public var keyCode: UInt16
    public var shift: Bool
    public var capsLock: Bool

    public init(keyCode: UInt16, shift: Bool = false, capsLock: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.capsLock = capsLock
    }

    var modifierState: UInt32 {
        // UCKeyTranslate wants (EventRecord.modifiers >> 8) & 0xFF.
        var m: UInt32 = 0
        if shift { m |= UInt32(shiftKey >> 8) }
        if capsLock { m |= UInt32(alphaLock >> 8) }
        return m
    }
}

/// Roles of the layouts the app works with: one Cyrillic layout and up to two
/// Latin ones. Which installed input source plays each role is resolved at
/// start from the enabled keyboard layouts (see `LayoutKind.resolve`).
public enum LayoutKind: String, CaseIterable, Sendable, Codable {
    /// The Russian layout (Apple Russian or Russian - PC).
    case ru
    /// The main Latin layout (U.S., ABC, British and the like).
    case us
    /// The second Latin layout, Slovak by default.
    case sk

    public var isLatin: Bool { self != .ru }

    static let candidates: [LayoutKind: [String]] = [
        .ru: ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin", "com.apple.keylayout.Russian-Phonetic"],
        .us: ["com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.British",
              "com.apple.keylayout.British-PC", "com.apple.keylayout.USInternational-PC", "com.apple.keylayout.Australian",
              "com.apple.keylayout.Canadian", "com.apple.keylayout.Irish", "com.apple.keylayout.Colemak",
              "com.apple.keylayout.Dvorak", "com.apple.keylayout.ABC-QWERTZ", "com.apple.keylayout.ABC-AZERTY"],
        .sk: ["com.apple.keylayout.Slovak-QWERTY", "com.apple.keylayout.Slovak", "com.apple.keylayout.Czech-QWERTY",
              "com.apple.keylayout.Czech", "com.apple.keylayout.German", "com.apple.keylayout.Polish",
              "com.apple.keylayout.PolishPro"],
    ]

    nonisolated(unsafe) private static var resolved: [LayoutKind: String] = [
        .ru: "com.apple.keylayout.Russian", .us: "com.apple.keylayout.US", .sk: "com.apple.keylayout.Slovak-QWERTY",
    ]

    /// Picks an input source for every role among `enabledIDs` (in the order of
    /// preference above). A role without a matching layout stays unassigned.
    /// If only a "second" Latin layout is enabled, it takes the main role.
    public static func resolve(enabledIDs: [String]) {
        var r: [LayoutKind: String] = [:]
        for k in allCases {
            if let id = candidates[k]!.first(where: { enabledIDs.contains($0) }) { r[k] = id }
        }
        if r[.us] == nil, let sk = r[.sk] {
            r[.us] = sk
            r[.sk] = nil
        }
        resolved = r
    }

    public static var available: [LayoutKind] { allCases.filter { resolved[$0] != nil } }

    public var inputSourceID: String? { Self.resolved[self] }

    public var shortName: String {
        guard let id = inputSourceID else { return rawValue.uppercased() }
        if self == .ru { return "RU" }
        if id.contains("Slovak") { return "SK" }
        if id.contains("Czech") { return "CZ" }
        if id.contains("German") { return "DE" }
        if id.contains("Polish") { return "PL" }
        return "EN"
    }

    public init?(inputSourceID: String) {
        guard let k = LayoutKind.allCases.first(where: { $0.inputSourceID == inputSourceID }) else { return nil }
        self = k
    }
}

/// A keyboard layout read from the system (`uchr` data), able to turn key strokes
/// into text and text back into key strokes.
public final class KeyboardLayout: @unchecked Sendable {
    public let kind: LayoutKind
    private let data: Data
    private let keyboardType: UInt32
    /// Character -> key stroke that produces it (first match, unshifted preferred).
    private(set) var reverse: [Character: KeyStroke] = [:]
    /// Characters reachable only through a dead key: dead stroke + base stroke.
    private(set) var reverseDead: [Character: [KeyStroke]] = [:]
    /// Key codes that produce a letter in this layout (with or without shift).
    private(set) var letterKeys: Set<UInt16> = []

    /// Key codes worth scanning: the main alphanumeric block of an Apple keyboard.
    public static let typingKeyCodes: [UInt16] = Array(0...50).filter { ![36, 48, 49].contains($0) }

    public init(kind: LayoutKind, data: Data) {
        self.kind = kind
        self.data = data
        self.keyboardType = UInt32(LMGetKbdType())
        buildTables()
    }

    /// Loads the layout from the installed input sources.
    public static func load(_ kind: LayoutKind) -> KeyboardLayout? {
        guard let id = kind.inputSourceID else { return nil }
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first,
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let cfData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        return KeyboardLayout(kind: kind, data: cfData as Data)
    }

    private func buildTables() {
        for shift in [false, true] {
            for code in Self.typingKeyCodes {
                let ks = KeyStroke(keyCode: code, shift: shift)
                let s = translate([ks])
                guard s.count == 1, let ch = s.first else { continue }
                if reverse[ch] == nil { reverse[ch] = ks }
                if ch.isLetter { letterKeys.insert(code) }
            }
        }
        var deadStrokes: [KeyStroke] = []
        for shift in [false, true] {
            for code in Self.typingKeyCodes {
                let ks = KeyStroke(keyCode: code, shift: shift)
                if translate([ks]).isEmpty { deadStrokes.append(ks) }
            }
        }
        for d in deadStrokes {
            for shift in [false, true] {
                for code in Self.typingKeyCodes {
                    let ks = KeyStroke(keyCode: code, shift: shift)
                    let s = translate([d, ks])
                    guard s.count == 1, let ch = s.first, reverse[ch] == nil, reverseDead[ch] == nil else { continue }
                    reverseDead[ch] = [d, ks]
                }
            }
        }
    }

    /// Text produced by typing the strokes in this layout. Dead keys combine with
    /// the following stroke exactly as the system would do it.
    public func translate(_ strokes: [KeyStroke]) -> String {
        var out = ""
        var deadState: UInt32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var buf = [UniChar](repeating: 0, count: 8)
            for ks in strokes {
                var len = 0
                let status = UCKeyTranslate(layout, ks.keyCode, UInt16(kUCKeyActionDown), ks.modifierState,
                                            keyboardType, 0, &deadState, buf.count, &len, &buf)
                if status == noErr, len > 0 {
                    out += String(utf16CodeUnits: buf, count: len)
                }
            }
        }
        return out
    }

    /// Single stroke rendering without dead-key carry-over.
    public func character(for ks: KeyStroke) -> String { translate([ks]) }

    /// Key strokes for one character, nil when the layout cannot type it.
    public func strokes(for ch: Character) -> [KeyStroke]? {
        if ch == " " { return [KeyStroke(keyCode: 49)] }
        if let ks = reverse[ch] { return [ks] }
        if let seq = reverseDead[ch] { return seq }
        let lowerS = String(ch).lowercased()
        if lowerS != String(ch), lowerS.count == 1, let lower = lowerS.first {
            if var ks = reverse[lower] { ks.shift = true; return [ks] }
            if var seq = reverseDead[lower], seq.count == 2 { seq[1].shift = true; return seq }
        }
        return nil
    }

    /// Key strokes that type the whole text, nil if some character is impossible.
    public func strokes(for text: String) -> [KeyStroke]? {
        var out: [KeyStroke] = []
        for ch in text {
            guard let s = strokes(for: ch) else { return nil }
            out += s
        }
        return out
    }
}

/// The three layouts used together.
public final class LayoutSet: @unchecked Sendable {
    public let layouts: [LayoutKind: KeyboardLayout]

    private var wordStrokes: Set<UInt32> = []

    public init(layouts: [LayoutKind: KeyboardLayout]) {
        self.layouts = layouts
        for code in KeyboardLayout.typingKeyCodes {
            for shift in [false, true] {
                let ks = KeyStroke(keyCode: code, shift: shift)
                if layouts.values.contains(where: { $0.character(for: ks).contains(where: \.isLetter) }) {
                    wordStrokes.insert(UInt32(code) << 1 | (shift ? 1 : 0))
                }
            }
        }
    }

    /// True when this key (with this Shift state) gives a letter in at least one
    /// layout: such a key belongs to the word even if it typed punctuation.
    public func isWordStroke(_ ks: KeyStroke) -> Bool {
        wordStrokes.contains(UInt32(ks.keyCode) << 1 | (ks.shift ? 1 : 0))
    }

    /// IDs of the enabled keyboard layouts.
    public static func enabledLayoutIDs() -> [String] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { s in
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
    }

    /// Loads the layouts that play a role. Needs the Russian layout and at
    /// least one Latin layout. With `resolveFromSystem` the roles are first
    /// taken from the enabled layouts; otherwise the defaults (U.S., Slovak -
    /// QWERTY, Russian) are used, which is what the tests rely on.
    public static func loadSystem(resolveFromSystem: Bool = false) -> LayoutSet? {
        if resolveFromSystem { LayoutKind.resolve(enabledIDs: enabledLayoutIDs()) }
        var d: [LayoutKind: KeyboardLayout] = [:]
        for k in LayoutKind.available {
            if let l = KeyboardLayout.load(k) { d[k] = l }
        }
        guard d[.ru] != nil, d[.us] != nil else { return nil }
        return LayoutSet(layouts: d)
    }

    public func has(_ k: LayoutKind) -> Bool { layouts[k] != nil }

    public subscript(_ k: LayoutKind) -> KeyboardLayout { layouts[k]! }

    /// True when the key produces a letter in at least one of the layouts, so it
    /// can be part of a word typed in the wrong layout.
    public func isWordKey(_ code: UInt16) -> Bool {
        layouts.values.contains { $0.letterKeys.contains(code) }
    }

    /// Converts text typed in `from` into what the same keys give in `to`.
    /// Characters that `from` cannot type are kept as they are.
    public func convert(_ text: String, from: LayoutKind, to: LayoutKind) -> String {
        guard from != to else { return text }
        let src = self[from], dst = self[to]
        var out = ""
        for ch in text {
            if let seq = src.strokes(for: ch) {
                let r = dst.translate(seq)
                out += r.isEmpty ? String(ch) : r
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
