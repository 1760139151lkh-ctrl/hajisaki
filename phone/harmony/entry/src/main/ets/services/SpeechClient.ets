import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import { Artifact, ArtifactPage } from '../model/Types';
import { SpeechState, SpeechStatus, SpeechJob, SpeechDraft, SpeechSuggestion, SpeechHotword,
  SpeechHotwords, SpeechCleanResult, speechOngoing } from '../model/SpeechTypes';
import { NativeRecorder, RecorderState } from '../platform/NativeRecorder';
import { NativeFiles, NativeFileError } from '../platform/NativeFiles';
import { Gateway, GatewayError } from './Gateway';
import { LocalStore } from './LocalStore';

/** Real host speech API plus retained local drafts/audio; no fabricated ASR result. */
export class SpeechClient {
  readonly state: SpeechState;
  private gateway: Gateway;
  private local: LocalStore;
  private context: common.UIAbilityContext;
  private files: NativeFiles;
  private recorder: NativeRecorder = new NativeRecorder();
  private generation: number = 0;
  private textRevision: number = 0;
  private dictionaryRevision: number = 0;
  private jobRevision: number = 0;
  private disposed: boolean = false;
  private pollTimer: number = -1;
  private recordTimer: number = -1;
  private recordingStart: number = 0;
  private recordedMillis: number = 0;
  private player?: media.AVPlayer;
  private playerFile?: fileIo.File;
  private playerGeneration: number = 0;

  constructor(gateway: Gateway, local: LocalStore, context: common.UIAbilityContext, state: SpeechState) {
    this.gateway = gateway; this.local = local; this.context = context; this.state = state;
    this.files = new NativeFiles(context, gateway);
    this.recorder.onState = (next: RecorderState) => {
      if (this.recordingStart > 0 && next !== 'recording') {
        this.recordedMillis += Date.now() - this.recordingStart; this.recordingStart = 0;
      }
      if (next === 'recording' && this.recordingStart === 0) this.recordingStart = Date.now();
      if ((next === 'stopped' || next === 'failed') && this.recordTimer >= 0) {
        clearInterval(this.recordTimer); this.recordTimer = -1;
      }
      if (!this.disposed) {
        this.state.recording = next;
        this.state.recordSeconds = this.recordedMillis / 1000;
        if (next === 'failed') this.state.notice = '录音暂时停了一下，已经留下的原音不会被清掉。';
      }
    };
  }

  async initialize(artifact?: Artifact): Promise<void> {
    try {
      this.state.recordedPath = await this.local.get('speech', 'recorded_path', '');
      if (artifact) await this.selectArtifact(artifact);
      else {
        const previous = await this.local.get('speech', 'last_artifact', '');
        if (previous) await this.selectArtifact(JSON.parse(previous) as Artifact);
        else await this.selectScratch();
      }
    } catch (error) { this.fail(error as Error); }
    await this.refreshStatus();
  }

  async refreshStatus(): Promise<void> {
    if (this.disposed) return;
    this.state.loadingStatus = true;
    try {
      const status = await this.gateway.request<SpeechStatus>('/api/speech/status');
      if (!this.disposed) this.state.status = status;
    } catch (error) { this.fail(error as Error); }
    finally { if (!this.disposed) this.state.loadingStatus = false; }
  }

  async selectScratch(): Promise<void> {
    const ticket = ++this.generation;
    const revision = this.textRevision;
    this.jobRevision++; this.stopPolling(); await this.stopPlayback();
    const draft = JSON.parse(await this.local.get('speech_draft', 'scratch', '{"text":"","edited":false}')) as SpeechDraft;
    if (this.disposed || ticket !== this.generation || revision !== this.textRevision) return;
    this.state.artifact = undefined; this.state.job = undefined;
    this.state.text = draft.text; this.state.edited = draft.edited; this.textRevision++;
    this.state.submissionUncertain = false; this.state.notice = '';
    this.state.beforeClean = ''; this.state.cleanedText = '';
    await this.local.put('speech', 'last_artifact', '');
  }

  async selectArtifact(artifact: Artifact): Promise<void> {
    if (!this.supports(artifact)) { this.state.notice = '请选一段 WAV、MP3、AAC、M4A、FLAC、OGG、Opus 或 WebM 原音。'; return; }
    const ticket = ++this.generation;
    this.jobRevision++;
    this.stopPolling(); await this.stopPlayback();
    const draft = JSON.parse(await this.local.get('speech_draft', artifact.id, '{"text":"","edited":false}')) as SpeechDraft;
    const jobId = await this.local.get('speech_job', artifact.id, '');
    const uncertain = await this.local.get('speech_uncertain', artifact.id, 'false');
    if (this.disposed || ticket !== this.generation) return;
    this.state.artifact = artifact; this.state.job = undefined;
    this.state.text = draft.text; this.state.edited = draft.edited; this.textRevision++;
    this.state.submissionUncertain = uncertain === 'true';
    this.state.beforeClean = ''; this.state.cleanedText = '';
    await this.local.put('speech', 'last_artifact', JSON.stringify(artifact));
    await this.local.put('artifact', artifact.id, JSON.stringify(artifact));
    if (jobId && ticket === this.generation && !this.disposed) await this.readJob(jobId, ticket);
  }

  async loadArtifacts(): Promise<void> {
    if (this.state.libraryLoading || this.disposed) return;
    this.state.libraryLoading = true;
    try {
      const page = await this.gateway.request<ArtifactPage>('/api/artifacts');
      if (!this.disposed) this.state.artifacts = page.artifacts.filter((item: Artifact) => this.supports(item));
    } catch (error) { this.fail(error as Error); }
    finally { if (!this.disposed) this.state.libraryLoading = false; }
  }

  async importAudio(): Promise<void> {
    if (!this.begin('import')) return;
    try {
      const artifact = await this.files.uploadPicked((done: number, total: number) => this.transfer(done, total));
      if (artifact && !this.disposed) await this.selectArtifact(artifact);
    } catch (error) { this.fail(error as Error); }
    finally { this.finish('import'); }
  }

  async startRecording(): Promise<void> {
    if (!this.begin('record')) return;
    try {
      await this.stopPlayback();
      await this.recorder.release();
      this.recordedMillis = 0; this.recordingStart = 0; this.state.recordSeconds = 0;
      await this.recorder.start(this.context);
      this.state.recordedPath = this.recorder.currentPath;
      await this.local.put('speech', 'recorded_path', this.recorder.currentPath);
      if (!this.disposed && this.recordTimer < 0) this.recordTimer = setInterval(() => {
        this.state.recordSeconds = (this.recordedMillis + (this.recordingStart > 0 ? Date.now() - this.recordingStart : 0)) / 1000;
      }, 250);
    } catch (error) { this.fail(error as Error); }
    finally { this.finish('record'); }
  }

  async pauseRecording(): Promise<void> {
    try { await this.recorder.pause(); } catch (error) { this.fail(error as Error); }
  }
  async resumeRecording(): Promise<void> {
    try { await this.recorder.resume(); } catch (error) { this.fail(error as Error); }
  }
  async finishRecording(): Promise<void> {
    if (!this.begin('record')) return;
    let stopped = false;
    try {
      const path = await this.recorder.stop();
      stopped = true;
      this.state.recordedPath = path;
      await this.local.put('speech', 'recorded_path', path);
      if (this.recordTimer >= 0) clearInterval(this.recordTimer); this.recordTimer = -1;
    } catch (error) { this.fail(error as Error); }
    finally { this.finish('record'); }
    if (stopped && !this.disposed && this.state.recordedPath) await this.uploadRecording();
  }

  async uploadRecording(): Promise<void> {
    if (!this.state.recordedPath || !this.begin('upload')) return;
    const path = this.state.recordedPath;
    try {
      const artifact = await this.files.uploadUri(path, '原音-' + path.substring(path.lastIndexOf('/') + 1), 'audio/aac',
        (done: number, total: number) => this.transfer(done, total));
      await this.local.put('speech_audio', artifact.id, path);
      if (!this.disposed) await this.selectArtifact(artifact);
    } catch (error) { this.fail(error as Error); }
    finally { this.finish('upload'); }
  }

  async transcribe(): Promise<void> {
    const artifact = this.state.artifact;
    if (!artifact || speechOngoing(this.state.job) || this.state.submissionUncertain || !this.begin('transcribe')) return;
    const ticket = this.generation;
    let submitted = false;
    try {
      const status = await this.gateway.request<SpeechStatus>('/api/speech/status');
      if (ticket !== this.generation || this.disposed) return;
      this.state.status = status;
      if (!status.available) { this.state.notice = status.detail; return; }
      if (artifact.size > status.limits.max_bytes) { this.state.notice = '这段原音超过主机当前的听写容量，请先分段。'; return; }
      submitted = true;
      const job = await this.gateway.request<SpeechJob>('/api/speech/transcriptions', http.RequestMethod.POST,
        JSON.stringify({ artifact_id: artifact.id, cleanup: false }));
      await this.local.put('speech_job', artifact.id, job.id);
      await this.local.put('speech_uncertain', artifact.id, 'false');
      if (ticket === this.generation && !this.disposed) { this.jobRevision++; await this.showJob(job); this.scheduleRead(job.id, ticket, 1000); }
    } catch (error) {
      const failure = error as GatewayError;
      if (submitted && (failure.status === 0 || failure.outcomeUncertain)) {
        await this.local.put('speech_uncertain', artifact.id, 'true');
        if (ticket === this.generation) this.state.submissionUncertain = true;
      }
      this.fail(error as Error);
    } finally { this.finish('transcribe'); }
  }

  async stopTranscription(): Promise<void> {
    const job = this.state.job;
    if (!job || !speechOngoing(job) || !this.begin('stop')) return;
    const ticket = this.generation;
    this.jobRevision++;
    this.stopPolling();
    try {
      const result = await this.gateway.request<SpeechJob>('/api/speech/transcriptions/' + encodeURIComponent(job.id) + '/stop',
        http.RequestMethod.POST, '{}');
      if (ticket === this.generation && !this.disposed) await this.showJob(result);
    } catch (error) {
      this.fail(error as Error);
      this.scheduleRead(job.id, ticket, 2000);
    } finally { this.finish('stop'); }
  }

  async recoverPending(): Promise<void> {
    const artifact = this.state.artifact;
    if (!artifact || !this.begin('recover')) return;
    const ticket = this.generation;
    try {
      const status = await this.gateway.request<SpeechStatus>('/api/speech/status');
      const ids = (status.active_jobs || []).concat(status.queued_jobs || []);
      const matches: SpeechJob[] = [];
      for (const id of ids) {
        const job = await this.gateway.request<SpeechJob>('/api/speech/transcriptions/' + encodeURIComponent(id));
        if (job.artifact_id === artifact.id) matches.push(job);
      }
      if (ticket !== this.generation || this.disposed) return;
      if (matches.length !== 1) {
        this.state.notice = '暂时无法唯一确认那次听写，请在主机核对回执；不会重复提交原音。'; return;
      }
      const job = matches[0];
      this.jobRevision++;
      await this.local.put('speech_job', artifact.id, job.id);
      await this.local.put('speech_uncertain', artifact.id, 'false');
      this.state.submissionUncertain = false; await this.showJob(job); this.scheduleRead(job.id, ticket, 1000);
    } catch (error) { this.fail(error as Error); }
    finally { this.finish('recover'); }
  }

  async edit(text: string): Promise<void> {
    this.textRevision++; this.state.text = text; this.state.edited = true;
    try { await this.persistDraft(); } catch (error) { this.fail(error as Error); }
  }

  async clean(): Promise<void> {
    if (!this.state.text.trim() || !this.begin('clean')) return;
    const before = this.state.text; const revision = this.textRevision; const ticket = this.generation;
    try {
      const result = await this.gateway.request<SpeechCleanResult>('/api/speech/clean', http.RequestMethod.POST, JSON.stringify({ text: before }));
      if (!this.disposed && ticket === this.generation && revision === this.textRevision) {
        this.state.beforeClean = before; this.state.cleanedText = result.text; await this.edit(result.text);
      }
    } catch (error) { this.fail(error as Error); }
    finally { this.finish('clean'); }
  }

  async undoClean(): Promise<void> {
    if (this.state.text !== this.state.cleanedText || !this.state.beforeClean) return;
    const before = this.state.beforeClean; this.state.beforeClean = ''; this.state.cleanedText = '';
    await this.edit(before);
  }

  async useTranscript(): Promise<void> {
    if (this.state.job) await this.edit(this.state.job.original_text || this.state.job.text);
  }

  async applySuggestion(suggestion: SpeechSuggestion): Promise<void> {
    if (suggestion.source !== 'user_dictionary' || !suggestion.text) return;
    const position = this.state.text.indexOf(suggestion.text);
    if (position < 0 || this.state.text.indexOf(suggestion.text, position + suggestion.text.length) >= 0) {
      this.state.notice = '这处文字已经改动或出现不止一次，请在手稿里选准位置再改。'; return;
    }
    await this.edit(this.state.text.substring(0, position) + suggestion.replacement +
      this.state.text.substring(position + suggestion.text.length));
  }

  async loadHotwords(): Promise<void> {
    if (this.state.hotwordsLoading || this.disposed) return;
    this.state.hotwordsLoading = true; this.state.hotwordsLoaded = false;
    const revision = this.dictionaryRevision;
    try {
      const words = await this.gateway.request<SpeechHotwords>('/api/speech/hotwords');
      await this.local.put('speech', 'hotwords', JSON.stringify(words));
      if (!this.disposed) {
        if (revision === this.dictionaryRevision) this.state.hotwordText = words.hotwords.map((word: SpeechHotword) => [word.term].concat(word.aliases).join(', ')).join('\n');
        this.state.hotwordsLoaded = true;
      }
    } catch (error) { this.fail(error as Error); }
    finally { if (!this.disposed) this.state.hotwordsLoading = false; }
  }

  editHotwords(value: string): void { this.dictionaryRevision++; this.state.hotwordText = value; }

  async saveHotwords(): Promise<boolean> {
    if (!this.state.hotwordsLoaded || !this.begin('words')) return false;
    const revision = this.dictionaryRevision;
    try {
      const words: SpeechHotword[] = [];
      for (const line of this.state.hotwordText.split('\n')) {
        const parts = line.split(/[,，]/).map((part: string) => part.trim()).filter((part: string) => part.length > 0);
        if (parts.length === 0) continue;
        if (parts.length > 11 || parts.some((part: string) => Array.from(part).length > 80)) {
          this.state.notice = '每个词不超过 80 字，别名最多 10 个。'; return false;
        }
        words.push({ term: parts[0], aliases: parts.slice(1) });
      }
      if (words.length > 100 || words.reduce((sum: number, word: SpeechHotword) => sum + Array.from(word.term).length, 0) > 1000) {
        this.state.notice = '热词最多 100 项，词名合计不超过 1000 字。'; return false;
      }
      const result = await this.gateway.request<SpeechHotwords>('/api/speech/hotwords', http.RequestMethod.PUT, JSON.stringify({ hotwords: words }));
      await this.local.put('speech', 'hotwords', JSON.stringify(result));
      return revision === this.dictionaryRevision;
    } catch (error) { this.fail(error as Error); return false; }
    finally { this.finish('words'); }
  }

  async saveOriginal(): Promise<void> {
    if (!this.state.artifact || !this.begin('download')) return;
    try { await this.files.saveArtifact(this.state.artifact); }
    catch (error) { this.fail(error as Error); }
    finally { this.finish('download'); }
  }

  async play(seconds: number = 0): Promise<void> {
    if (this.state.recording === 'recording' || this.state.recording === 'paused' || !this.begin('play')) return;
    const ticket = this.generation;
    let playbackTicket = -1;
    try {
      await this.stopPlayback();
      const artifact = this.state.artifact;
      const path = artifact ? await this.audioPath(artifact) : this.state.recordedPath;
      if (!path || this.disposed || ticket !== this.generation) return;
      playbackTicket = ++this.playerGeneration;
      const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      if (this.disposed || ticket !== this.generation || playbackTicket !== this.playerGeneration) {
        await fileIo.close(file); return;
      }
      this.playerFile = file;
      const player = await media.createAVPlayer();
      if (this.disposed || ticket !== this.generation || playbackTicket !== this.playerGeneration) {
        await player.release(); return;
      }
      this.player = player;
      let readyTimer = -1;
      try {
        await new Promise<void>((resolve, reject) => {
          player.on('stateChange', (status: media.AVPlayerState) => {
            if (status === 'initialized') resolve();
            if (status === 'error') reject(new Error('Audio unavailable'));
            if (playbackTicket === this.playerGeneration && !this.disposed) {
              this.state.playing = status === 'playing';
            }
          });
          player.on('timeUpdate', (milliseconds: number) => {
            if (playbackTicket === this.playerGeneration && !this.disposed) this.state.playbackSeconds = milliseconds / 1000;
          });
          player.on('error', () => {
            reject(new Error('Audio unavailable'));
            if (playbackTicket === this.playerGeneration && !this.disposed) {
              this.state.notice = '这一段暂时不能回听，原音仍可保存到文件中。';
              this.stopPlayback().catch(() => {});
            }
          });
          readyTimer = setTimeout(() => reject(new Error('Audio preparation timed out')), 10000);
          player.fdSrc = { fd: file.fd };
        });
      } finally { if (readyTimer >= 0) clearTimeout(readyTimer); }
      if (this.disposed || ticket !== this.generation || playbackTicket !== this.playerGeneration) return;
      await player.prepare();
      if (this.disposed || ticket !== this.generation || playbackTicket !== this.playerGeneration) return;
      this.state.playbackDuration = player.duration / 1000;
      player.seek(Math.max(0, seconds) * 1000, media.SeekMode.SEEK_CLOSEST);
      await player.play();
    } catch (_) {
      await this.stopPlayback();
      if (!this.disposed && ticket === this.generation) this.state.notice = '这一段暂时不能回听，原音仍可保存到文件中。';
    }
    finally { this.finish('play'); }
  }

  async stopPlayback(): Promise<void> {
    this.playerGeneration++;
    const player = this.player; const file = this.playerFile;
    this.player = undefined; this.playerFile = undefined; this.state.playing = false;
    try { if (player) await player.release(); }
    finally { if (file) await fileIo.close(file); }
  }

  async close(): Promise<void> {
    this.disposed = true; this.generation++; this.stopPolling();
    if (this.recordTimer >= 0) clearInterval(this.recordTimer); this.recordTimer = -1;
    try { await this.recorder.release(); }
    finally {
      try { if (this.recorder.currentPath) await this.local.put('speech', 'recorded_path', this.recorder.currentPath); }
      finally { await this.stopPlayback(); }
    }
  }

  private async audioPath(artifact: Artifact): Promise<string> {
    const saved = await this.local.get('speech_audio', artifact.id, '');
    if (saved) {
      try { if ((await fileIo.stat(saved)).size === artifact.size) return saved; } catch (_) {}
    }
    const path = this.context.filesDir + '/speech-audio-' + Date.now() + '-' + artifact.id.replace(/[^a-zA-Z0-9_-]/g, '') + '.audio';
    const file = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    const hash = cryptoFramework.createMd('SHA256');
    let offset = 0;
    try {
      while (offset < artifact.size) {
        if (this.disposed) throw new Error('Speech room closed');
        const end = Math.min(artifact.size, offset + 1024 * 1024) - 1;
        const bytes = await this.audioChunk(artifact, offset, end);
        let written = 0;
        while (written < bytes.byteLength) {
          const count = await fileIo.write(file.fd, bytes.slice(written), { offset: offset + written });
          if (count <= 0) throw new Error('Audio could not be retained');
          written += count;
        }
        await hash.update({ data: new Uint8Array(bytes) });
        offset += bytes.byteLength; this.transfer(offset, artifact.size);
      }
      const digest = await hash.digest();
      let encoded = '';
      for (const value of digest.data) encoded += value.toString(16).padStart(2, '0');
      if (encoded !== artifact.sha256.toLowerCase()) throw new Error('Audio checksum mismatch');
    } finally { await fileIo.close(file); }
    await this.local.put('speech_audio', artifact.id, path);
    return path;
  }

  private async audioChunk(artifact: Artifact, start: number, end: number): Promise<ArrayBuffer> {
    const path = '/api/artifacts/' + encodeURIComponent(artifact.id) + '/content';
    if (this.gateway.isRelayActive()) return this.gateway.readRelayChunk(path, start, end);
    const request = http.createHttp();
    const headers = this.gateway.headers(); headers['Range'] = 'bytes=' + start + '-' + end;
    try {
      const result = await request.request(this.gateway.endpoint(path), {
        method: http.RequestMethod.GET, header: headers, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false, usingProxy: false, connectTimeout: 4500, readTimeout: 30000
      });
      const bytes = result.result as ArrayBuffer;
      const responseHeaders = result.header as Record<string, string>;
      const range = responseHeaders['content-range'] || responseHeaders['Content-Range'] || '';
      if (result.responseCode !== 206 || !range.startsWith('bytes ' + start + '-' + end + '/') || bytes.byteLength !== end - start + 1) {
        throw new Error('Audio range incomplete');
      }
      return bytes;
    } finally { request.destroy(); }
  }

  private async readJob(id: string, ticket: number): Promise<void> {
    if (this.disposed || ticket !== this.generation) return;
    const revision = this.jobRevision;
    try {
      const job = await this.gateway.request<SpeechJob>('/api/speech/transcriptions/' + encodeURIComponent(id));
      if (this.disposed || ticket !== this.generation || revision !== this.jobRevision) return;
      await this.showJob(job);
      if (speechOngoing(job)) this.scheduleRead(id, ticket, 1200);
    } catch (error) {
      if (revision !== this.jobRevision) return;
      this.fail(error as Error);
      const failure = error as GatewayError;
      if (failure.status === 0 || failure.status >= 500) this.scheduleRead(id, ticket, 2500);
    }
  }

  private async showJob(job: SpeechJob): Promise<void> {
    this.state.job = job;
    if (!this.state.edited) {
      this.state.text = job.text || ''; this.textRevision++; await this.persistDraft();
    }
    if (job.detail && !speechOngoing(job)) this.state.notice = job.detail;
  }
  private scheduleRead(id: string, ticket: number, delay: number): void {
    if (this.disposed || ticket !== this.generation) return;
    this.stopPolling();
    if (!this.disposed && ticket === this.generation) this.pollTimer = setTimeout(() => {
      this.pollTimer = -1; this.readJob(id, ticket);
    }, delay);
  }
  private stopPolling(): void { if (this.pollTimer >= 0) clearTimeout(this.pollTimer); this.pollTimer = -1; }
  private async persistDraft(): Promise<void> {
    const draft: SpeechDraft = { text: this.state.text, edited: this.state.edited };
    await this.local.put('speech_draft', this.state.artifact?.id || 'scratch', JSON.stringify(draft));
  }
  private supports(artifact: Artifact): boolean { return /\.(wav|mp3|ogg|opus|m4a|mp4|aac|flac|webm)$/i.test(artifact.name); }
  private begin(action: string): boolean {
    if (this.disposed || this.state.busy) return false;
    this.state.busy = action; this.state.notice = ''; this.state.transferDone = 0; this.state.transferTotal = 0; return true;
  }
  private finish(action: string): void { if (this.state.busy === action) this.state.busy = ''; }
  private transfer(done: number, total: number): void { if (!this.disposed) { this.state.transferDone = done; this.state.transferTotal = total; } }
  private fail(error: Error): void {
    if (!this.disposed) this.state.notice = error instanceof GatewayError || error instanceof NativeFileError ? error.message : '这一段暂时没接稳，原音和手稿都先留在这里。';
  }
}
