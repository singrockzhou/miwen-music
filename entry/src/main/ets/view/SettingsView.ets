import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { Const } from '../common/Constants';
import { Fmt } from '../common/Fmt';
import { Theme, Tokens } from '../common/Theme';
import { TrackStore } from '../db/TrackStore';
import { PlayerCore } from '../service/PlayerCore';
import { PlayerSnapshot } from '../model/PlayerState';
import { LibraryService } from '../service/LibraryService';
import { ImportFlow } from '../service/ImportFlow';
import { RootService } from '../service/RootService';
import { SettingsService } from '../service/SettingsService';
import { ActionPanel, ActionItem } from '../components/ActionPanel';
import { SettingRow } from '../components/SettingRow';
import { SelfTest } from '../service/SelfTest';
import { NativeSelfTest } from '../service/NativeSelfTest';
import { AudioProbe, AudioProbeReport } from '../service/AudioProbe';
import { LyricService } from '../service/LyricService';
import { ProService } from '../service/ProService';
import { Logger } from '../common/Logger';

/**
 * 设置。
 *
 * 这里的顺序是刻意的：外观 → 曲库 → 播放 → 关于 → 诊断。
 * "曲库"必须排在前面：目录授权是这个 App 唯一容易卡住用户的地方，
 * 让它在设置里第一眼就能找到，比藏在某个二级菜单里强。
 */
@Component
export struct SettingsView {
  @State mode: string = Const.MODE_LOOP;
  @State source: string = Const.SRC_LOCAL;
  @State count: number = 0;
  @State bytes: number = 0;
  @State formats: string[] = [];
  @State libUri: string = '';
  /** 已授权的音乐目录个数 */
  @State rootCount: number = 0;
  @State scanning: boolean = false;
  @State scanText: string = '';
  @State sleepLabel: string = '关闭';
  @State panelOpen: boolean = false;
  @State panelItems: ActionItem[] = [];
  // 同一个面板兼两种用途：'sleep' 选定时、'clear' 确认清空。
  // 清空用系统 AlertDialog 会带圆角白卡，和"纸面、无圆角"的规范冲突，故收到这里。
  @State panelMode: string = 'sleep';
  /** 无缝播放档位标签 */
  @State gapLabel: string = '关闭';
  /** 桌面歌词开关（Pro，走系统桌面歌词） */
  @State deskLyric: boolean = false;
  /** 直出模式开关（Pro） */
  @State direct: boolean = false;
  /** 音频能力探测结果，一行摘要 */
  @State probeText: string = '未探测';
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('proOwned') proOwned: boolean = false;
  @StorageProp('bp') bp: string = Const.BP_SM;
  // 曲库被扫描/清空/载入示例后版本号会涨，这里跟着重算，否则计数会停在旧值。
  // 注意 @Watch 只能挂同步方法，直接挂 async 的 reload 不会触发。
  @StorageLink('libVersion') @Watch('onLibChanged') libVersion: number = 0;

  private core: PlayerCore = PlayerCore.instance();
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private listener: (s: PlayerSnapshot) => void = (s: PlayerSnapshot): void => {
    this.mode = s.mode;
  };

  aboutToAppear(): void {
    this.mode = SettingsService.mode();
    this.libUri = SettingsService.libUri();
    this.direct = this.core.directMode();
    this.gapLabel = this.gapLabelOf(SettingsService.gapless());
    this.deskLyric = SettingsService.deskLyric();
    this.proOwned = ProService.isPro();
    this.core.onChange(this.listener);
    this.reload();
  }

  aboutToDisappear(): void {
    this.core.offChange(this.listener);
  }

  onLibChanged(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const src: string = SettingsService.source();
    this.source = src;
    if (!TrackStore.ready()) {
      return;
    }
    this.count = await TrackStore.count(src);
    this.bytes = await TrackStore.totalBytes(src);
    this.formats = await TrackStore.suffixStats(src);
    this.libUri = SettingsService.libUri();
    this.rootCount = RootService.count();
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  // ---------------- 动作 ----------------

  private async pickFolder(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.scanText = '正在读取目录…';
    const r = await ImportFlow.pickAndAdd(this.ctx, (t: string) => {
      this.scanText = t;
    });
    this.scanning = false;
    this.scanText = '';
    if (r.message !== '没有选择文件夹') {
      promptAction.showToast({ message: r.message, duration: 2400 });
    }
    this.reload();
  }

  private async rescan(): Promise<void> {
    if (this.rootCount === 0) {
      await this.pickFolder();
      return;
    }
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.scanText = '正在重新扫描…';
    const r = await ImportFlow.rescanAll(this.ctx, (t: string) => {
      this.scanText = t;
    });
    this.scanning = false;
    this.scanText = '';
    promptAction.showToast({ message: r.message, duration: 2200 });
    this.reload();
  }

  private gapLabelOf(v: string): string {
    if (v === Const.GAP_SEAMLESS) {
      return '无缝';
    }
    if (v === Const.GAP_FADE) {
      return '淡入淡出';
    }
    return '关闭';
  }

  /** 无缝播放：三态面板（关 / 无缝 / 淡入淡出），Pro 试用门槛 */
  private openGapless(): void {
    if (!this.proOwned) {
      if (ProService.trialLeft('gapless') <= 0) {
        promptAction.showToast({ message: '无缝播放的试用次数用完了' });
        router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn('Settings', `${e}`));
        return;
      }
      this.panelMode = 'gapless';
      this.panelItems = [
        { label: `试用一次（还剩 ${ProService.trialLeft('gapless')} 次，本次开启无缝档）`, hint: '', danger: false },
        { label: '去解锁密纹 Pro', hint: `¥${Const.PRO_PRICE_EARLY}`, danger: false }
      ];
      this.panelOpen = true;
      return;
    }
    this.showGapPanel();
  }

  private showGapPanel(): void {
    this.panelMode = 'gapless';
    const cur: string = SettingsService.gapless();
    this.panelItems = [
      { label: '关闭', hint: cur === Const.GAP_OFF ? '当前' : '', danger: false },
      { label: '无缝（预加载切流）', hint: cur === Const.GAP_SEAMLESS ? '当前' : '轨间不留静音缝，现场专辑连着听', danger: false },
      { label: '淡入淡出（3 秒交叉）', hint: cur === Const.GAP_FADE ? '当前' : '两曲交叠 3 秒，适合歌单顺滑连播', danger: false }
    ];
    this.panelOpen = true;
  }

  private applyGapless(v: string): void {
    this.core.setGaplessMode(v);
    this.gapLabel = this.gapLabelOf(v);
  }

  /** 桌面歌词开关：Pro 直达；没购试用一次 */
  private toggleDeskLyric(): void {
    if (!this.proOwned) {
      if (ProService.trialLeft('desklyric') <= 0) {
        promptAction.showToast({ message: '桌面歌词的试用次数用完了' });
        router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn('Settings', `${e}`));
        return;
      }
      this.panelMode = 'desklyric';
      this.panelItems = [
        { label: `试用一次（还剩 ${ProService.trialLeft('desklyric')} 次）`, hint: '', danger: false },
        { label: '去解锁密纹 Pro', hint: `¥${Const.PRO_PRICE_EARLY}`, danger: false }
      ];
      this.panelOpen = true;
      return;
    }
    this.doDeskLyric();
  }

  private doDeskLyric(): void {
    const next: boolean = !this.deskLyric;
    this.core.setDesktopLyric(next).then((msg: string) => {
      if (msg.length === 0) {
        this.deskLyric = next;
        promptAction.showToast({
          message: next ? '桌面歌词已交给系统渲染，回桌面就能看到' : '桌面歌词已关闭',
          duration: 2200
        });
      } else {
        SettingsService.setDeskLyric(false);
        this.deskLyric = false;
        promptAction.showToast({ message: msg, duration: 2600 });
      }
    }).catch((e: Object) => Logger.warn('Settings', `desk lyric ${e}`));
  }

  /** 听歌统计入口：已购直达；没购给试用面板（与数据页同一套门槛） */
  private openStats(): void {
    if (this.proOwned) {
      router.pushUrl({ url: 'pages/StatsPage' }).catch((e: Object) => Logger.warn('Settings', `${e}`));
      return;
    }
    if (ProService.trialLeft('stats') <= 0) {
      promptAction.showToast({ message: '听歌统计的试用次数用完了' });
      router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn('Settings', `${e}`));
      return;
    }
    this.panelMode = 'stats';
    this.panelItems = [
      { label: `试用一次（还剩 ${ProService.trialLeft('stats')} 次）`, hint: '', danger: false },
      { label: '去解锁密纹 Pro', hint: `¥${Const.PRO_PRICE_EARLY}`, danger: false }
    ];
    this.panelOpen = true;
  }

  private confirmClear(): void {
    this.panelMode = 'clear';
    this.panelItems = [
      { label: '清空索引', hint: '只删索引，不动文件', danger: true },
      { label: '取消', hint: '', danger: false }
    ];
    this.panelOpen = true;
  }

  private onPanelPick(i: number): void {
    if (this.panelMode === 'gapless') {
      this.panelOpen = false;
      if (!this.proOwned) {
        // 试用面板：选试用才扣次数，直接给无缝档
        if (i === 0) {
          if (!ProService.consumeTrial('gapless')) {
            promptAction.showToast({ message: '试用次数用完了' });
            return;
          }
          const left: number = ProService.trialLeft('gapless');
          promptAction.showToast({
            message: left > 0 ? `已用一次试用，剩 ${left} 次` : '这是最后一次试用',
            duration: 2000
          });
          this.applyGapless(Const.GAP_SEAMLESS);
          return;
        }
        router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn('Settings', `${e}`));
        return;
      }
      // 已购：i = 0/1/2 三档直选
      const vals: string[] = [Const.GAP_OFF, Const.GAP_SEAMLESS, Const.GAP_FADE];
      if (i >= 0 && i < vals.length) {
        this.applyGapless(vals[i]);
        promptAction.showToast({ message: `无缝播放：${this.gapLabel}`, duration: 1800 });
      }
      return;
    }
    if (this.panelMode === 'desklyric') {
      this.panelOpen = false;
      if (i === 0) {
        if (!ProService.consumeTrial('desklyric')) {
          promptAction.showToast({ message: '试用次数用完了' });
          return;
        }
        const left: number = ProService.trialLeft('desklyric');
        promptAction.showToast({
          message: left > 0 ? `已用一次试用，剩 ${left} 次` : '这是最后一次试用',
          duration: 2000
        });
        this.doDeskLyric();
        return;
      }
      router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn('Settings', `${e}`));
      return;
    }
    if (this.panelMode === 'stats') {
      this.panelOpen = false;
      if (i === 0) {
        if (!ProService.consumeTrial('stats')) {
          promptAction.showToast({ message: '试用次数用完了' });
          return;
        }
        const left: number = ProService.trialLeft('stats');
        promptAction.showToast({
          message: left > 0 ? `已用一次试用，剩 ${left} 次` : '这是最后一次试用',
          duration: 2000
        });
        router.pushUrl({ url: 'pages/StatsPage' }).catch((e: Object) => Logger.warn('Settings', `${e}`));
        return;
      }
      router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn('Settings', `${e}`));
      return;
    }
    if (this.panelMode === 'clear') {
      this.panelOpen = false;
      // 第 0 项是"清空"，第 1 项是"取消"（放在下面更好按，也更符合避开误触的习惯）
      if (i === 0) {
        LibraryService.clear(this.source).then(() => {
          this.reload();
          promptAction.showToast({ message: '索引已清空，文件都还在' });
        });
      }
      return;
    }
    this.onSleepPick(i);
  }

  private openSleep(): void {
    this.panelMode = 'sleep';
    this.panelItems = [
      { label: '关闭', hint: this.sleepLabel === '关闭' ? '当前' : '', danger: false },
      { label: '15 分钟后暂停', hint: '', danger: false },
      { label: '30 分钟后暂停', hint: '', danger: false },
      { label: '60 分钟后暂停', hint: '', danger: false }
    ];
    this.panelOpen = true;
  }

  private onSleepPick(i: number): void {
    this.panelOpen = false;
    const minutes: number = i === 0 ? 0 : (i === 1 ? 15 : (i === 2 ? 30 : 60));
    this.core.setSleep(minutes);
    this.sleepLabel = i === 0 ? '关闭' : `${minutes} 分钟`;
    promptAction.showToast({ message: i === 0 ? '已取消定时' : `${minutes} 分钟后自动暂停` });
  }

  // ---------------- 探测 ----------------

  private async runProbe(): Promise<void> {
    promptAction.showToast({ message: '正在探测音频能力…', duration: 1200 });
    const r: AudioProbeReport = await AudioProbe.inspect();
    this.probeText = r.modes;
    promptAction.showToast({ message: `${r.modes} · ${r.note}`, duration: 3200 });
    Logger.info('Settings', `probe ${r.modes} eq=${r.eq}`);
  }

  // ---------------- 组件 ----------------

  @Builder
  SectionTitle(cn: string, en: string) {
    Row() {
      Text(cn)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.c().accent)
        .letterSpacing(1.4)
      Blank()
      Text(en)
        .fontSize(7)
        .fontColor(this.c().faint)
        .letterSpacing(1.6)
    }
    .width('100%')
    .padding({ top: 26, bottom: 8 })
  }

  @Builder
  Divider() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor(this.c().lineSoft)
  }

  @Builder
  ThemeRow(key: string, label: string, en: string) {
    Row() {
      // 色样：底色 + 铜点 + 纸白
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(34)
          .height(34)
          .backgroundColor(Theme.of(key).bg)
          .border({ width: 0.5, color: this.c().line })
        Circle()
          .width(9)
          .height(9)
          .fill(Theme.of(key).accent)
      }
      .width(34)
      .height(34)

      Column() {
        Text(label)
          .fontSize(12)
          .fontColor(this.themeKey === key ? this.c().text : (this.locked(key) ? this.c().dim : this.c().text))
        Text(en)
          .fontSize(7)
          .fontColor(this.c().faint)
          .letterSpacing(1)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
      .layoutWeight(1)

      if (this.themeKey === key) {
        Text('●')
          .fontSize(11)
          .fontColor(this.c().accent)
      } else if (this.locked(key)) {
        // 锁着的主题只标 PRO，不做模糊预览：给个假缩略图比不给更让人恼火
        Text('PRO')
          .fontSize(7)
          .fontColor(this.c().accent)
          .letterSpacing(0.8)
          .border({ width: 0.5, color: this.c().accentDeep })
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
      }
    }
    .width('100%')
    .height(56)
    .onClick(() => {
      if (this.locked(key)) {
        promptAction.showToast({ message: `${label} 是密纹 Pro 主题` });
        router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => {
          Logger.warn('Settings', `open pro ${e}`);
        });
        return;
      }
      SettingsService.setTheme(key);
    })
  }

  /** 未解锁且这套主题属于 Pro → 需要拦一下 */
  private locked(key: string): boolean {
    return Theme.isPro(key) && !this.proOwned;
  }

  @Builder
  ModeChip(mode: string, label: string) {
    Text(label)
      .fontSize(10)
      .fontColor(this.mode === mode ? this.c().onAccent : this.c().dim)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.mode === mode ? this.c().accent : Color.Transparent)
      .border({ width: 0.5, color: this.c().line })
      .margin({ right: 8 })
      .onClick(() => {
        this.core.setMode(mode);
      })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row() {
          Text('设置')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.c().text)
            .letterSpacing(1.5)
          Blank()
          Text(`v${Const.VERSION}`)
            .fontSize(9)
            .fontColor(this.c().faint)
        }
        .width('100%')
        .padding({ top: 10, bottom: 4 })

        Scroll() {
          Column() {
            // ---- 密纹 Pro ----
            // 不做"全屏引导页"，入口就这一张纸：点进去看详情，不点就继续听歌。
            Row() {
              Column() {
                Row() {
                  Text('密纹 PRO')
                    .fontSize(9)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.c().accent)
                    .letterSpacing(1.8)
                  Blank()
                  Text(this.proOwned ? '已解锁' : '未解锁')
                    .fontSize(8)
                    .fontColor(this.proOwned ? this.c().accent : this.c().faint)
                    .letterSpacing(0.8)
                }
                .width('100%')

                Text(this.proOwned
                  ? `直出模式已可用 · ${ProService.since()}`
                  : '一次买断，解锁直出模式与后续进阶功能')
                  .fontSize(12)
                  .fontColor(this.c().text)
                  .width('100%')
                  .margin({ top: 9 })

                Text(this.proOwned
                  ? '感谢支持。不含订阅，不会自动续费。'
                  : `¥${Const.PRO_PRICE_EARLY} 早鸟价 · 永久可用 · 不联网校验`)
                  .fontSize(9)
                  .fontColor(this.c().dim)
                  .width('100%')
                  .margin({ top: 5 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .padding({ left: 14 })
            }
            .width('100%')
            .padding({ top: 16, bottom: 16, right: 14 })
            .backgroundColor(this.c().surface)
            .border({
              width: { left: 2, top: 0.5, bottom: 0.5, right: 0.5 },
              color: {
                left: this.c().accent,
                top: this.c().line,
                bottom: this.c().line,
                right: this.c().line
              }
            })
            .margin({ top: 14 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => {
                Logger.warn('Settings', `open pro ${e}`);
              });
            })

            // ---- 外观 ----
            this.SectionTitle('外观', 'APPEARANCE')
            this.Divider()
            // 主题已经是"唯一色源"，多加几套只是加令牌组，不碰页面代码 ——
            // 所以这一项成本最低，却最容易被看见。key 里带上 proOwned，
            // 解锁/撤销后才会重挂子项（否则 PRO 角标会停在旧状态）。
            ForEach(Theme.KEYS, (k: string, i: number) => {
              this.ThemeRow(k, Theme.label(k), Theme.en(k))
              if (i < Theme.KEYS.length - 1) {
                this.Divider()
              }
            }, (k: string) => `theme_${k}_${this.proOwned}`)
            Row() {
              Text('后四套为密纹 Pro 主题。高对比把对比度拉到最满，是给弱视用户用的，不是"更黑的暗夜"。')
                .fontSize(9)
                .fontColor(this.c().faint)
                .lineHeight(15)
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 10, bottom: 2 })

            // ---- 曲库 ----
            this.SectionTitle('曲库', 'LIBRARY')
            this.Divider()
            SettingRow({
              label: this.source === Const.SRC_DEMO ? '当前：示例唱片' : '当前：本机文件夹',
              value: `${this.count} 首`,
              detail: this.source === Const.SRC_DEMO
                ? '示例数据只用于体验播放与整理，不含任何真实音频。换成自己的文件夹后，示例会自动让位。'
                : (this.rootCount > 0
                  ? `${this.rootCount} 个目录并存，各扫各的。点下面「音乐文件夹」可以增删、重新授权。`
                  : '还没有授权目录。鸿蒙不允许应用全盘扫描，需要你选一次。')
            })
            this.Divider()
            SettingRow({
              label: '音乐文件夹',
              value: this.rootCount > 0 ? `${this.rootCount} 个` : '',
              detail: '可以加多个目录：无损放一处、播客放一处。移除只清索引，不动文件',
              onTap: () => {
                router.pushUrl({ url: 'pages/RootsPage' }).catch((e: Object) => {
                  Logger.warn('Settings', `open roots ${e}`);
                });
              }
            })
            this.Divider()
            SettingRow({
              label: this.scanning ? this.scanText : '全部重新扫描',
              detail: '核对磁盘上的增删；已入库的曲目不会被重复收录',
              onTap: () => {
                this.rescan();
              }
            })
            this.Divider()
            SettingRow({
              label: '载入示例曲库',
              detail: '22 首示例唱片，用于验收播放与列表',
              onTap: () => {
                LibraryService.loadDemo().then((n: number) => {
                  promptAction.showToast({ message: `已载入 ${n} 首示例` });
                  this.reload();
                });
              }
            })
            this.Divider()
            SettingRow({
              label: '听歌统计',              value: this.proOwned ? '' : 'PRO',
              detail: '起播次数、收听时长、最常听与近两周趋势，全部本机生成；可存成长图',
              onTap: () => {
                this.openStats();
              }
            })
            this.Divider()
            SettingRow({
              label: '清空曲库索引',
              detail: '不删除磁盘文件，只清掉密纹的索引',
              danger: true,
              onTap: () => {
                this.confirmClear();
              }
            })

            // 统计
            if (this.count > 0) {
              Row() {
                Column() {
                  Text('曲目')
                    .fontSize(8)
                    .fontColor(this.c().faint)
                  Text(`${this.count}`)
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.c().text)
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Column() {
                  Text('占用')
                    .fontSize(8)
                    .fontColor(this.c().faint)
                  Text(Fmt.bytes(this.bytes))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.c().text)
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Column() {
                  Text('格式')
                    .fontSize(8)
                    .fontColor(this.c().faint)
                  Text(this.formats.length > 0 ? this.formats.join(' · ') : '—')
                    .fontSize(9)
                    .fontColor(this.c().dim)
                    .margin({ top: 6 })
                    .maxLines(2)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1.4)
              }
              .width('100%')
              .padding({ top: 16, bottom: 14 })
            }

            this.Divider()
            SettingRow({
              label: '数据与迁移',
              value: 'M3U · 备份',
              detail: '导入导出歌单文件、把索引与收藏备份成单个 zip。换机不丢十年歌单',
              onTap: () => {
                router.pushUrl({ url: 'pages/DataPage' }).catch((e: Object) => {
                  Logger.warn('Settings', `open data ${e}`);
                });
              }
            })

            // ---- 播放 ----
            this.SectionTitle('播放', 'PLAYBACK')
            this.Divider()
            Column() {
              Text('默认播放模式')
                .fontSize(11)
                .fontColor(this.c().text)
                .width('100%')
                .margin({ top: 14, bottom: 10 })
              Row() {
                this.ModeChip(Const.MODE_LOOP, '列表循环')
                this.ModeChip(Const.MODE_SINGLE, '单曲循环')
                this.ModeChip(Const.MODE_SHUFFLE, '随机播放')
              }
              .width('100%')
            }
            this.Divider()
            SettingRow({
              label: '睡眠定时',
              value: this.sleepLabel,
              detail: '到点只暂停，不关应用',
              onTap: () => {
                this.openSleep();
              }
            })
            this.Divider()
            SettingRow({
              label: '音频焦点',
              value: '已启用 DUCK',
              detail: '导航播报时音乐降到 30% 而不是暂停；来电暂停，挂断后从原位置继续',
              onTap: () => {
                promptAction.showToast({ message: '导航播报会压低音乐，不会打断播放', duration: 2600 });
              }
            })

            this.Divider()
            // 直出模式：Pro 的唯一"听得出差别"的功能，所以放在播放区而不是高级设置里
            SettingRow({
              label: '直出模式',
              value: this.proOwned ? (this.direct ? '开' : '关') : 'PRO',
              detail: this.proOwned
                ? '关掉系统音效（Histen / 杜比等），把解码出的 PCM 原样送到输出。切换后下一首起全程生效。'
                : '密纹 Pro 功能：旁路系统音效链，PCM 原样输出。鸿蒙不开放频段增益，所以做的是"直出"而不是"调 EQ"。',
              onTap: () => {
                if (!this.proOwned) {
                  router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => {
                    Logger.warn('Settings', `open pro ${e}`);
                  });
                  return;
                }
                const next: boolean = !this.direct;
                const ok: boolean = this.core.setDirectMode(next);
                this.direct = next;
                // 偏好一定存下了；ok 只代表"是否已经作用到当前播放实例"。
                // 没在播的时候说"稍后再试"是错的——下一首起会生效，文案要如实。
                promptAction.showToast({
                  message: ok
                    ? (next ? '直出已开启：系统音效已旁路' : '已恢复系统音效')
                    : (next ? '直出已开启，下一首起生效' : '已关闭直出，下一首起恢复系统音效'),
                  duration: 2400
                });
              }
            })

            this.Divider()
            SettingRow({
              label: '无缝播放',
              value: this.proOwned ? this.gapLabel : 'PRO',
              detail: '双播放器预加载，提前 2.5 秒切流：现场专辑、古典、电子 mix 轨间不留静音缝；淡入淡出则是 3 秒音量交叉。',
              onTap: () => {
                this.openGapless();
              }
            })

            this.Divider()
            SettingRow({
              label: '桌面歌词',
              value: this.deskLyric ? '开' : (this.proOwned ? '关' : 'PRO'),
              detail: '回桌面也能看词：交给系统桌面歌词渲染（窗口拖动、锁屏共存都是系统行为），锁屏歌词与播控中心歌词共用同一份数据。',
              onTap: () => {
                this.toggleDeskLyric();
              }
            })

            // ---- 关于 ----
            this.SectionTitle('关于', 'ABOUT')
            this.Divider()
            SettingRow({
              label: '密纹音乐',
              value: `v${Const.VERSION}`,
              detail: '只读本地、不联网、不要账号的私人唱片库。'
            })
            this.Divider()
            SettingRow({
              label: '权限说明',
              value: '无网络权限',
              detail: '核心链路不申请 INTERNET；不上传文件、不收集任何播放数据。',
              onTap: () => {
                promptAction.showToast({ message: '本应用没有网络权限，装完可以断网用', duration: 2400 });
              }
            })
            this.Divider()
            SettingRow({
              label: '为什么不能自动扫描全盘',
              detail: '鸿蒙第三方应用拿不到 /storage/emulated/0/Music 这类全盘目录，只能用系统选择器授权一个目录。这不是缺陷，是平台规则。'
            })

            // ---- 诊断 ----
            this.SectionTitle('诊断', 'DIAGNOSTICS')
            this.Divider()
            SettingRow({
              label: '播放自检',
              value: '4 秒',
              detail: '用内置测试音走一遍真实解码链路，确认扬声器与 AVPlayer 正常',
              onTap: () => {
                SelfTest.play(this.ctx).then((p: string) => {
                  promptAction.showToast({ message: '正在播放内置测试音', duration: 2000 });
                  Logger.info('Settings', `selftest ${p}`);
                }).catch((e: Object) => {
                  promptAction.showToast({ message: `自检失败：${e}` });
                });
              }
            })
            this.Divider()
            // 这条证明"自建解码链"是真的：现场生成 AIFF，走 libmiwen.so 解码 + AudioRenderer 输出，
            // 听到 440 / 660 / 880 / 1100 Hz 四个音就说明字节序、声道、位深全对
            SettingRow({
              label: '原生解码自检',
              value: '8 秒',
              detail: '现场生成一个 AIFF（前 4 段各 2 秒：440 / 660 / 880 / 1100 Hz），走自建解码链播放。听到四个依次升高的音=解码与输出都对',
              onTap: () => {
                NativeSelfTest.run(this.ctx).then((s: string) => {
                  promptAction.showToast({ message: s, duration: 3200 });
                  Logger.info('Settings', `native selftest ${s}`);
                }).catch((e: Object) => {
                  promptAction.showToast({ message: `原生自检失败：${e}` });
                });
              }
            })
            this.Divider()
            SettingRow({
              label: '模拟播放异常',
              value: '演示用',
              detail: '触发一次解码失败，验证错误提示与自动跳下一首',
              onTap: () => {
                this.core.simulateError();
                promptAction.showToast({ message: '已触发一次播放异常' });
              }
            })
            this.Divider()
            // 这条决定"均衡器能不能做"。结论是系统只开放两态音效，没有频段通道，
            // 所以 Pro 只承诺直出；以后系统放开了，这里会读到更多模式。
            SettingRow({
              label: '音频能力探测',
              value: this.probeText,
              detail: '查系统给第三方开放了哪些音效通道。当前检测结果是"关/默认"两态，所以密纹不做图形均衡器，只做直出。',
              onTap: () => {
                this.runProbe();
              }
            })

            this.Divider()
            // 这条用来证明"读内嵌歌词"不是文档里的一句话：现场造一个带 USLT 的文件再解析回来
            SettingRow({
              label: '歌词解析自检',
              value: this.proOwned ? '' : 'PRO',
              detail: '造一个含 USLT 帧的 ID3 文件，再走真实的打开与解析路径，验证内嵌歌词读取',
              onTap: () => {
                if (!this.proOwned) {
                  router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => {
                    Logger.warn('Settings', `open pro ${e}`);
                  });
                  return;
                }
                LyricService.selfCheck(this.ctx).then((s: string) => {
                  promptAction.showToast({ message: s, duration: 3200 });
                  Logger.info('Settings', `lyric check ${s}`);
                }).catch((e: Object) => {
                  promptAction.showToast({ message: `歌词自检失败：${e}` });
                });
              }
            })

            Text('密纹音乐 · 单机版 · 2026')
              .fontSize(8)
              .fontColor(this.c().faint)
              .letterSpacing(1)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 30, bottom: 90 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: 720 })
      .alignSelf(ItemAlign.Center)
      .padding({ left: this.bp === Const.BP_SM ? 20 : 32, right: this.bp === Const.BP_SM ? 20 : 32 })

      if (this.panelOpen) {
        ActionPanel({
          title: this.panelMode === 'clear' ? '清空曲库索引？'
            : (this.panelMode === 'stats' ? '听歌统计'
              : (this.panelMode === 'gapless' ? '无缝播放' : (this.panelMode === 'desklyric' ? '桌面歌词' : '睡眠定时'))),
          subtitle: this.panelMode === 'clear'
            ? '只删除密纹自己建的索引，不会动你磁盘上的任何文件。下次选目录会重新扫。'
            : (this.panelMode === 'sleep' ? '到点自动暂停，不退出应用' : '密纹 Pro 功能'),
          items: this.panelItems,
          onPick: (i: number) => {
            this.onPanelPick(i);
          },
          onClose: () => {
            this.panelOpen = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.c().bg)
  }
}
