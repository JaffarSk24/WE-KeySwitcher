import AppKit
import ApplicationServices
import KeySwitcherCore
import ServiceManagement

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: KeyboardMonitor?
    private var inputs: InputSources!
    private var retryTimer: Timer?
    private var wordsWindow: WordsWindowController?
    private var loadError: String?
    private var appBeforeMenu: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let layouts = LayoutSet.loadSystem(resolveFromSystem: true)
        inputs = InputSources()
        inputs.onChange = { [weak self] k in
            MainActor.assumeIsolated {
                if let k, k.isLatin { Settings.shared.lastLatin = k }
                self?.updateTitle(k)
            }
        }
        updateTitle(inputs.current)

        // Open at login by default; later the menu switch decides.
        if !Settings.shared.loginItemConfigured {
            Settings.shared.loginItemConfigured = true
            do { try SMAppService.mainApp.register() } catch { NSLog("KeySwitcher: login item error %@", "\(error)") }
        }
        if !Settings.shared.puntoImported {
            let n = LearnedWords.shared.importPuntoRules()
            Settings.shared.puntoImported = true
            NSLog("KeySwitcher: imported %d PuntoSwitcher rules", n)
        }

        guard let layouts else {
            loadError = L("Enable the Russian keyboard layout and at least one Latin layout (U.S., ABC, Slovak...) in System Settings > Keyboard > Text Input")
            return
        }
        let dataDir = Bundle.main.resourceURL!.appendingPathComponent("data")
        do {
            let models = try Models(dataDirectory: dataDir)
            let m = KeyboardMonitor(layouts: layouts, classifier: Classifier(layouts: layouts, models: models), inputs: inputs)
            m.onLayoutSwitched = { [weak self] k in self?.updateTitle(k) }
            m.onLearned = { word in NSLog("KeySwitcher: learned word %@", word) }
            monitor = m
        } catch {
            loadError = L("Dictionaries could not be loaded:") + " " + error.localizedDescription
            return
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        tryStart()
        if !(monitor?.isRunning ?? false) {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tryStart() }
            }
        }
    }

    private func tryStart() {
        guard let monitor else { return }
        if monitor.start() {
            retryTimer?.invalidate()
            retryTimer = nil
        }
        updateTitle(inputs.current)
    }

    private func updateTitle(_ k: LayoutKind?) {
        let running = monitor?.isRunning ?? false
        let name = k?.shortName ?? "??"
        statusItem.button?.title = running ? name : name + "!"
        statusItem.button?.toolTip = running ? "WE KeySwitcher" : L("WE KeySwitcher: no access to the keyboard")
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        appBeforeMenu = NSWorkspace.shared.frontmostApplication
        menu.removeAllItems()
        let s = Settings.shared
        if let loadError {
            menu.addItem(disabled(loadError))
            menu.addItem(.separator())
        }
        let ax = AXIsProcessTrusted()
        let im = CGPreflightListenEventAccess()
        if !ax || !im || !(monitor?.isRunning ?? false) {
            menu.addItem(disabled(L("No access to the keyboard:")))
            menu.addItem(item(ax ? "✓ " + L("Accessibility") : "✗ " + L("Accessibility: turn on…"), #selector(openAccessibility)))
            menu.addItem(item(im ? "✓ " + L("Input Monitoring") : "✗ " + L("Input Monitoring: turn on…"), #selector(openInputMonitoring)))
            menu.addItem(.separator())
        }
        menu.addItem(toggle(L("Switch layout automatically"), s.autoSwitch, #selector(toggleAuto)))
        let whileTyping = toggle(L("Already while typing a word"), s.switchWhileTyping, #selector(toggleWhileTyping))
        whileTyping.indentationLevel = 1
        whileTyping.isEnabled = s.autoSwitch
        menu.addItem(whileTyping)
        menu.addItem(toggle(L("Sound on automatic switch"), s.sound, #selector(toggleSound)))
        menu.addItem(toggle(L("Fix TWo capitals"), s.fixTwoCapitals, #selector(toggleCaps)))
        menu.addItem(.separator())
        menu.addItem(item(String(format: L("Remembered words (%d)…"), LearnedWords.shared.words.count), #selector(showWords)))

        let ex = NSMenuItem(title: L("Excluded apps"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for id in s.excludedApps {
            let it = item("✕ " + appName(id), #selector(removeExcluded(_:)))
            it.representedObject = id
            it.toolTip = L("Remove from excluded apps")
            sub.addItem(it)
        }
        if !s.excludedApps.isEmpty { sub.addItem(.separator()) }
        if let app = appBeforeMenu, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !s.excludedApps.contains(id) {
            let it = item(String(format: L("Add “%@”"), app.localizedName ?? id), #selector(addExcluded(_:)))
            it.representedObject = id
            sub.addItem(it)
        }
        sub.addItem(item(L("Choose an app…"), #selector(chooseExcluded)))
        ex.submenu = sub
        menu.addItem(ex)
        menu.addItem(.separator())
        menu.addItem(toggle(L("Open at login"), SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(disabled(L("Option: convert the word or the selection")))
        menu.addItem(disabled(L("Option+Shift: invert case")))
        menu.addItem(.separator())
        menu.addItem(item(L("Quit"), #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let it = item(title, action)
        it.state = on ? .on : .off
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @objc private func toggleAuto() { Settings.shared.autoSwitch.toggle() }
    @objc private func toggleWhileTyping() { Settings.shared.switchWhileTyping.toggle() }
    @objc private func toggleSound() { Settings.shared.sound.toggle() }
    @objc private func toggleCaps() { Settings.shared.fixTwoCapitals.toggle() }

    @objc private func removeExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.excludedApps.removeAll { $0 == id }
    }

    @objc private func addExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.excludedApps.append(id)
    }

    @objc private func chooseExcluded() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var list = Settings.shared.excludedApps
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !list.contains(id) { list.append(id) }
        }
        Settings.shared.excludedApps = list
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("KeySwitcher: login item error \(error)")
        }
    }

    @objc private func showWords() {
        if wordsWindow == nil { wordsWindow = WordsWindowController() }
        wordsWindow?.show()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Window with the list of remembered words: search, add, delete.
@MainActor
final class WordsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let window: NSWindow
    private let table = NSTableView()
    private let search = NSSearchField()
    private var shown: [String] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = L("Remembered words")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 300, height: 300)

        let info = NSTextField(wrappingLabelWithString: L("These words are never switched automatically. A word gets here after you undo its automatic switch three times (Option right after the switch)."))
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor

        search.placeholderString = L("Search")
        search.delegate = self

        let col = NSTableColumn(identifier: .init("w"))
        col.title = L("Word")
        table.addTableColumn(col)
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: L("Add…"), target: self, action: #selector(addWord))
        let del = NSButton(title: L("Delete"), target: self, action: #selector(deleteWords))
        let buttons = NSStackView(views: [add, NSView(), del])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [info, search, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        reload()
    }

    func show() {
        reload()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        let q = search.stringValue.lowercased()
        let all = LearnedWords.shared.words.sorted { $0.lowercased() < $1.lowercased() }
        shown = q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tf = NSTextField(labelWithString: shown[row])
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }

    @objc private func deleteWords() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        for r in rows { LearnedWords.shared.remove(shown[r]) }
        reload()
    }

    @objc private func addWord() {
        let alert = NSAlert()
        alert.messageText = L("New word")
        alert.informativeText = L("The word exactly as it is typed, for example petdoctor.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("Add"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            LearnedWords.shared.add(field.stringValue)
            reload()
        }
    }
}
