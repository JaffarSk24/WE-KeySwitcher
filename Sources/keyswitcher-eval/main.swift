import Foundation
import KeySwitcherCore

// Evaluates the switching decision on word lists in Tests/data.
// Usage: keyswitcher-eval [repo-root] [--verbose] [--set key=value ...]

let args = CommandLine.arguments.dropFirst()
let root = URL(fileURLWithPath: args.first(where: { !$0.hasPrefix("--") && !$0.contains("=") }) ?? FileManager.default.currentDirectoryPath)
let verbose = args.contains("--verbose")
let dataDir = root.appendingPathComponent("Resources/data")
let testDir = root.appendingPathComponent("Tests/data")

guard let layouts = LayoutSet.loadSystem() else { fatalError("layouts not installed") }
let t0 = Date()
let models = try Models(dataDirectory: dataDir)
var config = ClassifierConfig()
for a in args where a.contains("=") {
    let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
    guard kv.count == 2, let v = Double(kv[1]) else { continue }
    switch kv[0] {
    case "margin": config.margin = v
    case "marginBothUnknown": config.marginBothUnknown = v
    case "marginShort": config.marginShort = v
    case "keepIfPerMillion": config.keepIfPerMillion = v
    case "hugeMargin": config.hugeMargin = v
    case "marginNgramToLatin": config.marginNgramToLatin = v
    case "marginPlausible": config.marginPlausible = v
    case "marginBothKnown": config.marginBothKnown = v
    case "marginBothKnownRare": config.marginBothKnownRare = v
    case "rarePerMillion": config.rarePerMillion = v
    case "marginRareOther": config.marginRareOther = v
    case "oovMass": config.oovMass = v
    case "implausibleStep": config.implausibleStep = v
    case "ru": config.prior[.ru] = v
    case "en": config.prior[.en] = v
    case "sk": config.prior[.sk] = v
    default: print("unknown parameter \(kv[0])")
    }
}
let classifier = Classifier(layouts: layouts, models: models, config: config)
print(String(format: "models loaded in %.2fs", Date().timeIntervalSince(t0)))

// --word=<w>: show the decision for one word typed in every layout.
if let wArg = args.first(where: { $0.hasPrefix("--word=") }) {
    let w = String(wArg.dropFirst(7))
    let intended: LayoutKind = w.contains(where: TextTools.isCyrillic) ? .ru : (w.contains(where: { "áäčďéíĺľňóôŕšťúýž".contains($0) }) ? .sk : .us)
    for typedIn in LayoutKind.allCases {
        guard let st = layouts[intended].strokes(for: w) else { continue }
        let typed = layouts[typedIn].translate(st)
        let d = classifier.decide(strokes: st, typed: typed, current: typedIn, latin: typedIn.isLatin ? typedIn : (intended == .sk ? .sk : .us))
        print("\(typedIn.rawValue): '\(typed)' \(d)")
    }
    exit(0)
}

// --prefix: simulates switching while a word is still being typed. After each
// letter from the 3rd on, the prefix typed so far is compared with the same
// keys in the other layout by the n-gram models only (a prefix is rarely a
// dictionary word). A switch fires when the other reading is ahead by the
// margin and the typed reading contains an improbable letter transition.
if args.contains("--prefix") {
    func lp(_ text: String, latin: Bool) -> (Double, Double) {
        var best = -Double.infinity, worst = -Double.infinity
        for m in models.models(latin: latin) {
            let w = m.normalize(text)
            guard w.allSatisfy(\.isLetter) else { return (-99, -99) }
            best = max(best, log10(config.prior[m.language] ?? 0.1) + m.ngrams.logProb(w, end: false))
            worst = max(worst, m.ngrams.worstStep(w, end: false))
        }
        return (best, worst)
    }
    func strip(_ s: String) -> String {
        String(s.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x0300...0x036F).contains($0.value) }.map(Character.init))
    }
    func load(_ f: String) -> [String] {
        ((try? String(contentsOf: testDir.appendingPathComponent(f), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    struct C { let word: String; let intended: LayoutKind; let typedIn: LayoutKind; let latin: LayoutKind }
    var cases: [C] = []
    for set in ["manual", "freq", "mid", "rare"] {
        let ru = load(set == "manual" ? "manual_ru.txt" : "ru_\(set).txt")
        let en = load(set == "manual" ? "manual_en.txt" : "en_\(set).txt")
        let sk = load(set == "manual" ? "manual_sk.txt" : "sk_\(set).txt")
        for w in ru { cases += [C(word: w, intended: .ru, typedIn: .ru, latin: .us), C(word: w, intended: .ru, typedIn: .us, latin: .us)] }
        for w in en { cases += [C(word: w, intended: .us, typedIn: .us, latin: .us), C(word: w, intended: .us, typedIn: .ru, latin: .us)] }
        for w in sk { cases += [C(word: w, intended: .sk, typedIn: .sk, latin: .sk), C(word: strip(w), intended: .us, typedIn: .us, latin: .us),
                                C(word: w, intended: .sk, typedIn: .ru, latin: .sk)] }
    }
    for w in load("webster_en.txt") + load("names_en.txt") {
        cases += [C(word: w, intended: .us, typedIn: .us, latin: .us), C(word: w, intended: .us, typedIn: .ru, latin: .us)]
    }
    print("margin minLetters implausible | keep cases: wrong mid-word switch | switch cases: switched early, avg letters saved, long words (6+) switched early")
    for minLetters in [3, 4, 5] {
        for margin in [3.0, 4.0, 5.0, 6.0] {
            for implausible in [-2.5, -3.0, -3.5] {
                var keepN = 0, keepBad = 0, swN = 0, swEarly = 0, saved = 0, longN = 0, longEarly = 0
                var badSamples: [String] = []
                for c in cases {
                    guard let st = layouts[c.intended].strokes(for: c.word), c.word.filter(\.isLetter).count >= 2 else { continue }
                    let shouldSwitch = c.intended.isLatin != c.typedIn.isLatin
                    let alt: LayoutKind = c.typedIn == .ru ? c.latin : .ru
                    var firedAt: Int? = nil
                    if st.count > minLetters {
                        for k in minLetters..<st.count {
                            let pre = Array(st.prefix(k))
                            let t = layouts[c.typedIn].translate(pre), o = layouts[alt].translate(pre)
                            let (sT, wT) = lp(t, latin: c.typedIn.isLatin)
                            let (sO, _) = lp(o, latin: alt.isLatin)
                            guard sO > -99 else { break }
                            let need = margin + (c.typedIn == .ru ? 1.0 : 0)
                            if sO - sT > need && wT < implausible { firedAt = k; break }
                        }
                    }
                    if shouldSwitch {
                        swN += 1
                        if let f = firedAt { swEarly += 1; saved += st.count - f }
                        if st.count >= 6 { longN += 1; if firedAt != nil { longEarly += 1 } }
                    } else {
                        keepN += 1
                        if let f = firedAt { keepBad += 1; if badSamples.count < 6 { badSamples.append("\(c.word)@\(f)") } }
                    }
                }
                print(String(format: "%.1f %d %.1f | %d of %d (%.2f%%) %@ | %.1f%% early, %.1f letters saved, long %.1f%%",
                             margin, minLetters, implausible, keepBad, keepN, 100.0 * Double(keepBad) / Double(keepN),
                             badSamples.joined(separator: ",") as NSString,
                             100.0 * Double(swEarly) / Double(swN), Double(saved) / Double(max(swEarly, 1)),
                             100.0 * Double(longEarly) / Double(max(longN, 1))))
            }
        }
    }
    exit(0)
}

struct Case {
    let word: String
    let intended: LayoutKind
    let typedIn: LayoutKind
    let latin: LayoutKind
}

struct Tally {
    var total = 0
    var errors = 0
    var samples: [String] = []
}

var tallies: [String: Tally] = [:]
var singleLetter = 0
var order: [String] = []

func run(_ name: String, _ c: Case) {
    guard let strokes = layouts[c.intended].strokes(for: c.word) else { return }
    // One-letter words are never switched automatically (by design): counted apart.
    if c.word.filter(\.isLetter).count < 2 { singleLetter += 1; return }
    let typed = layouts[c.typedIn].translate(strokes)
    let d = classifier.decide(strokes: strokes, typed: typed, current: c.typedIn, latin: c.latin)
    let shouldSwitch = c.intended != c.typedIn && !(c.intended.isLatin && c.typedIn.isLatin)
    var ok: Bool
    switch d.action {
    case .keep: ok = !shouldSwitch
    case .switchTo: ok = shouldSwitch && d.convertedText == c.word
    }
    if tallies[name] == nil { order.append(name) }
    tallies[name, default: Tally()].total += 1
    if !ok {
        tallies[name]!.errors += 1
        tallies[name]!.samples.append("\(c.word) [\(typed)] \(d)")
    }
}

func load(_ file: String) -> [String] {
    guard let s = try? String(contentsOf: testDir.appendingPathComponent(file), encoding: .utf8) else { return [] }
    return s.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func strip(_ s: String) -> String {
    String(s.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x0300...0x036F).contains($0.value) }.map(Character.init))
}

for set in ["manual", "freq", "mid", "rare"] {
    let ru = load(set == "manual" ? "manual_ru.txt" : "ru_\(set).txt")
    let en = load(set == "manual" ? "manual_en.txt" : "en_\(set).txt")
    let sk = load(set == "manual" ? "manual_sk.txt" : "sk_\(set).txt")
    for w in ru {
        run("\(set) ru: typed in RU, keep", Case(word: w, intended: .ru, typedIn: .ru, latin: .us))
        run("\(set) ru: typed in US, switch", Case(word: w, intended: .ru, typedIn: .us, latin: .us))
        run("\(set) ru: typed in SK, switch", Case(word: w, intended: .ru, typedIn: .sk, latin: .sk))
    }
    for w in en {
        run("\(set) en: typed in US, keep", Case(word: w, intended: .us, typedIn: .us, latin: .us))
        run("\(set) en: typed in RU, switch", Case(word: w, intended: .us, typedIn: .ru, latin: .us))
    }
    for w in sk {
        run("\(set) sk: typed in SK, keep", Case(word: w, intended: .sk, typedIn: .sk, latin: .sk))
        let s = strip(w)
        run("\(set) sk: no diacritics in US, keep", Case(word: s, intended: .us, typedIn: .us, latin: .us))
        run("\(set) sk: typed in RU, switch", Case(word: w, intended: .sk, typedIn: .ru, latin: .sk))
    }
}

// Capitalised words and words followed by a comma or full stop typed on a key
// that is a letter in the other layout.
for w in load("freq_ru.txt".isEmpty ? "" : "ru_freq.txt") {
    let cap = w.prefix(1).uppercased() + w.dropFirst()
    run("variants ru: Capitalised in US, switch", Case(word: cap, intended: .ru, typedIn: .us, latin: .us))
    run("variants ru: Capitalised in RU, keep", Case(word: cap, intended: .ru, typedIn: .ru, latin: .us))
}
for w in load("en_freq.txt") + load("en_mid.txt").prefix(300) {
    let cap = w.prefix(1).uppercased() + w.dropFirst()
    run("variants en: Capitalised in RU, switch", Case(word: cap, intended: .us, typedIn: .ru, latin: .us))
    run("variants en: with comma in RU, switch", Case(word: w + ",", intended: .us, typedIn: .ru, latin: .us))
    run("variants en: with full stop in RU, switch", Case(word: w + ".", intended: .us, typedIn: .ru, latin: .us))
    run("variants en: with comma in US, keep", Case(word: w + ",", intended: .us, typedIn: .us, latin: .us))
}
for w in load("sk_freq.txt") {
    run("variants sk: with comma in RU, switch", Case(word: w + ",", intended: .sk, typedIn: .ru, latin: .sk))
    run("variants sk: with comma in SK, keep", Case(word: w + ",", intended: .sk, typedIn: .sk, latin: .sk))
}

for (file, label) in [("webster_en.txt", "webster en"), ("names_en.txt", "names en")] {
    for w in load(file) {
        run("\(label): typed in US, keep", Case(word: w, intended: .us, typedIn: .us, latin: .us))
        run("\(label): typed in RU, switch", Case(word: w, intended: .us, typedIn: .ru, latin: .us))
    }
}

var keepT = 0, keepE = 0, swT = 0, swE = 0
print("")
for name in order {
    let t = tallies[name]!
    let pct = 100.0 * Double(t.errors) / Double(max(t.total, 1))
    print(String(format: "%-42@ %5d cases %4d errors %6.2f%%", name as NSString, t.total, t.errors, pct))
    if name.hasSuffix("keep") { keepT += t.total; keepE += t.errors } else { swT += t.total; swE += t.errors }
    if verbose { for s in t.samples.prefix(40) { print("    " + s) } }
}
print("one-letter cases left out (never auto-switched by design): \(singleLetter)")
print(String(format: "\nfalse switches: %d of %d (%.2f%%)", keepE, keepT, 100.0 * Double(keepE) / Double(keepT)))
print(String(format: "missed switches: %d of %d (%.2f%%)", swE, swT, 100.0 * Double(swE) / Double(swT)))
print(String(format: "total: %d errors of %d (%.2f%%)", keepE + swE, keepT + swT, 100.0 * Double(keepE + swE) / Double(keepT + swT)))
