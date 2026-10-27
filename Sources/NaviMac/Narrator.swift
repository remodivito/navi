import AppKit
import Darwin
import AudioToolbox
import AVFoundation
import CoreAudio

/// Speaks answers with an on-device voice: Kokoro when its model is
/// installed (see Kokoro.swift), otherwise the Mac's own. `speak` returns when the words
/// have been said, or straight away if `stop` cuts them off.
final class Narrator: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    /// Called with each word as it is spoken (main queue).
    var onWord: ((String) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Callers are on the main thread, like the AppKit code they live in.
    var isSpeaking: Bool { synth.isSpeaking || MainActor.assumeIsolated { KokoroVoice.shared.isSpeaking } }

    /// The Kokoro voice to use, or nil for a Mac voice. Kokoro is the default
    /// when its model is there; "kokoro:<id>" picks one of its voices.
    static var kokoroVoice: String? {
        let id = Settings.shared.voiceID
        if id.hasPrefix("kokoro:") { return KokoroVoice.available ? String(id.dropFirst(7)) : nil }
        return id.isEmpty && KokoroVoice.available ? KokoroVoice.defaultVoice : nil
    }

    /// The chosen voice's name, for the menu and the preview line.
    static var voiceName: String {
        if let k = kokoroVoice {
            let name = KokoroVoice.voices.first { $0.id == k }?.name ?? k
            return String(name.prefix { $0 != " " })
        }
        return voice()?.name ?? "this voice"
    }

    @MainActor
    func speak(_ text: String) async {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        if let k = Self.kokoroVoice,
           await KokoroVoice.shared.speak(clean, voice: k, onWord: { [weak self] in self?.onWord?($0) }) {
            return
        }
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.voice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        u.prefersAssistiveTechnologySettings = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiting[ObjectIdentifier(u)] = c
            synth.speak(u)
        }
    }

    func stop() {
        MainActor.assumeIsolated { KokoroVoice.shared.stop() }
        synth.stopSpeaking(at: .immediate)
        // Anything still queued never gets a delegate callback, so release it here.
        let pending = waiting
        waiting = [:]
        pending.values.forEach { $0.resume() }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish(u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finish(u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        let word = (u.speechString as NSString).substring(with: r)
        DispatchQueue.main.async { self.onWord?(word) }
    }

    private func finish(_ u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.waiting.removeValue(forKey: ObjectIdentifier(u))?.resume()
        }
    }

    /// Drops what shouldn't be read aloud: leftover brackets, markdown, URLs.
    static func speakable(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`#>\[\]]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: " – ", with: ", ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Voices

    /// The chosen voice, else the best installed one for the user's language
    /// (Premium, then Enhanced, then the default).
    static func voice() -> AVSpeechSynthesisVoice? {
        let id = Settings.shared.voiceID
        if !id.isEmpty, !id.hasPrefix("kokoro:"), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return choices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Installed voices for the user's language, best first. Novelty voices
    /// (Bells, Bubbles, Zarvox…) are left out.
    static func choices() -> [AVSpeechSynthesisVoice] {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(lang) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            let q = v.quality == .premium ? 3 : v.quality == .enhanced ? 2 : 1
            let r = region.map { v.language.hasSuffix($0) } == true ? 1 : 0
            return q * 10 + r
        }
        return all.sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0.name < $1.name }
    }

    static func qualityName(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }
}

/// Reads and nudges the Mac's audio state through Core Audio: mute, volume,
/// headphones, and whether something else is using the microphone.
enum Audio {
    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return ok == noErr && id != 0 ? id : nil
    }

    private static func get<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ initial: T) -> T? {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func set<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ value: T) {
        var v = value
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return }
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    private static var output: AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    private static var input: AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    static var volume: Float32? {
        output.flatMap { get($0, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, Float32(0)) }
    }

    /// True when the output is muted or turned right down, so speech would go unheard.
    static var outputSilent: Bool {
        #if DEBUG
        if NaviFiles.environment("FAKE_MUTED") == "1" { return true }
        #endif
        guard let out = output else { return false }
        if let muted = get(out, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0)), muted != 0 { return true }
        if let v = volume, v < 0.03 { return true }
        return false
    }

    /// Headphones or a Bluetooth headset, where the mic won't hear our own voice.
    static var headphones: Bool {
        guard let out = output else { return false }
        let transport = get(out, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        // Built-in output reports 'hdpn' as its data source when headphones are plugged in.
        let source = get(out, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, UInt32(0)) ?? 0
        return source == 0x6864_706E   // 'hdpn'
    }

    /// Another app is recording from a microphone: most likely a call. Uses
    /// Core Audio's per-process objects (macOS 14.2+) so our own listening
    /// doesn't count; older systems fall back to "the mic is in use at all".
    static var micBusyElsewhere: Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        if AudioObjectHasProperty(system, &addr), AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 {
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return false }
            let me = getpid()
            return ids.contains { id in
                let pid = get(id, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(0)) ?? 0
                let running = get(id, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
                return pid != me && pid > 0 && running != 0 && !isSystemProcess(pid)
            }
        }
        guard let mic = input else { return false }
        return (get(mic, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) != 0
    }

    /// macOS's own audio services (corespeechd for dictation and Siri,
    /// historicalaudiod, …) hold the mic without anyone being on a call.
    /// Only apps count: anything run from /System, /usr or /Library/Apple is not one.
    static func isSystemProcess(_ pid: pid_t) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        return ["/System/", "/usr/", "/Library/Apple/", "/sbin/", "/bin/"].contains { path.hasPrefix($0) }
    }

    /// The screen is being shared through macOS Screen Sharing.
    static var screenShared: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsShared"] as? Bool) == true
    }

    /// Turns the sound back on: clears mute and, if the volume is at zero,
    /// raises it to a comfortable level.
    static func unmute() {
        guard let out = output else { return }
        set(out, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0))
        if let v = volume, v < 0.05 {
            set(out, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, Float32(0.4))
        }
    }

    // MARK: Ducking

    private static var savedVolume: Float32?

    /// Lowers the output while the user talks, so music or a video doesn't
    /// drown them out. `restore` puts it back.
    static func duck() {
        guard savedVolume == nil, let out = output, let v = volume, v > 0.1 else { return }
        savedVolume = v
        set(out, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, Float32(v * 0.3))
    }

    static func restore() {
        guard let v = savedVolume, let out = output else { return }
        savedVolume = nil
        set(out, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, v)
    }
}
