import { audio } from '@kit.AudioKit';
import { open as decOpen, read as decRead, seek as decSeek, close as decClose,
  handles as decHandles, version as decVersion, stats as decStats,
  setRate as decSetRate, openSacdTrack as decOpenSacdTrack } from 'libmiwen.so';
import { Logger } from '../common/Logger';

const TAG: string = 'NativePlayer';

/** SACD ISO 虚拟曲目的 uri 方案：`<iso路径>#mwi:<trackIndex>`（扫描入库时展开） */
export function SplitIsoUri(uri: string): string[] {
  const at = uri.lastIndexOf('#mwi:');
  if (at < 0) {
    return [];
  }
  const idxStr = uri.substring(at + 5);
  if (!/^\d+$/.test(idxStr)) {
    return [];
  }
  return [uri.substring(0, at), idxStr];
}

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
  /** 变速不变调（Pro 2.0）：WSOLA 在 native 侧做；1.0 = 原速直通 */
  private rate: number = 1.0;
  /**
   * 源时间轴帧数（变速折算后的累计源帧）。变速时 read 返回的是"输出帧"，
   * 直接当进度用会错 rate 倍——按 gotFrames*rate 折算回源帧，seek 时置为落点。
   */
  private srcFrames: number = 0;
  /** 输出电平统计：每 2 秒一条 rms 日志 */
  private rmsSum: number = 0;
  private rmsCount: number = 0;
  private rmsNextFrame: number = 0;

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

  /** 打开并解析文件头。失败时 error 是可直接展示的中文原因。
   *  SACD ISO 的虚拟曲目走 `#mwi:<idx>` 方案，openSacdTrack 直连 native。 */
  open(path: string): boolean {
    this.release();
    const isoParts = SplitIsoUri(path);
    const info = isoParts.length === 2 ? decOpenSacdTrack(isoParts[0], parseInt(isoParts[1])) : decOpen(path);
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
    this.srcFrames = 0;
    this.ended = false;
    this.rmsSum = 0;
    this.rmsCount = 0;
    this.rmsNextFrame = this.sampleRate * 2;
    // 变速是会话级偏好：换曲保持，open 后立即应用到新句柄
    try {
      decSetRate(this.id, this.rate);
    } catch (e) {
      Logger.warn(TAG, `setRate on open failed ${JSON.stringify(e)}`);
    }

    // 多声道（3–6）：v1.7.0 起支持解码，输出层 downmix 立体声（真机只有两个扬声器）。
    // renderer 通道恒为 1/2，fill() 里按源声道读取后混音。
    if (this.channels < 1 || this.channels > 6) {
      this.lastError = `暂不支持 ${this.channels} 声道（支持 1–6）`;
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
    // 进度走"源时间轴"：变速时输出帧 ×rate 才是真实播放位置
    return Math.floor(this.srcFrames * 1000 / this.sampleRate);
  }

  /** 变速不变调：0.5~2.0；1.0 = 原速。播放中即时生效，换曲保持 */
  setRate(rate: number): void {
    const r: number = Math.max(0.5, Math.min(2.0, rate));
    this.rate = r;
    if (this.id !== 0) {
      try {
        decSetRate(this.id, r);
      } catch (e) {
        Logger.warn(TAG, `setRate failed ${JSON.stringify(e)}`);
      }
    }
    Logger.info(TAG, `rate -> ${r}`);
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
    this.srcFrames = landed;
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
        channels: this.channels === 1 ? audio.AudioChannel.CHANNEL_1 : audio.AudioChannel.CHANNEL_2,        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_F32LE,
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
      Logger.info(TAG, `renderer built ${this.sampleRate}Hz ${this.channels}ch` +
        (this.channels > 2 ? '(→2 downmix)' : '') + ' f32le');
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

    // 输出通道恒 1/2；源是 3–6 声道时按源声道解码，写入前 downmix（v1.7.0）
    const outCh: number = this.channels > 2 ? 2 : this.channels;
    const outFrames: number = Math.floor(data.byteLength / (4 * outCh));
    if (outFrames <= 0) {
      return audio.AudioDataCallbackResult.INVALID;
    }

    let src: ArrayBuffer | null = null;
    try {
      src = decRead(this.id, outFrames);
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
    if (this.channels > 2) {
      // N→2 downmix：ch0=L 基底、ch1=R 基底，其余声道 0.5 幅度同混入两侧（布局未知时的保守混法）
      const n: number = Math.min(gotFrames, outFrames);
      for (let f = 0; f < n; f++) {
        const base: number = f * this.channels;
        let l: number = got[base];
        let r: number = got[base + 1];
        for (let c = 2; c < this.channels; c++) {
          l += got[base + c] * 0.5;
          r += got[base + c] * 0.5;
        }
        dst[f * 2] = Math.max(-1, Math.min(1, l));
        dst[f * 2 + 1] = Math.max(-1, Math.min(1, r));
      }
      if (gotFrames < outFrames) {
        dst.fill(0, gotFrames * 2);
      }
      this.writtenFrames += gotFrames;
      this.srcFrames += gotFrames * this.rate;
      this.trackLevel(new Float32Array(dst.subarray(0, n * 2)));
      if (gotFrames < outFrames) {
        if (!this.ended) {
          this.ended = true;
          setTimeout(() => {
            if (this.onEnded !== null) {
              this.onEnded();
            }
          }, 0);
        }
      }
      return audio.AudioDataCallbackResult.VALID;
    }

    dst.set(got, 0);
    this.writtenFrames += gotFrames;
    this.srcFrames += gotFrames * this.rate;
    this.trackLevel(got);
    if (gotFrames < outFrames) {
      dst.fill(0, got.length);
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
    return audio.AudioDataCallbackResult.VALID;
  }

  /**
   * 输出电平统计。两条用途：
   * 1. 判断"进度在走但没声音"——rms 一直 0 就说明解码给的是静音，而不是渲染器的问题；
   * 2. 核对解码值域——知道了源素材的 RMS 就能反查位深/浮点是否解释错（差 256 倍这类硬错一眼看出）。
   * 抽样步长 8：44100Hz 下每 8 个样本取一个，对 RMS 是无偏估计，也不至于在音频回调里逐样本比较。
   */
  private trackLevel(got: Float32Array): void {
    for (let i = 0; i < got.length; i += 8) {
      const v: number = got[i];
      this.rmsSum += v * v;
      this.rmsCount++;
    }
    if (this.writtenFrames < this.rmsNextFrame) {
      return;
    }
    const rms: number = this.rmsCount > 0 ? Math.sqrt(this.rmsSum / this.rmsCount) : 0;
    const dbg: string = decStats(this.id);
    Logger.info(TAG, `level rms=${rms.toFixed(3)} @${this.getPositionMs()}ms` +
      (dbg.length > 0 ? ` [${dbg}]` : ''));
    this.rmsSum = 0;
    this.rmsCount = 0;
    this.rmsNextFrame = this.writtenFrames + this.sampleRate * 2;
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
    this.srcFrames = 0;
    this.rmsSum = 0;
    this.rmsCount = 0;
    this.rmsNextFrame = 0;
  }
}
