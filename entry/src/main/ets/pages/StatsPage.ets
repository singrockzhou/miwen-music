import { router, promptAction, componentSnapshot } from '@kit.ArkUI';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { Const } from '../common/Constants';
import { Fmt } from '../common/Fmt';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { Track } from '../model/Track';
import { TrackStore } from '../db/TrackStore';
import { StatsStore, StatsOverall, TopPlay, DayPlay } from '../db/StatsStore';
import { PlayerCore } from '../service/PlayerCore';

const TAG: string = 'StatsPage';
const BAR_DAYS: number = 14;

/**
 * 听歌统计（密纹 Pro）。
 *
 * 所有数字都是本机 play_log 表聚合出来的，不联网、不上传。
 * 两个口径在这里说清楚：
 * - 播放次数 = 起播次数（长曲中途切走也算听过）；
 * - 收听时长 = 内核推进的真实毫秒（seek 与跳歌不计）。
 *
 * 「存成长图」用 componentSnapshot 把当前页面拍成一张 JPEG，
 * 交给系统保存面板，路径由用户选 —— 与备份还原同一套文件出口。
 */
@Entry
@Component
struct StatsPage {
  @State overall: StatsOverall = { plays: 0, listenMs: 0, tracks: 0, days: 0, firstTs: 0 };
  @State tops: TopPlay[] = [];
  @State days: DayPlay[] = [];
  @State recent: TopPlay[] = [];
  @State loaded: boolean = false;
  @State saving: boolean = false;
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('proOwned') proOwned: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;

  private core: PlayerCore = PlayerCore.instance();
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    // 页面停留期间的收听时长还没落库，离开时补上
    this.core.saveNow();
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.Friction })
      .slide(SlideEffect.Right)
    PageTransitionExit({ duration: 240, curve: Curve.Friction })
      .slide(SlideEffect.Right)
  }

  private async load(): Promise<void> {
    if (!TrackStore.ready()) {
      return;
    }
    // 先把内核里攒着的收听时长落库，再查 —— 否则刚听的时间不进总览（真机验证踩过）
    await this.core.flushStats();
    try {
      this.overall = await StatsStore.overall();
      this.tops = await StatsStore.topTracks(10);
      this.days = await StatsStore.daily(BAR_DAYS);
      this.recent = await StatsStore.recentStarts(5);
    } catch (e) {
      Logger.error(TAG, `load failed ${JSON.stringify(e)}`);
    }
    this.loaded = true;
  }

  /** 点最常听的一行：把 TOP 列表当队列放，从这一首开始 */
  private playTop(uri: string): void {
    TrackStore.listByUris(this.tops.map((t: TopPlay) => t.uri)).then((list: Track[]) => {
      if (list.length === 0) {
        return;
      }
      this.core.playList(list, list.findIndex((t: Track) => t.uri === uri));
      router.pushUrl({ url: 'pages/PlayerPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
    });
  }

  /** 长图：拍当前页面 → JPEG → 系统保存面板 */
  private async saveImage(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      const pm: image.PixelMap = await componentSnapshot.get('stats_root');
      const packer: image.ImagePacker = image.createImagePacker();
      const buf: ArrayBuffer = await packer.packToData(pm, { format: 'image/jpeg', quality: 92 });
      const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.ctx);
      const opt: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opt.newFileNames = ['miwen-stats.jpg'];
      opt.fileSuffixChoices = ['.jpg'];
      const uris: string[] = await dp.save(opt);
      if (!uris || uris.length === 0) {
        this.saving = false;
        return;
      }
      const f: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, buf);
      } finally {
        fs.closeSync(f);
      }
      promptAction.showToast({ message: '统计图已保存', duration: 2200 });
      Logger.info(TAG, `stats image saved ${buf.byteLength} bytes`);
    } catch (e) {
      Logger.error(TAG, `save image failed ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '生成图片失败，这台系统不支持长图', duration: 2600 });
    }
    this.saving = false;
  }

  private firstDay(): string {
    if (this.overall.firstTs <= 0) {
      return '';
    }
    const d: Date = new Date(this.overall.firstTs);
    return `${d.getFullYear()}.${d.getMonth() + 1}.${d.getDate()}`;
  }

  private maxDayPlays(): number {
    let m: number = 0;
    for (const d of this.days) {
      m = Math.max(m, d.plays);
    }
    return m;
  }

  // ---------------- 组件 ----------------

  @Builder
  SectionTitle(cn: string, en: string) {
    Row() {
      Text(cn)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.c().text)
        .letterSpacing(1.2)
      Blank()
      Text(en)
        .fontSize(7)
        .fontColor(this.c().faint)
        .letterSpacing(1.6)
    }
    .width('100%')
    .padding({ top: 20, bottom: 10 })
  }

  /**
   * 总览四格直接写在 build 里。
   * 教训（真机 15:32-15:39 三轮复现）：@Builder 按值传参不随状态刷新，
   * 连"无参 @Builder 内再调带参 @Builder"也不会刷新 —— 数据在、界面停在 0。
   * 内联虽然啰嗦，但每一格都真实跟着 this.overall 走。
   */
  private statNum(n: number): string {
    return `${n}`;
  }

  @Builder
  PlayRow(t: TopPlay, i: number, showAgo: boolean) {
    Row({ space: 10 }) {
      Text((i + 1).toString().padStart(2, '0'))
        .fontSize(10)
        .fontColor(this.c().faint)
        .width(22)
      Column() {
        Text(t.title)
          .fontSize(11)
          .fontColor(this.c().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(showAgo ? `${Fmt.ago(t.plays)} · ${t.artist.length > 0 ? t.artist : '未知艺人'}` :
          `${t.artist.length > 0 ? t.artist : '未知艺人'} · 听过 ${Fmt.span(t.ms)}`)
          .fontSize(8)
          .fontColor(this.c().faint)
          .maxLines(1)
          .margin({ top: 3 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(showAgo ? '' : `${t.plays} 次`)
        .fontSize(9)
        .fontColor(this.c().accent)
      Text('›')
        .fontSize(12)
        .fontColor(this.c().faint)
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
    .onClick(() => {
      this.playTop(t.uri);
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 顶栏
        Row() {
          Text('‹')
            .fontSize(26)
            .fontColor(this.c().dim)
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .onClick(() => router.back())
          Column() {
            Text('听歌统计')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.c().text)
              .letterSpacing(1.2)
            Text('STATS')
              .fontSize(6)
              .fontColor(this.c().faint)
              .letterSpacing(2.4)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 6 })
          Blank()
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 6 })

        Scroll() {
          Column() {
            this.SectionTitle('总览', 'OVERVIEW')
            Row() {
              Column() {
                Text(`${this.overall.plays}`)
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.c().text)
                Text('次起播')
                  .fontSize(8)
                  .fontColor(this.c().faint)
                  .letterSpacing(0.8)
                  .margin({ top: 5 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
              Column() {
                Text(Fmt.span(this.overall.listenMs))
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.c().text)
                Text('收听时长')
                  .fontSize(8)
                  .fontColor(this.c().faint)
                  .letterSpacing(0.8)
                  .margin({ top: 5 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
              Column() {
                Text(`${this.overall.tracks}`)
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.c().text)
                Text('听过曲目')
                  .fontSize(8)
                  .fontColor(this.c().faint)
                  .letterSpacing(0.8)
                  .margin({ top: 5 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
              Column() {
                Text(`${this.overall.days}`)
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.c().text)
                Text('收听天数')
                  .fontSize(8)
                  .fontColor(this.c().faint)
                  .letterSpacing(0.8)
                  .margin({ top: 5 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .padding({ top: 6, bottom: 4 })
            if (this.firstDay().length > 0) {
              Text(`记录自 ${this.firstDay()} · 全部在本机生成，不上传`)
                .fontSize(8)
                .fontColor(this.c().faint)
                .width('100%')
                .margin({ top: 6 })
            }

            this.SectionTitle(`近 ${BAR_DAYS} 天`, 'LAST 14 DAYS')
            Row({ space: 4 }) {
              ForEach(this.days, (d: DayPlay, i: number) => {
                Column() {
                  Column()
                    .width('100%')
                    .height(d.plays > 0 ? Math.max(6, Math.round(d.plays / Math.max(1, this.maxDayPlays()) * 56)) : 2)
                    .backgroundColor(d.plays > 0 ? this.c().accent : this.c().line)
                    .alignItems(HorizontalAlign.Center)
                    .justifyContent(FlexAlign.End)
                  if (i % 3 === 0 || i === this.days.length - 1) {
                    Text(d.day.substring(5).replace('-', '.'))
                      .fontSize(6)
                      .fontColor(this.c().faint)
                      .margin({ top: 4 })
                  } else {
                    Text('').fontSize(6).margin({ top: 4 })
                  }
                }
                .layoutWeight(1)
                .height(74)
                .justifyContent(FlexAlign.End)
              }, (d: DayPlay) => d.day)
            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)

            this.SectionTitle('最常听', 'TOP 10')
            if (this.tops.length === 0) {
              Text('还没有播放记录。去曲库放一首，这里就会开始记账。')
                .fontSize(10)
                .fontColor(this.c().dim)
                .lineHeight(17)
                .width('100%')
            } else {
              ForEach(this.tops, (t: TopPlay, i: number) => {
                this.PlayRow(t, i, false)
                if (i < this.tops.length - 1) {
                  Divider().color(this.c().lineSoft).strokeWidth(0.5)
                }
              }, (t: TopPlay) => `${t.uri}_${t.plays}`)
            }

            this.SectionTitle('最近在听', 'RECENT')
            if (this.recent.length === 0) {
              Text('暂无记录')
                .fontSize(10)
                .fontColor(this.c().dim)
                .width('100%')
            } else {
              ForEach(this.recent, (t: TopPlay, i: number) => {
                this.PlayRow(t, i, true)
                if (i < this.recent.length - 1) {
                  Divider().color(this.c().lineSoft).strokeWidth(0.5)
                }
              }, (t: TopPlay) => `${t.uri}_${t.plays}`)
            }
            Row().height(24)
          }
          .width('100%')
          .padding({ left: 22, right: 22, bottom: 86 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      // 长图快照的锚点：saveImage 按这个 id 拍当前页面
      .id('stats_root')

      // 底部：存成长图
      Row() {
        Text(this.saving ? '正在生成…' : '存成长图')
          .fontSize(11)
          .fontColor(this.c().onAccent)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .height(44)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.c().accent)
          .onClick(() => {
            this.saveImage();
          })
      }
      .width('100%')
      .padding({ left: 22, right: 22, bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset, bottom: this.bottomInset })
    .backgroundColor(this.c().bg)
  }
}
