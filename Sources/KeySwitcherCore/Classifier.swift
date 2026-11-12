import Foundation

public struct ClassifierConfig: Sendable {
    /// Prior share of each language in what the user types.
    public var prior: [Language: Double] = [.ru: 0.5, .en: 0.3, .sk: 0.2]
    /// Probability mass given to words missing from a dictionary.
    public var oovMass: Double = 0.03
    /// Required advantage (log10) of the other layout before switching.
    public var margin: Double = 1.0
    /// Extra advantage required when neither form is a dictionary word.
    public var marginBothUnknown: Double = 1.5
    /// ...and when the typed form has no improbable letter transition.
    public var marginPlausible: Double = 3.0
    /// Advantage required when both forms are dictionary words.
    public var marginBothKnown: Double = 2.0
    public var marginBothKnownRare: Double = 1.5
    /// Words rarer than this (per million) are weak evidence for switching.
    public var rarePerMillion: Double = 0.2
    public var marginRareOther: Double = 2.5
    public var marginNgramToLatin: Double = 4.0
    /// Switching while a word is still being typed: earliest letter...
    public var prefixMinLetters: Int = 3
    /// ...required advantage (log10) of the other reading of the prefix...
    public var prefixMargin: Double = 5.0
    /// ...plus this when leaving Cyrillic...
    public var prefixMarginToLatinExtra: Double = 1.0
    /// ...and the typed prefix must contain a transition at least this improbable.
    public var prefixImplausibleStep: Double = -2.5
    /// With such a key inside (see `decidePrefix`) the other reading must have
    /// no transition less probable than this.
    public var prefixInnerPlausibleStep: Double = -2.5
    /// A one- or two-letter word right before a word that switched follows it
    /// when, in the new language, it is at least this common (per million)...
    public var contextMinPerMillion: Double = 100
    /// ...and this many times more common than the form it was typed in.
    public var contextRatio: Double = 5
    /// Advantage required for two-letter words.
    public var marginShort: Double = 2.3
    /// A typed word this common (per million words) is never switched.
    public var keepIfPerMillion: Double = 1.0
    public var keepIfPerMillionShort: Double = 5.0
    /// ...unless the other form is this much (log10) more likely.
    public var hugeMargin: Double = 2.3
    /// Minimal number of letters for automatic switching.
    public var minLetters: Int = 2
    /// When neither form is in a dictionary, the typed form must contain a
    /// letter transition at least this improbable (log10).
    public var implausibleStep: Double = -3.0

    public init() {}
}

public struct Decision: Sendable, CustomStringConvertible {
    public enum Action: Sendable, Equatable {
        case keep
        case switchTo(LayoutKind)
    }
    public var action: Action
    /// Text the word becomes in the other layout (whole word, punctuation included).
    public var convertedText: String
    public var reason: String
    public var scoreTyped: Double = 0
    public var scoreOther: Double = 0

    public var description: String {
        switch action {
        case .keep: return "keep (\(reason)) \(String(format: "%.2f/%.2f", scoreTyped, scoreOther))"
        case .switchTo(let k): return "switch->\(k.rawValue) '\(convertedText)' (\(reason)) \(String(format: "%.2f/%.2f", scoreTyped, scoreOther))"
        }
    }
}

public final class Classifier: @unchecked Sendable {
    public let layouts: LayoutSet
    public let models: Models
    public var config: ClassifierConfig

    public init(layouts: LayoutSet, models: Models, config: ClassifierConfig = ClassifierConfig()) {
        self.layouts = layouts
        self.models = models
        self.config = config
    }

    struct Score {
        var value: Double
        var known: Bool
        var perMillion: Double
        var worstStep: Double
    }

    /// Best language score of a word among the languages of its script.
    func score(_ word: String, latin: Bool) -> Score {
        var best = Score(value: -Double.infinity, known: false, perMillion: 0, worstStep: -Double.infinity)
        for m in models.models(latin: latin) {
            let w = m.normalize(word)
            let prior = log10(config.prior[m.language] ?? 0.1)
            let c = m.dictionary.count(w)
            let bare = w.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "'", with: "")
            let ws = m.ngrams.worstStep(bare)
            if c > 0 {
                let pm = Double(c) * 1_000_000 / Double(m.dictionary.total)
                let v = prior + log10(Double(c) / Double(m.dictionary.total))
                if !best.known || v > best.value {
                    best = Score(value: v, known: true, perMillion: max(pm, best.perMillion), worstStep: max(ws, best.worstStep))
                }
            } else if !best.known {
                let v = prior + log10(config.oovMass) + m.ngrams.logProb(bare)
                if v > best.value { best.value = v }
                best.worstStep = max(best.worstStep, ws)
            } else {
                best.worstStep = max(best.worstStep, ws)
            }
        }
        return best
    }

    static let innerKeys: Set<Character> = [",", ";", "[", "]"]
    static let sentencePunctuation: Set<Character> = Set(".,;:!?\"'»)…”’")

    /// Leading strokes that are not letters in either layout are dropped;
    /// trailing sentence punctuation is dropped per rendering.
    static func cores(_ t: [String], _ o: [String]) -> (String, String) {
        var start = 0
        while start < t.count, !t[start].contains(where: \.isLetter), !o[start].contains(where: \.isLetter) {
            start += 1
        }
        func trimTail(_ a: ArraySlice<String>) -> String {
            var end = a.endIndex
            while end > a.startIndex {
                let c = a[end - 1]
                if c.isEmpty || (c.count == 1 && sentencePunctuation.contains(c.first!)) { end -= 1 } else { break }
            }
            return a[a.startIndex..<end].joined()
        }
        return (trimTail(t[start...]), trimTail(o[start...]))
    }

    /// Decides whether a word just finished in layout `current` was meant for
    /// the other script. `typed` is the text the application received.
    public func decide(strokes: [KeyStroke], typed: String, current: LayoutKind, latin: LayoutKind,
                       remembered: Set<String> = []) -> Decision {
        let alt: LayoutKind = current == .ru ? (latin.isLatin && layouts.has(latin) ? latin : .us) : .ru
        let other = layouts[alt].translate(strokes)
        var d = Decision(action: .keep, convertedText: other, reason: "")
        func keep(_ r: String) -> Decision { d.reason = r; return d }

        let tChars = strokes.map { layouts[current].character(for: $0) }
        let oChars = strokes.map { layouts[alt].character(for: $0) }
        let (coreTyped, coreOther) = Self.cores(tChars, oChars)
        let letters = max(coreTyped.filter(\.isLetter).count, coreOther.filter(\.isLetter).count)

        if remembered.contains(typed.lowercased()) || remembered.contains(TextTools.trimNonLetters(typed).lowercased()) {
            return keep("remembered")
        }
        if letters < config.minLetters || coreOther.isEmpty { return keep("short") }
        if other.contains(where: \.isNumber) { return keep("digits") }
        if !TextTools.isPlainWord(coreOther) { return keep("other not a word") }
        if current.isLatin {
            if typed.contains(where: \.isNumber) { return keep("digits") }
            if typed.contains("/") || typed.contains("@") || typed.contains("\\") && typed.contains(".") { return keep("path or mail") }
            if typed.lowercased().hasPrefix("www.") || TextTools.hasDomainSuffix(TextTools.trimNonLetters(typed)) { return keep("domain") }
            if TextTools.isCamelCase(coreTyped) { return keep("camelCase") }
        }

        let sT = score(coreTyped, latin: current.isLatin)
        let sO = score(coreOther, latin: alt.isLatin)
        d.scoreTyped = sT.value
        d.scoreOther = sO.value
        let typedWordLike = TextTools.isPlainWord(coreTyped)
        let delta = sO.value - sT.value

        if current.isLatin && TextTools.isAllCaps(coreTyped) && coreTyped.count >= 2 {
            // Latin abbreviations stay; only long all-caps words that are clearly
            // Russian typed with Caps Lock get converted.
            if !(coreTyped.count >= 5 && sO.known && !sT.known && sO.perMillion >= 1) {
                return keep("latin caps")
            }
        }
        let keepPM = letters <= 2 ? config.keepIfPerMillionShort : config.keepIfPerMillion
        // Latin letters with full stops between them ("s.r.o", "e.g", "U.S.A")
        // are abbreviations; the same keys are ю in Russian, so only a real
        // Russian word ("c.lf" is "сюда") may take them over.
        if current.isLatin && TextTools.isDottedAbbreviation(coreTyped) && !(sO.known && sO.perMillion >= config.keepIfPerMillion) {
            return keep("dotted abbreviation")
        }
        if typedWordLike && sT.known && sT.perMillion >= keepPM && delta < config.hugeMargin {
            return keep("typed is common")
        }
        var need = config.margin
        if letters <= 2 { need = config.marginShort }
        if typedWordLike && !sT.known && !sO.known {
            need = max(need, config.marginBothUnknown)
            if sT.worstStep > config.implausibleStep { need = max(need, config.marginPlausible) }
        }
        if typedWordLike && sT.known && sO.known {
            // A rare typed word (slang, an abbreviation) is weaker evidence.
            need = max(need, sT.perMillion >= config.keepIfPerMillion ? config.marginBothKnown : config.marginBothKnownRare)
        }
        // Most text is Russian: leaving Cyrillic needs a dictionary word on the
        // Latin side or very strong n-gram evidence.
        if current == .ru && !sO.known { need = max(need, config.marginNgramToLatin) }
        if sO.known && sO.perMillion < config.rarePerMillion { need = max(need, config.marginRareOther) }
        if typedWordLike && !sO.known && sT.known { return keep("only typed known") }
        if delta > need {
            d.action = .switchTo(alt)
            d.reason = sO.known ? "other known" : "ngram"
            return d
        }
        return keep("margin")
    }

    /// A short word (one or two letters) that stayed as typed right before a
    /// word which was then switched to `target`: "PROD d ,kb;fqibt" ends with
    /// "ближайшие", so the lone "d" is the preposition "в". Short words are too
    /// ambiguous on their own, but the next word tells which language this is.
    /// Returns the converted word, or nil when it should stay.
    public func followsSwitch(strokes: [KeyStroke], typed: String, current: LayoutKind, target: LayoutKind,
                              remembered: Set<String> = []) -> String? {
        guard current != target, layouts.has(target), current.isLatin != target.isLatin else { return nil }
        let other = layouts[target].translate(strokes)
        let (coreTyped, coreOther) = Self.cores(strokes.map { layouts[current].character(for: $0) },
                                                strokes.map { layouts[target].character(for: $0) })
        let letters = max(coreTyped.filter(\.isLetter).count, coreOther.filter(\.isLetter).count)
        guard (1...2).contains(letters) else { return nil }
        if remembered.contains(typed.lowercased()) || remembered.contains(TextTools.trimNonLetters(typed).lowercased()) { return nil }
        if other.contains(where: \.isNumber) || (current.isLatin && typed.contains(where: \.isNumber)) { return nil }
        guard TextTools.isPlainWord(coreOther) else { return nil }
        let sO = score(coreOther, latin: target.isLatin)
        guard sO.known, sO.perMillion >= config.contextMinPerMillion else { return nil }
        let sT = score(coreTyped, latin: current.isLatin)
        if TextTools.isPlainWord(coreTyped) && sT.known && sO.perMillion < sT.perMillion * config.contextRatio { return nil }
        return other
    }

    /// Decision for a word that is still being typed: returns the layout to
    /// switch to only when the letters typed so far are clearly the other
    /// language. Prefixes are rarely dictionary words, so only the n-gram
    /// models are compared, with a much larger margin than for whole words,
    /// and only on plain letters. Everything else waits for the end of the word.
    public func decidePrefix(strokes: [KeyStroke], current: LayoutKind, latin: LayoutKind,
                             remembered: Set<String> = []) -> LayoutKind? {
        guard strokes.count >= config.prefixMinLetters else { return nil }
        let alt: LayoutKind = current == .ru ? (latin.isLatin && layouts.has(latin) ? latin : .us) : .ru
        let typed = layouts[current].translate(strokes)
        let other = layouts[alt].translate(strokes)
        guard typed.count == strokes.count, other.count == strokes.count, other.allSatisfy(\.isLetter) else { return nil }
        // Inside an English word a comma, a semicolon or a bracket is never
        // followed by a letter, while in the Russian layout these keys are
        // б, ж, х and ъ. Such a key in the middle of the prefix is strong
        // evidence; the full stop and the apostrophe are not (e.g., don't).
        let chars = Array(typed)
        var inner = 0
        for (i, ch) in chars.enumerated() where !ch.isLetter {
            // Not the last key (it may be sentence punctuation), and at the very
            // start only the comma and the semicolon (б, ж): "[" opens links.
            guard current.isLatin, Self.innerKeys.contains(ch), i < chars.count - 1,
                  i > 0 || ch == "," || ch == ";" else { return nil }
            inner += 1
        }
        guard chars.contains(where: \.isLetter) else { return nil }
        if current.isLatin && (TextTools.isAllCaps(typed) || TextTools.isCamelCase(typed)) { return nil }
        // A remembered word may start like this: wait for the whole word.
        let low = typed.lowercased()
        if remembered.contains(where: { $0.hasPrefix(low) }) { return nil }
        // The typed letters already form a common word: it may end right here.
        let sTw = score(typed, latin: current.isLatin)
        if sTw.known && sTw.perMillion >= config.keepIfPerMillion { return nil }

        func prefixScore(_ text: String, latin: Bool) -> (Double, Double) {
            var best = -Double.infinity, worst = -Double.infinity
            for m in models.models(latin: latin) {
                let w = m.normalize(text)
                best = max(best, log10(config.prior[m.language] ?? 0.1) + m.ngrams.logProb(w, end: false))
                worst = max(worst, m.ngrams.worstStep(w, end: false))
            }
            return (best, worst)
        }
        let (sO, worstO) = prefixScore(other, latin: alt.isLatin)
        if inner > 0 {
            return strokes.count >= config.prefixMinLetters + 1 && worstO > config.prefixInnerPlausibleStep ? alt : nil
        }
        let (sT, worstT) = prefixScore(typed, latin: current.isLatin)
        let need = config.prefixMargin + (current == .ru ? config.prefixMarginToLatinExtra : 0)
        return sO - sT > need && worstT < config.prefixImplausibleStep ? alt : nil
    }
}
