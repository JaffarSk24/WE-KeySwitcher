import AppKit
import KeySwitcherCore
import Security

/// Updates from GitHub Releases: checks once a day, asks, downloads the zip,
/// verifies that the new app is signed by the same certificate as this one,
/// replaces this bundle in place and relaunches. Settings, remembered words,
/// the login item and the macOS permissions stay: they belong to the bundle
/// identifier, path and signature, which do not change.
@MainActor
final class Updater {
    static let shared = Updater()

    private let releasesAPI = URL(string: "https://api.github.com/repos/JaffarSk24/WE-KeySwitcher/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/JaffarSk24/WE-KeySwitcher/releases/latest")!
    private var timer: Timer?
    private var busy = false
    /// Shown in the menu while an update is downloaded.
    private(set) var status: String?
    var onStatusChange: (() -> Void)?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Release {
        let version: String
        let notes: String
        let assetURL: URL
        let assetSize: Int
    }

    /// Automatic checks: a minute after start, then every 24 hours.
    func start() {
        timer?.invalidate()
        guard Settings.shared.autoCheckUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
    }

    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: releasesAPI, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WE-KeySwitcher/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let asset = assets.first(where: { ($0["name"] as? String) == "WE-KeySwitcher-\(version).zip" }),
              let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString) else { return nil }
        return Release(version: version, notes: json["body"] as? String ?? "", assetURL: url,
                       assetSize: asset["size"] as? Int ?? 0)
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let release: Release?
        do {
            release = try await fetchLatest()
        } catch {
            if userInitiated { inform(L("Could not check for updates."), error.localizedDescription) }
            return
        }
        guard let release, Versions.isNewer(release.version, than: Self.currentVersion) else {
            if userInitiated {
                inform(L("You have the latest version."), String(format: L("WE KeySwitcher %@ is the newest version available."), Self.currentVersion))
            }
            return
        }
        if !userInitiated && Settings.shared.skippedVersion == release.version { return }
        await offer(release, userInitiated: userInitiated)
    }

    /// Release notes without Markdown marks, cut to a readable length.
    private static func plainNotes(_ md: String) -> String {
        var lines: [String] = []
        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            var l = String(raw).trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("SHA-256") || l.hasPrefix("## ") || l.hasPrefix("Install") { break }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if l.hasPrefix("- ") { l = "• " + l.dropFirst(2) }
            lines.append(l)
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 900 { text = String(text.prefix(900)) + "…" }
        return text
    }

    private func offer(_ release: Release, userInitiated: Bool) async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(format: L("WE KeySwitcher %@ is available"), release.version)
        alert.informativeText = String(format: L("You have version %@. The new version installs itself and restarts; your settings and remembered words stay."), Self.currentVersion)
            + "\n\n" + Self.plainNotes(release.notes)
        alert.addButton(withTitle: L("Install and Relaunch"))
        alert.addButton(withTitle: L("Later"))
        if !userInitiated { alert.addButton(withTitle: L("Skip This Version")) }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await install(release)
        case .alertThirdButtonReturn:
            Settings.shared.skippedVersion = release.version
        default:
            break
        }
    }

    private func setStatus(_ s: String?) {
        status = s
        onStatusChange?()
    }

    private func install(_ release: Release) async {
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: bundle.path)
            || !FileManager.default.isWritableFile(atPath: bundle.appendingPathComponent("Contents").path) {
            inform(L("WE KeySwitcher cannot update itself here."),
                   L("Move the app to the Applications folder (or install it with your own user account) and try again. The release page opens now."))
            NSWorkspace.shared.open(releasesPage)
            return
        }
        setStatus(String(format: L("Downloading %@…"), release.version))
        defer { setStatus(nil) }
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("WE-KeySwitcher-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: release.assetURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)
            if release.assetSize > 0,
               let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int, size != release.assetSize {
                throw UpdateError.download
            }
            let unpacked = work.appendingPathComponent("unpacked")
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let newApp = unpacked.appendingPathComponent("WE KeySwitcher.app")
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.contents }
            try verifySignature(of: newApp)
            try launchReplacement(new: newApp, old: bundle, work: work)
            NSApp.terminate(nil)
        } catch {
            inform(L("The update was not installed."), "\(error.localizedDescription)\n\n" + L("Nothing was changed. You can download the new version from the release page."))
        }
    }

    enum UpdateError: LocalizedError {
        case download, contents, signature(String), tool(String)
        var errorDescription: String? {
            switch self {
            case .download: return L("The download was incomplete.")
            case .contents: return L("The downloaded archive does not contain the expected app.")
            case .signature(let s): return L("The new app is not signed like this one.") + " " + s
            case .tool(let s): return s
            }
        }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.tool("\(tool) exited with \(p.terminationStatus)") }
    }

    /// The new bundle must be intact and satisfy the designated requirement
    /// of the running app (same identifier, same signing certificate).
    private func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var staticSelf: SecStaticCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticSelf) == errSecSuccess, let staticSelf,
              SecCodeCopyDesignatedRequirement(staticSelf, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.signature("")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.signature(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")
        }
    }

    /// A small detached script waits until this process has quit, copies the
    /// new files over the old bundle (same path, so the login item and the
    /// permissions stay) and opens the app again.
    private func launchReplacement(new: URL, old: URL, work: URL) throws {
        let script = work.appendingPathComponent("replace.sh")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let text = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if /usr/bin/rsync -a --delete \(q(new.path + "/")) \(q(old.path + "/")); then
          /usr/bin/xattr -cr \(q(old.path)) 2>/dev/null
        fi
        /usr/bin/open \(q(old.path))
        /bin/rm -rf \(q(work.path))
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // A new session: the script must outlive the app it replaces.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        defer { posix_spawnattr_destroy(&attr) }
        var pid: pid_t = 0
        let args = ["/bin/sh", script.path]
        var cargs = args.map { strdup($0) } + [nil]
        defer { for a in cargs { free(a) } }
        let rc = posix_spawn(&pid, "/bin/sh", nil, &attr, &cargs, environ)
        if rc != 0 { throw UpdateError.tool("posix_spawn \(rc)") }
    }

    private func inform(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
