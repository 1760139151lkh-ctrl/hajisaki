import { common } from '@kit.AbilityKit';
import { Palette } from '../design/Theme';
import { Artifact } from '../model/Types';
import { SpeechState, SpeechSegment, SpeechSuggestion, UncertainSpeech, speechOngoing, speechTime } from '../model/SpeechTypes';
import { Gateway } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { SpeechClient } from '../services/SpeechClient';

@Component
export struct SpeechRoom {
  gateway: Gateway = new Gateway();
  local: LocalStore = new LocalStore();
  context?: common.UIAbilityContext;
  @Prop @Watch('sourceChanged') artifact?: Artifact;
  @Prop colors: Palette = new Palette();
  @Prop compact: boolean = false;
  onUseText: (text: string) => void = (_text: string) => {};
  onClose: () => void = () => {};
  onConnect: () => void = () => {};
  @State state: SpeechState = new SpeechState();
  @State ready: boolean = false;
  @State showWords: boolean = false;
  @State showLibrary: boolean = false;
  @State showOriginal: boolean = false;
  @State handingOff: boolean = false;
  private client?: SpeechClient;
  private closed: boolean = false;

  aboutToAppear(): void {
    const context = this.context || this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.client = new SpeechClient(this.gateway, this.local, context, this.state);
    this.client.initialize(this.artifact).then(() => { if (!this.closed) this.ready = true; });
  }
  aboutToDisappear(): void {
    if (!this.closed) {
      this.closed = true;
      this.client?.close().catch(() => {});
    }
  }
  private sourceChanged(): void {
    if (this.artifact && this.client && this.artifact.id !== this.state.artifact?.id) {
      this.client.selectArtifact(this.artifact).catch(() => { this.state.notice = '这份原音暂时没能打开，稍后再试一次。'; });
    }
  }
  private recordingActive(): boolean {
    return this.state.recording === 'recording' || this.state.recording === 'paused' || this.state.recording === 'preparing';
  }
  private async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    try { await this.client?.close(); }
    catch (_) { /* Originals remain retained even when native resource release reports a failure. */ }
    finally { this.onClose(); }
  }
  private async useText(): Promise<void> {
    if (!this.state.text.trim() || this.handingOff || !this.client) return;
    this.handingOff = true;
    const text = this.state.text;
    try {
      await this.client.edit(text);
      this.onUseText(text);
      await this.close();
    } catch (_) { this.state.notice = '输入框还没接住这段话，手稿仍在这里。'; }
    finally { this.handingOff = false; }
  }
  private async choose(artifact: Artifact): Promise<void> {
    try { await this.client?.selectArtifact(artifact); this.showLibrary = false; this.showOriginal = false; }
    catch (_) { this.state.notice = '这份原音暂时没能打开，稍后再试一次。'; }
  }
  private async chooseScratch(): Promise<void> {
    try { await this.client?.selectScratch(); this.showLibrary = false; this.showOriginal = false; }
    catch (_) { this.state.notice = '便笺暂时没能翻开，已经写下的文字仍在。'; }
  }
  private async words(): Promise<void> {
    this.showWords = true;
    await this.client?.loadHotwords();
  }
  private async saveWords(): Promise<void> {
    if (await this.client?.saveHotwords()) this.showWords = false;
  }
  private jobLabel(): string {
    const job = this.state.job;
    if (!job) return '';
    if (job.status === 'queued') return '等她落笔…';
    if (job.status === 'running') return '已听到 ' + speechTime(job.progress.through_seconds);
    if (job.status === 'completed') return '听写已收好';
    if (job.status === 'cancelled') return '已停在这里';
    if (job.status === 'failed') return '这一段没能听完';
    return '上次听写中断了';
  }
  private face(): Resource {
    if(this.recordingActive()) return $r('app.media.listening_attentive');
    if(speechOngoing(this.state.job)) return $r('app.media.thinking_deep');
    if(this.state.job?.status==='completed') return $r('app.media.happy_achieved');
    return $r('app.media.idle_gentle');
  }

  @Builder
  private heading() {
    Row({ space: 12 }) {
      if(!this.compact) Image(this.face()).width(48).height(64).objectFit(ImageFit.Cover).borderRadius(16)
      Column({ space: 3 }) {
        Text(this.showWords ? '熟悉的名字' : this.showLibrary ? '档案里的原音' : '原音手稿')
          .fontSize(25).fontWeight(FontWeight.Medium).fontColor(this.colors.text)
        if (!this.compact && !this.showWords && !this.showLibrary) Text('把未说完的话，慢慢写下来。').fontSize(13).fontColor(this.colors.secondary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button(this.showWords || this.showLibrary ? '返回手稿' : '返回琴房')
        .fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
        .onClick(() => {
          if (this.showWords) this.showWords = false;
          else if (this.showLibrary) this.showLibrary = false;
          else this.close();
        })
    }.width('100%').padding({ left: 20, right: 12, top: 16, bottom: 15 })
  }

  @Builder
  private originalAudio() {
    Column({ space: 12 }) {
      if (this.state.artifact) {
        Text(this.state.artifact.name).fontSize(17).fontColor(this.colors.text).maxLines(3).width('100%')
        Row({ space: 8 }) {
          Button(this.state.playing ? '停止回听' : '回听原音')
            .fontSize(13).fontColor(this.colors.accent).backgroundColor(this.colors.raised).height(42).layoutWeight(1)
            .enabled(!this.recordingActive() && (!this.state.busy || this.state.playing))
            .onClick(() => { if (this.state.playing) this.client?.stopPlayback(); else this.client?.play(); })
          Button('保存原音').fontSize(13).fontColor(this.colors.accent).backgroundColor(this.colors.raised)
            .height(42).layoutWeight(1).enabled(!this.state.busy).onClick(() => this.client?.saveOriginal())
        }.width('100%')
        if (this.state.playing) Text(speechTime(this.state.playbackSeconds) + ' / ' + speechTime(this.state.playbackDuration))
          .fontSize(13).fontColor(this.colors.secondary).width('100%')
      }
      if (this.recordingActive()) {
        Text((this.state.recording === 'paused' ? '暂歇 · ' : this.state.recording === 'preparing' ? '正在打开麦克风 · ' : '原音 · ') + speechTime(this.state.recordSeconds))
          .fontSize(20).fontColor(this.colors.accent).width('100%')
        Row({ space: 8 }) {
          Button(this.state.recording === 'paused' ? '继续录音' : '暂停录音')
            .fontColor(this.colors.text).backgroundColor(this.colors.raised).layoutWeight(1).height(44)
            .enabled(!this.state.busy && this.state.recording !== 'preparing')
            .onClick(() => { if (this.state.recording === 'paused') this.client?.resumeRecording(); else this.client?.pauseRecording(); })
          Button('收好录音').fontColor(this.colors.background).backgroundColor(this.colors.accent).layoutWeight(1).height(44)
            .enabled(!this.state.busy && this.state.recording !== 'preparing').onClick(() => this.client?.finishRecording())
        }.width('100%')
      } else {
        Row({ space: 8 }) {
          Button('开始录音').fontSize(14).fontColor(this.colors.text).backgroundColor(this.colors.raised)
            .layoutWeight(1).height(44).enabled(this.ready && !this.state.busy).onClick(() => this.client?.startRecording())
          Button('导入原音').fontSize(14).fontColor(this.colors.text).backgroundColor(this.colors.raised)
            .layoutWeight(1).height(44).enabled(this.ready && !this.state.busy).onClick(() => this.client?.importAudio())
        }.width('100%')
        Row({ space: 8 }) {
          if (this.state.recordedPath) Button('上传保留录音').fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .height(40).enabled(!this.state.busy).onClick(() => this.client?.uploadRecording())
          Blank()
          Button('从档案选择').fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(40)
            .enabled(this.ready && !this.state.busy).onClick(() => { this.showLibrary = true; this.client?.loadArtifacts(); })
        }.width('100%')
      }
      if (this.state.transferTotal > 0 && this.state.busy) {
        Progress({ value: this.state.transferDone, total: this.state.transferTotal, type: ProgressType.Linear })
          .color(this.colors.accent).backgroundColor(this.colors.border).width('100%')
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding(16)
      .backgroundColor(this.colors.surface).borderRadius(16).border({ width: 0.5, color: this.colors.border })
  }

  @Builder
  private manuscript() {
    Column({ space: 13 }) {
      Row({ space: 8 }) {
        Text('听写手稿').fontSize(18).fontColor(this.colors.text).layoutWeight(1)
        Button('个人热词').fontSize(13).fontColor(this.colors.gold).backgroundColor(Color.Transparent).height(40)
          .enabled(!this.state.busy && !this.recordingActive()).onClick(() => this.words())
      }.width('100%')
      if (this.state.status && !this.state.status.available) {
        Text(this.state.status.detail).fontSize(14).lineHeight(22).fontColor(this.colors.secondary).width('100%')
      }
      Row({ space: 8 }) {
        if (speechOngoing(this.state.job)) {
          LoadingProgress().color(this.colors.accent).width(22).height(22)
          Text(this.jobLabel()).fontSize(14).fontColor(this.colors.secondary).layoutWeight(1)
          Button('停止听写').fontSize(13).fontColor(this.colors.danger).backgroundColor(Color.Transparent).height(42)
            .enabled(!this.state.busy).onClick(() => this.client?.stopTranscription())
        } else {
          Button(this.state.busy === 'transcribe' ? '正在交给她…' : '听写成文')
            .fontColor(this.colors.background).backgroundColor(this.colors.accent).height(44).layoutWeight(1)
            .enabled(!!this.state.artifact && !this.state.busy && !this.state.submissionUncertain && !this.recordingActive())
            .onClick(() => this.client?.transcribe())
          Button('刷新状态').fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
            .enabled(!this.state.loadingStatus).onClick(() => this.client?.refreshStatus())
        }
      }.width('100%')
      if (this.state.job && !speechOngoing(this.state.job)) Text(this.jobLabel()).fontSize(13).fontColor(this.colors.secondary).width('100%')
      if (this.state.submissionUncertain) {
        Text('这次听写的回执还没有对上，先保留原音。').fontSize(14).fontColor(this.colors.secondary).width('100%')
        Button('查找主机回执').fontColor(this.colors.accent).backgroundColor(this.colors.surface).height(42)
          .enabled(!this.state.busy).onClick(() => this.client?.recoverPending())
      }
      TextArea({ text: this.state.text, placeholder: '听写内容会留在这里，也可以自己修改。' })
        .fontSize(16).fontColor(this.colors.text).placeholderColor(this.colors.secondary).backgroundColor(this.colors.surface)
        .constraintSize({ minHeight: 190, maxHeight: 460 }).padding(14).borderRadius(12)
        .enabled(!this.handingOff).maxLength(100000).onChange((value: string) => this.client?.edit(value))
      Row({ space: 8 }) {
        Button(this.state.busy === 'clean' ? '正在顺句…' : '去掉口头停顿词')
          .fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(42)
          .enabled(!!this.state.text.trim() && !this.state.busy).onClick(() => this.client?.clean())
        if (this.state.beforeClean && this.state.text === this.state.cleanedText) Button('撤回顺句')
          .fontSize(13).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(42).onClick(() => this.client?.undoClean())
      }.width('100%')
      if (this.state.job && this.state.job.dictionary_suggestions.length > 0) {
        ForEach(this.state.job.dictionary_suggestions, (suggestion: SpeechSuggestion) => {
          if (suggestion.source === 'user_dictionary') Button(suggestion.text + ' → ' + suggestion.replacement)
            .fontSize(14).fontColor(this.colors.gold).backgroundColor(this.colors.surface).height(42)
            .onClick(() => this.client?.applySuggestion(suggestion))
        })
      }
      if (this.state.job) {
        Button(this.showOriginal ? '收起原始听写' : '原始听写与时间片段')
          .fontSize(13).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(42)
          .onClick(() => { this.showOriginal = !this.showOriginal; })
        if (this.showOriginal) {
          Text(this.state.job.original_text || '这一段还没有文字。').fontSize(15).lineHeight(25)
            .fontColor(this.colors.secondary).copyOption(CopyOptions.InApp).width('100%')
          if (this.state.job.original_text) Button('用原始听写重新编辑').fontSize(12).fontColor(this.colors.accent)
            .backgroundColor(Color.Transparent).height(40).onClick(() => this.client?.useTranscript())
          if (this.state.job.uncertain_spans.length > 0) Text('她没听清的片段').fontSize(15).fontColor(this.colors.gold).width('100%')
          ForEach(this.state.job.uncertain_spans, (span: UncertainSpeech) => {
            Button(speechTime(span.start_seconds) + '  ' + span.text).fontSize(14).fontColor(this.colors.gold)
              .backgroundColor(this.colors.surface).width('100%').height(44)
              .enabled(span.start_seconds !== null && !this.state.busy && !this.recordingActive())
              .onClick(() => this.client?.play(span.start_seconds || 0))
          })
          ForEach(this.state.job.segments, (segment: SpeechSegment) => {
            Row({ space: 10 }) {
              Button(speechTime(segment.start)).fontSize(12).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
                .height(40).enabled(segment.start !== null && !this.state.busy && !this.recordingActive())
                .onClick(() => this.client?.play(segment.start || 0))
              Text(segment.text).fontSize(14).lineHeight(23).fontColor(this.colors.secondary).layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Top)
          })
        }
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  build() {
    Column({ space: 0 }) {
      this.heading()
      if (!this.gateway.isConfigured()) Row({space:8}) {
        Text('还没连上琴房，原音会先留在手机里。').fontSize(13).lineHeight(21).fontColor(this.colors.secondary).layoutWeight(1)
        Button('连接琴房').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .enabled(!this.recordingActive()).onClick(()=>this.onConnect())
      }.width('100%').padding({left:20,right:12,bottom:12})
      else if (this.state.notice) Text(this.state.notice).fontSize(14).lineHeight(22).fontColor(this.colors.danger)
        .width('100%').padding({ left: 20, right: 20, bottom: 12 })
      if (this.showWords) {
        Column({ space: 15 }) {
          Text('每行一个词，别名用逗号隔开。').fontSize(14).fontColor(this.colors.secondary).width('100%')
          TextArea({ text: this.state.hotwordText, placeholder: '词名, 听写中常见的别名' })
            .fontSize(16).fontColor(this.colors.text).placeholderColor(this.colors.secondary).backgroundColor(this.colors.surface)
            .layoutWeight(1).padding(14).borderRadius(12).maxLength(100000)
            .enabled(this.state.hotwordsLoaded && this.state.busy !== 'words')
            .onChange((value: string) => this.client?.editHotwords(value))
          if (!this.state.hotwordsLoaded) Button(this.state.hotwordsLoading ? '正在取回热词…' : '重新连接热词')
            .fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(42)
            .enabled(!this.state.hotwordsLoading).onClick(() => this.client?.loadHotwords())
          Button(this.state.busy === 'words' ? '正在收好…' : '保存热词').fontColor(this.colors.background)
            .backgroundColor(this.colors.accent).height(48).width('100%')
            .enabled(this.state.hotwordsLoaded && !this.state.busy).onClick(() => this.saveWords())
        }.layoutWeight(1).width('100%').padding(20)
      } else if (this.showLibrary) {
        Scroll() {
          Column({ space: 12 }) {
            Button('随手便笺').fontSize(15).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
              .height(54).width('100%').onClick(() => this.chooseScratch())
            ForEach(this.state.artifacts, (artifact: Artifact) => {
              Button(artifact.name).fontSize(15).fontColor(this.colors.text).backgroundColor(this.colors.surface)
                .height(54).width('100%').onClick(() => this.choose(artifact))
            }, (artifact: Artifact) => artifact.id)
            if (this.state.libraryLoading) LoadingProgress().color(this.colors.accent).width(28).height(28)
            else if (this.state.artifacts.length === 0) Text('还没有可选的原音。').fontSize(15).fontColor(this.colors.secondary)
          }.width('100%').padding(20)
        }.layoutWeight(1).width('100%').align(Alignment.Top)
      } else {
        Scroll() {
          Column({ space: 24 }) {
            this.originalAudio()
            this.manuscript()
          }.width('100%').padding({ left: 20, right: 20, bottom: 24 })
        }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto)
        Button(this.handingOff ? '正在带回…' : '放回输入框').fontColor(this.colors.background)
          .backgroundColor(this.colors.accent).height(48).width('90%').margin({ bottom: 16, top: 8 })
          .enabled(this.ready && !!this.state.text.trim() && !this.handingOff && !this.recordingActive())
          .onClick(() => this.useText())
      }
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
