import AppKit
import EventKit

/// Navi's errands on the Mac: opening a page, an app or a file straight away, and
/// downloading a file after asking in the caption. What's never done: opening an
/// installer or a downloaded app (they're shown in Finder for the user to open),
/// following anything but http and https links, or downloading without a yes.
final class MacErrands: Shell.Actions {
    private let caption: Caption
    private var task: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?
    /// Bumped by `cancel()`: a HEAD answer or a download from before it is dropped.
    private var generation = 0
    /// The engine's callback for the offer under way, so `cancel()` can answer it.
    private var pendingDone: ((String?, String?) -> Void)?

    init(caption: Caption) { self.caption = caption }

    /// Esc: the offer goes and a download under way stops (decision 13). The engine
    /// hears "cancelled", so nothing carries on from a file that never landed.
    func cancel() {
        generation += 1
        let wasBusy = task != nil || pendingDone != nil
        task?.cancel()
        task = nil
        progress = nil
        caption.offerRow.onChoice = nil
        caption.endOffer()
        if let done = pendingDone { pendingDone = nil; done(nil, "cancelled") }
        if wasBusy { trace("Download cancelled.") }
    }

    /// Answers the engine once, unless `cancel()` already did.
    private func finish(_ gen: Int, _ path: String?, _ problem: String?) {
        guard gen == generation, let done = pendingDone else { return }
        pendingDone = nil
        done(path, problem)
    }

    // MARK: Opening

    func open(_ target: String, with app: String?) -> String? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let appURL = app.flatMap(Self.application)
        if app != nil, appURL == nil { return "there's no app called \(app!) on this Mac" }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: t) else { return "that isn't a valid link" }
            if let appURL { NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) }
            else { NSWorkspace.shared.open(url) }
            return nil
        }
        // A System Settings pane, opened at the right page.
        if lower.hasPrefix("x-apple.systempreferences:") {
            guard let url = URL(string: t) else { return "that isn't a valid Settings link" }
            NSWorkspace.shared.open(url)
            return nil
        }
        if lower.contains("://") || lower.hasPrefix("file:") || lower.contains(":") && !t.hasPrefix("/") && !t.hasPrefix("~") && lower.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: .regularExpression) != nil {
            return "only web pages (http or https) and Settings panes are opened"
        }
        if t.hasPrefix("/") || t.hasPrefix("~") {
            // The real file: "..", symlinks and Finder aliases resolved before any check.
            var url = URL(fileURLWithPath: (t as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            if let target = try? URL(resolvingAliasFileAt: url) { url = target.standardizedFileURL.resolvingSymlinksInPath() }
            guard FileManager.default.fileExists(atPath: url.path) else { return "there's no file at \(t)" }
            // Secrets aren't opened: on screen they'd be in the next screenshot, around the read rules.
            if Self.isSecret(url) { return "that file holds secrets, so Navi won't open it" }
            // Apps that run what they open (a terminal, a script runner) never get a file from Navi.
            if let appURL, Self.runsScripts(appURL) { NSWorkspace.shared.activateFileViewerSelecting([url]); return nil }
            // Installers and apps from elsewhere are only ever shown: the user opens them.
            if Self.mustNotOpen(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return nil
            }
            if let appURL { NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) }
            else { NSWorkspace.shared.open(url) }
            return nil
        }
        guard let found = Self.application(t) else { return "there's no app called \(t) on this Mac" }
        NSWorkspace.shared.openApplication(at: found, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }

    /// An installed app by name ("MuJoCo", "System Settings") or bundle identifier.
    static func application(_ name: String) -> URL? {
        // By bundle identifier only when that app is installed (not one sitting in Downloads).
        if name.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name),
           !mustNotOpen(url) { return url }
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let fm = FileManager.default
        let places = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                      "/System/Library/CoreServices", (("~/Applications") as NSString).expandingTildeInPath]
        for dir in places {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: { $0.lowercased() == wanted + ".app" }) { return URL(fileURLWithPath: dir).appendingPathComponent(hit) }
        }
        // "Duck" for "Open Duck Mini.app" only when it's the one match, and never among the
        // system's own utilities ("Erase" mustn't find Erase Assistant).
        for dir in places where dir != "/System/Library/CoreServices" {
            let hits = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") && $0.lowercased().contains(wanted) }
            if hits.count == 1 { return URL(fileURLWithPath: dir).appendingPathComponent(hits[0]) }
        }
        return nil
    }

    /// Installers, scripts, links to elsewhere and apps that aren't installed: shown in
    /// Finder, never opened by Navi. Also any file the system would run as a program.
    static func mustNotOpen(_ given: URL) -> Bool {
        let placed = given.standardizedFileURL   // ".." gone, links kept
        let url = placed.resolvingSymlinksInPath()
        let ext = url.pathExtension.lowercased()
        let never: Set<String> = ["pkg", "mpkg", "dmg", "command", "sh", "zsh", "bash", "py", "rb", "pl", "tool", "terminal",
                                  "workflow", "scpt", "scptd", "applescript", "jar", "webloc", "inetloc", "fileloc", "url",
                                  "ftploc", "vncloc", "afploc", "pyw",
                                  "prefpane", "mobileconfig", "shortcut", "kext", "plugin", "osax", "saver", "qlgenerator"]
        if never.contains(ext) { return true }
        if ext == "app" {
            // Installed: sitting in an Applications folder, and really living there or in the
            // system (Safari in /Applications is a link into a protected system volume).
            let home = ("~/Applications/" as NSString).expandingTildeInPath + "/"
            let installed = ["/Applications/", "/System/Applications/", home]
            let sits = installed.contains { placed.path.hasPrefix($0) }
            let lives = installed.contains { url.path.hasPrefix($0) } || url.path.hasPrefix("/System/")
            return !(sits && lives)
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
           FileManager.default.isExecutableFile(atPath: url.path) { return true }
        return false
    }

    /// Where secrets live (the same places Claude's read tools are kept out of).
    static func isSecret(_ url: URL) -> Bool {
        let p = url.path.lowercased(), home = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        let dirs = ["/.ssh/", "/.gnupg/", "/.aws/", "/.azure/", "/.kube/", "/.docker/", "/.config/", "/.claude/",
                    "/library/keychains/", "/library/cookies/", "/library/containers/", "/library/group containers/",
                    "/library/mail/", "/library/messages/", "/library/accounts/", "/library/safari/",
                    "/library/application support/google/chrome/", "/library/application support/firefox/",
                    "/library/application support/1password/", "/library/application support/bitwarden/"]
        if dirs.contains(where: { p.contains($0) }) { return true }
        let name = url.lastPathComponent.lowercased(), ext = url.pathExtension.lowercased()
        if ["pem", "key", "p12", "pfx", "kdbx", "ppk", "keychain-db", "ovpn", "env"].contains(ext) { return true }
        if name == ".env" || name.hasPrefix(".env.") || name == ".envrc" || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519")
            || name.hasPrefix("id_ecdsa") || name.hasPrefix("credentials") || [".netrc", ".npmrc", ".pypirc", ".git-credentials", ".claude.json"].contains(name)
            || name.hasSuffix("_history") { return true }
        return p == home + "/.claude.json"
    }

    /// Apps that would run a file handed to them: Terminal, script editors, launchers.
    static func runsScripts(_ app: URL) -> Bool {
        let id = Bundle(url: app)?.bundleIdentifier?.lowercased() ?? ""
        let name = app.deletingPathExtension().lastPathComponent.lowercased()
        let runners = ["com.apple.terminal", "com.googlecode.iterm2", "org.python.pythonlauncher", "com.apple.scripteditor2",
                       "com.apple.automator", "com.apple.shortcuts", "com.apple.installer", "dev.warp.warp-stable", "com.github.wez.wezterm",
                       "net.kovidgoyal.kitty", "io.alacritty"]
        return runners.contains(id) || ["terminal", "iterm", "script editor", "python launcher", "automator", "shortcuts",
                                        "installer", "warp", "kitty", "alacritty", "wezterm"].contains(name)
    }

    /// A new turn started while an offer was still asking: put it away, unanswered.
    func cancelOffer() {
        guard caption.offering, case .asking = caption.offerRow.phase else { return }
        caption.offerRow.onChoice = nil
        caption.endOffer()
        pendingDone = nil   // the engine forgets this offer itself
        trace("Download offer put away: a new turn started.")
    }

    // MARK: Keeping

    /// Copies, saves to Notes (in a "Navi" folder) or sets a reminder in Reminders.
    /// macOS asks once before Navi may use Notes or Reminders.
    func keep(_ k: Keep, done given: @escaping (String?, String?) -> Void) {
        // A failure is shown, not only traced: the user asked for it and Claude's words say it's done.
        let done: (String?, String?) -> Void = { [weak self] said, problem in
            if said == nil, let problem { self?.caption.setKicker(Self.couldNotKeep(k.kind, problem)) }
            given(said, problem)
        }
        switch k.kind {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(k.text, forType: .string)
            done("Copied: \(k.preview)", nil)   // the engine shows what was copied
        case .note:
            let title = k.detail ?? String(k.text.prefix(40))
            // NSAppleScript is main-thread only (and one at a time).
            DispatchQueue.main.async { [weak self] in
                let problem = Self.saveNote(title: title, body: k.text)
                if problem == nil { self?.caption.setKicker("SAVED TO NOTES") }
                done(problem == nil ? "Saved to Notes: \(title)" : nil, problem)
            }
        case .remind:
            // Asking for Reminders without a usage text ends the app (a bare debug build).
            guard Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") != nil else {
                return done(nil, "Reminders can't be used from this build")
            }
            // A time Claude wrote in words ("tomorrow 9am") isn't dropped silently: no reminder
            // without the time they asked for.
            if let when = k.detail, !when.trimmingCharacters(in: .whitespaces).isEmpty, Self.date(when) == nil {
                return done(nil, "couldn't read the time \"\(when)\"")
            }
            let store = EKEventStore()
            store.requestFullAccessToReminders { [weak self] granted, _ in
                guard granted else { return DispatchQueue.main.async { done(nil, Self.remindersDenied) } }
                guard let list = store.defaultCalendarForNewReminders() else {
                    return DispatchQueue.main.async { done(nil, "there's no Reminders list to add it to") }
                }
                let r = EKReminder(eventStore: store)
                r.title = k.text
                r.calendar = list
                if let detail = k.detail, let when = Self.date(detail) {
                    // A date with no time is a day to do it, not an alert at midnight.
                    let timed = detail.contains(":")
                    r.dueDateComponents = Calendar.current.dateComponents(timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: when)
                    if timed { r.addAlarm(EKAlarm(absoluteDate: when)) }
                }
                let problem: String? = (try? store.save(r, commit: true)) == nil ? "Reminders didn't save it" : nil
                DispatchQueue.main.async {
                    if problem == nil { self?.caption.setKicker("ADDED TO REMINDERS") }
                    done(problem == nil ? "Reminder set" : nil, problem)
                }
            }
        }
    }

    /// "2026-10-30 09:00", "2026-10-30T09:00" or "2026-10-30".
    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }

    /// A new note in Notes, in a "Navi" folder. Returns why not, or nil once saved.
    static func saveNote(title: String, body: String) -> String? {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let html = "<h1>" + escapeHTML(title) + "</h1>" + body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<div>" + (escapeHTML(String($0)).isEmpty ? "<br>" : escapeHTML(String($0))) + "</div>" }.joined()
        let source = """
        tell application "Notes"
            if not (exists folder "Navi") then make new folder with properties {name:"Navi"}
            make new note at folder "Navi" with properties {body:\(quoted(html))}
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -1743: the user said no to Navi controlling Notes; only Settings can undo that.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { return notesDenied }
            return (error[NSAppleScript.errorMessage] as? String) ?? "Notes didn't save it"
        }
        return nil
    }

    static let notesDenied = "allow Navi to control Notes in System Settings › Privacy & Security › Automation"
    static let remindersDenied = "allow Navi in System Settings › Privacy & Security › Reminders"

    /// The kicker for a keep that failed: what didn't happen, then why.
    static func couldNotKeep(_ kind: Keep.Kind, _ problem: String) -> String {
        let what: String
        switch kind {
        case .copy: what = "COULDN'T COPY"
        case .note: what = "COULDN'T SAVE TO NOTES"
        case .remind: what = "COULDN'T SET THE REMINDER"
        }
        return (what + " · " + problem).uppercased()
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Downloading

    func offerDownload(_ link: String, done: @escaping (String?, String?) -> Void) {
        guard var url = URL(string: link), url.scheme?.lowercased() == "https" else {
            return done(nil, "only secure (https) links are downloaded")
        }
        url = Self.direct(url)
        generation += 1   // a new offer replaces an old one's callback
        let gen = generation
        pendingDone = done
        let done: (String?, String?) -> Void = { [weak self] path, problem in self?.finish(gen, path, problem) }
        // Ask the server for its size and name first, but don't keep the question waiting long.
        var head = URLRequest(url: url, timeoutInterval: 4)
        head.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: head) { [weak self] _, response, _ in
            let http = response as? HTTPURLResponse
            // Where it really comes from, after any redirects: that's the host the card names.
            let final = http?.url ?? url
            let size = (http?.expectedContentLength).flatMap { $0 > 0 ? $0 : nil }
            let name = Self.fileName(for: final, response: http)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }   // Esc came first
                guard final.scheme?.lowercased() == "https" else { return done(nil, "the link redirects to an insecure address") }
                if let size, size > Self.sizeCap { return done(nil, "the file is too big (over 2 GB)") }
                let host = final.host ?? "the web"
                trace("Offering a download: \(name) from \(host)\(size.map { " (\($0) bytes)" } ?? "")", content: true)
                guard self.caption.offer(file: name, size: size, from: host) else {
                    return done(nil, "the caption had gone, so the offer couldn't be shown")
                }
                self.caption.offerRow.onChoice = { [weak self] yes in
                    guard let self else { return }
                    guard yes else {
                        trace("Download declined.")
                        self.caption.endOffer()
                        return done(nil, "they said not now")
                    }
                    self.fetch(url, name: name, size: size, gen: gen, done: done)
                }
            }
        }.resume()
    }

    private func fetch(_ url: URL, name: String, size: Int64?, gen: Int, done: @escaping (String?, String?) -> Void) {
        caption.offerRow.set(.downloading(0), size: size)
        let t = URLSession.shared.downloadTask(with: url) { [weak self] temp, response, error in
            let result: Result<URL, Error> = Result {
                if let error { throw error }
                // A redirect mid-download must not have dropped to plain http.
                if let final = response?.url, final.scheme?.lowercased() != "https" {
                    throw NSError(domain: "Navi", code: 2, userInfo: [NSLocalizedDescriptionKey: "it redirected to an insecure address"])
                }
                if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                    throw NSError(domain: "Navi", code: code, userInfo: [NSLocalizedDescriptionKey: "the site answered \(code)"])
                }
                guard let temp else { throw URLError(.unknown) }
                return try Self.keep(temp, as: name, from: url)
            }
            DispatchQueue.main.async {
                // Cancelled with Esc: the file (if it landed) stays, but nothing carries on from it.
                guard let self, gen == self.generation else { return }
                self.progress = nil
                self.task = nil
                switch result {
                case .success(let saved):
                    trace("Downloaded to \(saved.path)", content: true)
                    self.caption.offerRow.set(.saved)
                    // A moment to see it landed, then Navi carries on from it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        guard gen == self.generation else { return }
                        self.caption.endOffer()
                        if Self.mustNotOpen(saved) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        done(saved.path, nil)
                    }
                case .failure(let error):
                    trace("Download failed: \(error.localizedDescription)")
                    self.caption.offerRow.set(.failed("Couldn't download it: \(error.localizedDescription)"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.caption.endOffer() }
                    done(nil, error.localizedDescription)
                }
            }
        }
        progress = t.progress.observe(\.fractionCompleted) { [weak self, weak t] p, _ in
            // A file that turns out bigger than it said is stopped at the cap.
            if p.completedUnitCount > Self.sizeCap { t?.cancel() }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.caption.offerRow.set(.downloading(p.fractionCompleted), size: size)
            }
        }
        task = t
        t.resume()
    }

    /// A GitHub "blob" page is the file's web page; the raw file is what's wanted.
    static func direct(_ url: URL) -> URL {
        guard url.host == "github.com", url.path.contains("/blob/") else { return url }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2] == "blob" else { return url }
        let raw = "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/" + parts[3...].joined(separator: "/")
        return URL(string: raw) ?? url
    }

    /// The biggest download Navi will offer.
    static let sizeCap: Int64 = 2_000_000_000

    static func fileName(for url: URL, response: HTTPURLResponse?) -> String {
        if let cd = response?.value(forHTTPHeaderField: "Content-Disposition") {
            // RFC 5987's filename*=UTF-8''name wins over a plain filename=.
            if let r = cd.range(of: #"filename\*=[^']*'[^']*'([^;]+)"#, options: .regularExpression) {
                let raw = String(cd[r]).replacingOccurrences(of: #"^filename\*=[^']*'[^']*'"#, with: "", options: .regularExpression)
                return safeName(raw.removingPercentEncoding ?? raw)
            }
            if let r = cd.range(of: #"filename="?([^";]+)"?"#, options: .regularExpression) {
                return safeName(String(cd[r]).replacingOccurrences(of: #"^filename="?|"$"#, with: "", options: .regularExpression))
            }
        }
        return safeName(url.lastPathComponent)
    }

    /// A plain file name for Downloads: no folders, no leading dots, never "." or "..".
    static func safeName(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        var name = (decoded.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        name = String(name.drop(while: { $0 == "." || $0 == " " })).replacingOccurrences(of: ":", with: "-")
        return name.isEmpty || name == "/" ? "download" : String(name.prefix(200))
    }

    /// Moves the download into Downloads under a name that doesn't overwrite anything,
    /// marked as downloaded from the web, as Safari would mark it.
    static func keep(_ temp: URL, as name: String, from source: URL) throws -> URL {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        let name = safeName(name)
        var dest = downloads.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        // Belt and braces: whatever the name, the file lands inside Downloads.
        guard dest.standardizedFileURL.path.hasPrefix(downloads.standardizedFileURL.path + "/") else {
            throw NSError(domain: "Navi", code: 1, userInfo: [NSLocalizedDescriptionKey: "that file name points outside Downloads"])
        }
        // Quarantined before it's where Finder can see it (the flag moves with the file).
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Navi",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                                       kLSQuarantineDataURLKey as String: source]
        var marked = temp
        do { try marked.setResourceValues(values) } catch { trace("Download: couldn't mark it as from the web (\(error.localizedDescription)).") }
        try fm.moveItem(at: temp, to: dest)
        // A move across volumes can lose it: check, and try once more where it landed.
        var landed = dest
        if (try? landed.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties == nil {
            do { try landed.setResourceValues(values) } catch {
                trace("Download: \(dest.lastPathComponent) isn't marked as downloaded (\(error.localizedDescription)); macOS won't warn before it opens.", content: true)
            }
        }
        return dest
    }
}
