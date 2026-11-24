import { audio } from '@kit.AudioKit';
import { open as decOpen, read as decRead, seek as decSeek, close as decClose,
  handles as decHandles, version as decVersion } from 'libmiwen.so';
import { Logger } from '../common/Logger';

const TAG: string = 'NativePlayer';

/**
 * 原生解码播放通道。
 *
 * 为什么需要它：AVPlayer 的解码器是系统给的那一套，APE / ALAC / WavPack / AIFF
 * 解不了（识别层只能拦下来给话术）。这里换成"自己解 → 自己喂 PCM"：
 * libmiwen.so 解出交错 float32，AudioRenderer 以 SAMPLE_FORMAT_F32LE 直接播。
 *
 * 几个刻意的取舍：
 * 1. **不做重采样**。AudioRenderer 的采样率必须与素材一致，否则变调。素材采样率
 *    落在系统支持列表之外时直接报错，不静默凑合 —— 变调比"播不了"更伤发烧友信任。
 * 2. **进度口径是"已写入帧数"**，比真实出声早约一个缓冲区（100~200ms）。AVPlayer
 *    那边同样有这个延迟，界面观感一致即可；精确口径要等系统给播放位置回调。
 * 3. **write() 已废弃**（API 11 起），走 on('writeData') 回调，由系统按需索要数据。
 */
export class NativePlayer {

  private id: number = 0;
  private renderer: audio.AudioRenderer | null = null;
  private channels: number = 2;
  private sampleRate: number = 44100;
  private totalFrames: number = 0;
  private writtenFrames: number = 0;
  private durationMs: number = 0;
  private ended: boolean = false;
  private playing: boolean = false;
  private starting: boolean = false;
  private onEnded: (() => void) | null = null;
  private onInterrupt: ((event: audio.InterruptEvent) => void) | null = null;
  /** 直出模式：旁路系统音效。AudioRenderer 也开放了 setAudioEffectMode，与 AVPlayer 同口径 */
  private direct: boolean = false;

  /** 这个后缀是否由原生解码器负责 */
  static handles(suffix: string): boolean {
    try {
      return decHandles(suffix);
    } catch (e) {
      Logger.warn(TAG, `handles(${suffix}) failed ${JSON.stringify(e)}`);
      return false;
    }
  }

  static version(): string {
    try {
      return decVersion();
    } catch (e) {
      return 'native 未加载';
    }
  }

  /** 打开并解析文件头。失败时 error 是可直接展示的中文原因。 */
  open(path: string): boolean {
    this.release();
    const info = decOpen(path);
    if (!info.ok) {
      Logger.warn(TAG, `open failed ${path}: ${info.error}`);
      this.lastError = info.error.length > 0 ? info.error : '解码器打不开该文件';
      return false;
    }
    this.id = info.id;
    this.channels = info.channels;
    this.sampleRate = info.sampleRate;
    this.totalFrames = info.totalFrames;
    this.durationMs = info.durationMs;
    this.writtenFrames = 0;
    this.ended = false;

    if (this.channels < 1 || this.channels > 2) {
      this.lastError = `暂不支持 ${this.channels} 声道（当前支持单声道与立体声）`;
      this.release();
      return false;
    }
    if (this.sampleRate < 8000 || this.sampleRate > 192000) {
      this.lastError = `采样率 ${this.sampleRate} Hz 不在支持范围`;
      this.release();
      return false;
    }

    Logger.info(TAG, `opened ${info.format} ${this.sampleRate}Hz ${this.channels}ch ` +
      `${info.bitsPerSample}bit ${this.durationMs}ms`);
    return true;
  }

  private lastError: string = '';

  errorText(): string {
    return this.lastError;
  }

  formatName(): string {
    return '';
  }

  getDurationMs(): number {
    return this.durationMs;
  }

  getPositionMs(): number {
    if (this.sampleRate <= 0) {
      return 0;
    }
    return Math.floor(this.writtenFrames * 1000 / this.sampleRate);
  }

  setEndCallback(cb: () => void): void {
    this.onEnded = cb;
  }

  /** 音频焦点变化（来电、其他应用播放）。原生通道没有 AVPlayer 替我们申请焦点，必须自己听。 */
  setInterruptCallback(cb: (event: audio.InterruptEvent) => void): void {
    this.onInterrupt = cb;
  }

  /** 直出模式开关。渲染器已经建好时立即生效，否则记下来在创建后应用。 */
  setDirectMode(on: boolean): void {
    this.direct = on;
    if (this.renderer !== null) {
      this.applyDirect();
    }
  }

  /** 0.0 ~ 1.0；DUCK 时把音量压下去 */
  setVolume(v: number): void {
    if (this.renderer === null) {
      return;
    }
    const vol: number = Math.max(0, Math.min(1, v));
    this.renderer.setVolume(vol).catch((e: Error) => {
      Logger.warn(TAG, `setVolume failed ${e.message}`);
    });
  }

  async start(): Promise<boolean> {
    if (this.id === 0 || this.starting) {
      return false;
    }
    if (this.renderer === null) {
      const built: boolean = await this.buildRenderer();
      if (!built) {
        return false;
      }
    }
    this.starting = true;
    try {
      await this.renderer!.start();
      this.playing = true;
      Logger.info(TAG, 'renderer started');
      return true;
    } catch (e) {
      Logger.warn(TAG, `start failed ${JSON.stringify(e)}`);
      this.lastError = '音频输出启动失败';
      return false;
    } finally {
      this.starting = false;
    }
  }

  async pause(): Promise<void> {
    if (this.renderer === null || !this.playing) {
      return;
    }
    try {
      await this.renderer.pause();
      this.playing = false;
      Logger.info(TAG, 'renderer paused');
    } catch (e) {
      Logger.warn(TAG, `pause failed ${JSON.stringify(e)}`);
    }
  }

  /** 定位到 ms 毫秒。返回实际定位到的毫秒。 */
  async seekTo(ms: number): Promise<number> {
    if (this.id === 0) {
      return 0;
    }
    const frame: number = Math.floor(Math.max(0, ms) * this.sampleRate / 1000);
    const landed: number = decSeek(this.id, Math.min(frame, this.totalFrames));
    if (landed < 0) {
      return this.getPositionMs();
    }
    this.writtenFrames = landed;
    this.ended = false;
    return this.getPositionMs();
  }

  async stop(): Promise<void> {
    await this.pause();
    this.release();
  }

  private async buildRenderer(): Promise<boolean> {
    // 采样率按素材原样给，系统不支持就让它抛错，而不是悄悄换成 48k
    const opts: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: this.sampleRate,
        channels: this.channels === 1 ? audio.AudioChannel.CHANNEL_1 : audio.AudioChannel.CHANNEL_2,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_F32LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      rendererInfo: {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      }
    };
    try {
      this.renderer = await audio.createAudioRenderer(opts);
      this.renderer.on('writeData', (data: ArrayBuffer) => this.fill(data));
      this.renderer.on('audioInterrupt', (event: audio.InterruptEvent) => {
        Logger.info(TAG, `interrupt hint=${event.hintType} force=${event.forceType}`);
        if (this.onInterrupt !== null) {
          this.onInterrupt(event);
        }
      });
      Logger.info(TAG, `renderer built ${this.sampleRate}Hz ${this.channels}ch f32le`);
      if (this.direct) {
        await this.applyDirect();
      }
      return true;
    } catch (e) {
      Logger.warn(TAG, `createAudioRenderer failed ${JSON.stringify(e)}`);
      this.renderer = null;
      this.lastError = `音频输出不支持 ${this.sampleRate}Hz / ${this.channels} 声道`;
      return false;
    }
  }

  /** 旁路系统音效。与 AVPlayer 的 audioEffectMode 是同一个开关，只是挂在渲染器上 */
  private async applyDirect(): Promise<void> {
    const r: audio.AudioRenderer | null = this.renderer;
    if (r === null) {
      return;
    }
    try {
      const mode: audio.AudioEffectMode = this.direct
        ? audio.AudioEffectMode.EFFECT_NONE
        : audio.AudioEffectMode.EFFECT_DEFAULT;
      await r.setAudioEffectMode(mode);
      Logger.info(TAG, `audioEffectMode=${this.direct ? 'NONE' : 'DEFAULT'}`);
    } catch (e) {
      // 与 AVPlayer 侧一致：改不了就降级，不打断播放
      Logger.warn(TAG, `setAudioEffectMode failed ${JSON.stringify(e)}`);
    }
  }

  /** 系统要数据时被调用：解一缓冲、拷贝、写满。返回值决定这段数据是否有效。 */
  private fill(data: ArrayBuffer): audio.AudioDataCallbackResult {
    const dst: Float32Array = new Float32Array(data);
    if (this.id === 0 || this.ended) {
      dst.fill(0);
      return audio.AudioDataCallbackResult.VALID;
    }

    const bytesPerFrame: number = 4 * this.channels;
    const wantFrames: number = Math.floor(data.byteLength / bytesPerFrame);
    if (wantFrames <= 0) {
      return audio.AudioDataCallbackResult.INVALID;
    }

    let src: ArrayBuffer | null = null;
    try {
      src = decRead(this.id, wantFrames);
    } catch (e) {
      Logger.warn(TAG, `read failed ${JSON.stringify(e)}`);
      src = null;
    }

    if (src === null || src.byteLength === 0) {
      // 到底了：补静音并通知上层收尾。回调里直接 stop 容易和音频线程互等，放到下一轮事件循环。
      dst.fill(0);
      if (!this.ended) {
        this.ended = true;
        Logger.info(TAG, `eof at ${this.getPositionMs()}ms`);
        setTimeout(() => {
          if (this.onEnded !== null) {
            this.onEnded();
          }
        }, 0);
      }
      return audio.AudioDataCallbackResult.VALID;
    }

    const got: Float32Array = new Float32Array(src);
    const gotFrames: number = Math.floor(got.length / this.channels);
    dst.set(got, 0);
    if (gotFrames < wantFrames) {
      dst.fill(0, got.length);
      this.writtenFrames += gotFrames;
      if (!this.ended) {
        this.ended = true;
        setTimeout(() => {
          if (this.onEnded !== null) {
            this.onEnded();
          }
        }, 0);
      }
      return audio.AudioDataCallbackResult.VALID;
    }
    this.writtenFrames += gotFrames;
    return audio.AudioDataCallbackResult.VALID;
  }

  private release(): void {
    if (this.renderer !== null) {
      const r: audio.AudioRenderer = this.renderer;
      this.renderer = null;
      try {
        r.off('writeData');
      } catch (e) {
        // 已释放时 off 会抛，忽略
      }
      r.release().catch((e: Error) => {
        Logger.warn(TAG, `release failed ${e.message}`);
      });
    }
    if (this.id !== 0) {
      decClose(this.id);
      this.id = 0;
    }
    this.playing = false;
    this.ended = false;
    this.writtenFrames = 0;
  }
}
