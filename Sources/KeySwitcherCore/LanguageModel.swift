import Foundation

public enum Language: String, CaseIterable, Sendable {
    case ru, en, sk
}

/// 64-bit FNV-1a over UTF-8, identical to tools/prep_data.py.
@inline(__always)
func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x100000001b3
    }
    return h
}

/// Word frequency list stored as sorted 64-bit hashes plus counts.
public final class FrequencyDictionary: @unchecked Sendable {
    private let hashes: [UInt64]
    private let counts: [UInt32]
    public let total: UInt64

    public init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        guard d.count >= 16, d.prefix(4) == Data("WEKD".utf8) else {
            throw NSError(domain: "KeySwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad dictionary \(url.lastPathComponent)"])
        }
        let n = Int(d.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        total = d.subdata(in: 8..<16).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        var hs = [UInt64](repeating: 0, count: n)
        var cs = [UInt32](repeating: 0, count: n)
        d.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for i in 0..<n {
                hs[i] = base.loadUnaligned(fromByteOffset: 16 + i * 8, as: UInt64.self)
                cs[i] = base.loadUnaligned(fromByteOffset: 16 + n * 8 + i * 4, as: UInt32.self)
            }
        }
        hashes = hs
        counts = cs
    }

    public var wordCount: Int { hashes.count }

    /// Count of an already normalized (lower-case) word, 0 when unknown.
    public func count(_ word: String) -> UInt32 {
        let h = fnv1a(word)
        var lo = 0, hi = hashes.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = hashes[mid]
            if v == h { return counts[mid] }
            if v < h { lo = mid + 1 } else { hi = mid - 1 }
        }
        return 0
    }
}

/// Character n-gram model (order 4) with Witten-Bell interpolation, trained on
/// dictionary word types. Gives a probability to any word, including unknown ones.
public final class NgramModel: @unchecked Sendable {
    public static let order = 4
    private var gramCount: [String: Double] = [:]
    private var contextTotal: [String: Double] = [:]
    private var contextTypes: [String: Double] = [:]
    private var vocabularySize: Double = 1

    public init(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let g = String(line[line.startIndex..<tab])
            guard let c = Double(line[line.index(after: tab)...]) else { continue }
            gramCount[g] = c
            let ctx = String(g.dropLast())
            contextTotal[ctx, default: 0] += c
            contextTypes[ctx, default: 0] += 1
        }
        vocabularySize = (contextTypes[""] ?? 1) + 1
    }

    private func prob(_ ch: Character, _ history: Substring) -> Double {
        // Recursive interpolation from the empty context upwards.
        var p = 1.0 / vocabularySize
        let h = Array(history)
        for len in 0...min(h.count, Self.order - 1) {
            let ctx = String(h.suffix(len))
            guard let total = contextTotal[ctx], let types = contextTypes[ctx] else { break }
            let c = gramCount[ctx + String(ch)] ?? 0
            p = (c + types * p) / (total + types)
        }
        return p
    }

    /// log10 P(word) including the end-of-word marker.
    public func logProb(_ word: String) -> Double {
        let padded = String(repeating: "^", count: Self.order - 1) + word + "$"
        let chars = Array(padded)
        var lp = 0.0
        for i in (Self.order - 1)..<chars.count {
            let hist = String(chars[max(0, i - (Self.order - 1))..<i])
            lp += log10(prob(chars[i], Substring(hist)))
        }
        return lp
    }

    /// Lowest single-character log10 probability within the word: catches
    /// letter combinations a language practically never has.
    public func worstStep(_ word: String) -> Double {
        let padded = String(repeating: "^", count: Self.order - 1) + word + "$"
        let chars = Array(padded)
        var worst = 0.0
        for i in (Self.order - 1)..<chars.count {
            let hist = String(chars[max(0, i - (Self.order - 1))..<i])
            worst = min(worst, log10(prob(chars[i], Substring(hist))))
        }
        return worst
    }
}

/// Dictionary plus n-gram model for one language.
public final class LanguageModel: @unchecked Sendable {
    public let language: Language
    public let dictionary: FrequencyDictionary
    public let ngrams: NgramModel

    public init(language: Language, dataDirectory: URL) throws {
        self.language = language
        dictionary = try FrequencyDictionary(url: dataDirectory.appendingPathComponent("\(language.rawValue).dict"))
        ngrams = try NgramModel(url: dataDirectory.appendingPathComponent("\(language.rawValue).ngram"))
    }

    public func normalize(_ w: String) -> String {
        var s = w.lowercased()
        if language == .ru { s = s.replacingOccurrences(of: "ё", with: "е") }
        return s.precomposedStringWithCanonicalMapping
    }

    /// Occurrences per million words, 0 when not in the dictionary.
    public func perMillion(_ word: String) -> Double {
        let c = dictionary.count(normalize(word))
        return Double(c) * 1_000_000 / Double(dictionary.total)
    }
}

/// All language models.
public final class Models: @unchecked Sendable {
    public let ru: LanguageModel
    public let en: LanguageModel
    public let sk: LanguageModel

    public init(dataDirectory: URL) throws {
        ru = try LanguageModel(language: .ru, dataDirectory: dataDirectory)
        en = try LanguageModel(language: .en, dataDirectory: dataDirectory)
        sk = try LanguageModel(language: .sk, dataDirectory: dataDirectory)
    }

    public func models(latin: Bool) -> [LanguageModel] { latin ? [en, sk] : [ru] }
}
