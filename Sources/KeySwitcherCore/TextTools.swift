import Foundation

public enum TextTools {
    static let tlds: Set<String> = ["com", "net", "org", "ru", "sk", "cz", "io", "ua", "info", "app", "dev", "me",
                                    "eu", "de", "uk", "us", "online", "ai", "co", "by", "kz", "pl", "at", "py", "js",
                                    "md", "txt", "json", "html", "php", "pdf", "png", "jpg", "swift", "sh"]

    public static func trimNonLetters(_ s: String) -> String {
        guard let first = s.firstIndex(where: \.isLetter), let last = s.lastIndex(where: \.isLetter) else { return "" }
        return String(s[first...last])
    }

    /// Letters with optional single inner hyphens or apostrophes.
    public static func isPlainWord(_ s: String) -> Bool {
        guard let f = s.first, let l = s.last, f.isLetter, l.isLetter else { return false }
        var prevJoin = false
        for ch in s {
            if ch.isLetter { prevJoin = false; continue }
            if ch == "-" || ch == "'" || ch == "’" {
                if prevJoin { return false }
                prevJoin = true
                continue
            }
            return false
        }
        return true
    }

    /// Single letters with full stops between them: "s.r.o", "e.g", "U.S.A".
    public static func isDottedAbbreviation(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { $0.count == 1 && $0.first!.isLetter }
    }

    public static func isCamelCase(_ s: String) -> Bool {
        var prevLower = false
        for ch in s {
            if ch.isUppercase && prevLower { return true }
            prevLower = ch.isLowercase
        }
        return false
    }

    public static func isAllCaps(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    public static func hasDomainSuffix(_ s: String) -> Bool {
        let parts = s.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let last = parts.last, !parts[parts.count - 2].isEmpty else { return false }
        return tlds.contains(String(last))
    }

    /// пРИВЕТ -> Привет: swaps the case of every letter.
    public static func invertCase(_ s: String) -> String {
        String(s.map { ch -> String in
            if ch.isUppercase { return ch.lowercased() }
            if ch.isLowercase { return ch.uppercased() }
            return String(ch)
        }.joined())
    }

    /// ПРивет -> Привет. Returns nil when the word does not have that shape.
    public static func fixTwoCapitals(_ s: String) -> String? {
        let chars = Array(s)
        guard chars.count >= 4, chars[0].isLetter, chars[1].isLetter,
              chars[0].isUppercase, chars[1].isUppercase else { return nil }
        let rest = chars[2...]
        guard rest.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return nil }
        return String(chars[0]) + String(chars[1]).lowercased() + String(rest)
    }

    public static func isCyrillic(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }

    public static func isLatinLetter(_ ch: Character) -> Bool {
        ch.isLetter && ch.unicodeScalars.allSatisfy { $0.value < 0x0250 }
    }

    static let slovakOnly: Set<Character> = Set("áäčďéíĺľňóôŕšťúýžÁÄČĎÉÍĹĽŇÓÔŔŠŤÚÝŽ§")

    /// Decides direction for converting an arbitrary piece of text.
    /// Returns (source, target).
    public static func direction(of text: String, lastLatin: LayoutKind, available: Set<LayoutKind> = Set(LayoutKind.allCases)) -> (LayoutKind, LayoutKind) {
        let latin: LayoutKind = lastLatin.isLatin && available.contains(lastLatin) ? lastLatin : .us
        let cyr = text.filter(isCyrillic).count
        let lat = text.filter(isLatinLetter).count
        if cyr > lat { return (.ru, latin) }
        if available.contains(.sk), text.contains(where: { slovakOnly.contains($0) }) { return (.sk, .ru) }
        return (latin, .ru)
    }
}

public enum Versions {
    /// Compares dotted version numbers: "1.10.0" is newer than "1.9.2".
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
