import AVFoundation
import Foundation

#if SP_KOKORO
import KokoroTTS

/// The on-device neural voice: Kokoro 82M on Core ML (Apache 2.0). Speaks one
/// sentence at a time through an audio engine and reports each word as it
/// starts, from the timings Kokoro predicted for it.
///
/// The model lives in the app's Resources/Kokoro (in a dev build, next to the
/// package in tools/kokoro/bundle). Without it, `speak` returns false and the
/// Narrator falls back to the Mac's own voices.
@MainActor
final class KokoroVoice {
    static let shared = KokoroVoice()

    /// Voices in the bundle, British first. IDs are Kokoro's.
    nonisolated static let voices: [(id: String, name: String)] = [
        ("bf_emma", "Emma (British)"), ("bf_isabella", "Isabella (British)"),
        ("bm_george", "George (British)"), ("bm_fable", "Fable (British)"),
        ("bm_lewis", "Lewis (British)"), ("af_heart", "Heart (American)"),
    ]
    nonisolated static let defaultVoice = "bf_emma"

    private var loading: Task<KokoroTTS?, Never>?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var generation = 0
    private var finishing: CheckedContinuation<Void, Never>?
    private(set) var isSpeaking = false
    private var wordTimer: DispatchSourceTimer?

    /// Where the model bundle is, if it's there.
    nonisolated static var bundleURL: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Kokoro"),
            // A development run: the Kokoro folder the build used (NAVI_KOKORO_DIR).
            ProcessInfo.processInfo.environment["NAVI_KOKORO_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("bundle") },
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("KokoroRuntimeManifest.json").path)
        }
    }

    nonisolated static var available: Bool { bundleURL != nil }

    /// Loads and warms the model in the background. The first load compiles
    /// the Core ML models (about 10 s, cached afterwards); later ones take
    /// about a second.
    @discardableResult
    func load() -> Task<KokoroTTS?, Never> {
        if let loading { return loading }
        let task = Task<KokoroTTS?, Never>.detached(priority: .utility) {
            guard let root = KokoroVoice.bundleURL else { return nil }
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("local.screenpointer/Kokoro", isDirectory: true)
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let started = Date()
            do {
                let tts = try await KokoroTTS.load(resources: .directory(root, compiledModelsDirectory: cache))
                try await tts.prewarm(text: "Hello there.", voice: KokoroVoiceID(rawValue: KokoroVoice.defaultVoice))
                await MainActor.run { trace("Kokoro ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s") }
                return tts
            } catch {
                await MainActor.run { trace("Kokoro failed to load: \(error)") }
                return nil
            }
        }
        loading = task
        return task
    }

    /// Speaks `text` and returns once it has been heard or stopped. Returns
    /// false, having said nothing, if Kokoro isn't available.
    func speak(_ text: String, voice: String, onWord: @escaping (String) -> Void) async -> Bool {
        guard let tts = await load().value else { return false }
        generation += 1
        let mine = generation
        let started = Date()
        let result: (audio: KokoroAudio, wordStarts: [Double])
        do {
            result = try await tts.synthesizeTimed(text, voice: KokoroVoiceID(rawValue: voice))
        } catch {
            trace("Kokoro synthesis failed: \(error)")
            return false
        }
        guard mine == generation else { return true }  // stopped while synthesising
        trace("Kokoro: \(String(format: "%.2f", Date().timeIntervalSince(started))) s for \(String(format: "%.1f", result.audio.durationSeconds)) s of speech")
        let audio = KokoroAudio(samples: Self.trimmingTrailingSilence(result.audio.samples), sampleRate: result.audio.sampleRate)
        guard let buffer = try? audio.makePCMBuffer(), startEngine(for: buffer.format) else { return false }

        isSpeaking = true
        let words = Self.wordTimes(text: text, starts: result.wordStarts)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishing = c
            // The player's clock keeps counting across sentences until it is
            // stopped, so restart it: word times are measured from zero.
            player.stop()
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.finish(mine) }
            }
            player.play()
            followWords(words, generation: mine, onWord: onWord)
        }
        return true
    }

    /// Fires each word as playback reaches it, read from the player's own
    /// clock. A strict timer, because macOS otherwise bunches timers together
    /// and words would land in clumps.
    private func followWords(_ words: [(String, Double)], generation mine: Int, onWord: @escaping (String) -> Void) {
        wordTimer?.cancel()
        var next = 0
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(15), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine, self.isSpeaking, next < words.count else {
                    timer.cancel()
                    return
                }
                guard let nodeTime = self.player.lastRenderTime,
                      let t = self.player.playerTime(forNodeTime: nodeTime) else { return }
                let played = Double(t.sampleTime) / t.sampleRate
                while next < words.count, words[next].1 <= played {
                    onWord(words[next].0)
                    next += 1
                }
            }
        }
        wordTimer = timer
        timer.resume()
    }

    func stop() {
        generation += 1
        player.stop()
        finish(generation)
    }

    /// Ends the current sentence. Completions from buffers stopped earlier
    /// carry an older generation and are ignored.
    private func finish(_ gen: Int) {
        guard gen == generation else { return }
        isSpeaking = false
        finishing?.resume()
        finishing = nil
    }

    private func startEngine(for format: AVAudioFormat) -> Bool {
        if self.format != format {
            if self.format == nil { engine.attach(player) }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                trace("Kokoro audio engine failed: \(error)")
                return false
            }
        }
        return true
    }
}
#else
/// Built without the Kokoro voice (no `.with-kokoro` file next to Package.swift):
/// answers aren't spoken with it, and the Mac's own voices are the only choice.
@MainActor
final class KokoroVoice {
    static let shared = KokoroVoice()
    nonisolated static let voices: [(id: String, name: String)] = []
    nonisolated static let defaultVoice = ""
    nonisolated static var available: Bool { false }
    var isSpeaking: Bool { false }
    @discardableResult func load() -> Task<Void, Never> { Task {} }
    func speak(_ text: String, voice: String, onWord: @escaping (String) -> Void) async -> Bool { false }
    func stop() {}
}
#endif

extension KokoroVoice {
    /// Drops the quiet tail Kokoro leaves after the last word, keeping 80 ms,
    /// so the next sentence follows without a long pause.
    nonisolated static func trimmingTrailingSilence(_ samples: [Float], sampleRate: Int = 24_000) -> [Float] {
        guard let last = samples.lastIndex(where: { abs($0) > 0.01 }) else { return samples }
        return Array(samples.prefix(min(samples.count, last + 1 + sampleRate * 80 / 1000)))
    }

    /// Pairs each word of `text` with when it starts. Kokoro times words as
    /// it pronounced them; when that count differs from the text's (numbers
    /// read as several words, say), words are spread across the timings in order.
    nonisolated static func wordTimes(text: String, starts: [Double]) -> [(String, Double)] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, !starts.isEmpty else { return [] }
        if words.count == starts.count { return Array(zip(words, starts)) }
        return words.enumerated().map { i, w in
            (w, starts[min(starts.count - 1, i * starts.count / words.count)])
        }
    }
}
