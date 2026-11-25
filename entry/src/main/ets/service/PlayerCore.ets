import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { audio } from '@kit.AudioKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Track } from '../model/Track';
import { PlayerSnapshot, emptySnapshot } from '../model/PlayerState';
import { TrackStore } from '../db/TrackStore';
import { PlaylistStore } from '../db/PlaylistStore';
import { StatsStore } from '../db/StatsStore';
import { SettingsService } from './SettingsService';
import { ProService, PRO_KEY } from './ProService';
import { LyricService } from './LyricService';
import { NativePlayer } from './NativePlayer';
import { LrcLine, LrcParser } from '../common/Lrc';

const TAG: string = 'PlayerCore';

/**
 * 播放内核（单例）。
 *
 * 为什么必须单例：
 * - AVSession 一个进程只能有一个，跟着页面走就会被销毁；
 * - 队列要活得比页面长，返回首页/切 tab 时播放不能断；
 * - 长时任务的申请与释放必须成对。
 *
 * 两种引擎：
 * - local：AVPlayer + fdSrc，一首一个实例，切歌先摘引用再 release（旧实例的迟到回调自动作废）；
 * - demo：示例曲库没有真实文件，用 200ms 计时器推进度，保证播放/暂停/进度/上下曲都能验收。
 *
 * 状态同步只有一条路：所有变更走 notify()，UI 拿到的是一份完整快照。
 */
export class PlayerCore {
  private static single: PlayerCore | null = null;

  private ctx: common.UIAbilityContext | null = null;
  private player: media.AVPlayer | null = null;
  private session: avSession.AVSession | null = null;
  private fd: number = -1;

  private queue: Track[] = [];
  private index: number = -1;
  private position: number = 0;
  private duration: number = 0;
  private status: string = Const.ST_IDLE;
  private mode: string = Const.MODE_LOOP;
  private errorText: string = '';
  private isDemo: boolean = false;
  private lrc: string = '';

  private demoTimer: number = -1;
  // 原生解码通道（AIFF/AIFC，后续 WavPack/ALAC/APE）：AVPlayer 解不了，自己解 PCM 喂 AudioRenderer
  private native: NativePlayer | null = null;
  private isNative: boolean = false;
  private nativeTimer: number = -1;
  private skipTimer: number = -1;
  private sleepTimer: number = -1;
  private bgRunning: boolean = false;
  private ducked: boolean = false;
  private errorStreak: number = 0;
  /**
   * 同一轮起播只处理一次失败。
   * AVPlayer 进 error 状态后仍会持续回调 error，没有这层守卫时一首坏文件就能把
   * fail() 打成几十万次（真机日志里 streak 到过 482840，刷屏并且卡住界面）。
   * 每次 openReal / openNative 开始时复位。
   */
  private failHandled: boolean = false;
  private direct: boolean = false;
  private lastNotify: number = 0;
  private lastSessionSync: number = 0;
  // A-B 循环：-1 表示未设。只在内核里挡，UI 只展示与设置点
  private abA: number = -1;
  private abB: number = -1;
  // 播放统计：当前曲目的收听毫秒累计，换歌/暂停/退出时落库
  private listenUri: string = '';
  private listenMs: number = 0;
  private lastTickPos: number = 0;
  // CUE 分轨（密纹 Pro）：当前曲目的时间片（毫秒），-1 表示整轨播放
  private cueStart: number = -1;
  private cueEnd: number = -1;
  // 无缝播放（第二梯队第 8 项）：双 AVPlayer 预加载 + 提前切流 / 交叉淡入淡出
  private gapless: string = Const.GAP_OFF;
  private nextP: media.AVPlayer | null = null;
  private nextFd: number = -1;
  private nextIndex: number = -1;
  private nextReady: boolean = false;
  // 预加载失败过的队列序号：加密文件这类永久性失败会无限重试（100ms 一次，
  // 真机实测刷爆日志），记住失败序号，本轮播放内不再碰它；切歌时复位
  private nextFailIndex: number = -1;
  // 内核拉词的令牌：快速切歌时旧请求晚到不能覆盖新词
  private coreLrcToken: number = 0;
  private fadeTimer: number = -1;
  private fadeStart: number = 0;
  private fadeSwapped: boolean = false;
  /** 交叉淡入淡出期间还在出声的旧实例；接棒时挂在这里，k=1 再释放 */
  private fadeOld: media.AVPlayer | null = null;
  private fadeOldFd: number = -1;
  /**
   * 交叉淡入淡出的「对外显示暂存」。
   *
   * 音频必须立刻接棒（新实例已经在出声，旧实例只负责淡出），但界面上不能跟着跳：
   * 旧曲还剩 3 秒有声，标题/封面/进度条已经变成下一首，看起来像 bug。
   * 所以接棒时把旧曲的展示信息扣在这里，snapshot() / 播控 / 桌面歌词先返回这一份，
   * 到 k=1（旧实例真的静音并被释放）再一次性结算到新曲。
   *
   * 不是第二套播放状态：playing/status 始终取自当前实例，这里只暂存「显示哪首、进度多少」。
   */
  private uiHoldTrack: Track | null = null;
  private uiHoldIndex: number = -1;
  private uiHoldDur: number = 0;
  private uiHoldPos: number = 0;
  /** 旧曲的时间片起点：CUE 虚拟轨要把文件绝对位置换算回片内位置 */
  private uiHoldCue: number = 0;
  // 桌面歌词：AVMetadata.lyric 给系统整份带时间轴的 LRC，singleLyricText 是我们推的当前行
  private lyricLines: LrcLine[] = [];
  private lastLyricLine: number = -1;
  private lastLyricPush: number = 0;
  private rawDur: number = 0;
  /** CUE 试用解锁标记：本队列会话内自动连播不再重复扣试用（一张分轨专辑能把 3 次一秒烧光） */
  private cueUnlocked: boolean = false;

  private listeners: Array<(s: PlayerSnapshot) => void> = [];

  static instance(): PlayerCore {
    if (PlayerCore.single === null) {
      PlayerCore.single = new PlayerCore();
    }
    return PlayerCore.single;
  }

  // ---------------- 初始化 ----------------

  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.ctx !== null) {
      return;
    }
    this.ctx = ctx;
    this.direct = SettingsService.direct();
    this.mode = SettingsService.mode();
    this.gapless = SettingsService.gapless();
    await this.initSession();
    await this.restoreState();
    if (SettingsService.deskLyric()) {
      this.setDesktopLyric(true);
    }
    Logger.info(TAG, 'player core ready');
  }

  private async initSession(): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    try {
      this.session = await avSession.createAVSession(this.ctx, Const.SESSION_TAG, 'audio');
      this.session.on('play', () => {
        this.resume();
      });
      this.session.on('pause', () => {
        this.pause();
      });
      this.session.on('stop', () => {
        this.pause();
      });
      this.session.on('playNext', () => {
        this.next();
      });
      this.session.on('playPrevious', () => {
        this.prev();
      });
      this.session.on('seek', (time: number) => {
        this.seek(time);
      });
      await this.session.activate();
    } catch (e) {
      Logger.error(TAG, `session init failed ${JSON.stringify(e)}`);
    }
  }

  /**
   * 音频焦点。
   *
   * 挂在 AVPlayer 上而不是 AudioManager 上：焦点事件由播放器自己收，
   * AudioManager 只负责音量/设备。
   *
   * 只处理 FOCUS_LOSS 是常见的错：导航播报请求的是"可压低"，
   * 不实现 DUCK 就会两路声音叠在一起（导航在说话，歌还在原音量唱）。
   */
  private bindPlayerInterrupt(p: media.AVPlayer): void {
    p.on('audioInterrupt', (event: audio.InterruptEvent) => {
      Logger.info(TAG, `interrupt hint=${event.hintType}`);
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK) {
        this.duck(true);
      } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_UNDUCK) {
        this.duck(false);
      } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        this.pause();
      } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
        this.resume();
      }
    });
  }

  /** 压低到 30%，恢复回 1.0；不做暂停，否则导航会"切断"音乐 */
  private duck(on: boolean): void {
    this.ducked = on;
    const p: media.AVPlayer | null = this.player;
    if (p === null || this.isDemo) {
      return;
    }
    try {
      p.setVolume(on ? Const.DUCK_VOLUME : 1.0);
    } catch (e) {
      Logger.warn(TAG, 'setVolume failed');
    }
  }

  // ---------------- 队列 ----------------

  setQueue(list: Track[], startIndex: number): void {
    this.cueUnlocked = false;
    this.queue = list.slice(0);
    this.index = startIndex >= 0 && startIndex < this.queue.length ? startIndex : (this.queue.length > 0 ? 0 : -1);
    this.notify(true);
  }

  queueTracks(): Track[] {
    return this.queue;
  }

  /** 追加到队列末尾（不动当前曲目） */
  addToQueue(t: Track): void {
    if (this.queue.length === 0) {
      this.queue = [t];
      this.index = -1;
    } else {
      this.queue.push(t);
    }
    this.notify(true);
  }

  /** 插到当前曲目之后，下一首就播它 */
  playNext(t: Track): void {
    if (this.queue.length === 0 || this.index < 0) {
      this.queue.push(t);
      this.notify(true);
      return;
    }
    if (this.queue[this.index].uri === t.uri) {
      return;
    }
    this.queue.splice(this.index + 1, 0, t);
    this.notify(true);
  }

  removeAt(i: number): void {
    if (i < 0 || i >= this.queue.length) {
      return;
    }
    const wasCurrent: boolean = i === this.index;
    this.queue.splice(i, 1);
    if (this.queue.length === 0) {
      this.index = -1;
      this.pause();
      return;
    }
    if (wasCurrent) {
      this.index = Math.min(i, this.queue.length - 1);
      this.playAt(this.index).catch((e: Object) => Logger.warn(TAG, `${e}`));
      return;
    }
    if (i < this.index) {
      this.index--;
    }
    this.notify(true);
  }

  current(): Track | null {
    if (this.index < 0 || this.index >= this.queue.length) {
      return null;
    }
    return this.queue[this.index];
  }

  /** 播一张唱片/一个歌单：整体替换队列 */
  async playList(list: Track[], startIndex: number): Promise<void> {
    if (list.length === 0) {
      return;
    }
    this.setQueue(list, startIndex);
    await this.playAt(this.index);
  }

  async playAt(i: number, manual: boolean = true): Promise<void> {
    if (i < 0 || i >= this.queue.length) {
      return;
    }
    this.flushListen();
    this.index = i;
    const t: Track = this.queue[i];
    this.position = 0;
    // CUE 曲目的展示时长是时间片长度，不是整轨文件时长
    this.duration = t.cueEnd > t.cueStart ? t.cueEnd - t.cueStart : t.duration;
    this.rawDur = t.duration;
    this.errorText = '';
    this.clearSkipTimer();
    this.cancelFade(true);
    this.releaseNext();
    this.nextFailIndex = -1; // 换了曲目，之前预加载失败的下一曲值得再试一次
    this.cueStart = t.cueStart;
    this.cueEnd = t.cueEnd;
    this.lastLyricLine = -1;
    // A-B 只对一首歌有意义，换歌必须清掉，否则上一首的 B 点会把这一首卡死
    this.abA = -1;
    this.abB = -1;
    this.lastTickPos = 0;

    if (t.uri.startsWith(Const.DEMO_SCHEME)) {
      await this.releaseReal();
      this.isDemo = true;
      this.setStatus(Const.ST_PLAYING);
      this.startTicker();
    } else {
      // CUE 分轨是 Pro：手动点播消耗一次试用；试用解锁只对本队列会话生效，
      // 自动连播不重复扣，否则一张分轨专辑连播起来试用瞬间清零
      if (t.cueStart >= 0 && !ProService.isPro() && !this.cueUnlocked) {
        if (manual && ProService.consumeTrial('cue')) {
          this.cueUnlocked = true;
          Logger.info(TAG, `cue trial consumed, left ${ProService.trialLeft('cue')}`);
        }
        if (!this.cueUnlocked) {
          this.fail('CUE 分轨是密纹 Pro 功能：手动点播可用一次试用，或到设置 → 密纹 Pro 解锁');
          return;
        }
      }
      this.isDemo = false;
      // 自建解码链（第二梯队第 7 项）：系统解码器解不了的格式交给 libmiwen.so + AudioRenderer。
      // 判定读 NativePlayer.handles()，与 Constants.UNDECODED_SUFFIX 是同一份口径的两面。
      if (NativePlayer.handles(t.suffix)) {
        if (t.cueStart >= 0) {
          // 分轨要按时间片裁 PCM，原生通道还没做窗口限制；放它播整轨会让用户听到下一轨
          this.fail('CUE 分轨暂只支持系统可解码的格式（WAV / FLAC）');
          return;
        }
        await this.openNative(t);
      } else if (Const.UNDECODED_SUFFIX.indexOf(t.suffix) >= 0) {
        // 识别层（第二梯队第 11 项）：还没接原生解码的格式，给明确话术而不是笼统报错
        this.fail(`${t.suffix.substring(1).toUpperCase()} 系统解码不了，原生解码器还没接入；先转成 FLAC/WAV`);
        return;
      } else {
        await this.openReal(t);
      }
    }

    this.setMeta(t);
    this.loadLrcForSession(t); // 后台也能有词：桌面歌词逐行推送不依赖页面
    this.pushSessionState(false);
    this.notify(true);
    SettingsService.saveCard(t.title, t.artist.length > 0 ? t.artist : '未知艺人', true);
    SettingsService.pushCard();
    PlaylistStore.addRecent(t).catch((e: Object) => Logger.warn(TAG, `${e}`));
    // 统计：起播事件 + 从这一刻起累计收听时长
    StatsStore.recordStart(t.uri).catch((e: Object) => Logger.warn(TAG, `stats ${e}`));
    this.listenUri = t.uri;
    this.listenMs = 0;
    this.persistState();
  }

  // ---------------- 播放控制 ----------------

  async toggle(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    if (this.index < 0) {
      await this.playAt(0);
      return;
    }
    if (this.status === Const.ST_PLAYING) {
      await this.pause();
    } else {
      await this.resume();
    }
  }

  async resume(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    if (this.index < 0) {
      await this.playAt(0);
      return;
    }
    if (this.isDemo) {
      this.setStatus(Const.ST_PLAYING);
      this.startTicker();
      this.pushSessionState(false);
      this.notify(true);
      return;
    }
    if (this.isNative) {
      const np: NativePlayer | null = this.native;
      if (np === null) {
        await this.playAt(this.index);
        return;
      }
      const ok: boolean = await np.start();
      if (!ok) {
        this.fail(np.errorText().length > 0 ? np.errorText() : '无法继续播放');
        return;
      }
      this.setStatus(Const.ST_PLAYING);
      this.startNativeTicker();
      this.pushSessionState(false);
      this.notify(true);
      return;
    }
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      // 出错后实例已释放，重新起播而不是干等
      await this.playAt(this.index);
      return;
    }
    try {
      this.setStatus(Const.ST_PLAYING);
      await p.play();
    } catch (e) {
      this.fail('无法开始播放，文件可能已损坏');
    }
  }

  async pause(): Promise<void> {
    // 淡出还没走完就暂停：先把过渡结算掉，否则旧实例会继续出声直到 3 秒结束
    this.cancelFade(true);
    this.flushListen();
    if (this.isDemo) {
      this.stopTicker();
      this.setStatus(Const.ST_PAUSED);
      this.pushSessionState(false);
      this.notify(true);
      this.persistState();
      return;
    }
    if (this.isNative) {
      const np: NativePlayer | null = this.native;
      if (np === null) {
        return;
      }
      await np.pause();
      this.stopNativeTicker();
      this.setStatus(Const.ST_PAUSED);
      this.pushSessionState(false);
      this.notify(true);
      this.stopBgTask();
      this.persistState();
      return;
    }
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return;
    }
    try {
      await p.pause();
      this.setStatus(Const.ST_PAUSED);
      this.pushSessionState(false);
      this.notify(true);
      this.stopBgTask();
      this.persistState();
    } catch (e) {
      Logger.warn(TAG, `pause failed ${JSON.stringify(e)}`);
    }
  }

  async next(): Promise<void> {
    if (this.uiHoldTrack !== null) {
      // 淡出期内核已经接到「旧曲的下一首」，这正是用户此刻想要的下一首；
      // 再 advance 一次会跳过它（index 已前进），所以这里只做结算
      this.cancelFade(true);
      return;
    }
    await this.advance(true);
  }

  async prev(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    // 播过 3 秒再按上一首 = 回到本曲开头，这是行业惯例
    if (this.position > 3000) {
      await this.seek(0);
      return;
    }
    const i: number = this.mode === Const.MODE_SHUFFLE
      ? this.randomIndex()
      : (this.index - 1 + this.queue.length) % this.queue.length;
    await this.playAt(i);
  }

  private async advance(manual: boolean): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    if (!manual && this.mode === Const.MODE_SINGLE) {
      // 播完的单曲要重新起播：completed 之后 seek 在部分版本不会重新拉流
      await this.playAt(this.index);
      return;
    }
    const i: number = this.mode === Const.MODE_SHUFFLE
      ? this.randomIndex()
      : (this.index + 1) % this.queue.length;
    await this.playAt(i, manual);
  }

  private randomIndex(): number {
    if (this.queue.length <= 1) {
      return 0;
    }
    let i: number = Math.floor(Math.random() * this.queue.length);
    if (i === this.index) {
      i = (i + 1) % this.queue.length;
    }
    return i;
  }

  async seek(ms: number): Promise<void> {
    // 淡出期内核已经在新曲上，而用户拖的是（界面上）旧曲的进度条：
    // 先结算再落针，避免「显示旧曲、定位到新曲」的错位
    this.cancelFade(true);
    const target: number = Math.max(0, Math.min(ms, this.duration > 0 ? this.duration : ms));
    this.position = target;
    if (this.isDemo) {
      this.notify(true);
      this.pushSessionState(true);
      return;
    }
    if (this.isNative) {
      const np: NativePlayer | null = this.native;
      if (np === null) {
        return;
      }
      const landed: number = await np.seekTo(target);
      this.position = landed;
      this.lastTickPos = landed; // 收听统计从新位置续算，不把回退算成负增量
      this.pushSessionState(true);
      this.notify(true);
      return;
    }
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return;
    }
    try {
      // CUE 曲目：用户拖的是时间片内进度，落盘到播放器要加回片头偏移
      await p.seek(this.rawPos(target));
      this.pushSessionState(true);
      this.notify(true);
    } catch (e) {
      Logger.warn(TAG, `seek failed ${JSON.stringify(e)}`);
    }
  }

  // ---------------- A-B 循环（密纹 Pro） ----------------

  /** 设 A 点 = 当前进度；已有 A 点时重设不影响 B */
  setPointA(): boolean {
    if (this.duration <= 0 || this.position >= this.duration - 500) {
      return false;
    }
    this.abA = this.position;
    // A 点动了以后 B 点可能跑到 A 前面，直接作废，宁可让用户重设也别循环出错
    if (this.abB >= 0 && this.abB <= this.abA) {
      this.abB = -1;
    }
    Logger.info(TAG, `ab loop A=${Math.round(this.abA)}ms`);
    this.notify(true);
    return true;
  }

  /** 设 B 点 = 当前进度，必须晚于 A 点至少 1 秒 */
  setPointB(): boolean {
    if (this.abA < 0 || this.position < this.abA + 1000) {
      return false;
    }
    this.abB = this.position;
    Logger.info(TAG, `ab loop B=${Math.round(this.abB)}ms`);
    this.notify(true);
    return true;
  }

  clearAB(): void {
    if (this.abA < 0 && this.abB < 0) {
      return;
    }
    this.abA = -1;
    this.abB = -1;
    this.notify(true);
  }

  /** 过了 B 点回 A 点。只在播放推进时调用， seek 的异步结果下一帧自然校正 */
  private abLoopCheck(pos: number): void {
    if (this.abA < 0 || this.abB < 0 || this.abB <= this.abA) {
      return;
    }
    if (pos >= this.abB) {
      this.seek(this.abA).catch((e: Object) => Logger.warn(TAG, `ab seek ${e}`));
      this.position = this.abA;
      Logger.info(TAG, `ab loop wrap ${Math.round(this.abA)}ms`);
    }
  }

  // ---------------- 播放统计 ----------------

  /** 正向推进的毫秒都算收听时长；seek 回退/跳歌的负差值不算 */
  private accumulateListen(nowPos: number): void {
    const delta: number = nowPos - this.lastTickPos;
    this.lastTickPos = nowPos;
    if (delta > 0 && delta <= 2000) {
      this.listenMs += delta;
    }
  }

  /** 换歌 / 暂停 / 退出时把累计时长落库。累计量小（≤ 一首曲长），单条 INSERT 足够 */
  private flushListen(): void {
    if (this.listenUri.length === 0 || this.listenMs < 1000) {
      this.listenUri = '';
      this.listenMs = 0;
      return;
    }
    const uri: string = this.listenUri;
    const ms: number = Math.floor(this.listenMs);
    this.listenUri = '';
    this.listenMs = 0;
    StatsStore.addListen(uri, ms).catch((e: Object) => Logger.warn(TAG, `stats flush ${e}`));
  }

  /** 可等待版：统计页要先落库再查，否则刚听的时间会缺席（真机验证踩过） */
  async flushStats(): Promise<void> {
    if (this.listenUri.length === 0 || this.listenMs < 1000) {
      this.listenUri = '';
      this.listenMs = 0;
      return;
    }
    const uri: string = this.listenUri;
    const ms: number = Math.floor(this.listenMs);
    this.listenUri = '';
    this.listenMs = 0;
    try {
      await StatsStore.addListen(uri, ms);
    } catch (e) {
      Logger.warn(TAG, `stats flush ${JSON.stringify(e)}`);
    }
  }

  // ---------------- 播放模式 / 收藏 ----------------

  setMode(mode: string): void {
    this.mode = mode;
    SettingsService.setMode(mode);
    this.notify(true);
  }

  cycleMode(): void {
    if (this.mode === Const.MODE_LOOP) {
      this.setMode(Const.MODE_SINGLE);
    } else if (this.mode === Const.MODE_SINGLE) {
      this.setMode(Const.MODE_SHUFFLE);
    } else {
      this.setMode(Const.MODE_LOOP);
    }
  }

  async toggleFavorite(): Promise<boolean> {
    const t: Track | null = this.current();
    if (t === null) {
      return false;
    }
    const fav: boolean = await PlaylistStore.toggleFavorite(t);
    this.notify(true);
    return fav;
  }

  /** 睡眠定时：分钟，0 = 关闭 */
  setSleep(minutes: number): void {
    if (this.sleepTimer >= 0) {
      clearTimeout(this.sleepTimer);
      this.sleepTimer = -1;
    }
    if (minutes <= 0) {
      return;
    }
    this.sleepTimer = setTimeout(() => {
      this.pause();
      this.sleepTimer = -1;
      Logger.info(TAG, 'sleep timer fired');
    }, minutes * 60000);
  }

  /** 退出到后台/切 tab 时落盘一次，供断点续播 */
  saveNow(): void {
    this.flushListen();
    this.persistState();
  }

  /** 用户已经看过错误提示，收起横幅（不改变播放状态） */
  clearError(): void {
    if (this.errorText.length === 0) {
      return;
    }
    this.errorText = '';
    if (this.status === Const.ST_ERROR) {
      this.setStatus(Const.ST_PAUSED);
    }
    this.notify(true);
  }

  /** 设置页的"模拟播放异常"，用来验收异常提示与自动跳曲 */
  simulateError(): void {
    this.fail('无法解码该文件（示例：APE/DSD 需要转成 FLAC 或 PCM）');
  }

  // ---------------- 直出模式（密纹 Pro）----------------

  /**
   * 直出：把系统音效链（Histen / 杜比 / 各种"增强"）旁路掉，PCM 原样送到输出。
   *
   * 鸿蒙只给第三方开放 AudioEffectMode 两态，没有频段增益接口，
   * 所以这里做的是"旁路"而不是"调曲线"——界面文案也必须这么写，不能叫均衡器。
   *
   * audioEffectMode 是动态属性，但首次生效必须在 play() 之前落（见 onState 的 prepared 分支），
   * 否则第一次播放仍会走系统音效，第二首才对。
   */
  setDirectMode(on: boolean): boolean {
    this.direct = on;
    SettingsService.setDirect(on);
    let ok: boolean = false;
    if (this.isNative) {
      // 原生通道的开关挂在 AudioRenderer 上，不是 AVPlayer
      if (this.native !== null) {
        this.native.setDirectMode(on);
        ok = true;
      }
    } else {
      ok = this.applyEffect();
    }
    Logger.info(TAG, `direct -> ${on ? 'ON' : 'OFF'} applied=${ok}`);
    this.notify(true);
    return ok;
  }

  directMode(): boolean {
    return this.direct;
  }

  private applyEffect(): boolean {
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return false;
    }
    try {
      const mode: audio.AudioEffectMode = this.direct
        ? audio.AudioEffectMode.EFFECT_NONE
        : audio.AudioEffectMode.EFFECT_DEFAULT;
      p.audioEffectMode = mode;
      Logger.info(TAG, `audioEffectMode=${mode === audio.AudioEffectMode.EFFECT_NONE ? 'NONE' : 'DEFAULT'}`);
      return true;
    } catch (e) {
      // 部分机型/部分状态不允许改，这里只降级不打断播放
      Logger.warn(TAG, `audioEffectMode failed ${JSON.stringify(e)}`);
      return false;
    }
  }

  // ---------------- 真实引擎 ----------------

  private async openReal(t: Track): Promise<void> {
    await this.releaseReal();
    this.failHandled = false;
    this.setStatus(Const.ST_LOADING);
    this.notify(true);
    let p: media.AVPlayer;
    try {
      p = await media.createAVPlayer();
      this.player = p;
      const file: fs.File = fs.openSync(t.path, fs.OpenMode.READ_ONLY);
      this.fd = file.fd;
      const size: number = t.size > 0 ? t.size : fs.statSync(t.path).size;

      p.on('stateChange', (state: media.AVPlayerState) => {
        this.onState(p, state);
      });
      p.on('timeUpdate', (time: number) => {
        this.handleTime(p, time);
      });
      p.on('durationUpdate', (d: number) => {
        this.handleDuration(p, d);
      });
      this.bindPlayerInterrupt(p);
      p.on('error', (err: BusinessError) => {
        Logger.error(TAG, `avplayer error ${err.code}`);
        this.fail(PlayerCore.hintOf(err.code));
      });

      // VERIFY: fdSrc 需要 length；传 0 在部分版本会被判为空文件
      p.fdSrc = { fd: this.fd, offset: 0, length: size };
    } catch (e) {
      Logger.error(TAG, `open real failed ${JSON.stringify(e)}`);
      await this.releaseReal();
      // 重装应用会让 FILE_ACCESS_PERSIST 授权失效，索引还在但 fd 打不开（13900001）。
      // 这时只说"文件失效"会让人以为歌没了，必须给出下一步动作。
      this.fail('文件打不开：可能被移动，或重装后目录授权失效。去设置里重选文件夹');
    }
  }

  /**
   * 原生解码通道。
   *
   * 与 openReal 的差别：这里没有 AVPlayer，PCM 由 libmiwen.so 解出来、AudioRenderer 按需索要。
   * 所以 duration / 进度 / 播完事件全部要自己维护 —— 系统不会再替我们发 timeUpdate。
   */
  private async openNative(t: Track): Promise<void> {
    await this.releaseReal();
    this.failHandled = false;
    this.isNative = true;
    this.setStatus(Const.ST_LOADING);
    this.notify(true);

    const np: NativePlayer = new NativePlayer();
    this.native = np;
    if (!np.open(t.path)) {
      const why: string = np.errorText();
      this.native = null;
      this.isNative = false;
      np.stop().catch((e: Object) => Logger.warn(TAG, `${e}`));
      // m4a 容器里未必是 ALAC（AAC/MP3 也走这个容器）：native 报「mp4 容器非 ALAC」
      // 说明系统本来就能解，回退 AVPlayer，不给用户报错。
      if (why.startsWith('mp4 容器非 ALAC')) {
        Logger.info(TAG, `m4a 非 ALAC（${why}），回退 AVPlayer`);
        await this.openReal(t);
        return;
      }
      this.fail(`原生解码打不开：${why}`);
      return;
    }

    // 时长只能从解码器拿：AVPlayer 的 durationUpdate 在原生通道里不存在
    this.duration = np.getDurationMs();
    // 直出（旁路系统音效）在原生通道同样生效：AudioRenderer 也有 setAudioEffectMode
    np.setDirectMode(this.direct);
    np.setInterruptCallback((event: audio.InterruptEvent) => {
      if (this.native !== np) {
        return;
      }
      this.handleNativeInterrupt(np, event);
    });
    np.setEndCallback(() => {
      if (this.native !== np) {
        return; // 已经切走，旧实例的迟到回调
      }
      Logger.info(TAG, 'native eof -> advance');
      this.advance(false).catch((e: Object) => Logger.warn(TAG, `${e}`));
    });

    const started: boolean = await np.start();
    if (this.native !== np) {
      return; // start 期间用户又切了歌
    }
    if (!started) {
      this.fail(np.errorText().length > 0 ? np.errorText() : '音频输出启动失败');
      return;
    }
    this.setStatus(Const.ST_PLAYING);
    this.errorText = '';
    this.errorStreak = 0;
    this.startBgTask();
    this.startNativeTicker();
    this.pushSessionState(false);
    this.notify(true);
    Logger.info(TAG, `native playing ${t.path} dur=${this.duration}ms`);
  }

  /** 原生通道的音频焦点处理，语义与 bindPlayerInterrupt 保持一致 */
  private handleNativeInterrupt(np: NativePlayer, event: audio.InterruptEvent): void {
    if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK) {
      np.setVolume(0.25);
      this.ducked = true;
      this.notify(true);
    } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_UNDUCK) {
      np.setVolume(1.0);
      this.ducked = false;
      this.notify(true);
    } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
      event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      this.pause().catch((e: Object) => Logger.warn(TAG, `interrupt pause ${e}`));
    } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      this.resume().catch((e: Object) => Logger.warn(TAG, `interrupt resume ${e}`));
    }
  }

  /** 原生通道的进度源：已写入 AudioRenderer 的帧数换算成毫秒，250ms 采一次 */
  private startNativeTicker(): void {
    this.stopNativeTicker();
    this.nativeTimer = setInterval(() => {
      const np: NativePlayer | null = this.native;
      if (np === null || this.status !== Const.ST_PLAYING) {
        return;
      }
      const ms: number = np.getPositionMs();
      if (ms < this.position) {
        return; // seek 之后位置还没追上，别让进度条来回跳
      }
      this.accumulateListen(ms);
      this.position = ms;
      this.abLoopCheck(ms);
      if (this.status !== Const.ST_PLAYING) {
        return; // A-B 回跳已经触发 seek，这一帧不再推
      }
      this.notify(false);
      this.pushSessionState(false);
    }, 250);
  }

  private stopNativeTicker(): void {
    if (this.nativeTimer >= 0) {
      clearInterval(this.nativeTimer);
      this.nativeTimer = -1;
    }
  }

  private onState(p: media.AVPlayer, state: media.AVPlayerState): void {
    if (p !== this.player) {
      return; // 旧实例的迟到回调，忽略
    }
    Logger.info(TAG, `state -> ${state}`);
    if (state === 'initialized') {
      p.prepare().catch((e: Object) => {
        Logger.error(TAG, `prepare failed ${e}`);
        this.fail('无法解析该音频，可能格式不受支持');
      });
    } else if (state === 'prepared') {
      // 直出必须在起播前落一次，否则首曲仍走系统音效
      this.applyEffect();
      p.play().catch((e: Object) => {
        Logger.error(TAG, `play failed ${e}`);
        this.fail('播放启动失败，请重试');
      });
    } else if (state === 'playing') {
      this.setStatus(Const.ST_PLAYING);
      this.errorText = '';
      this.errorStreak = 0;
      this.startBgTask();
      this.pushSessionState(false);
      this.notify(true);
    } else if (state === 'paused') {
      this.setStatus(Const.ST_PAUSED);
      this.pushSessionState(false);
      this.notify(true);
      this.persistState();
    } else if (state === 'completed') {
      // 无缝模式：预加载好的实例直接接棒，不走重建流程
      if (this.gapless === Const.GAP_SEAMLESS && this.swapToNext()) {
        return;
      }
      this.advance(false).catch((e: Object) => Logger.warn(TAG, `${e}`));
    }
  }

  private async releaseReal(): Promise<void> {
    this.releaseNext();
    this.cancelFade(true);
    this.releaseNative();
    const p: media.AVPlayer | null = this.player;
    this.player = null;
    if (p !== null) {
      try {
        if (p.state !== 'idle' && p.state !== 'released') {
          await p.stop();
        }
      } catch (e) {
        Logger.info(TAG, 'stop ignored');
      }
      try {
        await p.release();
      } catch (e) {
        Logger.warn(TAG, 'release failed');
      }
    }
    if (this.fd >= 0) {
      try {
        fs.closeSync(this.fd);
      } catch (e) {
        Logger.warn(TAG, 'fd already closed');
      }
      this.fd = -1;
    }
  }

  /**
   * 释放原生通道。不 await：AudioRenderer.release() 是异步的，对调用方来说
   * 只要"不再由我们驱动"就够了，句柄与 .so 内的解码器由 NativePlayer 自己收尾。
   */
  private releaseNative(): void {
    this.stopNativeTicker();
    const np: NativePlayer | null = this.native;
    this.native = null;
    this.isNative = false;
    if (np !== null) {
      np.stop().catch((e: Object) => Logger.warn(TAG, `native stop ${e}`));
    }
  }

  private static hintOf(code: number): string {
    if (code === 5400103) {
      return '网络或数据源中断（本地文件也可能被占用）';
    }
    if (code === 5400102) {
      return '当前状态不允许该操作，请重试';
    }
    if (code === 5400104 || code === 5400105) {
      return '文件读取超时，已跳过';
    }
    return '这个文件播不了，可能格式不受支持（APE/DSD 建议转 FLAC）';
  }

  // ---------------- CUE 时间片映射 ----------------

  /** 播放器原始毫秒 → 用户看到的分轨内毫秒 */
  private dispPos(raw: number): number {
    return this.cueStart >= 0 ? Math.max(0, raw - this.cueStart) : raw;
  }

  /** 用户看到的分轨内毫秒 → 播放器原始毫秒 */
  private rawPos(shown: number): number {
    return this.cueStart >= 0 ? this.cueStart + shown : shown;
  }

  /** timeUpdate 的统一入口（真实例与无缝预加载实例共用） */
  private handleTime(p: media.AVPlayer, time: number): void {
    if (p !== this.player) {
      return; // 旧实例 / 预加载实例的迟到回调
    }
    const shown: number = this.dispPos(time);
    this.accumulateListen(shown);
    this.abLoopCheck(shown);
    // CUE 时间片到点 = 下一轨，不必等整轨文件播完；无缝模式下直接切预加载实例
    if (this.cueEnd >= 0 && time >= this.cueEnd) {
      if (this.gapless === Const.GAP_SEAMLESS && this.swapToNext()) {
        return;
      }
      this.advance(false).catch((e: Object) => Logger.warn(TAG, `${e}`));
      return;
    }
    this.position = shown;
    this.gaplessTick(time, shown);
    this.pushLyricLine(shown);
    this.syncSessionThrottled();
    this.notify(false);
  }

  private handleDuration(p: media.AVPlayer, d: number): void {
    if (p !== this.player) {
      return;
    }
    this.rawDur = d;
    // 有 cueEnd 是中间轨（段长）；只有 cueStart 是末轨（到文件尾，时长 = 文件长 - 片头）；
    // 都没有是整轨。末轨不修的话显示时长会是整轨 24s，进度条比例全错。
    this.duration = this.cueEnd > this.cueStart
      ? this.cueEnd - this.cueStart
      : (this.cueStart >= 0 ? Math.max(0, d - this.cueStart) : d);
    const cur: Track | null = this.current();
    if (cur !== null && this.duration > 0 && cur.duration === 0) {
      cur.duration = this.duration;
      TrackStore.updateDuration(cur.uri, this.duration).catch((e: Object) => Logger.warn(TAG, `${e}`));
    }
    this.notify(true);
  }

  // ---------------- 无缝播放 / 交叉淡入淡出（密纹 Pro） ----------------

  /** 本次播放的原始终点：CUE 曲是时间片终点，整轨是文件尾 */
  private rawEnd(): number {
    return this.cueEnd >= 0 ? this.cueEnd : this.rawDur;
  }

  private gaplessTick(rawTime: number, shown: number): void {
    if (this.gapless === Const.GAP_OFF || this.queue.length <= 1 || this.isDemo) {
      return;
    }
    // 下一首不确定的模式没有"预加载下一曲"可言
    if (this.mode === Const.MODE_SINGLE || this.mode === Const.MODE_SHUFFLE) {
      return;
    }
    const remain: number = this.rawEnd() - rawTime;
    if (this.gapless === Const.GAP_FADE) {
      if (remain <= Const.FADE_MS && this.fadeTimer < 0) {
        this.prepareNext();
        this.startFade();
      }
      return;
    }
    if (remain <= Const.GAP_PRELOAD_MS) {
      this.prepareNext();
    }
  }

  /**
   * 预加载下一曲：起一个新 AVPlayer prepare 到位但不 play。
   * 真正的零缝隙要 PCM 管线（Pro 2.0 量级）；这里做到的是
   * "completed 回调 → 立刻起播已就绪实例"，把轨间缝压到感知阈值以下。
   */
  private prepareNext(): void {
    if (this.nextP !== null || this.nextIndex >= 0 || this.queue.length === 0) {
      return;
    }
    const ni: number = (this.index + 1) % this.queue.length;
    if (ni === this.index || ni === this.nextFailIndex) {
      return;
    }
    const t: Track = this.queue[ni];
    if (t.uri.startsWith(Const.DEMO_SCHEME) || t.path.length === 0) {
      return;
    }
    this.nextIndex = ni;
    media.createAVPlayer().then((np: media.AVPlayer) => {
      if (this.nextIndex !== ni) {
        // 等待期间队列变了，放弃这个实例
        PlayerCore.quietRelease(np);
        return;
      }
      this.nextP = np;
      try {
        const file: fs.File = fs.openSync(t.path, fs.OpenMode.READ_ONLY);
        this.nextFd = file.fd;
        const size: number = t.size > 0 ? t.size : fs.statSync(t.path).size;
        np.fdSrc = { fd: file.fd, offset: 0, length: size };
        this.wireNext(np, ni);
        this.bindPlayerInterrupt(np);
        Logger.info(TAG, `preload next #${ni} ${t.title}`);
      } catch (e) {
        Logger.warn(TAG, `preload failed ${JSON.stringify(e)}`);
        this.nextFailIndex = ni;
        this.releaseNext();
      }
    }).catch((e: Object) => {
      Logger.warn(TAG, `create next failed ${e}`);
      this.nextIndex = -1;
    });
  }

  /** 预加载实例的回调：换角色前处理就绪/失败，换角色后走通用路径 */
  private wireNext(np: media.AVPlayer, ni: number): void {
    np.on('stateChange', (state: media.AVPlayerState) => {
      if (np === this.nextP) {
        if (state === 'initialized') {
          np.prepare().catch((e: Object) => Logger.warn(TAG, `next prepare ${e}`));
        } else if (state === 'prepared') {
          this.nextReady = true;
          // 直出模式对预加载实例同样要在起播前落
          try {
            np.audioEffectMode = this.direct
              ? audio.AudioEffectMode.EFFECT_NONE
              : audio.AudioEffectMode.EFFECT_DEFAULT;
          } catch (e) {
            Logger.warn(TAG, 'next audioEffectMode failed');
          }
          Logger.info(TAG, `next ready #${ni}`);
        }
        return;
      }
      if (np === this.player) {
        this.onState(np, state);
      }
    });
    np.on('timeUpdate', (time: number) => {
      this.handleTime(np, time);
    });
    np.on('durationUpdate', (d: number) => {
      this.handleDuration(np, d);
    });
    np.on('error', (err: BusinessError) => {
      if (np === this.nextP) {
        Logger.warn(TAG, `preload error ${err.code}`);
        this.nextFailIndex = this.nextIndex;
        this.releaseNext();
        return;
      }
      if (np === this.player) {
        this.fail(PlayerCore.hintOf(err.code));
      }
    });
  }

  /**
   * 无缝切换：预加载实例直接接棒；返回 false 表示没接成，调用方退回普通 advance。
   * keepOld = true 时**不释放**旧实例（交叉淡入淡出要它继续出声），由 fadeTick 收尾。
   */
  private swapToNext(keepOld: boolean = false): boolean {
    if (this.nextP === null || !this.nextReady || this.nextIndex < 0) {
      return false;
    }
    const np: media.AVPlayer = this.nextP;
    const ni: number = this.nextIndex;
    const nfd: number = this.nextFd;
    const oldP: media.AVPlayer | null = this.player;
    const oldFd: number = this.fd;
    // 抓旧曲的展示信息（必须在覆盖 index/position 之前）：keepOld 时界面要停在这首上
    const oldIndex: number = this.index;
    const oldTrack: Track | null =
      oldIndex >= 0 && oldIndex < this.queue.length ? this.queue[oldIndex] : null;
    const oldDur: number = this.duration;
    const oldPos: number = this.position;
    const oldCue: number = this.cueStart;
    this.nextP = null;
    this.nextFd = -1;
    this.nextReady = false;
    this.nextIndex = -1;
    this.player = np;
    this.flushListen();
    this.index = ni;
    const t: Track = this.queue[ni];
    this.fd = nfd;
    this.cueStart = t.cueStart;
    this.cueEnd = t.cueEnd;
    this.duration = t.cueEnd > t.cueStart ? t.cueEnd - t.cueStart : t.duration;
    this.rawDur = t.duration;
    this.position = 0;
    this.lastTickPos = 0;
    this.abA = -1;
    this.abB = -1;
    this.errorText = '';
    this.clearSkipTimer();
    try {
      np.setVolume(this.ducked ? Const.DUCK_VOLUME : 1.0);
    } catch (e) {
      // 音量恢复失败不打断切换
    }
    // 无缝切到 CUE 虚拟轨：新实例起播位置是文件头，必须立刻 seek 到时间片起点
    if (this.cueStart > 0) {
      try {
        np.seek(this.cueStart);
      } catch (e) {
        Logger.warn(TAG, 'seamless cue seek failed');
      }
    }
    np.play().catch((e: Object) => {
      Logger.error(TAG, `seamless play failed ${e}`);
      this.fail('无缝切换起播失败，请重试');
    });
    if (oldP !== null) {
      if (keepOld) {
        // 交叉淡入淡出：旧实例还要出声，先挂起来由 fadeTick 压到 0 再释放
        this.fadeOld = oldP;
        this.fadeOldFd = oldFd;
        // 同时把对外显示扣在旧曲上，等 cancelFade 结算
        if (oldTrack !== null) {
          this.uiHoldTrack = oldTrack;
          this.uiHoldIndex = oldIndex;
          this.uiHoldDur = oldDur;
          this.uiHoldPos = oldPos;
          this.uiHoldCue = oldCue > 0 ? oldCue : 0;
        }
      } else {
        PlayerCore.quietRelease(oldP);
      }
    }
    if (oldFd >= 0 && !keepOld) {
      try {
        fs.closeSync(oldFd);
      } catch (e) {
        Logger.warn(TAG, 'old fd close failed');
      }
    }
    if (this.uiHoldTrack === null) {
      // 常规接棒（无缝档 / 无淡出）：对外立刻切到新曲
      this.setMeta(t);
      this.loadLrcForSession(t); // 后台也能有词：桌面歌词逐行推送不依赖页面
      this.pushSessionState(false);
    } else {
      // 交叉淡入淡出：音频已在新曲出声，但标题/进度/歌词先停在旧曲，由 cancelFade 结算
      Logger.info(TAG, `crossfade audio -> #${ni}, ui hold on #${oldIndex}`);
    }
    this.notify(true);
    SettingsService.saveCard(t.title, t.artist.length > 0 ? t.artist : '未知艺人', true);
    SettingsService.pushCard();
    PlaylistStore.addRecent(t).catch((e: Object) => Logger.warn(TAG, `${e}`));
    StatsStore.recordStart(t.uri).catch((e: Object) => Logger.warn(TAG, `stats ${e}`));
    this.listenUri = t.uri;
    this.listenMs = 0;
    this.persistState();
    Logger.info(TAG, `seamless switch -> #${ni} ${t.title}`);
    return true;
  }

  private startFade(): void {
    if (this.fadeTimer >= 0) {
      return;
    }
    this.fadeSwapped = false;
    this.fadeStart = Date.now();
    this.fadeTimer = setInterval(() => this.fadeTick(), 100);
    Logger.info(TAG, 'crossfade start');
  }

  /**
   * 交叉淡入淡出：两条音轨真的同时出声 3 秒。
   * 旧曲 1 → 0，新曲 0 → 1，同一个 k 走同一条包络；旧实例在 k=1 时才释放。
   * （早期版本接棒后立刻释放旧实例，实测两个日志只差 104ms，听感是"硬切 + 新曲淡入"，
   *   和界面上写的"两曲交叠 3 秒"不符，故改成保留旧实例。）
   */
  private fadeTick(): void {
    const k: number = Math.min(1, (Date.now() - this.fadeStart) / Const.FADE_MS);
    const cur: media.AVPlayer | null = this.player;
    const old: media.AVPlayer | null = this.fadeOld;
    const cap: number = this.ducked ? Const.DUCK_VOLUME : 1.0;
    // 界面还停在旧曲：进度条要跟着旧实例走，否则会冻在接棒那一刻
    if (this.uiHoldTrack !== null && old !== null) {
      try {
        const ct: number = old.currentTime;
        if (ct > 0) {
          this.uiHoldPos = this.uiHoldCue > 0 ? Math.max(0, ct - this.uiHoldCue) : ct;
        }
      } catch (e) {
        // 实例正在释放，读不到就沿用上一次的位置
      }
      this.notify(false);
    }
    if (!this.fadeSwapped) {
      // 还没接棒：只压当前曲，同时等预加载就绪
      try {
        if (cur !== null) {
          cur.setVolume(this.ducked ? Math.min(cap, cap * (1 - k)) : Math.max(0, 1 - k));
        }
      } catch (e) {
        // 音量调节失败继续走流程
      }
      if (this.nextP !== null && this.nextReady && this.swapToNext(true)) {
        this.fadeSwapped = true;
        try {
          if (this.player !== null) {
            this.player.setVolume(cap * 0.02);
          }
        } catch (e) {
          // 忽略
        }
      }
    } else {
      // 已接棒：旧曲继续下行到 0，新曲上行到满，两条曲线同时走
      try {
        if (old !== null) {
          old.setVolume(cap * Math.max(0, 1 - k));
        }
      } catch (e) {
        // 忽略
      }
      try {
        if (cur !== null) {
          cur.setVolume(cap * Math.max(0.02, Math.min(1, k)));
        }
      } catch (e) {
        // 忽略
      }
    }
    if (k >= 1) {
      const swapped: boolean = this.fadeSwapped;
      this.cancelFade(true);
      if (!swapped) {
        // 下一曲始终没就绪（曲太短 / 预加载失败），退化为普通切歌
        this.advance(false).catch((e: Object) => Logger.warn(TAG, `${e}`));
      }
    }
  }

  /** 停掉淡入淡出并结算对外状态；resetVolume 时把音量恢复到正常值 */
  private cancelFade(resetVolume: boolean): void {
    if (this.fadeTimer >= 0) {
      clearInterval(this.fadeTimer);
      this.fadeTimer = -1;
      Logger.info(TAG, 'crossfade end');
    }
    this.fadeSwapped = false;
    const held: Track | null = this.uiHoldTrack;
    // 淡出中的旧实例到此为止（没接棒就退化的那种情况，fadeOld 为空，这里是空操作）
    this.releaseFading();
    if (resetVolume && !this.isDemo) {
      const p: media.AVPlayer | null = this.player;
      try {
        if (p !== null) {
          p.setVolume(this.ducked ? Const.DUCK_VOLUME : 1.0);
        }
      } catch (e) {
        // 忽略
      }
    }
    if (held !== null) {
      // 结算：旧曲已彻底静音并释放，此刻才把标题 / 进度 / 歌词 / 播控切到新曲。
      // 用户中途操作（暂停、拖进度、切歌）也走这里，保证不留"显示旧曲、声音新曲"的错位。
      const t: Track | null = this.current();
      if (t !== null) {
        this.setMeta(t);
        this.loadLrcForSession(t);
      }
      this.pushSessionState(true);
      this.notify(true);
      Logger.info(TAG, `crossfade settle ui -> #${this.index} (was ${held.title})`);
    }
  }

  private releaseNext(): void {
    const np: media.AVPlayer | null = this.nextP;
    const nfd: number = this.nextFd;
    this.nextP = null;
    this.nextFd = -1;
    this.nextReady = false;
    this.nextIndex = -1;
    this.releaseFading(); // 切歌/出错中断时，别把淡出中的旧实例留成幽灵音轨
    if (np !== null) {
      PlayerCore.quietRelease(np);
    }
    if (nfd >= 0) {
      try {
        fs.closeSync(nfd);
      } catch (e) {
        // fd 可能已被实例释放
      }
    }
  }

  /** 释放还在淡出的旧实例（交叉淡入淡出收尾、切歌、退出都要走一遍，不然会留一条幽灵音轨） */
  private releaseFading(): void {
    const p: media.AVPlayer | null = this.fadeOld;
    const fd: number = this.fadeOldFd;
    this.fadeOld = null;
    this.fadeOldFd = -1;
    // 旧实例没了就没有"停在哪首"可言，展示暂存一并清掉（结算动作由调用方决定）
    this.uiHoldTrack = null;
    this.uiHoldIndex = -1;
    this.uiHoldDur = 0;
    this.uiHoldPos = 0;
    this.uiHoldCue = 0;
    if (p !== null) {
      PlayerCore.quietRelease(p);
    }
    if (fd >= 0) {
      try {
        fs.closeSync(fd);
      } catch (e) {
        // 已关闭
      }
    }
  }

  /** 旧实例的静默释放：stop/release 失败都不影响主流程，资源由系统回收 */
  private static quietRelease(p: media.AVPlayer): void {
    try {
      if (p.state !== 'idle' && p.state !== 'released') {
        p.stop().catch(() => {
        });
      }
      p.release().catch(() => {
      });
    } catch (e) {
      // 忽略
    }
  }

  /** 无缝模式切换，立即生效并清理旧状态 */
  setGaplessMode(v: string): void {
    this.gapless = v;
    SettingsService.setGapless(v);
    this.releaseNext();
    this.cancelFade(true);
    Logger.info(TAG, `gapless -> ${v}`);
    this.notify(true);
  }

  gaplessMode(): string {
    return this.gapless;
  }

  // ---------------- 桌面歌词（密纹 Pro，走 AVSession 系统桌面歌词） ----------------

  /**
   * 开/关系统桌面歌词。
   * 返回空串表示成功；否则是给用户的失败话术。
   * 系统（API 23+）负责窗口渲染、拖动与锁屏共存，应用只负责喂歌词内容。
   */
  async setDesktopLyric(on: boolean): Promise<string> {
    SettingsService.setDeskLyric(on);
    if (this.session === null) {
      return on ? '播放会话还没就绪，稍后再试' : '';
    }
    try {
      if (on) {
        const sup: boolean = await avSession.isDesktopLyricSupported();
        if (!sup) {
          SettingsService.setDeskLyric(false);
          return '这台设备的系统桌面歌词不可用';
        }
        await this.session.enableDesktopLyric(true);
        await this.session.setDesktopLyricVisible(true);
        Logger.info(TAG, 'desktop lyric on');
        return '';
      }
      try {
        await this.session.setDesktopLyricVisible(false);
      } catch (e) {
        // 本来就不可见时忽略，继续关 enable
      }
      await this.session.enableDesktopLyric(false);
      Logger.info(TAG, 'desktop lyric off');
      return '';
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn(TAG, `desktop lyric ${on} failed code=${err.code}`);
      SettingsService.setDeskLyric(false);
      return on ? `系统没接受桌面歌词请求（${err.code}）` : '';
    }
  }

  deskLyricEnabled(): boolean {
    return SettingsService.deskLyric();
  }

  /** 把整份带时间轴歌词推给会话（锁屏 / 播控 / 桌面共用） */
  private pushLrcMeta(): void {
    if (this.session === null || this.lrc.length === 0 || !LrcParser.isTimed(this.lrc)) {
      return;
    }
    const t: Track | null = this.current();
    if (t === null) {
      return;
    }
    const meta: avSession.AVMetadata = { assetId: t.uri, lyric: this.lrc };
    this.session.setAVMetadata(meta).catch((e: Object) => Logger.warn(TAG, `lrc meta ${e}`));
  }

  /** 当前行推进（singleLyricText），按 400ms 节流、换行才推 */
  private pushLyricLine(pos: number): void {
    if (this.lyricLines.length === 0 || this.session === null) {
      return;
    }
    // 淡出期间对外还是旧曲：此时页面刚加载的是旧曲的词，而位置已属于新曲，
    // 两种都会把词挂到错的 assetId 上，等 cancelFade 结算时统一补推
    if (this.uiHoldTrack !== null) {
      return;
    }
    const i: number = LrcParser.indexAt(this.lyricLines, pos);
    if (i === this.lastLyricLine) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastLyricPush < 400) {
      return;
    }
    this.lastLyricLine = i;
    this.lastLyricPush = now;
    const t: Track | null = this.current();
    if (t === null) {
      return;
    }
    let line: string = '';
    if (i >= 0) {
      const l: LrcLine = this.lyricLines[i];
      line = l.trans.length > 0 ? `${l.text} / ${l.trans}` : l.text;
    }
    // 逐行推送必须带完整元数据：setAVMetadata 是整份覆盖，只给 singleLyricText 会把
    // title/duration 冲成空，而 duration 正是系统算桌面歌词进度的依据（缺了它高亮退回第 1 行）。
    // 同时把整份 LRC 一起重推：桌面窗口的高亮按"这一次推送里的位置"算，换行时重推才跟着跳。
    const meta: avSession.AVMetadata = this.fullMeta(t);
    meta.singleLyricText = line;
    this.session.setAVMetadata(meta).catch((e: Object) => Logger.warn(TAG, `lyric line ${e}`));
  }

  // ---------------- 示例引擎 ----------------

  private startTicker(): void {
    this.stopTicker();
    this.demoTimer = setInterval(() => {
      if (this.status !== Const.ST_PLAYING || !this.isDemo) {
        return;
      }
      const nextPos: number = this.position + 200;
      this.accumulateListen(nextPos);
      this.position = nextPos;
      if (this.duration > 0 && this.position >= this.duration) {
        this.position = this.duration;
        this.advance(false).catch((e: Object) => Logger.warn(TAG, `${e}`));
        return;
      }
      this.abLoopCheck(this.position);
      if (this.status !== Const.ST_PLAYING) {
        return; // A-B 回跳触发了 seek，这一帧不要继续推进
      }
      this.notify(false);
    }, 200);
  }

  private stopTicker(): void {
    if (this.demoTimer >= 0) {
      clearInterval(this.demoTimer);
      this.demoTimer = -1;
    }
  }

  // ---------------- 异常 ----------------

  private fail(msg: string): void {
    if (this.failHandled) {
      return;   // 同一个失败已经处理过，别被系统重复回调卷进死循环
    }
    this.failHandled = true;
    // 起播失败时若还在淡出，先把过渡结算掉：否则旧实例留着出声、界面停在旧曲上不出来
    this.cancelFade(true);
    // 出错的实例必须释放：AVPlayer 停在 error 状态会持续报错，留着它只会把日志打爆
    this.releaseReal().catch((e: Object) => Logger.warn(TAG, `release after fail ${e}`));
    this.errorText = msg;
    this.setStatus(Const.ST_ERROR);
    this.stopTicker();
    this.errorStreak++;
    // 带 streak 与延时，方便真机按日志时间戳核算提示停留是否符合预期
    Logger.warn(TAG, `playback failed: ${msg} (streak ${this.errorStreak}, skip after 2500ms)`);
    this.notify(true);
    this.pushSessionState(false);
    this.stopBgTask();
    // 队列里还有别的歌就自动跳过，连挂 3 首才停下（避免死循环）
    // 2.5s 停留：1.8s 时真机上错误文案读不完就被下一首覆盖，2.5s 够看清又不至于让用户等
    if (this.queue.length > 1 && this.errorStreak <= 3) {
      this.clearSkipTimer();
      this.skipTimer = setTimeout(() => {
        this.advance(true).catch((e: Object) => Logger.warn(TAG, `${e}`));
      }, 2500);
    }
  }

  private clearSkipTimer(): void {
    if (this.skipTimer >= 0) {
      clearTimeout(this.skipTimer);
      this.skipTimer = -1;
    }
  }

  private setStatus(s: string): void {
    this.status = s;
  }

  // ---------------- AVSession ----------------

  /**
   * 一份完整的 AVMetadata。setAVMetadata 是整份覆盖而不是字段合并，
   * 凡是单独推某种状态的路径（逐行歌词、清词）都必须从这里取，否则会把
   * title/artist/duration 冲掉，桌面歌词窗口随即失去进度基准。
   */
  private fullMeta(t: Track): avSession.AVMetadata {
    const meta: avSession.AVMetadata = {
      assetId: t.uri,
      title: t.title,
      artist: t.artist.length > 0 ? t.artist : '未知艺人',
      album: t.album,
      // d.ts 原话：used to automatically calculate playback position。
      // 不给 duration，系统桌面歌词算不出当前进度，高亮永远停在第 1 行（真机实测）。
      // CUE 虚拟轨用时间片时长，与 pushSessionState 里的 position 口径一致
      duration: this.duration
    };
    // 带时间轴的整份 LRC：锁屏歌词、播控中心、系统桌面歌词都从这一份渲染
    if (this.lrc.length > 0 && LrcParser.isTimed(this.lrc)) {
      meta.lyric = this.lrc;
    }
    return meta;
  }

  private setMeta(t: Track): void {
    if (this.session === null) {
      return;
    }
    const meta: avSession.AVMetadata = this.fullMeta(t);
    // 不给 mediaImage。查过两条路都不通：
    // 不传 → 媒体层打 `img uri empty`（一行提示，语义就是"没图"，可接受）；
    // 传应用沙箱的 file:// 路径 → 系统用 curl 去下载，直接报
    // `URL using bad/illegal format` + `DoDownload failed`（比前者更糟）。
    // 要让播控中心真正出图得给媒体库 uri，那需要 READ_IMAGEVIDEO 权限，
    // 与"只读本地、不要权限"的定位冲突，故放弃。
    this.session.setAVMetadata(meta).catch((e: Object) => Logger.warn(TAG, `meta ${e}`));
    // 系统桌面歌词组件（API 23+）的整份 LRC 高亮只在"播放状态变化事件"时用事件里的
    // 位置算一次（起点 0 → 高亮永远卡第 1 行），setAVPlaybackState 的位置推送不触发行
    // 重算（真机 movePosition result:0 实测）。所以桌面窗口不走 lyricContent，
    // 改用逐行推 singleLyricText（文档定义的"单条歌词"通道），每换一行推一次。
    const desc: avSession.AVMediaDescription = {
      assetId: t.uri,
      title: meta.title,
      artist: meta.artist,
      albumTitle: t.album,
      duration: this.duration
    };
    const item: avSession.AVQueueItem = { itemId: 1, description: desc };
    this.session.setAVQueueItems([item]).catch((e: Object) => Logger.warn(TAG, `queue item ${e}`));
  }

  /** 内核自己拉词：后台自动切歌时没有页面帮 loadLrc，桌面歌词不能断粮 */
  private async loadLrcForSession(t: Track): Promise<void> {
    const token: number = ++this.coreLrcToken;
    try {
      const owned: boolean = AppStorage.get<boolean>(PRO_KEY) === true;
      const doc = await LyricService.load(t, owned);
      if (token !== this.coreLrcToken) {
        return; // 期间又切歌了
      }
      this.setLrc(doc.synced ? doc.raw : '');
      Logger.info(TAG, `core lrc ${doc.source} lines=${doc.lines.length}`);
    } catch (e) {
      Logger.warn(TAG, `core lrc load failed ${JSON.stringify(e)}`);
      this.setLrc('');
    }
  }

  private syncSessionThrottled(): void {
    const now: number = Date.now();
    if (now - this.lastSessionSync < 500) {
      return;
    }
    this.lastSessionSync = now;
    this.pushSessionState(true);
  }

  /**
   * 播控中心状态。
   * 起播前必须先置 BUFFERING：直接置 PLAY 会让播控进度条先走一段再回退。
   */
  private pushSessionState(buffering: boolean): void {
    if (this.session === null) {
      return;
    }
    let state: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    if (this.status === Const.ST_PLAYING) {
      state = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    } else if (this.status === Const.ST_LOADING || buffering) {
      state = avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
    }
    const st: avSession.AVPlaybackState = {
      state: state,
      speed: 1.0,
      // 淡出期间播控中心也停在旧曲（metadata 同样延后），否则会出现"旧标题 + 新进度"
      position: {
        elapsedTime: this.uiHoldTrack !== null ? this.uiHoldPos : this.position,
        updateTime: Date.now()
      }
    };
    this.session.setAVPlaybackState(st).catch((e: Object) => Logger.warn(TAG, `state ${e}`));
  }

  setLrc(text: string): void {
    this.lrc = text;
    this.lyricLines = LrcParser.parse(text);
    this.lastLyricLine = -1;
    if (this.uiHoldTrack !== null) {
      // 淡出期间页面加载的是旧曲的词，而 current() 已经是新曲：
      // 此时推 metadata 会把旧词挂到新曲 assetId 上，还会提前暴露下一首。等结算时统一重推。
      return;
    }
    const t: Track | null = this.current();
    if (t === null || this.session === null) {
      return;
    }
    // 按新词状态重推元数据（此时 setMeta 可能已用旧词推过一次）
    this.setMeta(t);
    if (this.lyricLines.length === 0) {
      // 无词：显式清掉桌面窗口残留的上一首行，不然切歌后旧词挂在窗口上。
      // 同样要带完整字段，否则清词这一下会把 duration 一起清掉
      const meta: avSession.AVMetadata = this.fullMeta(t);
      meta.singleLyricText = '';
      this.session.setAVMetadata(meta).catch((e: Object) => Logger.warn(TAG, `lyric clear ${e}`));
    }
  }

  lyric(): string {
    return this.lrc;
  }

  // ---------------- 后台任务 ----------------

  private async startBgTask(): Promise<void> {
    if (this.bgRunning || this.ctx === null || this.isDemo) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: this.ctx.abilityInfo.bundleName,
          abilityName: this.ctx.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: Object = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        this.ctx, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.bgRunning = true;
      Logger.info(TAG, 'background audio task started');
    } catch (e) {
      Logger.error(TAG, `startBackgroundRunning ${JSON.stringify(e)}`);
    }
  }

  private stopBgTask(): void {
    if (!this.bgRunning || this.ctx === null) {
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(this.ctx)
      .then(() => {
        this.bgRunning = false;
      })
      .catch((e: Object) => Logger.warn(TAG, `stop bg ${e}`));
  }

  // ---------------- 断点续播 ----------------

  private persistState(): void {
    const uris: string[] = [];
    const end: number = Math.min(this.queue.length, Const.QUEUE_REMEMBER);
    for (let i = 0; i < end; i++) {
      uris.push(this.queue[i].uri);
    }
    SettingsService.saveQueue(JSON.stringify(uris), this.index, this.position);
  }

  private async restoreState(): Promise<void> {
    const raw: string = SettingsService.queueUris();
    if (raw.length === 0) {
      return;
    }
    let uris: string[] = [];
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (Array.isArray(parsed)) {
        uris = (parsed as string[]).filter((u: string) => typeof u === 'string');
      }
    } catch (e) {
      Logger.warn(TAG, 'queue cache broken, drop it');
      return;
    }
    if (uris.length === 0) {
      return;
    }
    const list: Track[] = await TrackStore.listByUris(uris);
    if (list.length === 0) {
      return;
    }
    this.queue = list;
    this.index = Math.min(SettingsService.queueIndex(), list.length - 1);
    this.position = SettingsService.queuePosition();
    this.duration = list[this.index].duration;
    this.setStatus(Const.ST_PAUSED);
    this.notify(true);
  }

  // ---------------- 订阅 ----------------

  onChange(cb: (s: PlayerSnapshot) => void): void {
    this.listeners.push(cb);
    cb(this.snapshot());
  }

  offChange(cb: (s: PlayerSnapshot) => void): void {
    this.listeners = this.listeners.filter((x: (s: PlayerSnapshot) => void) => x !== cb);
  }

  snapshot(): PlayerSnapshot {
    // 交叉淡入淡出期间对外仍显示旧曲（此时音频已经在新曲出声）。
    // 因为页面只消费这一份快照，标题 / 封面 / 进度条 / 歌词 / 队列高亮全部自动跟随，
    // 不必给 UI 加第二套索引。
    const hold: Track | null = this.uiHoldTrack;
    const t: Track | null = hold !== null ? hold : this.current();
    const snap: PlayerSnapshot = emptySnapshot();
    snap.track = t;
    snap.status = this.status;
    snap.playing = this.status === Const.ST_PLAYING;
    snap.position = hold !== null ? this.uiHoldPos : this.position;
    snap.duration = hold !== null ? this.uiHoldDur : this.duration;
    snap.index = hold !== null ? this.uiHoldIndex : this.index;
    snap.total = this.queue.length;
    snap.mode = this.mode;
    snap.favorite = t !== null && PlaylistStore.isFavorite(t.uri);
    snap.error = this.errorText;
    snap.isDemo = t !== null && t.uri.startsWith(Const.DEMO_SCHEME);
    snap.abA = this.abA;
    snap.abB = this.abB;
    return snap;
  }

  private notify(force: boolean): void {
    const now: number = Date.now();
    if (!force && now - this.lastNotify < 160) {
      return;
    }
    this.lastNotify = now;
    const s: PlayerSnapshot = this.snapshot();
    for (const cb of this.listeners) {
      cb(s);
    }
  }
}
