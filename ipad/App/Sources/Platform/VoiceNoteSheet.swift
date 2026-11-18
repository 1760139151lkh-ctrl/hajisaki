import SwiftUI
import UIKit
@preconcurrency import AVFoundation

/// Opening this sheet never activates a microphone. Only the recording button asks permission.
struct VoiceNoteSheet: View {
    let onKeep: (URL) -> Void
    @StateObject private var capture = VoiceCapture()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theaterPalette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 20) {
                        VStack(spacing: 10) {
                            CameoPortrait(image: "listening_attentive", size: 76)
                                .padding(5).background(palette.selection, in: Circle())
                            Text(capture.isRecording ? "我在听，慢慢说。" : "想说的话，说给我听吧。")
                                .font(.theaterSerif(16)).foregroundStyle(palette.secondary)
                        }
                        Text(capture.durationLabel)
                            .font(.system(size: 48, weight: .light, design: .serif)).monospacedDigit()
                            .accessibilityLabel("录音时长 \(capture.durationLabel)")
                        VoiceLevelView(levels: capture.levels, color: capture.isRecording ? palette.rose : palette.blue)
                            .frame(height: 64).accessibilityHidden(true)
                        HStack(spacing: 14) {
                            if capture.isRecording {
                                Button("暂停") { capture.pause() }
                                    .buttonStyle(TheaterActionStyle(prominent: true))
                            } else {
                                Button(capture.hasAudio ? "继续录音" : "开始录音") {
                                    Task { await capture.start() }
                                }
                                .buttonStyle(TheaterActionStyle(prominent: true))
                                .disabled(capture.isBusy || !capture.isReady)
                            }
                            if capture.hasAudio && !capture.isRecording {
                                Button(capture.isPlaying ? "停止回听" : "回听") {
                                    if capture.isPlaying { capture.stopPlayback() }
                                    else { Task { await capture.play() } }
                                }
                                .buttonStyle(TheaterActionStyle())
                                .disabled(capture.isBusy)
                            }
                        }
                        if capture.isBusy { ProgressView().tint(palette.rose) }
                        if let notice = capture.notice {
                            Text(notice).font(.footnote).foregroundStyle(palette.warning)
                                .multilineTextAlignment(.center)
                        }
                        if capture.permissionDenied {
                            Button("麦克风设置") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }.buttonStyle(TheaterActionStyle())
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)

                    if let take = capture.selected, !take.segments.isEmpty {
                        DisclosureGroup("分段原声") {
                            VStack(spacing: 12) {
                                ForEach(Array(take.segments.enumerated()), id: \.element.id) { index, segment in
                                    HStack(spacing: 12) {
                                        Text("片段 \(index + 1)")
                                        Spacer()
                                        Text(segment.readable ? VoiceCapture.formatDuration(segment.duration) : "中断片段")
                                            .foregroundStyle(palette.secondary).monospacedDigit()
                                        if let original = capture.segmentURL(segment) {
                                            ShareLink(item: original) { Text("导出") }
                                            if segment.readable {
                                                Button("带回这段") {
                                                    capture.close(); onKeep(original); dismiss()
                                                }
                                            }
                                        }
                                    }.font(.system(size: 13))
                                }
                            }.padding(.top, 14)
                        }.disabled(capture.isBusy || capture.isRecording)
                    }

                    if !capture.takes.isEmpty {
                        HStack {
                            Text("语音便笺").font(.headline)
                            Spacer()
                            Button("新录一段") { capture.newTake() }
                                .disabled(capture.isBusy || capture.isRecording)
                        }
                        VStack(spacing: 0) {
                            ForEach(capture.takes) { take in
                                Button {
                                    capture.select(take.id)
                                } label: {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(take.createdAt, format: .dateTime.month().day().hour().minute())
                                        Spacer()
                                        Text(VoiceCapture.formatDuration(take.duration)).monospacedDigit()
                                        if take.id == capture.selectedID { Text("当前").font(.caption).foregroundStyle(palette.gold) }
                                    }.font(.system(size: 15)).padding(.vertical, 15).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(capture.isBusy || capture.isRecording)
                                if take.id != capture.takes.last?.id { TheaterRule() }
                            }
                        }
                    }
                }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(palette.background).foregroundStyle(palette.text)
            .navigationTitle("语音便笺").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { capture.close(); dismiss() }.disabled(capture.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("带回对话") {
                        Task {
                            if let url = await capture.finish() {
                                onKeep(url); dismiss()
                            }
                        }
                    }.disabled(!capture.hasAudio || capture.isBusy)
                }
            }
            .interactiveDismissDisabled(capture.isBusy)
            .task { capture.restore() }
            .onDisappear { capture.close() }
        }
    }
}

private struct VoiceLevelView: View {
    let levels: [CGFloat]
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 4) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(color.opacity(0.8))
                        .frame(width: max(2, (proxy.size.width - 4 * CGFloat(levels.count - 1)) / CGFloat(levels.count)),
                               height: max(2, level * proxy.size.height))
                }
            }.frame(maxHeight: .infinity)
        }
    }
}

private struct VoiceSegment: Codable, Identifiable {
    let id: String
    let filename: String
    var duration: TimeInterval
    var readable: Bool
}

private struct VoiceTake: Codable, Identifiable {
    let id: String
    let createdAt: Date
    var segments: [VoiceSegment]
    var exportedFile: String?
    var completed: Bool
    var interrupted: Bool
    var duration: TimeInterval { segments.reduce(0) { $0 + ($1.readable ? $1.duration : 0) } }
}

@MainActor private final class VoiceCapture: NSObject, ObservableObject {
    @Published private(set) var takes: [VoiceTake] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: 32)
    @Published private(set) var notice: String?
    @Published private(set) var permissionDenied = false

    private var root: URL?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var currentSegmentID: String?
    private var operation = 0
    private var visible = true
    private var resumeAfterInterruption = false
    private var ownsAudioSession = false
    private var holdsTheaterAudio = false
    private var audioInterrupted = false

    var selected: VoiceTake? { takes.first { $0.id == selectedID } }
    var hasAudio: Bool { (selected?.duration ?? 0) > 0 || (recorder?.currentTime ?? 0) > 0 }
    var durationLabel: String { Self.formatDuration(elapsed) }

    override init() {
        super.init()
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type: type, options: options) }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                if self.isRecording { self.pause(); self.notice = "收音设备已断开，这段声音留好了。" }
                self.stopPlayback()
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pause(); self.stopPlayback(); self.notice = "录音已暂停，可以从这里接着说。"
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
                if !modes.contains("audio") { self.pause(); self.notice = "录音已暂停，回来后可以接着说。" }
            }
        })
    }

    deinit {
        meterTimer?.invalidate()
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }

    func restore() {
        guard !isReady else { return }
        visible = true
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("VoiceNotes", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            root = directory
            let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var recovered: [VoiceTake] = []
            var hasUnreadablePart = false
            for folder in folders {
                let manifest = folder.appendingPathComponent("take.json")
                guard FileManager.default.fileExists(atPath: manifest.path),
                      var take = try? JSONDecoder().decode(VoiceTake.self, from: Data(contentsOf: manifest)),
                      take.id == folder.lastPathComponent else { continue }
                for index in take.segments.indices {
                    let segment = take.segments[index]
                    guard segment.filename == URL(fileURLWithPath: segment.filename).lastPathComponent else { continue }
                    let file = folder.appendingPathComponent(segment.filename)
                    let duration = Self.readDuration(file)
                    take.segments[index].duration = duration ?? 0
                    take.segments[index].readable = duration.map { $0 > 0 } ?? false
                    if duration == nil { hasUnreadablePart = true }
                }
                recovered.append(take)
            }
            takes = recovered.sorted { $0.createdAt > $1.createdAt }
            selectedID = takes.first?.id; elapsed = selected?.duration ?? 0
            isReady = true
            if hasUnreadablePart { notice = "部分中断片段暂时无法打开；原声文件仍留着。" }
        } catch { notice = "语音便笺暂时没能展开，请重新打开。" }
    }

    func newTake() {
        guard !isRecording, !isBusy else { return }
        stopPlayback(); selectedID = nil; elapsed = 0; notice = nil; levels = Array(repeating: 0, count: 32)
    }

    func select(_ id: String) {
        guard !isRecording, !isBusy, takes.contains(where: { $0.id == id }) else { return }
        stopPlayback(); selectedID = id; elapsed = selected?.duration ?? 0; notice = nil
    }

    func start() async {
        guard isReady, !isBusy, !isRecording, visible else { return }
        stopPlayback(releaseSession: false); notice = nil; permissionDenied = false; isBusy = true
        operation += 1; let generation = operation
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard visible, generation == operation else { isBusy = false; return }
        guard permitted else {
            permissionDenied = true; notice = "麦克风还没获准，先把想说的留在文字里也好。"; isBusy = false
            deactivateAudio(); return
        }
        do {
            try activateAudio(category: .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            if selectedID == nil { try createTake() }
            resumeAfterInterruption = false
            try beginSegment()
            isBusy = false
        } catch {
            isRecording = false; isBusy = false
            notice = "这一段还没开始录，请检查麦克风后再试。"
            deactivateAudio()
        }
    }

    private func createTake() throws {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        let take = VoiceTake(id: UUID().uuidString, createdAt: Date(), segments: [], exportedFile: nil, completed: false, interrupted: false)
        let directory = root.appendingPathComponent(take.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        takes.insert(take, at: 0); selectedID = take.id; try persist()
    }

    private func beginSegment() throws {
        guard let directory = selectedDirectory, let index = selectedIndex else { throw CocoaError(.fileNoSuchFile) }
        let id = UUID().uuidString
        let filename = "segment-\(id).m4a"
        let url = directory.appendingPathComponent(filename)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let next = try AVAudioRecorder(url: url, settings: settings)
        next.delegate = self; next.isMeteringEnabled = true
        takes[index].segments.append(VoiceSegment(id: id, filename: filename, duration: 0, readable: false))
        takes[index].exportedFile = nil; takes[index].completed = false
        try persist() // Journal the original filename before the microphone starts.
        guard next.prepareToRecord(), next.record(forDuration: 30) else { throw CocoaError(.fileWriteUnknown) }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        recorder = next; currentSegmentID = id; isRecording = true
        startMeter()
    }

    func pause() {
        resumeAfterInterruption = false
        guard recorder != nil else { isRecording = false; return }
        finalizeSegment()
        deactivateAudio()
    }

    private func finalizeSegment() {
        isRecording = false; meterTimer?.invalidate(); meterTimer = nil
        let finished = recorder; let segmentID = currentSegmentID
        recorder = nil; currentSegmentID = nil
        finished?.stop()
        guard let finished, let segmentID, let index = selectedIndex,
              let part = takes[index].segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let duration = Self.readDuration(finished.url)
        takes[index].segments[part].duration = duration ?? 0
        takes[index].segments[part].readable = duration.map { $0 > 0 } ?? false
        elapsed = takes[index].duration
        do { try persist() }
        catch { notice = "原声已经留下，便笺索引还没存好。" }
        if duration == nil { notice = "这段录音暂时无法打开，原声文件仍留着。" }
    }

    private func segmentEnded(_ finished: AVAudioRecorder, success: Bool) {
        guard recorder === finished else { return }
        let shouldContinue = isRecording && visible
        finalizeSegment()
        guard success, shouldContinue else {
            if !success { notice = "录音已停下，已完成的片段还在。" }
            deactivateAudio(); return
        }
        do { try beginSegment() }
        catch { notice = "录音已暂停，已完成的片段还在。"; deactivateAudio() }
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder, self.isRecording else { return }
                recorder.updateMeters()
                let amplitude = CGFloat(pow(10, Double(recorder.averagePower(forChannel: 0)) / 20))
                self.levels = Array(self.levels.dropFirst()) + [min(1, amplitude * 4)]
                self.elapsed = (self.selected?.duration ?? 0) + recorder.currentTime
            }
        }
    }

    private func interruption(type: UInt?, options: UInt) {
        guard let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch interruption {
        case .began:
            audioInterrupted = true
            let recording = isRecording
            pause(); stopPlayback(); resumeAfterInterruption = recording
            if let index = selectedIndex, recording {
                takes[index].interrupted = true; try? persist()
                notice = "录音被打断了，前面的片段留好了。"
            }
        case .ended:
            audioInterrupted = false
            let shouldResume = resumeAfterInterruption && visible && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            resumeAfterInterruption = false
            if shouldResume { Task { await start() } }
            else { deactivateAudio() }
        @unknown default: break
        }
    }

    func play() async {
        guard !isBusy, !isRecording, hasAudio else { return }
        isBusy = true; notice = nil
        do {
            let url = try await exportSelected()
            guard visible else { isBusy = false; return }
            try activateAudio(category: .playback, mode: .spokenAudio)
            let next = try AVAudioPlayer(contentsOf: url); next.delegate = self
            guard next.prepareToPlay(), next.play() else { throw CocoaError(.fileReadUnknown) }
            player = next; isPlaying = true; isBusy = false
        } catch { notice = "这段声音暂时没能播放，原声仍留着。"; isBusy = false; deactivateAudio() }
    }

    func stopPlayback(releaseSession: Bool = true) {
        player?.stop(); player = nil; isPlaying = false
        if !isRecording && releaseSession { deactivateAudio() }
    }

    func finish() async -> URL? {
        guard !isBusy else { return nil }
        pause(); stopPlayback()
        guard hasAudio else { return nil }
        if selected?.segments.contains(where: { !$0.readable }) == true {
            notice = "有一个中断片段暂时无法打开，可分别带回原声。"; return nil
        }
        isBusy = true; notice = nil
        do {
            let result = try await exportSelected()
            guard visible else { isBusy = false; return nil }
            if let index = selectedIndex { takes[index].completed = true; try persist() }
            isBusy = false; return result
        } catch { notice = "原声仍在，暂时没能整理成一段。"; isBusy = false; return nil }
    }

    private func exportSelected() async throws -> URL {
        guard let take = selected, let directory = selectedDirectory else { throw CocoaError(.fileNoSuchFile) }
        if let filename = take.exportedFile {
            let existing = directory.appendingPathComponent(filename)
            if (Self.readDuration(existing) ?? 0) > 0 { return existing }
        }
        let readable = take.segments.filter { $0.readable && $0.duration > 0 }
        guard !readable.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        // Refuse to silently omit an interrupted, unreadable fragment from a claimed complete take.
        guard readable.count == take.segments.count else { throw CocoaError(.fileReadCorruptFile) }
        if readable.count == 1 { return directory.appendingPathComponent(readable[0].filename) }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var insertionTime = CMTime.zero
        for segment in readable {
            let asset = AVURLAsset(url: directory.appendingPathComponent(segment.filename))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else { throw CocoaError(.fileReadCorruptFile) }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: insertionTime)
            insertionTime = CMTimeAdd(insertionTime, duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let filename = "语音便笺-\(UUID().uuidString.prefix(8)).m4a"
        let destination = directory.appendingPathComponent(filename)
        try await exporter.export(to: destination, as: .m4a)
        guard (Self.readDuration(destination) ?? 0) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        if let index = takes.firstIndex(where: { $0.id == take.id }) {
            takes[index].exportedFile = filename; try persist(id: take.id)
        }
        return destination
    }

    func close() {
        visible = false; operation += 1; resumeAfterInterruption = false; audioInterrupted = false
        pause(); stopPlayback()
    }

    private var selectedIndex: Int? { takes.firstIndex { $0.id == selectedID } }
    private var selectedDirectory: URL? {
        guard let root, let selectedID else { return nil }
        return root.appendingPathComponent(selectedID, isDirectory: true)
    }
    func segmentURL(_ segment: VoiceSegment) -> URL? {
        guard let directory = selectedDirectory,
              segment.filename == URL(fileURLWithPath: segment.filename).lastPathComponent else { return nil }
        let file = directory.appendingPathComponent(segment.filename)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    private func persist(id: String? = nil) throws {
        guard let root, let take = takes.first(where: { $0.id == (id ?? selectedID) }) else { throw CocoaError(.fileNoSuchFile) }
        let manifest = root.appendingPathComponent(take.id).appendingPathComponent("take.json")
        try JSONEncoder().encode(take).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private static func readDuration(_ url: URL) -> TimeInterval? {
        guard let audio = try? AVAudioFile(forReading: url), audio.processingFormat.sampleRate > 0 else { return nil }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }
    private func activateAudio(category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                               options: AVAudioSession.CategoryOptions = []) throws {
        if !holdsTheaterAudio { TheaterAudio.shared.suspendForRecording(); holdsTheaterAudio = true }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(category, mode: mode, options: options)
        try audio.setActive(true); ownsAudioSession = true
    }
    private func deactivateAudio() {
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
        if holdsTheaterAudio && !audioInterrupted {
            holdsTheaterAudio = false; TheaterAudio.shared.resumeAfterRecording()
        }
    }
    static func formatDuration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

extension VoiceCapture: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.segmentEnded(recorder, success: flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.pause(); self.notice = "录音已停下，已完成的片段还在。"
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stopPlayback() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.stopPlayback(); self?.notice = "这段声音暂时没能播放，原声仍留着。" }
    }
}
