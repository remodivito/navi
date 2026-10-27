import AppKit
import AVFoundation
import Speech

/// Hold-to-talk transcription, entirely on-device.
protocol Transcriber: AnyObject {
    /// Starts listening. `onText` gets the full transcript so far (on any queue).
    func start(hints: [String], onText: @escaping (String) -> Void) async throws
    /// Stops listening and returns the final transcript.
    func stop() async -> String
    func cancel()
}

enum Voice {
    /// Makes a live transcript read like what was meant: no filler sounds
    /// ("um", "uh", "#um"), no stray marks, no question mark dropped mid-
    /// sentence ("How do I? start" → "How do I start"), single spaces, a
    /// capital at the start.
    static func tidy(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "#", with: " ")
        // Filler sounds, with any comma that came with them.
        s = s.replacingOccurrences(of: #"(?i)\b(u+m+|u+h+m*|e+r+m+|a+h+|h+m+|m+h+m+)\b[,.]?"#, with: " ", options: .regularExpression)
        // A ? or . the recogniser put before a sentence that carries on in lower case.
        s = s.replacingOccurrences(of: #"[?.!](\s+)(?=[a-z])"#, with: "$1", options: .regularExpression)
        // Repeated or orphaned punctuation, and spaces before punctuation.
        s = s.replacingOccurrences(of: #"\s+([,.?!])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([,.?!])[,.?!]+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s,.?!]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first.isLowercase { s = first.uppercased() + s.dropFirst() }
        return s
    }

    static func make() -> Transcriber {
        if #available(macOS 26, *) { return AnalyzerTranscriber() }
        return LegacyTranscriber()
    }

    /// Mic and speech permissions. Speech authorisation is only requested when
    /// we run as a bundle with the usage string, since macOS kills the process otherwise.
    static func authorize() async -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            if !(await AVCaptureDevice.requestAccess(for: .audio)) { return "Microphone access was denied." }
        default: return "Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone."
        }
        if Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
           SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        return nil
    }

    /// Words to bias recognition towards: the front app's name plus the
    /// user's own list (one per line in Vocabulary.txt, up to 50).
    static func hints(app: NSRunningApplication?) -> [String] {
        var words = [app?.localizedName].compactMap { $0 }
        let url = NaviFiles.support.appendingPathComponent("Vocabulary.txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            words += text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(50)
        }
        return words
    }

    /// Downloads the on-device model ahead of time so the first hold isn't slow.
    static func prepare() async {
        if #available(macOS 26, *) { await AnalyzerTranscriber.installAssets() }
    }
}

/// Runs `op` but stops waiting after `seconds`. Unlike a task group, this
/// returns on timeout even if `op` ignores cancellation.
func raceTimeout(_ seconds: Double, _ op: @escaping () async -> Void) async {
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !fired { fired = true; f() } }
    }
    let once = Once()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        Task { await op(); once.run { c.resume() } }
        Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); once.run { c.resume() } }
    }
}

/// The microphone's current loudness, 0…1, for the companion cursor's waveform.
enum MicLevel {
    private static let lock = NSLock()
    private static var level: Float = 0
    static var value: Float { lock.withLock { level } }

    static func update(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(buf.frameLength)).squareRoot()
        // Roughly -50 dB → 0 and -10 dB → 1.
        let db = 20 * log10(max(rms, 1e-6))
        let v = min(1, max(0, (db + 50) / 40))
        lock.withLock { level = level * 0.5 + v * 0.5 }
    }

    static func reset() { lock.withLock { level = 0 } }
}

/// Feeds microphone audio into a converter-provided format.
enum MicError: LocalizedError {
    case notAllowed, noInput
    var errorDescription: String? {
        switch self {
        case .notAllowed: return "Navi isn't allowed to use the microphone. Turn it on in Settings › Privacy."
        case .noInput: return "There's no microphone input right now."
        }
    }
}

private final class MicTap {
    let engine = AVAudioEngine()

    func start(format target: AVAudioFormat?, deliver: @escaping (AVAudioPCMBuffer) -> Void) throws {
        // installTap raises an Objective-C exception (which ends the app) if a tap is
        // already there or the input has no usable format: rule both out first.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw MicError.notAllowed }
        if engine.isRunning { engine.stop() }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw MicError.noInput }
        let converter = target.flatMap { $0 == natural ? nil : AVAudioConverter(from: natural, to: $0) }
        input.installTap(onBus: 0, bufferSize: 4096, format: natural) { buf, _ in
            MicLevel.update(buf)
            guard let converter, let target else { return deliver(buf) }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / natural.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buf
            }
            if error == nil, out.frameLength > 0 { deliver(out) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// macOS 26+: SpeechAnalyzer + SpeechTranscriber. The model runs in a system
/// process, so it costs this app no memory and macOS handles loading it.
@available(macOS 26, *)
final class AnalyzerTranscriber: Transcriber {
    private let mic = MicTap()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    /// Bumped by every start, stop and cancel: a start still setting up when it's
    /// cancelled must not open the microphone afterwards (M18).
    private var generation = 0
    private func bump() -> Int { lock.withLock { generation += 1; return generation } }
    private func live(_ mine: Int) throws { if lock.withLock({ generation }) != mine { throw CancellationError() } }

    private var transcript: String {
        Voice.tidy(lock.withLock { finalized + volatile })
    }

    static func locale() async -> Locale {
        await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
    }

    /// macOS's dictation engine (the one behind keyboard dictation), tuned for
    /// short spoken questions: it punctuates and capitalises like typed text,
    /// rather than the raw long-form transcript. `Voice.tidy` still runs after it.
    static func makeTranscriber(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults], attributeOptions: [])
    }

    static func installAssets() async {
        let t = makeTranscriber(locale: await locale())
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await req.downloadAndInstall()
        }
    }

    func start(hints: [String], onText: @escaping (String) -> Void) async throws {
        let mine = bump()
        lock.withLock { finalized = ""; volatile = "" }
        let transcriber = Self.makeTranscriber(locale: await Self.locale())
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        try live(mine)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try live(mine)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        input = cont

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if !hints.isEmpty {
            // Biases recognition towards words on screen (app names, titles).
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = hints
            try? await analyzer.setContext(ctx)
        }

        let reading = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let s = String(r.text.characters)
                    self.lock.withLock {
                        if r.isFinal { self.finalized += s; self.volatile = "" } else { self.volatile = s }
                    }
                    onText(self.transcript)
                }
            } catch {}
        }
        results = reading

        do {
            try live(mine)
            try await analyzer.start(inputSequence: stream)
            try live(mine)   // cancelled while the analyzer started: the mic never opens
            try mic.start(format: format) { buf in cont.yield(AnalyzerInput(buffer: buf)) }
        } catch {
            cont.finish()
            reading.cancel()
            Task { await analyzer.cancelAndFinishNow() }
            if self.analyzer === analyzer { self.analyzer = nil; input = nil }
            throw error
        }
    }

    func stop() async -> String {
        _ = bump()
        mic.stop()
        input?.finish()
        input = nil
        if let analyzer {
            // Flush the last words, but don't hang the UI if it stalls.
            await raceTimeout(1.5) { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        results?.cancel()
        analyzer = nil
        return transcript
    }

    func cancel() {
        _ = bump()
        mic.stop()
        input?.finish()
        input = nil
        results?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }
}

/// macOS 14–15 fallback: SFSpeechRecognizer forced on-device where supported.
final class LegacyTranscriber: Transcriber {
    private let mic = MicTap()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var text = ""
    private var done = false
    /// Bumped by every start, stop and cancel (see AnalyzerTranscriber).
    private var generation = 0

    func start(hints: [String], onText: @escaping (String) -> Void) async throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available."])
        }
        let mine = lock.withLock { () -> Int in text = ""; done = false; generation += 1; return generation }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = hints
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            if let result { self.text = Voice.tidy(result.bestTranscription.formattedString) }
            if error != nil || result?.isFinal == true { self.done = true }
            let current = self.text
            self.lock.unlock()
            if result != nil { onText(current) }
        }
        do {
            if lock.withLock({ generation }) != mine { throw CancellationError() }
            try mic.start(format: nil) { buf in req.append(buf) }
        } catch {
            task?.cancel()
            request = nil
            throw error
        }
    }

    func stop() async -> String {
        lock.withLock { generation += 1 }
        mic.stop()
        request?.endAudio()
        // Wait briefly for the final result after the audio ends.
        for _ in 0..<24 {
            if lock.withLock({ done }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        task?.cancel()
        return lock.withLock { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func cancel() {
        lock.withLock { generation += 1 }
        mic.stop()
        task?.cancel()
        request = nil
    }
}
