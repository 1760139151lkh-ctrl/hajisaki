import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';

export type RecorderState = 'idle' | 'preparing' | 'recording' | 'paused' | 'stopped' | 'failed';

/**
 * Real microphone recording, with no silence timeout and no fabricated transcript.
 * AAC/ADTS is selected because AVRecorder does not expose an Opus recorder profile.
 * Each completed ADTS frame remains useful without a final MP4 index. Files are
 * retained in filesDir; release never silently deletes a recording.
 */
export class NativeRecorder {
  private recorder: media.AVRecorder | undefined = undefined;
  private file: fileIo.File | undefined = undefined;
  private path: string = '';
  private currentState: RecorderState = 'idle';
  private busy: boolean = false;
  private releaseRequested: boolean = false;
  onState: (state: RecorderState) => void = (_state: RecorderState): void => {};

  get state(): RecorderState {
    return this.currentState;
  }

  get currentPath(): string {
    return this.path;
  }

  private setState(state: RecorderState): void {
    this.currentState = state;
    this.onState(state);
  }

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.busy || this.recorder !== undefined) {
      throw new Error('这段录音还没有收好，请先结束它。');
    }
    this.busy = true;
    this.releaseRequested = false;
    this.path = '';
    this.setState('preparing');
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const permission = await manager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      if (permission.authResults.length !== 1 || permission.authResults[0] !== 0) {
        throw new Error('还没有麦克风许可，你也可以先把话写下来。');
      }
      if (this.releaseRequested) {
        this.setState('idle');
        return;
      }
      this.path = `${context.filesDir}/voice-${Date.now()}.aac`;
      this.file = await fileIo.open(this.path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      const recorder = await media.createAVRecorder();
      this.recorder = recorder;
      recorder.on('error', (_error: BusinessError): void => {
        if (recorder.state === 'error') {
          this.setState('failed');
        }
      });
      recorder.on('stateChange', (state: media.AVRecorderState): void => {
        if (state === 'started') {
          this.setState('recording');
        } else if (state === 'paused') {
          this.setState('paused');
        } else if (state === 'stopped') {
          this.setState('stopped');
        } else if (state === 'error') {
          this.setState('failed');
        }
      });
      const profile: media.AVRecorderProfile = {
        audioBitrate: 64000,
        audioChannels: 1,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: 48000,
        fileFormat: media.ContainerFormatType.CFT_AAC
      };
      const config: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: profile,
        url: `fd://${this.file.fd}`
      };
      await recorder.prepare(config);
      if (this.releaseRequested) {
        this.setState('idle');
        return;
      }
      await recorder.start();
      this.setState('recording');
    } catch (error) {
      await this.releaseResources();
      this.setState('failed');
      throw error as Error;
    } finally {
      this.busy = false;
      if (this.releaseRequested) {
        await this.release();
      }
    }
  }

  async pause(): Promise<void> {
    if (this.busy || this.recorder === undefined || this.recorder.state !== 'started') {
      return;
    }
    this.busy = true;
    try {
      await this.recorder.pause();
      this.setState('paused');
    } finally {
      this.busy = false;
      if (this.releaseRequested) {
        await this.release();
      }
    }
  }

  async resume(): Promise<void> {
    if (this.busy || this.recorder === undefined || this.recorder.state !== 'paused') {
      return;
    }
    this.busy = true;
    try {
      await this.recorder.resume();
      this.setState('recording');
    } finally {
      this.busy = false;
      if (this.releaseRequested) {
        await this.release();
      }
    }
  }

  async stop(): Promise<string> {
    if (this.busy) {
      throw new Error('录音正在收尾，请稍等一下。');
    }
    if (this.recorder === undefined) {
      return this.path;
    }
    this.busy = true;
    try {
      if (this.recorder.state === 'started' || this.recorder.state === 'paused') {
        await this.recorder.stop();
      }
      this.setState('stopped');
      return this.path;
    } catch (error) {
      this.setState('failed');
      throw error as Error;
    } finally {
      try {
        await this.releaseResources();
      } finally {
        this.busy = false;
      }
    }
  }

  /** Invoke when leaving the recording flow. An active recording is finalized. */
  async release(): Promise<void> {
    if (this.busy) {
      this.releaseRequested = true;
      return;
    }
    this.releaseRequested = false;
    if (this.recorder !== undefined &&
      (this.recorder.state === 'started' || this.recorder.state === 'paused')) {
      await this.stop();
    } else {
      await this.releaseResources();
    }
  }

  private async releaseResources(): Promise<void> {
    const recorder = this.recorder;
    if (recorder !== undefined) {
      try {
        recorder.off('stateChange');
        recorder.off('error');
      } catch (_) {
        // Still release the native recorder if its listeners were already removed.
      }
      await recorder.release();
      this.recorder = undefined;
    }
    await this.closeFile();
  }

  private async closeFile(): Promise<void> {
    const file = this.file;
    this.file = undefined;
    if (file !== undefined) {
      await fileIo.close(file);
    }
  }
}
