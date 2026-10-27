import Foundation

/// "Connect Claude" in one click, for people who've never opened Terminal: install
/// Claude Code if it isn't here, then Navi's own sign-in in the browser.
///
/// Installing runs Anthropic's own installer (https://claude.ai/install.sh) with no
/// terminal: it fetches the latest Claude Code, checks its SHA-256 against Anthropic's
/// manifest, and sets it up under the user's home folder (~/.local/bin/claude), exactly
/// as the documented Terminal command does. Nothing is installed anywhere else, and it
/// runs only from the user's click.
///
/// Signing in is `SignIn.run` (`claude setup-token`): the browser opens on Claude's
/// usual sign-in, and the year-long token it prints goes into Navi's Keychain entry.
enum ConnectClaude {
    enum Stage { case installing, signingIn }

    static let installer = URL(string: "https://claude.ai/install.sh")!
    /// The app resets its warm `claude` once there's a token (AppController sets it).
    static var onConnected: (() -> Void)?
    private(set) static var running = false

    /// Installs if needed, then signs in. `done` gets nil once connected, else what went
    /// wrong in a sentence (and Terminal stays the fallback).
    static func run(stage: @escaping (Stage) -> Void, done: @escaping (String?) -> Void) {
        guard !running else { return }
        running = true
        let finish: (String?) -> Void = { problem in
            running = false
            done(problem)
        }
        let signIn = {
            stage(.signingIn)
            SignIn.run { result in
                switch result {
                case .success(let token):
                    guard Keychain.setClaudeToken(token) else {
                        trace("Connect: the Keychain wouldn't save the token.")
                        return finish("Your Mac's Keychain wouldn't save the sign-in. Unlock it and try again.")
                    }
                    trace("Connect: signed in with Navi's own token.")
                    onConnected?()
                    MainActor.assumeIsolated { Connection.shared.refresh() }
                    finish(nil)
                case .failure(.timedOut):
                    finish("The sign-in wasn't approved in time. Try again when you're ready.")
                case .failure(.notInstalled):
                    finish("Claude Code didn't install properly. Try again, or install it from Terminal.")
                case .failure(.noToken(let tail)):
                    trace("Connect: no token from setup-token: \(tail)")
                    finish("The sign-in didn't finish. If your browser said you need a Claude plan, Pro or above works.")
                }
            }
        }
        if ClaudeCode.executable() != nil { return signIn() }
        stage(.installing)
        install { problem in
            if let problem { return finish(problem) }
            signIn()
        }
    }

    /// Runs Anthropic's installer without a terminal. `home` stands in for the user's
    /// home folder (the self-check installs into a throwaway one).
    static func install(home: String = NSHomeDirectory(), done: @escaping (String?) -> Void) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("navi-claude-install-\(UUID().uuidString).sh")
        var request = URLRequest(url: installer, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        trace("Connect: fetching Claude Code's installer from claude.ai.")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Only Anthropic's script: https from claude.ai, small, and a bash script.
            guard error == nil, status == 200, response?.url?.host?.hasSuffix("claude.ai") == true, let data,
                  data.count < 512 * 1024, String(decoding: data.prefix(64), as: UTF8.self).hasPrefix("#!") else {
                trace("Connect: couldn't fetch the installer (status \(status), \(error?.localizedDescription ?? "no error")).")
                return DispatchQueue.main.async { done("Couldn't reach claude.ai to download Claude Code. Check your internet and try again.") }
            }
            do { try data.write(to: script) } catch {
                return DispatchQueue.main.async { done("Couldn't save the installer. Try again.") }
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            p.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                             "TMPDIR": FileManager.default.temporaryDirectory.path]
            p.currentDirectoryURL = URL(fileURLWithPath: home)
            p.standardInput = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            var text = Data()
            let lock = NSLock()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                lock.lock(); text.append(d); lock.unlock()
            }
            let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
            p.terminationHandler = { proc in
                timeout.cancel()
                out.fileHandleForReading.readabilityHandler = nil
                try? FileManager.default.removeItem(at: script)
                lock.lock()
                let tail = String(String(decoding: text, as: UTF8.self).suffix(400))
                lock.unlock()
                trace("Connect: installer finished (exit \(proc.terminationStatus)): \(Redact.secrets(in: SignIn.clean(tail)))")
                let installed = FileManager.default.isExecutableFile(atPath: home + "/.local/bin/claude")
                DispatchQueue.main.async {
                    if proc.terminationStatus == 0, installed { return done(nil) }
                    if tail.contains("not available in your region") || tail.contains("supported-countries") {
                        return done("Claude Code isn't available in your region yet.")
                    }
                    done("Claude Code didn't install. Try again, or install it from Terminal.")
                }
            }
            do { try p.run() } catch {
                return DispatchQueue.main.async { done("Couldn't start the installer. Try again.") }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
            trace("Connect: installing Claude Code into \(home == NSHomeDirectory() ? "~" : "a test folder")/.local.")
        }.resume()
    }
}
