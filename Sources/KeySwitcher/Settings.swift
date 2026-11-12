import AppKit
import KeySwitcherCore

/// User settings kept in UserDefaults (sk.whiteeagles.keyswitcher).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "autoSwitch": true,
            "switchWhileTyping": true,
            "autoCheckUpdates": true,
            "sound": true,
            "fixTwoCapitals": true,
            "excludedApps": ["com.microsoft.VSCode"],
            "lastLatin": LayoutKind.us.rawValue,
        ])
    }

    var autoSwitch: Bool {
        get { d.bool(forKey: "autoSwitch") }
        set { d.set(newValue, forKey: "autoSwitch") }
    }

    /// Switch already while a word is typed when the first letters are clear.
    var switchWhileTyping: Bool {
        get { d.bool(forKey: "switchWhileTyping") }
        set { d.set(newValue, forKey: "switchWhileTyping") }
    }

    /// Daily check of GitHub Releases for a new version.
    var autoCheckUpdates: Bool {
        get { d.bool(forKey: "autoCheckUpdates") }
        set { d.set(newValue, forKey: "autoCheckUpdates") }
    }

    /// A version the user chose to skip in the update offer.
    var skippedVersion: String? {
        get { d.string(forKey: "skippedVersion") }
        set { d.set(newValue, forKey: "skippedVersion") }
    }

    var sound: Bool {
        get { d.bool(forKey: "sound") }
        set { d.set(newValue, forKey: "sound") }
    }

    var fixTwoCapitals: Bool {
        get { d.bool(forKey: "fixTwoCapitals") }
        set { d.set(newValue, forKey: "fixTwoCapitals") }
    }

    var excludedApps: [String] {
        get { d.stringArray(forKey: "excludedApps") ?? [] }
        set { d.set(newValue, forKey: "excludedApps") }
    }

    var lastLatin: LayoutKind {
        get { LayoutKind(rawValue: d.string(forKey: "lastLatin") ?? "us") ?? .us }
        set { if newValue.isLatin { d.set(newValue.rawValue, forKey: "lastLatin") } }
    }

    /// Learning from undone automatic switches (off only for automated tests).
    var learnFromUndo: Bool { d.object(forKey: "learnFromUndo") as? Bool ?? true }

    /// Writes decisions to the system log (defaults write sk.whiteeagles.keyswitcher debugLog -bool true).
    var debugLog: Bool { d.bool(forKey: "debugLog") }

    var loginItemConfigured: Bool {
        get { d.bool(forKey: "loginItemConfigured") }
        set { d.set(newValue, forKey: "loginItemConfigured") }
    }

    var puntoImported: Bool {
        get { d.bool(forKey: "puntoImported") }
        set { d.set(newValue, forKey: "puntoImported") }
    }
}

/// Words that must never be switched automatically, plus counters of manual
/// undos. Stored as JSON in ~/Library/Application Support/WE KeySwitcher/learned.json.
final class LearnedWords {
    static let shared = LearnedWords()
    static let undosToLearn = 3

    private struct Store: Codable {
        var words: [String] = []
        var undoCounts: [String: Int] = [:]
    }

    private var store = Store()
    private(set) var matchSet: Set<String> = []
    let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WE KeySwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("learned.json")
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Store.self, from: data) {
            store = s
        }
        rebuild()
    }

    var words: [String] { store.words }

    private func rebuild() {
        matchSet = Set(store.words.map { $0.lowercased() })
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(store) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !matchSet.contains(w.lowercased()) else { return }
        store.words.append(w)
        store.undoCounts[w.lowercased()] = nil
        rebuild()
        save()
    }

    func remove(_ word: String) {
        store.words.removeAll { $0 == word }
        rebuild()
        save()
    }

    /// Registers one manual undo of an automatic switch. Returns true when the
    /// word has just been learned.
    func registerUndo(of word: String) -> Bool {
        let key = word.lowercased()
        guard !key.isEmpty, !matchSet.contains(key) else { return false }
        let n = (store.undoCounts[key] ?? 0) + 1
        if n >= Self.undosToLearn {
            add(word)
            return true
        }
        store.undoCounts[key] = n
        save()
        return false
    }

    /// One-time import of PuntoSwitcher user rules (userRulesDictionary).
    func importPuntoRules() -> Int {
        guard let rules = CFPreferencesCopyAppValue("userRulesDictionary" as CFString, "ru.yandex.punto" as CFString) as? [[Any]] else {
            return 0
        }
        var n = 0
        for r in rules {
            guard let w = r.first as? String else { continue }
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !matchSet.contains(t.lowercased()) {
                store.words.append(t)
                matchSet.insert(t.lowercased())
                n += 1
            }
        }
        save()
        return n
    }
}

/// Debug log in ~/Library/Logs/WE KeySwitcher.log, written only when the
/// debugLog default is on.
enum DebugLog {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/WE KeySwitcher.log")

    static func write(_ message: String) {
        guard Settings.shared.debugLog else { return }
        let line = "\(Date()) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
