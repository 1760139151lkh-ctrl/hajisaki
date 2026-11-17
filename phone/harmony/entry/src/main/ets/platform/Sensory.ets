import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { media } from '@kit.MediaKit';
import { vibrator } from '@kit.SensorServiceKit';

export type SensoryCue = 'send' | 'reply' | 'effort' | 'bookmark';
export type SensoryPulse = 'record' | 'copy' | 'complete';

interface SoundWaiter {
  resolve: () => void;
  reject: (error: Error) => void;
  timeout: number;
}

/** Optional effects. No permission, routing preference, or system volume is changed. */
export class Sensory {
  private context: common.UIAbilityContext;
  private active: boolean = false;
  private lifecycle: number = 0;
  private intent: number = 0;
  private routeEpoch: number = 0;
  private pool?: media.SoundPool;
  private initializing?: Promise<media.SoundPool>;
  private closing?: Promise<void>;
  private routing?: audio.AudioRoutingManager;
  private volume?: audio.AudioVolumeGroupManager;
  private sounds: Map<SensoryCue, number> = new Map();
  private loads: Map<SensoryCue, Promise<number>> = new Map();
  private loaded: Set<number> = new Set();
  private waiters: Map<number, SoundWaiter> = new Map();
  private rawPaths: Set<string> = new Set();
  private streams: Set<number> = new Set();
  private hapticStarted: boolean = false;
  private renderer: audio.AudioRendererInfo = {
    usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
    rendererFlags: 1
  };
  private routeChanged: (devices: audio.AudioDeviceDescriptors) => void = (_devices) => {
    this.routeEpoch++;
    // Stop on every route transition, even between approved headsets. Do not
    // carry an in-progress cue onto a newly selected output device.
    this.stopAll();
  };
  private ringerChanged: (mode: audio.AudioRingMode) => void = (mode) => {
    this.routeEpoch++;
    if (mode !== audio.AudioRingMode.RINGER_MODE_NORMAL) this.stopAll();
  };

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  get enabled(): boolean { return this.active; }
  set enabled(value: boolean) {
    if (this.active === value) return;
    this.active = value;
    this.intent++;
    if (!value) {
      this.stopAll();
      this.stopHaptic();
    }
  }

  async play(cue: SensoryCue): Promise<void> {
    if (!this.active || !canIUse('SystemCapability.Multimedia.Media.SoundPool') ||
      !canIUse('SystemCapability.Multimedia.Audio.Device')) return;
    const ticket = this.intent;
    try {
      const pool = await this.ensurePool();
      if (!this.active || ticket !== this.intent) return;
      const sound = await this.loadCue(pool, cue);
      const route = this.routeEpoch;
      if (!await this.headphonesReady() || !this.active || ticket !== this.intent || route !== this.routeEpoch) return;
      // Allocate the stream silently. Recheck the route before raising its
      // per-stream volume; speaker/cast/Bluetooth profile guesses never pass.
      const parameters: media.PlayParameters = { loop: 0, leftVolume: 0, rightVolume: 0, priority: 1 };
      const stream = await pool.play(sound, parameters);
      this.streams.add(stream);
      if (!this.active || ticket !== this.intent || pool !== this.pool || route !== this.routeEpoch ||
        !await this.headphonesReady()) {
        this.streams.delete(stream);
        try { await pool.stop(stream); } catch (_) {}
        return;
      }
      if (!this.active || ticket !== this.intent || route !== this.routeEpoch) {
        this.streams.delete(stream);
        try { await pool.stop(stream); } catch (_) {}
        return;
      }
      await pool.setVolume(stream, 0.22, 0.22);
      if (!this.active || ticket !== this.intent || route !== this.routeEpoch) await this.stopAll();
    } catch (_) {
      // Optional accompaniment must never interrupt sending, copying or reading.
    }
  }

  async pulse(kind: SensoryPulse): Promise<void> {
    if (!this.active || !canIUse('SystemCapability.Sensors.MiscDevice')) return;
    const ticket = this.intent;
    const effect = kind === 'record' ? vibrator.HapticFeedback.EFFECT_SOFT :
      kind === 'copy' ? vibrator.HapticFeedback.EFFECT_SHARP : vibrator.HapticFeedback.EFFECT_NOTICE_SUCCESS;
    try {
      if (!await vibrator.isSupportEffect(effect) || !this.active || ticket !== this.intent) return;
      const preset: vibrator.VibratePreset = { type: 'preset', effectId: effect, count: 1, intensity: 45 };
      const attributes: vibrator.VibrateAttribute = { usage: kind === 'complete' ? 'notification' : 'touch' };
      await vibrator.startVibration(preset, attributes);
      this.hapticStarted = true;
      if (!this.active || ticket !== this.intent) await this.stopHaptic();
    } catch (_) {
      // Unsupported effects or denied VIBRATE permission remain silent.
    }
  }

  async release(): Promise<void> {
    if (this.closing) return this.closing;
    const operation = this.dispose();
    this.closing = operation;
    try { await operation; }
    finally { if (this.closing === operation) this.closing = undefined; }
  }

  private async dispose(): Promise<void> {
    this.active = false;
    this.intent++;
    this.lifecycle++;
    this.routeEpoch++;
    const pool = this.pool;
    this.pool = undefined;
    this.initializing = undefined;
    const paths = Array.from(this.rawPaths);
    const loads = Array.from(this.loads.values());
    this.rawPaths.clear();
    this.sounds.clear(); this.loads.clear(); this.loaded.clear(); this.streams.clear();
    for (const waiter of this.waiters.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(new Error('Sound pool released'));
    }
    this.waiters.clear();
    try { this.routing?.off('preferOutputDeviceChangeForRendererInfo', this.routeChanged); } catch (_) {}
    try { this.volume?.off('ringerModeChange', this.ringerChanged); } catch (_) {}
    this.routing = undefined; this.volume = undefined;
    await this.stopHaptic();
    try {
      if (pool) {
        try { pool.off('loadComplete'); } catch (_) {}
        try { pool.off('playFinishedWithStreamId'); } catch (_) {}
        try { pool.off('error'); } catch (_) {}
        await pool.release();
      }
    } finally {
      // A late getRawFd/load callback must finish its old-session cleanup before
      // another pool can open the same raw-resource path.
      await Promise.allSettled(loads);
      for (const path of paths) {
        try { await this.context.resourceManager.closeRawFd(path); } catch (_) {}
      }
    }
  }

  private async ensurePool(): Promise<media.SoundPool> {
    if (this.closing) await this.closing;
    if (this.pool) return this.pool;
    if (this.initializing) return this.initializing;
    const operation = this.createPool(this.lifecycle);
    this.initializing = operation;
    try { return await operation; }
    finally { if (this.initializing === operation) this.initializing = undefined; }
  }

  private async createPool(epoch: number): Promise<media.SoundPool> {
    const manager = audio.getAudioManager();
    const routing = manager.getRoutingManager();
    const volume = await manager.getVolumeManager().getVolumeGroupManager(0);
    const pool = await media.createSoundPool(2, this.renderer);
    if (epoch !== this.lifecycle) {
      await pool.release();
      throw new Error('Sound pool released');
    }
    this.pool = pool; this.routing = routing; this.volume = volume;
    try {
      routing.on('preferOutputDeviceChangeForRendererInfo', this.renderer, this.routeChanged);
      volume.on('ringerModeChange', this.ringerChanged);
      pool.on('loadComplete', (sound: number): void => {
        if (this.pool !== pool) return;
        this.loaded.add(sound);
        const waiter = this.waiters.get(sound);
        if (waiter) {
          clearTimeout(waiter.timeout); this.waiters.delete(sound); waiter.resolve();
        }
      });
      pool.on('playFinishedWithStreamId', (stream: number): void => {
        if (this.pool === pool) this.streams.delete(stream);
      });
      pool.on('error', (_error: BusinessError): void => {
        if (this.pool !== pool) return;
        for (const waiter of this.waiters.values()) {
          clearTimeout(waiter.timeout); waiter.reject(new Error('Sound cue unavailable'));
        }
        this.waiters.clear(); this.stopAll();
      });
      return pool;
    } catch (error) {
      await this.release();
      throw error as Error;
    }
  }

  private async loadCue(pool: media.SoundPool, cue: SensoryCue): Promise<number> {
    const existing = this.sounds.get(cue);
    if (existing !== undefined) return existing;
    const loading = this.loads.get(cue);
    if (loading) return loading;
    const operation = this.loadResource(pool, cue, this.lifecycle);
    this.loads.set(cue, operation);
    // Keep both success and failure until release, so a bad resource is not
    // repeatedly opened on every interaction.
    return operation;
  }

  private async loadResource(pool: media.SoundPool, cue: SensoryCue, epoch: number): Promise<number> {
    const path = this.pathFor(cue);
    const descriptor = await this.context.resourceManager.getRawFd(path);
    if (epoch !== this.lifecycle || pool !== this.pool) {
      await this.context.resourceManager.closeRawFd(path);
      throw new Error('Sound pool released');
    }
    this.rawPaths.add(path);
    const sound = await pool.load(descriptor.fd, descriptor.offset, descriptor.length);
    if (epoch !== this.lifecycle || pool !== this.pool) throw new Error('Sound pool released');
    if (!this.loaded.has(sound)) {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => {
          this.waiters.delete(sound); reject(new Error('Sound cue did not finish loading'));
        }, 5000);
        this.waiters.set(sound, { resolve: resolve, reject: reject, timeout: timer });
      });
    }
    if (epoch !== this.lifecycle || pool !== this.pool) throw new Error('Sound pool released');
    this.sounds.set(cue, sound);
    return sound;
  }

  private async headphonesReady(): Promise<boolean> {
    const routing = this.routing;
    const volume = this.volume;
    if (!routing || !volume) return false;
    const epoch = this.routeEpoch;
    const devices = await routing.getPreferOutputDeviceForRendererInfo(this.renderer);
    const mode = await volume.getRingerMode();
    if (epoch !== this.routeEpoch || mode !== audio.AudioRingMode.RINGER_MODE_NORMAL || devices.length === 0) return false;
    return devices.every((device: audio.AudioDeviceDescriptor): boolean => {
      // A2DP/SCO can also describe speakers and cars. No Bluetooth name or MAC
      // lookup is used as a substitute for an actual headphone classification.
      return device.deviceRole === audio.DeviceRole.OUTPUT_DEVICE &&
        (device.deviceType === audio.DeviceType.WIRED_HEADSET ||
          device.deviceType === audio.DeviceType.WIRED_HEADPHONES ||
          device.deviceType === audio.DeviceType.USB_HEADSET);
    });
  }

  private async stopAll(): Promise<void> {
    const pool = this.pool;
    const streams = Array.from(this.streams);
    this.streams.clear();
    if (!pool) return;
    for (const stream of streams) {
      try { await pool.setVolume(stream, 0, 0); } catch (_) {}
      try { await pool.stop(stream); } catch (_) {}
    }
  }

  private async stopHaptic(): Promise<void> {
    if (!this.hapticStarted) return;
    this.hapticStarted = false;
    try { await vibrator.stopVibration(); } catch (_) {}
  }

  private pathFor(cue: SensoryCue): string {
    switch (cue) {
      case 'send': return 'audio/send-felt-c6.wav';
      case 'reply': return 'audio/reply-major-nine.wav';
      case 'effort': return 'audio/effort-watch-click.wav';
      case 'bookmark': return 'audio/bookmark-chime.wav';
    }
  }
}
