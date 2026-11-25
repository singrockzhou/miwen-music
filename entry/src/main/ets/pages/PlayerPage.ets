import { router, promptAction } from '@kit.ArkUI';
import { Const } from '../common/Constants';
import { Fmt } from '../common/Fmt';
import { Logger } from '../common/Logger';
import { LrcParser } from '../common/Lrc';
import { Theme, Tokens } from '../common/Theme';
import { Track } from '../model/Track';
import { PlayerSnapshot, emptySnapshot } from '../model/PlayerState';
import { PlayerCore } from '../service/PlayerCore';
import { LyricDoc, LyricService, LRC_EMBED, LRC_NONE } from '../service/LyricService';
import { PlaylistStore } from '../db/PlaylistStore';
import { ProService } from '../service/ProService';
import { GrooveRing } from '../components/GrooveRing';
import { CoverArt } from '../components/CoverArt';
import { PlayPauseGlyph } from '../components/PlayPauseGlyph';
import { EmptyState } from '../components/EmptyState';
import { ActionPanel, ActionItem } from '../components/ActionPanel';

const TAG: string = 'PlayerPage';

/**
 * 播放页。
 *
 * 版式逻辑（来自视觉稿，一条都不改）：
 * 1. 环不是装饰，是进度 —— 3 圈不等距沟槽 + 落针点，进度直接长在沟槽上；
 * 2. 封面是唯一彩色源，其余全部压到灰，一屏只有一个视觉焦点；
 * 3. 歌词只露三行：当前行 + 译文 + 下一行，不做滚动动画；
 * 4. 白纸/牛皮纸主题下把铜金降明度，否则在浅底上会刺眼（用 accent 令牌自动处理）。
 *
 * 上滑进入、下滑退出由 pageTransition 负责；这是鸿蒙上最省力的"一镜到底"近似。
 */
@Entry
@Component
struct PlayerPage {
  @State snap: PlayerSnapshot = emptySnapshot();
  @State deskOn: boolean = false;
  @State doc: LyricDoc = LyricService.empty();
  @State curLine: number = -1;
  @State lrcOffset: number = 0;
  @State slider: number = 0;
  @State dragging: boolean = false;
  @State panelOpen: boolean = false;
  @State panelItems: ActionItem[] = [];
  // 变速二级面板（速率档位）
  @State rateOpen: boolean = false;
  @State rateItems: ActionItem[] = [];
  /** 与 panelItems 一一对应的动作键：行的有无随歌词状态变化，用下标分发会错位 */
  @State panelKeys: string[] = [];
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('proOwned') proOwned: boolean = false;
  @StorageProp('bp') bp: string = Const.BP_SM;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;

  private core: PlayerCore = PlayerCore.instance();
  private lastUri: string = '';
  /** 取词是异步的：切歌快时旧结果不能盖住新歌 */
  private lrcToken: number = 0;

  private listener: (s: PlayerSnapshot) => void = (s: PlayerSnapshot): void => {
    this.snap = s;
    if (!this.dragging) {
      this.slider = s.position;
    }
    const uri: string = s.track !== null ? s.track.uri : '';
    if (uri !== this.lastUri) {
      this.lastUri = uri;
      this.loadLrc(s.track);
    }
    this.syncLine(s.position);
  };

  aboutToAppear(): void {
    this.core.onChange(this.listener);
    // 进来先主动拉一次快照。内核只在状态变化时通知，而"解码失败""暂停"
    // 这类静置状态不会再发通知，光订阅会让页面停在空快照上——错误横幅
    // 因此永远不显示（真机 12:17 实测）。
    this.snap = this.core.snapshot();
    this.slider = this.snap.position;
    this.lastUri = this.snap.track !== null ? this.snap.track.uri : '';
    // 桌面歌词是全局开关，页面重新进来要按真实状态显示，否则标签永远写「桌面歌词」，
    // 窗口其实开着（真机 23:24 撞到：标签写「桌面歌词」，系统窗口正在滚词）
    this.deskOn = this.core.deskLyricEnabled();
    this.loadLrc(this.snap.track);
  }
  aboutToDisappear(): void {
    this.core.offChange(this.listener);
  }

  pageTransition() {
    PageTransitionEnter({ duration: 320, curve: Curve.Friction })
      .slide(SlideEffect.Bottom)
    PageTransitionExit({ duration: 260, curve: Curve.Friction })
      .slide(SlideEffect.Bottom)
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  // ---------------- 歌词 ----------------

  /**
   * 取词顺序：同名 .lrc → 文件内嵌 → 示例词。
   * 全在本地，不联网抓、不解析商用歌词站格式。
   */
  private async loadLrc(t: Track | null): Promise<void> {
    this.lrcToken++;
    const token: number = this.lrcToken;
    this.doc = LyricService.empty();
    this.curLine = -1;
    this.lrcOffset = t !== null ? LyricService.offset(t.uri) : 0;
    if (t === null) {
      return;
    }
    const doc: LyricDoc = await LyricService.load(t, this.proOwned);
    if (token !== this.lrcToken) {
      return;
    }
    this.doc = doc;
    // 内核拿到带时间轴的整份 LRC：锁屏 / 播控 / 系统桌面歌词共用这一份数据
    this.core.setLrc(doc.synced ? doc.raw : '');
    Logger.info(TAG, `lyric ${doc.source} lines=${doc.lines.length} plain=${doc.plain.length} trans=${doc.hasTrans}`);
    this.syncLine(this.snap.position);
  }

  /** 正数偏移 = 歌词推迟：查表时把播放位置往回拨同样的量 */
  private syncLine(ms: number): void {
    if (!this.doc.synced) {
      return;
    }
    this.curLine = LrcParser.indexAt(this.doc.lines, ms - this.lrcOffset);
  }

  private shiftLyric(delta: number): void {
    const t: Track | null = this.snap.track;
    if (t === null) {
      return;
    }
    if (!this.proOwned) {
      promptAction.showToast({ message: '歌词时间轴微调是密纹 Pro 功能' });
      router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
      return;
    }
    this.lrcOffset = LyricService.bump(t.uri, delta);
    this.syncLine(this.snap.position);
    promptAction.showToast({
      message: this.lrcOffset === 0
        ? '歌词已对齐'
        : `歌词偏移 ${LyricService.fmtOffset(this.lrcOffset)}`,
      duration: 1600
    });
  }

  /**
   * A-B 循环的 Pro 门槛：已购直接用；没购走试用（和购买页承诺一致：每个 Pro 功能都能用 3 次），
   * 用完才拦。试用在真正动手之前消耗，失败不退——次数本身就是让人试的。
   */
  /** 桌面歌词开关（Pro 试用门槛），失败给系统话术 */
  private toggleDeskLyric(): void {
    if (this.proOwned) {
      this.doDeskLyric();
      return;
    }
    if (ProService.consumeTrial('desklyric')) {
      const left: number = ProService.trialLeft('desklyric');
      promptAction.showToast({
        message: left > 0 ? `已用一次试用，剩 ${left} 次` : '这是最后一次试用',
        duration: 2000
      });
      this.doDeskLyric();
      return;
    }
    promptAction.showToast({ message: '桌面歌词的试用次数用完了', duration: 2200 });
    router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  private doDeskLyric(): void {
    const next: boolean = !this.core.deskLyricEnabled();
    this.core.setDesktopLyric(next).then((msg: string) => {
      if (msg.length === 0) {
        this.deskOn = next;
        promptAction.showToast({
          message: next ? '桌面歌词已交给系统渲染，回桌面就能看到' : '桌面歌词已关闭',
          duration: 2200
        });
      } else {
        promptAction.showToast({ message: msg, duration: 2600 });
      }
    }).catch((e: Object) => Logger.warn(TAG, `desk lyric ${e}`));
  }

  private abGate(run: () => void): void {
    if (this.proOwned) {
      run();
      return;
    }
    if (ProService.consumeTrial('abloop')) {
      const left: number = ProService.trialLeft('abloop');
      promptAction.showToast({
        message: left > 0 ? `已用一次试用，剩 ${left} 次` : '这是最后一次试用',
        duration: 2000
      });
      run();
      return;
    }
    promptAction.showToast({ message: 'A-B 循环的试用次数用完了', duration: 2200 });
    router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  // ---------------- 动作 ----------------

  private openPanel(): void {
    const t: Track | null = this.snap.track;
    if (t === null) {
      return;
    }
    const fav: boolean = PlaylistStore.isFavorite(t.uri);
    const items: ActionItem[] = [];
    const keys: string[] = [];
    items.push({ label: fav ? '取消收藏' : '收藏这首', hint: '', danger: false });
    keys.push('fav');
    items.push({ label: '下一首播放', hint: '', danger: false });
    keys.push('next');
    items.push({ label: '加入播放队列', hint: '', danger: false });
    keys.push('queue');
    items.push({ label: '查看所属专辑', hint: t.album.length > 0 ? t.album : '未知专辑', danger: false });
    keys.push('album');
    // 歌词微调只在"有轴"时出现：没时间轴的歌词调了也没用，不给假开关
    if (this.doc.synced) {
      items.push({
        label: '歌词推迟 0.5 秒',
        hint: this.lrcOffset !== 0 ? `当前 ${LyricService.fmtOffset(this.lrcOffset)}` : (this.proOwned ? '' : 'PRO'),
        danger: false
      });
      keys.push('lrc_later');
      items.push({ label: '歌词提前 0.5 秒', hint: '', danger: false });
      keys.push('lrc_earlier');
      if (this.lrcOffset !== 0) {
        items.push({ label: '重置歌词偏移', hint: '', danger: false });
        keys.push('lrc_reset');
      }
    }
    // A-B 循环：点位的顺序自然引导 —— 没 A 先设 A，有 A 设 B，设满给清除
    if (this.snap.abA < 0) {
      items.push({ label: 'A-B 循环：设 A 点', hint: `当前位置 ${Fmt.time(this.snap.position)}`, danger: false });
      keys.push('ab_a');
    } else if (this.snap.abB < 0) {
      items.push({
        label: 'A-B 循环：设 B 点',
        hint: `A ${Fmt.time(this.snap.abA)} · 至少比 A 点晚 1 秒`,
        danger: false
      });
      keys.push('ab_b');
    } else {
      items.push({
        label: `A-B 循环 ${Fmt.time(this.snap.abA)} → ${Fmt.time(this.snap.abB)}`,
        hint: '过了 B 点自动回 A',
        danger: false
      });
      keys.push('ab_none');
      items.push({ label: '清除 A-B 循环', hint: '', danger: false });
      keys.push('ab_clear');
    }
    items.push({
      label: '变速不变调',
      hint: this.core.getRate() !== 1 ? `当前 ${this.core.getRate()}×` : '0.5× ~ 2.0×',
      danger: false
    });
    keys.push('rate');
    if (this.core.sleepActive()) {
      items.push({ label: '取消睡眠定时', hint: '定时进行中', danger: false });
      keys.push('sleep_cancel');
    } else {
      items.push({ label: '睡眠定时', hint: '30 分钟 · 音量渐弱后暂停', danger: false });
      keys.push('sleep');
    }
    if (this.core.stopAfterAlbumActive()) {
      items.push({ label: '取消「播完本专辑停」', hint: '已启用：到专辑末尾自动暂停', danger: false });
      keys.push('album_stop_cancel');
    } else {
      items.push({ label: '播完本专辑停', hint: '到专辑末尾自动暂停，不绕回队列开头', danger: false });
      keys.push('album_stop');
    }
    items.push({ label: '文件信息', hint: Fmt.bytes(t.size), danger: false });
    keys.push('info');
    this.panelItems = items;
    this.panelKeys = keys;
    this.panelOpen = true;
  }

  private onPanelPick(i: number): void {
    const t: Track | null = this.snap.track;
    this.panelOpen = false;
    if (t === null || i < 0 || i >= this.panelKeys.length) {
      return;
    }
    const key: string = this.panelKeys[i];
    if (key === 'fav') {
      this.core.toggleFavorite();
    } else if (key === 'next') {
      this.core.playNext(t);
      promptAction.showToast({ message: '已排到下一首' });
    } else if (key === 'queue') {
      this.core.addToQueue(t);
      promptAction.showToast({ message: '已加入播放队列' });
    } else if (key === 'album') {
      router.pushUrl({
        url: 'pages/ListPage',
        params: {
          kind: Const.LIST_ALBUM,
          key: t.album.length > 0 ? t.album : '未知专辑',
          title: t.album.length > 0 ? t.album : '未知专辑',
          sub: t.source
        }
      }).catch((e: Object) => Logger.warn(TAG, `${e}`));
    } else if (key === 'lrc_later') {
      this.shiftLyric(LyricService.STEP);
    } else if (key === 'lrc_earlier') {
      this.shiftLyric(-LyricService.STEP);
    } else if (key === 'lrc_reset') {
      LyricService.reset(t.uri);
      this.lrcOffset = 0;
      this.syncLine(this.snap.position);
      promptAction.showToast({ message: '歌词偏移已重置' });
    } else if (key === 'ab_a') {
      this.abGate(() => {
        const ok: boolean = this.core.setPointA();
        if (ok) {
          promptAction.showToast({ message: `A 点已设 ${Fmt.time(this.snap.position)}`, duration: 1600 });
        } else {
          promptAction.showToast({ message: '快到曲末了，A 点往前挪一点再设', duration: 1800 });
        }
      });
    } else if (key === 'ab_b') {
      const ok: boolean = this.core.setPointB();
      if (ok) {
        promptAction.showToast({
          message: `A-B 循环 ${Fmt.time(this.core.snapshot().abA)} → ${Fmt.time(this.core.snapshot().abB)}`,
          duration: 2000
        });
      } else {
        promptAction.showToast({ message: 'B 点要晚于 A 点至少 1 秒', duration: 1800 });
      }
    } else if (key === 'ab_clear') {
      this.core.clearAB();
      promptAction.showToast({ message: 'A-B 循环已清除', duration: 1500 });
    } else if (key === 'ab_none') {
      this.panelOpen = false;
      return;
    } else if (key === 'rate') {
      this.rateOpen = true;
      this.rateItems = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((r: number): ActionItem => {
        return {
          label: r === 1 ? '原速' : `${r}×`,
          hint: r === this.core.getRate() ? '当前' : '',
          danger: false
        };
      });
    } else if (key === 'sleep') {
      this.core.setSleep(30);
      promptAction.showToast({ message: '30 分钟后音量渐弱并暂停' });
    } else if (key === 'sleep_cancel') {
      this.core.cancelSleep();
      promptAction.showToast({ message: '睡眠定时已取消' });
    } else if (key === 'album_stop') {
      this.core.armStopAfterAlbum();
      promptAction.showToast({ message: '播完本专辑后自动暂停' });
    } else if (key === 'album_stop_cancel') {
      this.core.cancelStopAfterAlbum();
      promptAction.showToast({ message: '已取消「播完本专辑停」' });
    } else if (key === 'info') {
      promptAction.showToast({
        message: `${Fmt.fmt(t.suffix)} · ${Fmt.rate(t.sampleRate)} · ${Fmt.bytes(t.size)}`,
        duration: 2600
      });
    }
  }

  private openQueue(): void {
    router.pushUrl({
      url: 'pages/ListPage',
      params: { kind: Const.LIST_QUEUE, key: '', title: '播放队列', sub: `${this.snap.total} 首` }
    }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  // ---------------- 组件 ----------------

  @Builder
  TopBar() {
    Row() {
      Text('⌄')
        .fontSize(22)
        .fontColor(this.c().dim)
        .width(44)
        .height(36)
        .textAlign(TextAlign.Start)
        .onClick(() => router.back())

      Blank()

      Column() {
        Text(this.snap.isDemo ? '示例唱片 · 无真实音频' : '来自本机 · 不联网')
          .fontSize(8)
          .fontColor(this.c().faint)
          .letterSpacing(1.2)
        if (this.snap.status === Const.ST_LOADING) {
          Text('正在读取…')
            .fontSize(8)
            .fontColor(this.c().accent)
            .margin({ top: 3 })
        }
      }
      .alignItems(HorizontalAlign.Center)

      Blank()

      // 曲目操作面板的入口。此前这块面板写好了却没有任何地方能打开它 ——
      // 真机上"收藏/下一首/歌词调轴"全都点不到，等于白写。
      Text('⋯')
        .fontSize(16)
        .fontColor(this.c().dim)
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .onClick(() => this.openPanel())

      Text(this.snap.total > 0 ? `队列 ${this.snap.index + 1}/${this.snap.total}` : '队列')
        .fontSize(9)
        .fontColor(this.c().dim)
        .width(64)
        .height(36)
        .textAlign(TextAlign.End)
        .onClick(() => this.openQueue())
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  CoverBlock(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      GrooveRing({
        progress: this.snap.duration > 0 ? this.snap.position / this.snap.duration : 0,
        diameter: size
      })

      if (this.snap.track !== null) {
        Stack() {
          CoverArt({
            coverPath: this.snap.track.coverPath,
            seed: this.snap.track.album.length > 0 ? this.snap.track.album : this.snap.track.title,
            title: this.snap.track.album.length > 0 ? this.snap.track.album : this.snap.track.title,
            subtitle: this.snap.track.artist,
            dim: false
          })
            .width(size * 0.786)
            .height(size * 0.786)
        }
        .width(size * 0.786)
        .height(size * 0.786)
        .opacity(this.snap.playing ? 1 : 0.9)
        .animation({ duration: 400, curve: Curve.EaseOut })
      }
    }
    .width(size)
    .height(size)
  }

  private emptyLyricHint(): string {
    if (this.snap.isDemo) {
      return '这首示例曲目没有歌词';
    }
    return this.proOwned
      ? '磁盘上没有同名 .lrc，文件里也没有内嵌歌词'
      : '磁盘上没有同名 .lrc（读文件内嵌歌词属 Pro）';
  }

  @Builder
  LyricBlock() {
    Column() {
      if (this.doc.cueEmpty) {
        // 有整轨 LRC，但这一段没词。和"磁盘上没有 .lrc"是两码事，别混成一句提示
        Text('这一轨没有歌词')
          .fontSize(11)
          .fontColor(this.c().dim)
        Text('整轨 LRC 未覆盖本段')
          .fontSize(9)
          .fontColor(this.c().faint)
          .margin({ top: 4 })
      } else if (this.doc.source === LRC_NONE) {
        Text(this.emptyLyricHint())
          .fontSize(10)
          .fontColor(this.c().faint)
          .textAlign(TextAlign.Center)
      } else if (!this.doc.synced) {
        // 有词但没时间轴：老老实实静态露三行，绝不按总时长均分伪造高亮
        ForEach(this.doc.plain.slice(0, 3), (s: string, i: number) => {
          Text(s)
            .fontSize(i === 0 ? 11 : 9)
            .fontColor(i === 0 ? this.c().dim : this.c().faint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: i === 0 ? 0 : 3 })
        }, (s: string, i: number) => `plain_${i}_${s}`)
      } else if (this.curLine < 0) {
        Text(this.doc.lines[0].text)
          .fontSize(11)
          .fontColor(this.c().dim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text(this.doc.lines[this.curLine].text)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.c().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 译文比正文小两号并压到 dim：读的时候眼睛先落在原文上
        if (this.doc.lines[this.curLine].trans.length > 0) {
          Text(this.doc.lines[this.curLine].trans)
            .fontSize(9)
            .fontColor(this.c().dim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
        if (this.curLine + 1 < this.doc.lines.length) {
          Text(this.doc.lines[this.curLine + 1].text)
            .fontSize(10)
            .fontColor(this.c().faint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
        }
      }

      // 来源标记：内嵌/LRC、是否双语、偏移多少 —— 全是可核对的实情，不是装饰
      if (this.doc.source !== LRC_NONE) {
        Row({ space: 8 }) {
          Text(this.doc.source === LRC_EMBED ? '内嵌歌词' : '同名 LRC')
            .fontSize(7)
            .fontColor(this.c().faint)
            .letterSpacing(0.6)
          if (this.doc.hasTrans) {
            Text('双语')
              .fontSize(7)
              .fontColor(this.c().faint)
              .letterSpacing(0.6)
          }
          if (!this.doc.synced && !this.doc.cueEmpty) {
            Text('无时间轴')
              .fontSize(7)
              .fontColor(this.c().faint)
              .letterSpacing(0.6)
          }
          if (this.doc.cueEmpty) {
            Text('本轨无词')
              .fontSize(7)
              .fontColor(this.c().faint)
              .letterSpacing(0.6)
          }
          if (this.lrcOffset !== 0) {
            Text(`偏移 ${LyricService.fmtOffset(this.lrcOffset)}`)
              .fontSize(7)
              .fontColor(this.c().accent)
              .letterSpacing(0.6)
          }
          // 桌面歌词入口与标签同行；74 高的歌词区放不下第二行，多起一行就会被裁掉看不见
          Text(this.deskOn ? '桌面 · 开' : '桌面歌词')
            .fontSize(7)
            .fontColor(this.deskOn ? this.c().accent : this.c().dim)
            .letterSpacing(0.6)
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .border({ width: 0.5, color: this.deskOn ? this.c().accentDeep : Color.Transparent })
            .onClick(() => this.toggleDeskLyric())
        }
        .margin({ top: 7 })
      }
    }
    .width('100%')
    .height(74)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 26, right: 26 })
  }

  @Builder
  ErrorBar() {
    Row({ space: 10 }) {
      Column()
        .width(2)
        .height(26)
        .backgroundColor(this.c().danger)
      Text(this.snap.error)
        .fontSize(10)
        .fontColor(this.c().danger)
        .lineHeight(16)
        .layoutWeight(1)
        .maxLines(2)
      Text('知道了')
        .fontSize(9)
        .fontColor(this.c().dim)
        .padding({ left: 8, right: 4 })
        .onClick(() => this.core.clearError())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.c().accentWash)
    .margin({ top: 8 })
  }

  @Builder
  PlayGlyph(size: number) {
    PlayPauseGlyph({ playing: this.snap.playing, glyph: size, color: this.c().accent })
  }

  @Builder
  Controls() {
    Column() {
      // 进度
      Slider({
        value: this.dragging ? this.slider : this.snap.position,
        min: 0,
        max: this.snap.duration > 0 ? this.snap.duration : 1,
        step: 1,
        style: SliderStyle.OutSet
      })
        .trackColor(this.c().line)
        .selectedColor(this.c().accent)
        .blockColor(this.c().accent)
        .trackThickness(1.2)
        .width('100%')
        .onChange((v: number, mode: SliderChangeMode) => {
          this.slider = v;
          this.dragging = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.dragging = false;
            this.core.seek(v);
          }
        })

      Row() {
        // A/B 点位直接标在时间行上：设了就能看见，不用去面板里翻
        if (this.snap.abA >= 0) {
          Text(`A ${Fmt.time(this.snap.abA)}`)
            .fontSize(8)
            .fontColor(this.c().accent)
          if (this.snap.abB >= 0) {
            Text(` ⇄ B ${Fmt.time(this.snap.abB)}`)
              .fontSize(8)
              .fontColor(this.c().accent)
          }
        } else {
          Text(Fmt.time(this.dragging ? this.slider : this.snap.position))
            .fontSize(8)
            .fontColor(this.c().faint)
        }
        Blank()
        Text(`-${Fmt.time(Math.max(0, this.snap.duration - (this.dragging ? this.slider : this.snap.position)))}`)
          .fontSize(8)
          .fontColor(this.c().faint)
      }
      .width('100%')
      .padding({ left: 2, right: 2 })

      // 主控
      Row() {
        // 播放模式：两行结构与右侧收藏对称，标题行才对齐
        Column() {
          Text(this.modeLabel())
            .fontSize(9)
            .fontColor(this.c().dim)
            .letterSpacing(0.5)
          Text('模式')
            .fontSize(7)
            .fontColor(this.c().faint)
            .margin({ top: 2 })
        }
        .width(52)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => this.core.cycleMode())

        Blank()

        Text('‹')
          .fontSize(30)
          .fontColor(this.c().dim)
          .width(48)
          .height(48)
          .textAlign(TextAlign.Center)
          .onClick(() => this.core.prev())

        Blank()

        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(66)
            .height(66)
            .fill(Color.Transparent)
            .stroke(this.c().accent)
            .strokeWidth(1)
          this.PlayGlyph(24)
        }
        .width(66)
        .height(66)
        .onClick(() => this.core.toggle())

        Blank()

        Text('›')
          .fontSize(30)
          .fontColor(this.c().dim)
          .width(48)
          .height(48)
          .textAlign(TextAlign.Center)
          .onClick(() => this.core.next())

        Blank()

        Column() {
          // 收藏：空心圈 / 实心铜点，用形状而不是 ●○ 字符，避免不同字体下大小不一
          Circle()
            .width(10)
            .height(10)
            .fill(this.snap.favorite ? this.c().accent : Color.Transparent)
            .stroke(this.snap.favorite ? this.c().accent : this.c().dim)
            .strokeWidth(1)
          Text('收藏')
            .fontSize(7)
            .fontColor(this.c().faint)
            .margin({ top: 4 })
        }
        .width(52)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => this.core.toggleFavorite())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 10 })
    }
    .width('100%')
    .padding({ left: 22, right: 22 })
  }

  private modeLabel(): string {
    if (this.snap.mode === Const.MODE_SINGLE) {
      return '单曲';
    }
    if (this.snap.mode === Const.MODE_SHUFFLE) {
      return '随机';
    }
    return '列表';
  }

  @Builder
  TrackInfo() {
    Column() {
      Text(this.snap.track !== null ? this.snap.track.title : '未在播放')
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.c().text)
        .letterSpacing(0.4)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(this.bp === Const.BP_SM ? TextAlign.Start : TextAlign.Center)
        .width('100%')

      Row({ space: 8 }) {
        Text(this.snap.track !== null ? Fmt.meta(this.snap.track.artist, this.snap.track.album) : '选一张唱片开始')
          .fontSize(10)
          .fontColor(this.c().dim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.snap.track !== null && this.snap.track.sampleRate > 0) {
          Text(Fmt.fmt(this.snap.track.suffix))
            .fontSize(7)
            .fontColor(this.c().accent)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .border({ width: 0.5, color: this.c().accentDeep })
          Text(Fmt.rate(this.snap.track.sampleRate))
            .fontSize(8)
            .fontColor(this.c().faint)
        }
      }
      .margin({ top: 7 })
      .width('100%')
      .justifyContent(this.bp === Const.BP_SM ? FlexAlign.Start : FlexAlign.Center)
    }
    .width('100%')
    .alignItems(this.bp === Const.BP_SM ? HorizontalAlign.Start : HorizontalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.TopBar()

        if (this.snap.track === null) {
          Column() {
            EmptyState({
              title: '还没有在播放的唱片',
              hint: '去曲库挑一张，或者直接在首页点一张封套。',
              actionLabel: '返回曲库',
              onAction: () => router.back()
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)

          Row().height(40)
        } else if (this.bp !== Const.BP_SM) {
          // 平板 / PC：左封面，右信息与控制
          Row() {
            Column() {
              this.CoverBlock(340)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .height('100%')

            Column() {
              Blank()
              this.TrackInfo()
              this.LyricBlock()
              if (this.snap.error.length > 0) {
                this.ErrorBar()
              }
              this.Controls()
              Blank()
              Row() {
                Text('全本地 · 不上传')
                  .fontSize(8)
                  .fontColor(this.c().faint)
                  .letterSpacing(1)
              }
              .margin({ bottom: 24 })
            }
            .layoutWeight(1)
            .height('100%')
            .padding({ left: 20, right: 20 })
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          Column() {
            Row().height(8)
            this.CoverBlock(Const.PLAYER_RING)
            Column() {
              this.TrackInfo()
            }
            .margin({ top: 22 })
            .width('100%')
            if (this.snap.error.length > 0) {
              this.ErrorBar()
            }
            Column() {
              this.LyricBlock()
            }
            .margin({ top: 6 })
            .width('100%')
            Blank()
            this.Controls()
            Row().height(26)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 6, right: 6 })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: 8 })

      if (this.panelOpen) {
        ActionPanel({
          title: this.snap.track !== null ? this.snap.track.title : '',
          subtitle: this.snap.track !== null ? Fmt.meta(this.snap.track.artist, this.snap.track.album) : '',
          items: this.panelItems,
          onPick: (i: number) => this.onPanelPick(i),
          onClose: () => {
            this.panelOpen = false;
          }
        })
      }

      if (this.rateOpen) {
        ActionPanel({
          title: '变速不变调',
          subtitle: '音高不动，只改速度；原速可随时恢复',
          items: this.rateItems,
          onPick: (i: number) => {
            this.rateOpen = false;
            const speeds: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
            if (i >= 0 && i < speeds.length) {
              const r: number = speeds[i];
              this.core.setRate(r);
              promptAction.showToast({
                message: r === 1 ? '已恢复原速' : `变速 ${r}×（音高不变）`
              });
            }
          },
          onClose: () => {
            this.rateOpen = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset, bottom: this.bottomInset })
    .backgroundColor(this.c().bg)
  }
}
