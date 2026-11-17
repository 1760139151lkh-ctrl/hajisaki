import Foundation
import UIKit
import Combine
@preconcurrency import AVFoundation

/// One owner for optional theater audio. Construction never activates an audio session.
@MainActor final class TheaterAudio: NSObject, ObservableObject {
    enum Cue: String, CaseIterable, Hashable {
        case send, reply, effort
        fileprivate var filename: String {
            switch self {
            case .send: return "send-felt-c6"
            case .reply: return "reply-major-nine"
            case .effort: return "effort-watch-click"
            }
        }
    }

    static let shared = TheaterAudio()
    @Published private(set) var effectsEnabled = false
    @Published private(set) var ambienceEnabled = false
    @Published private(set) var isAmbiencePlaying = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isSuspended = false
    @Published private(set) var notice: String?

    private let speech = AVSpeechSynthesizer()
    private var cues: [Cue: AVAudioPlayer] = [:]
    private var ambience: AVAudioPlayer?
    private var speechRequests: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []
    private var ownsSession = false
    private var captureOwnsSession = false
    private var interrupted = false
    private var routePaused = false
    private var manuallyStopped = false
    private var appActive = true

    private override init() {
        super.init()
        speech.delegate = self
        speech.usesApplicationAudioSession = true
        appActive = UIApplication.shared.applicationState == .active
        observe(AVAudioSession.interruptionNotification) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            self?.handleInterruption(type: type, options: options)
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let self, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            // Removing headphones must not send private speech to the loudspeaker.
            self.routePaused = true; self.stopOutputs(); self.deactivateOwnedSession(); self.updateSuspension()
        }
        observe(AVAudioSession.silenceSecondaryAudioHintNotification) { [weak self] _ in self?.refreshAmbience() }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            guard let self else { return }
            self.stopOutputs(); self.cues.removeAll(); self.ambience = nil; self.ownsSession = false
            self.refreshAmbience()
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            guard let self else { return }
            self.appActive = false; self.stopOutputs(); self.deactivateOwnedSession(); self.updateSuspension()
        }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            guard let self else { return }
            self.appActive = true; self.updateSuspension(); self.refreshAmbience()
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    /// Call with the user's preferences; both switches are independently off by default.
    func configure(effectsEnabled: Bool, ambienceEnabled: Bool) {
        let changed = self.effectsEnabled != effectsEnabled || self.ambienceEnabled != ambienceEnabled
        self.effectsEnabled = effectsEnabled; self.ambienceEnabled = ambienceEnabled
        if changed { manuallyStopped = false; routePaused = false; notice = nil }
        if !effectsEnabled { cues.values.forEach { $0.stop() } }
        if !ambienceEnabled { stopAmbience() }
        updateSuspension(); refreshAmbience()
        if !ambienceEnabled && !isSpeaking && !cues.values.contains(where: \.isPlaying) { deactivateOwnedSession() }
    }

    func play(_ cue: Cue) {
        guard effectsEnabled, canOutput, speechRequests.isEmpty else { return }
        do {
            try activateAmbientSession()
            let player: AVAudioPlayer
            if let cached = cues[cue] { player = cached }
            else {
                player = try AVAudioPlayer(contentsOf: resource(cue.filename))
                player.delegate = self; player.volume = 0.35
                player.prepareToPlay(); cues[cue] = player
            }
            player.stop(); player.currentTime = 0
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
        } catch { notice = "琴音暂时没能响起。"; deactivateIfQuiet() }
    }

    /// Explicit user action. Does not run when new messages arrive.
    func speak(text: String) {
        guard !captureOwnsSession, !interrupted, appActive else {
            notice = captureOwnsSession ? "先收好这段录音，再念给你听。" : "朗读已暂停，稍后再点一次。"
            return
        }
        let readable = Self.spokenText(from: text)
        guard !readable.isEmpty else { notice = "这段只有代码或链接，就不念出来了。"; return }
        stopSpeechWithoutRestoringAmbience(); stopAmbience(); cues.values.forEach { $0.stop() }
        manuallyStopped = false; routePaused = false; notice = nil; updateSuspension()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true); ownsSession = true
            let voiceLanguage = readable.range(of: "\\p{Han}", options: .regularExpression) == nil ? "en-US" : "zh-CN"
            for portion in Self.speechChunks(readable) {
                let utterance = AVSpeechUtterance(string: portion)
                utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                utterance.postUtteranceDelay = 0.12
                speechRequests.insert(ObjectIdentifier(utterance)); speech.speak(utterance)
            }
            isSpeaking = speech.isSpeaking
        } catch { notice = "朗读暂时没能开始，文字仍在。"; stopSpeechWithoutRestoringAmbience(); refreshAmbience() }
    }

    func stopSpeech() {
        stopSpeechWithoutRestoringAmbience(); refreshAmbience(); deactivateIfQuiet()
    }

    /// Immediate stop, including queued speech. A later preference change or explicit speak is required to resume.
    func stopAll() {
        manuallyStopped = true; stopOutputs(); deactivateOwnedSession(); updateSuspension()
    }

    /// VoiceNoteSheet calls this before acquiring its recording or original-playback session.
    func suspendForRecording() {
        guard !captureOwnsSession else { return }
        stopOutputs(); deactivateOwnedSession(); captureOwnsSession = true; updateSuspension()
    }

    /// Resumes only previously enabled ambience; never resumes speech or an old effect.
    func resumeAfterRecording() {
        guard captureOwnsSession else { return }
        captureOwnsSession = false; updateSuspension(); refreshAmbience()
    }

    private var canOutput: Bool { appActive && !captureOwnsSession && !interrupted && !routePaused && !manuallyStopped }
    private func updateSuspension() { isSuspended = !appActive || captureOwnsSession || interrupted || routePaused || manuallyStopped }

    private func activateAmbientSession() throws {
        guard !captureOwnsSession else { return }
        let session = AVAudioSession.sharedInstance()
        // Ambient respects the device's silent setting and mixes with other apps.
        try session.setCategory(.ambient, mode: .default)
        try session.setActive(true); ownsSession = true
    }

    private func refreshAmbience() {
        guard ambienceEnabled, canOutput, speechRequests.isEmpty,
              !AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint else {
            stopAmbience(); deactivateIfQuiet(); return
        }
        if ambience?.isPlaying == true { isAmbiencePlaying = true; return }
        do {
            try activateAmbientSession()
            if ambience == nil {
                let player = try AVAudioPlayer(contentsOf: resource("room-stereo"))
                player.delegate = self; player.numberOfLoops = -1; player.volume = 0.30
                player.prepareToPlay(); ambience = player
            }
            guard ambience?.play() == true else { throw CocoaError(.fileReadUnknown) }
            isAmbiencePlaying = true
        } catch { notice = "雨声暂时没能响起。"; stopAmbience(); deactivateIfQuiet() }
    }

    private func stopAmbience() { ambience?.pause(); isAmbiencePlaying = false }
    private func stopSpeechWithoutRestoringAmbience() {
        speechRequests.removeAll(); speech.stopSpeaking(at: .immediate); isSpeaking = false
    }
    private func stopOutputs() {
        cues.values.forEach { $0.stop() }; stopAmbience(); stopSpeechWithoutRestoringAmbience()
    }
    private func deactivateIfQuiet() {
        if !isAmbiencePlaying && speechRequests.isEmpty && !cues.values.contains(where: \.isPlaying) { deactivateOwnedSession() }
    }
    private func deactivateOwnedSession() {
        guard ownsSession, !captureOwnsSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        ownsSession = false
    }

    private func resource(_ name: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "audio") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
    private func observe(_ name: Notification.Name, action: @escaping @MainActor (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            Task { @MainActor in action(note) }
        })
    }
    private func handleInterruption(type: UInt?, options: UInt) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            interrupted = true; stopOutputs(); ownsSession = false; updateSuspension()
        case .ended:
            interrupted = false
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            if !shouldResume { routePaused = true }
            updateSuspension()
            if shouldResume { refreshAmbience() }
        @unknown default: break
        }
    }

    fileprivate func speechFinished(_ utterance: AVSpeechUtterance) {
        guard speechRequests.remove(ObjectIdentifier(utterance)) != nil else { return }
        isSpeaking = !speechRequests.isEmpty && speech.isSpeaking
        if speechRequests.isEmpty { isSpeaking = false; refreshAmbience(); deactivateIfQuiet() }
    }

    /// A production formatter shared by all speak buttons. Unclosed streamed code stays silent.
    static func spokenText(from markdown: String) -> String {
        var lines: [String] = []
        var fence: (Character, Int)?
        var inHTMLCode = false
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.contains("<pre") || lower.contains("<code") {
                inHTMLCode = !(lower.contains("</pre>") || lower.contains("</code>")); continue
            }
            if inHTMLCode {
                if lower.contains("</pre>") || lower.contains("</code>") { inHTMLCode = false }
                continue
            }
            if let open = fence {
                let run = trimmed.prefix { $0 == open.0 }
                if run.count >= open.1 && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                continue
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }.count
                if run >= 3 { fence = (first, run); continue }
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { continue }
            var prose = trimmed
            prose = prose.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            prose = prose.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            prose = prose.replacingOccurrences(of: #"(?i)(?:(?:https?|ftp|file)://|www\.)[^\s<>]+"#, with: "", options: .regularExpression)
            prose = prose.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            prose = prose.replacingOccurrences(of: #"^\s{0,3}(?:#{1,6}\s+|>\s*|[-*+]\s+)"#, with: "", options: .regularExpression)
            prose = prose.replacingOccurrences(of: #"`([^`]{1,40})`"#, with: "$1", options: .regularExpression)
            prose = prose.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
            prose = prose.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
            prose = prose.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
            if !prose.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(prose) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func speechChunks(_ text: String) -> [String] {
        var result: [String] = []; var current = ""
        for character in text {
            current.append(character)
            if current.count >= 600 || (current.count >= 180 && "。！？.!?\n".contains(character)) {
                result.append(current); current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

extension TheaterAudio: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.speechRequests.contains(ObjectIdentifier(utterance)) else { return }
            self.isSpeaking = true
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speechFinished(utterance) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speechFinished(utterance) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.deactivateIfQuiet() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.ambience === player { self.isAmbiencePlaying = false }
            self.notice = "这段琴音暂时没能继续。"; self.deactivateIfQuiet()
        }
    }
}
