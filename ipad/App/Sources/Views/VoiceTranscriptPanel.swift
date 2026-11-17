import SwiftUI
import AVFoundation

@MainActor
final class VoiceReviewDraft: ObservableObject {
    @Published var recordingURL: URL?
    @Published var artifact: Artifact?
    @Published var job: SpeechJob?
    @Published var text = ""
    @Published var busy = false
    @Published var problem: String?
    var destinationID: String?
    private(set) var libraryScope = ""
    private var operation: Task<Void, Never>?
    private var revision = UUID()
    var identifier: UUID { revision }

    func begin(url: URL, destinationID: String?, artifact: Artifact? = nil, libraryScope: String) {
        operation?.cancel()
        revision = UUID()
        recordingURL = url
        self.destinationID = destinationID
        self.libraryScope = libraryScope
        self.artifact = artifact
        job = nil; text = ""; problem = nil; busy = false
    }

    func prepare(using model: TheaterModel, newJob: Bool = false) {
        guard !busy, let recordingURL else { return }
        guard libraryScope == model.libraryScope else { refuseChangedScope(); return }
        if newJob { job = nil; text = "" }
        let current = revision
        busy = true; problem = nil
        operation = Task {
            defer { if revision == current { busy = false } }
            if artifact == nil {
                guard let uploaded = await model.upload(fileURL: recordingURL), isCurrent(current, model: model) else {
                    if revision == current { problem = "原音留在本机，接通琴房后可以继续转写。" }
                    return
                }
                artifact = uploaded
            }
            guard let artifact, isCurrent(current, model: model) else { return }
            if job == nil && !newJob {
                let previous = await model.recentTranscriptions()
                guard isCurrent(current, model: model) else { return }
                if let stored = previous.first(where: {
                    $0.artifactID == artifact.id || (!artifact.sha256.isEmpty && $0.originalAudio.sha256 == artifact.sha256 && $0.originalAudio.size == artifact.size)
                }) {
                    let savedText = await model.transcriptDraft(for: stored)
                    guard isCurrent(current, model: model) else { return }
                    job = stored
                    text = savedText ?? stored.text
                }
            }
            await model.attach(artifact, to: destinationID)
            guard isCurrent(current, model: model) else { return }
            if job == nil {
                let requested = await model.requestTranscription(for: artifact, conversationID: destinationID)
                guard isCurrent(current, model: model) else { return }
                job = requested
            }
            guard isCurrent(current, model: model), var currentJob = job else {
                if revision == current { problem = "这一段暂时没能转写，原音仍在。" }
                return
            }
            while !currentJob.isTerminal && isCurrent(current, model: model) {
                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                guard let refreshed = await model.refreshTranscription(currentJob), isCurrent(current, model: model) else {
                    if revision == current { problem = "暂时没接上转写进度，可以稍后继续查看。" }
                    return
                }
                currentJob = refreshed
                job = refreshed
            }
            guard isCurrent(current, model: model) else { return }
            if text.isEmpty {
                let savedText = await model.transcriptDraft(for: currentJob)
                guard isCurrent(current, model: model) else { return }
                text = savedText ?? currentJob.text
            }
            if currentJob.isTerminal && !currentJob.isCompleted && currentJob.status != "cancelled" {
                problem = "这一段暂时没能转写，原音仍在。"
            }
        }
    }

    func stop(using model: TheaterModel) async {
        guard libraryScope == model.libraryScope else { refuseChangedScope(); return }
        guard let job, !job.isTerminal else { return }
        let current = revision, stoppedJobID = job.id
        if let stopped = await model.stopTranscription(job), isCurrent(current, model: model), self.job?.id == stoppedJobID {
            self.job = stopped
            if text.isEmpty { text = stopped.text }
        }
    }
    func refuseChangedScope() {
        operation?.cancel(); revision = UUID(); busy = false
        problem = "这份语音属于另一间琴房，请先切回原来的连接。"
    }
    private func isCurrent(_ value: UUID, model: TheaterModel) -> Bool {
        revision == value && !Task.isCancelled && libraryScope == model.libraryScope
    }
}

@MainActor
private final class VoiceReviewPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var problem: String?
    private var player: AVAudioPlayer?
    private var url: URL?
    private var ownsAudioSession = false
    private var holdsTheaterAudio = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    func toggle(_ url: URL) {
        if playing { pause(); return }
        play(url, from: nil)
    }
    func play(_ url: URL, from seconds: Double?) {
        do {
            if self.url != url || player == nil {
                player?.stop()
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
                self.url = url
            }
            if !holdsTheaterAudio { TheaterAudio.shared.suspendForRecording(); holdsTheaterAudio = true }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            ownsAudioSession = true
            if let seconds { player?.currentTime = max(0, min(seconds, player?.duration ?? seconds)) }
            playing = player?.play() == true
            problem = playing ? nil : "这段原音暂时无法播放。"
            if !playing { releaseSession() }
        } catch { problem = "这段原音暂时无法播放，文件仍然保留。"; playing = false; releaseSession() }
    }
    func pause() { player?.pause(); playing = false; releaseSession() }
    private func releaseSession() {
        if ownsAudioSession {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                ownsAudioSession = false
            } catch { problem = "试听已经停下，声音通道暂时未能释放。"; return }
        }
        if holdsTheaterAudio { holdsTheaterAudio = false; TheaterAudio.shared.resumeAfterRecording() }
    }
    @objc nonisolated private func interrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor [weak self] in self?.pause() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            playing = false; releaseSession()
        }
    }
}

struct VoiceTranscriptPanel: View {
    @ObservedObject var model: TheaterModel
    @ObservedObject var review: VoiceReviewDraft
    let onNewRecording: () -> Void
    @Environment(\.theaterPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = VoiceReviewPlayback()
    @State private var showSegments = false
    @State private var applying = false
    @State private var cleaning = false
    private var scopeMatches: Bool { review.libraryScope == model.libraryScope }

    var body: some View {
        TheaterPanel(title: "语音手稿") {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sourceRow
                    if let job = review.job {
                        statusRow(job)
                        if job.isTerminal {
                            transcriptEditor
                            uncertainWords(job)
                            segments(job)
                        } else if !job.text.isEmpty {
                            Text(job.text).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled)
                        }
                    } else if review.busy {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在递上原音…").font(.system(size: 14)).foregroundStyle(palette.secondary)
                        }
                        if let progress = model.transferProgress { ProgressView(value: progress).tint(palette.gold) }
                    }
                    if let problem = review.problem ?? playback.problem {
                        Text(problem).font(.system(size: 14)).foregroundStyle(palette.warning)
                    }
                    if !review.busy && (review.job == nil || review.problem != nil) {
                        Button(review.job == nil ? "开始转写" : "继续查看转写") { review.prepare(using: model) }
                            .buttonStyle(TheaterActionStyle()).disabled(!model.isConnected || !scopeMatches)
                    }
                    HStack {
                        Button("录一段新的", action: onNewRecording).font(.system(size: 13)).disabled(applying || cleaning)
                        Spacer()
                        if let job = review.job, job.isTerminal, !job.isCompleted {
                            Button("重新转写") {
                                Task {
                                    await model.saveTranscriptDraft(review.text, for: job)
                                    review.prepare(using: model, newJob: true)
                                }
                            }
                                .font(.system(size: 13)).disabled(review.busy || !model.isConnected || !scopeMatches)
                        }
                    }.padding(.top, 6)
                }.padding(26).frame(maxWidth: 700).frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear { review.prepare(using: model) }
            .onChange(of: model.libraryScope) { _, _ in if !scopeMatches { review.refuseChangedScope() } }
            .onDisappear {
                playback.pause()
                if let job = review.job { Task { await model.saveTranscriptDraft(review.text, for: job) } }
            }
            .task(id: review.text) {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                if let job = review.job, job.isTerminal { await model.saveTranscriptDraft(review.text, for: job) }
            }
        }
    }

    private var sourceRow: some View {
        HStack(spacing: 14) {
            Image("icon_microphone").resizable().scaledToFit().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(review.artifact?.name ?? review.recordingURL?.lastPathComponent ?? "原音")
                    .font(.system(size: 15, weight: .medium)).lineLimit(2)
                HStack(spacing: 18) {
                    if let url = review.recordingURL {
                        Button(playback.playing ? "暂停试听" : "试听原音") { playback.toggle(url) }
                        ShareLink(item: url) { Text("保存原音") }
                    }
                }.font(.system(size: 12)).frame(minHeight: 32)
            }
            Spacer(minLength: 0)
        }
    }
    private func statusRow(_ job: SpeechJob) -> some View {
        HStack(spacing: 10) {
            if !job.isTerminal { ProgressView().controlSize(.small) }
            Text(statusLabel(job.status)).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.secondary)
            if !job.isTerminal, let through = job.progress.throughSeconds {
                Text(timeLabel(through)).font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.secondary)
            }
            Spacer()
            if !job.isTerminal {
                Button("停止转写") { Task { await review.stop(using: model) } }.font(.system(size: 12))
            }
        }
    }
    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文字稿").font(.system(size: 14, weight: .medium))
            TextEditor(text: $review.text).font(.system(size: 17)).lineSpacing(6)
                .scrollContentBackground(.hidden).padding(12).frame(minHeight: 190, maxHeight: 330)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.line, lineWidth: 0.5))
                .accessibilityLabel("可编辑的语音文字稿")
            HStack {
                Button(cleaning ? "正在顺句…" : "口语顺句") {
                    cleaning = true
                    let original = review.text
                    let current = review.identifier
                    Task {
                        if let clean = await model.cleanTranscript(text: original), review.identifier == current, review.text == original { review.text = clean }
                        cleaning = false
                    }
                }.font(.system(size: 13)).disabled(cleaning || review.text.isEmpty || !model.isConnected || !scopeMatches)
                Spacer()
                Button(applying ? "正在放入…" : "放入草稿") {
                    guard let job = review.job else { return }
                    let finalText = review.text
                    let destination = review.destinationID, current = review.identifier
                    applying = true; model.notice = nil
                    Task {
                        await model.saveTranscriptDraft(finalText, for: job)
                        await model.appendTranscript(finalText, from: job, to: destination)
                        applying = false
                        if model.notice == nil, review.identifier == current, review.job?.id == job.id { dismiss() }
                    }
                }.buttonStyle(TheaterActionStyle(prominent: true))
                    .disabled(applying || review.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !scopeMatches)
            }
        }
    }
    @ViewBuilder private func uncertainWords(_ job: SpeechJob) -> some View {
        if !job.uncertainSpans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("再听一遍这些地方").font(.system(size: 13, weight: .medium)).foregroundStyle(palette.secondary)
                ForEach(job.uncertainSpans) { span in
                    Button {
                        if let url = review.recordingURL, let seconds = span.startSeconds { playback.play(url, from: seconds) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(span.text).font(.system(size: 14)).multilineTextAlignment(.leading)
                            Spacer()
                            if let seconds = span.startSeconds { Text(timeLabel(seconds)).font(.system(size: 11, design: .monospaced)) }
                        }.padding(11).foregroundStyle(palette.text)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.gold.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }.buttonStyle(.plain).disabled(span.startSeconds == nil || review.recordingURL == nil)
                }
            }
        }
    }
    @ViewBuilder private func segments(_ job: SpeechJob) -> some View {
        if !job.segments.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                Button { showSegments.toggle() } label: {
                    HStack(spacing: 7) {
                        TheaterGlyph(kind: .chevron).stroke(lineWidth: 1).frame(width: 14, height: 14).rotationEffect(.degrees(showSegments ? 180 : 0))
                        Text("逐段听读").font(.system(size: 13))
                    }.foregroundStyle(palette.secondary)
                }.buttonStyle(.plain)
                if showSegments {
                    ForEach(job.segments) { segment in
                        Button {
                            if let url = review.recordingURL, let start = segment.start { playback.play(url, from: start) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                if let start = segment.start { Text(timeLabel(start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondary).frame(width: 45, alignment: .leading) }
                                Text(segment.text).font(.system(size: 14)).lineSpacing(5).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 9).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(segment.start == nil || review.recordingURL == nil)
                        TheaterRule()
                    }
                }
            }
        }
    }
    private func statusLabel(_ status: String) -> String {
        ["queued": "等待转写", "running": "正在转写", "transcribing": "正在转写", "completed": "转写完成", "cancelled": "已停止转写", "failed": "转写未完成", "interrupted": "转写已中断", "unconfigured": "转写尚未接通", "dependency_missing": "转写尚未接通"][status] ?? "正在接续转写"
    }
    private func timeLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

func artifactIsAudio(_ artifact: Artifact) -> Bool {
    artifact.mime.hasPrefix("audio/") || ["m4a", "wav", "mp3", "flac", "ogg", "opus", "aac"].contains(URL(fileURLWithPath: artifact.name).pathExtension.lowercased())
}
