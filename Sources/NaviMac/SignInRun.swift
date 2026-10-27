import Foundation

extension SignIn {
    /// Runs `claude setup-token` in a pseudo-terminal (it expects one) and waits
    /// up to five minutes for the user to approve it in their browser.
    static func run(completion: @escaping (Result<String, Failure>) -> Void) {
        guard let exe = ClaudeCode.executable() else { return completion(.failure(.notInstalled)) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // A wide pseudo-terminal, so the token is printed on one line (at 80 columns it wraps).
        let quoted = "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "'"
        p.arguments = ["-q", "/dev/null", "/bin/sh", "-c", "stty cols 1000 rows 60 2>/dev/null; exec \(quoted) setup-token"]
        var env = ClaudeCode.environment(for: exe)
        env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")   // a fresh one, not the old
        env["COLUMNS"] = "1000"                              // keep the token on one line
        p.environment = env
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        // stdin stays open (and silent) until we're done: `script` forwards an end-of-file on
        // its stdin to the pseudo-terminal, and setup-token reads that as the user giving up.
        let input = Pipe()
        p.standardInput = input
        var text = ""
        var finished = false
        let lock = NSLock()
        func finish(_ r: Result<String, Failure>) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            out.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
            try? input.fileHandleForWriting.close()
            DispatchQueue.main.async { completion(r) }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock()
            text += String(decoding: d, as: UTF8.self)
            let now = text
            lock.unlock()
            if let token = token(in: now) { finish(.success(token)) }
        }
        p.terminationHandler = { _ in
            // Read anything left, then decide.
            lock.lock()
            let now = text
            lock.unlock()
            // Never keep or log the raw output: it can hold a token.
            if let token = token(in: now) { finish(.success(token)) } else { finish(.failure(.noToken(redacted(now)))) }
        }
        do { try p.run() } catch { return completion(.failure(.notInstalled)) }
        trace("Sign-in: started claude setup-token (the browser will ask the user to approve).")
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { finish(.failure(.timedOut)) }
    }
}
