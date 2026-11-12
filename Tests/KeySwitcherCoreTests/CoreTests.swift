import Foundation
import Testing
@testable import KeySwitcherCore

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

enum Fixture {
    static let layouts: LayoutSet = {
        guard let l = LayoutSet.loadSystem() else {
            fatalError("Tests need the U.S., Slovak - QWERTY and Russian keyboard layouts installed")
        }
        return l
    }()
    static let models = try! Models(dataDirectory: repoRoot.appendingPathComponent("Resources/data"))
    static let classifier = Classifier(layouts: layouts, models: models)

    static func decide(_ word: String, intended: LayoutKind, typedIn: LayoutKind, latin: LayoutKind = .us) -> Decision {
        let strokes = layouts[intended].strokes(for: word)!
        return classifier.decide(strokes: strokes, typed: layouts[typedIn].translate(strokes), current: typedIn, latin: latin)
    }
}

@Suite struct LayoutTests {
    @Test func convertsBetweenLayouts() {
        let l = Fixture.layouts
        #expect(l.convert("ghbdtn", from: .us, to: .ru) == "привет")
        #expect(l.convert("руддщ", from: .ru, to: .us) == "hello")
        #expect(l.convert("Ghbdtn", from: .us, to: .ru) == "Привет")
        #expect(l.convert("j,]trn", from: .us, to: .ru) == "объект")
    }

    @Test func slovakDeadKeysAndNumberRow() {
        let sk = Fixture.layouts[.sk]
        let strokes = sk.strokes(for: "ďakujem, môžem ó")!
        #expect(sk.translate(strokes) == "ďakujem, môžem ó")
        #expect(Fixture.layouts.convert("účet", from: .sk, to: .ru) == "х4уе")
    }

    @Test func wordStrokes() {
        let l = Fixture.layouts
        #expect(l.isWordStroke(KeyStroke(keyCode: 43)))            // , in U.S. is б in Russian
        #expect(l.isWordStroke(KeyStroke(keyCode: 21)))            // 4 in U.S. is č in Slovak
        #expect(!l.isWordStroke(KeyStroke(keyCode: 22, shift: true))) // ^ / , / 6
        #expect(!l.isWordStroke(KeyStroke(keyCode: 27)))           // -
    }
}

@Suite struct TextToolsTests {
    @Test func invertCase() {
        #expect(TextTools.invertCase("пРИВЕТ") == "Привет")
        #expect(TextTools.invertCase("Hello, World") == "hELLO, wORLD")
    }

    @Test func twoCapitals() {
        #expect(TextTools.fixTwoCapitals("ПРивет") == "Привет")
        #expect(TextTools.fixTwoCapitals("HEllo") == "Hello")
        #expect(TextTools.fixTwoCapitals("USA") == nil)
        #expect(TextTools.fixTwoCapitals("IDs") == nil)
        #expect(TextTools.fixTwoCapitals("Привет") == nil)
    }

    @Test func shapes() {
        #expect(TextTools.isPlainWord("кто-то"))
        #expect(TextTools.isPlainWord("don't"))
        #expect(!TextTools.isPlainWord("j,trn"))
        #expect(TextTools.isCamelCase("iPhone"))
        #expect(TextTools.hasDomainSuffix("whiteeagles.sk"))
        #expect(!TextTools.hasDomainSuffix("k.,k."))
    }

    @Test func direction() {
        #expect(TextTools.direction(of: "привет мир", lastLatin: .sk) == (.ru, .sk))
        #expect(TextTools.direction(of: "hello", lastLatin: .us) == (.us, .ru))
        #expect(TextTools.direction(of: "účet", lastLatin: .us) == (.sk, .ru))
    }
}

@Suite struct ClassifierTests {
    @Test(arguments: ["привет", "спасибо", "сейчас", "нормально", "кстати", "договорились", "объект", "Привет",
                      "не", "да", "ну", "мы", "компьютер", "клавиатура", "раскладка", "жёлтый"])
    func russianTypedInLatinSwitches(_ word: String) {
        for latin in [LayoutKind.us, .sk] {
            let d = Fixture.decide(word, intended: .ru, typedIn: latin, latin: latin)
            #expect(d.action == .switchTo(.ru), "\(word) in \(latin): \(d)")
            #expect(d.convertedText == word)
        }
    }

    @Test(arguments: ["hello", "thanks", "please", "meeting", "github", "deploy", "kubernetes", "Hello", "weekend", "yesterday"])
    func englishTypedInRussianSwitches(_ word: String) {
        let d = Fixture.decide(word, intended: .us, typedIn: .ru)
        #expect(d.action == .switchTo(.us), "\(word): \(d)")
        #expect(d.convertedText == word)
    }

    @Test(arguments: ["ďakujem", "účet", "faktúra", "zmluva", "rezervácia", "môžem", "peniaze"])
    func slovakTypedInRussianSwitches(_ word: String) {
        let d = Fixture.decide(word, intended: .sk, typedIn: .ru, latin: .sk)
        #expect(d.action == .switchTo(.sk), "\(word): \(d)")
        #expect(d.convertedText == word)
    }

    @Test(arguments: ["hello", "git", "npm", "docker", "localhost", "USA", "HTML", "iPhone", "MacBook", "ok",
                      "dakujem", "prosim", "zajtra", "ahoj", "Bratislava", "Zvolen", "petdoctor"])
    func latinWordsStay(_ word: String) {
        let d = Fixture.decide(word, intended: .us, typedIn: .us)
        #expect(d.action == .keep, "\(word): \(d)")
    }

    @Test(arguments: ["привет", "ютуб", "шипящее", "вожатый", "Шереметьево", "директ", "лендос", "ёжик", "кто-то"])
    func russianWordsStay(_ word: String) {
        let d = Fixture.decide(word, intended: .ru, typedIn: .ru)
        #expect(d.action == .keep, "\(word): \(d)")
    }

    @Test func specialStringsStay() {
        let c = Fixture.classifier
        let us = Fixture.layouts[.us]
        for s in ["user@mail.sk", "www.google.com", "google.com", "/usr/bin", "abc123", "x2", "GA4"] {
            let strokes = us.strokes(for: s)!
            let d = c.decide(strokes: strokes, typed: s, current: .us, latin: .us)
            #expect(d.action == .keep, "\(s): \(d)")
        }
    }

    @Test func rememberedWordsStay() {
        let strokes = Fixture.layouts[.us].strokes(for: "ghbdtn")!
        let d = Fixture.classifier.decide(strokes: strokes, typed: "ghbdtn", current: .us, latin: .us, remembered: ["ghbdtn"])
        #expect(d.action == .keep)
    }

    @Test func singleLettersNeverSwitch() {
        for w in ["я", "в", "и", "к"] {
            #expect(Fixture.decide(w, intended: .ru, typedIn: .us).action == .keep)
        }
    }

    func context(_ word: String, intended: LayoutKind, typedIn: LayoutKind, target: LayoutKind) -> String? {
        let strokes = Fixture.layouts[intended].strokes(for: word)!
        return Fixture.classifier.followsSwitch(strokes: strokes, typed: Fixture.layouts[typedIn].translate(strokes),
                                                current: typedIn, target: target)
    }

    @Test(arguments: ["в", "с", "к", "у", "о", "и", "а", "я", "да", "на", "не", "ну", "мы", "по", "за", "из", "от", "до", "В", "Я"])
    func shortRussianWordBeforeSwitchedWordFollows(_ word: String) {
        #expect(context(word, intended: .ru, typedIn: .us, target: .ru) == word)
        #expect(context(word, intended: .ru, typedIn: .sk, target: .ru) == word)
    }

    @Test func shortEnglishWordBeforeSwitchedWordFollows() {
        #expect(context("I", intended: .us, typedIn: .ru, target: .us) == "I")
        #expect(context("a", intended: .us, typedIn: .ru, target: .us) == "a")
        #expect(context("to", intended: .us, typedIn: .ru, target: .us) == "to")
    }

    @Test func shortWordsThatStayBeforeSwitchedWord() {
        // Real words in the typed language that are rare as converted.
        #expect(context("a", intended: .us, typedIn: .us, target: .ru) == nil)   // ф
        #expect(context("I", intended: .us, typedIn: .us, target: .ru) == nil)   // Ш
        #expect(context("ok", intended: .us, typedIn: .us, target: .ru) == nil)  // щл
        #expect(context("он", intended: .ru, typedIn: .ru, target: .us) == nil)  // jy
        // Longer words and abbreviations are never pulled along.
        #expect(context("PROD", intended: .us, typedIn: .us, target: .ru) == nil)
        #expect(context("git", intended: .us, typedIn: .us, target: .ru) == nil)
        #expect(context("x2", intended: .us, typedIn: .us, target: .ru) == nil)
    }

    /// Accuracy on the word lists in Tests/data (the same lists keyswitcher-eval uses).
    @Test func accuracyOnWordLists() throws {
        func load(_ f: String) -> [String] {
            ((try? String(contentsOf: repoRoot.appendingPathComponent("Tests/data/\(f)"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).filter { $0.filter(\.isLetter).count >= 2 }
        }
        var keepTotal = 0, keepErrors = 0, switchTotal = 0, switchErrors = 0
        func run(_ words: [String], _ intended: LayoutKind, _ typedIn: LayoutKind, _ latin: LayoutKind, expectSwitch: Bool) {
            for w in words {
                guard Fixture.layouts[intended].strokes(for: w) != nil else { continue }
                let d = Fixture.decide(w, intended: intended, typedIn: typedIn, latin: latin)
                let ok = expectSwitch ? (d.action == .switchTo(intended) && d.convertedText == w) : d.action == .keep
                if expectSwitch { switchTotal += 1; if !ok { switchErrors += 1 } } else { keepTotal += 1; if !ok { keepErrors += 1 } }
            }
        }
        for set in ["freq", "mid", "rare"] {
            let ru = load("ru_\(set).txt"), en = load("en_\(set).txt"), sk = load("sk_\(set).txt")
            run(ru, .ru, .ru, .us, expectSwitch: false)
            run(ru, .ru, .us, .us, expectSwitch: true)
            run(en, .us, .us, .us, expectSwitch: false)
            run(en, .us, .ru, .us, expectSwitch: true)
            run(sk, .sk, .sk, .sk, expectSwitch: false)
            run(sk, .sk, .ru, .sk, expectSwitch: true)
        }
        let falseRate = Double(keepErrors) / Double(keepTotal)
        let missRate = Double(switchErrors) / Double(switchTotal)
        print(String(format: "false switches %.2f%% of %d, missed %.2f%% of %d", falseRate * 100, keepTotal, missRate * 100, switchTotal))
        #expect(keepTotal > 5000 && switchTotal > 5000)
        #expect(falseRate < 0.002)
        #expect(missRate < 0.03)
    }
}
