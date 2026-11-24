import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { Album, Track } from '../model/Track';
import { TrackStore } from '../db/TrackStore';
import { PlaylistStore } from '../db/PlaylistStore';
import { PlayerCore } from '../service/PlayerCore';
import { LibraryService } from '../service/LibraryService';
import { ImportFlow } from '../service/ImportFlow';
import { SettingsService } from '../service/SettingsService';
import { CoverArt } from '../components/CoverArt';
import { EmptyState } from '../components/EmptyState';

const TAG: string = 'HomeView';

/**
 * 首页 = 封面墙。
 *
 * 不做"歌单列表 + 推荐位"，因为这里只有用户自己的唱片：
 * 上面的空间给"最近在听"（4 张），下面整墙按专辑铺开，
 * 一屏能看到 6~8 张封套，翻起来像逛唱片店而不是刷列表。
 *
 * 首屏只查一页数据：曲库数量、前 30 张专辑、最近 4 首。
 * 5000 首的库在这里也只是三条 LIMIT 查询。
 */
@Component
export struct HomeView {
  @State albums: Album[] = [];
  @State recent: Track[] = [];
  @State total: number = 0;
  @State source: string = Const.SRC_LOCAL;
  @State scanning: boolean = false;
  @State scanText: string = '';
  @State wallW: number = 0;
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('bp') bp: string = Const.BP_SM;
  @StorageLink('libVersion') @Watch('reload') libVersion: number = 0;

  onGoLibrary: () => void = () => {
  };
  onGoSearch: () => void = () => {
  };

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      if (!TrackStore.ready()) {
        return;
      }
      this.source = SettingsService.source();
      this.total = await TrackStore.count(this.source);
      this.albums = await TrackStore.albums(this.source, 24);
      this.recent = await PlaylistStore.recentTracks(5);
    } catch (e) {
      Logger.error(TAG, `reload failed ${JSON.stringify(e)}`);
    }
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
    if (r.ok) {
      promptAction.showToast({ message: r.message, duration: 2000 });
      this.reload();
    } else if (r.message !== '没有选择文件夹') {
      promptAction.showToast({ message: r.message, duration: 2600 });
    }
  }

  private async loadDemo(): Promise<void> {
    const n: number = await LibraryService.loadDemo();
    promptAction.showToast({ message: `已载入 ${n} 首示例曲目，可在设置里换成自己的文件夹`, duration: 2600 });
    this.reload();
  }

  private async playRecent(i: number): Promise<void> {
    const core: PlayerCore = PlayerCore.instance();
    await core.playList(this.recent, i);
    router.pushUrl({ url: 'pages/PlayerPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  private openAlbum(a: Album): void {
    router.pushUrl({
      url: 'pages/ListPage',
      params: { kind: Const.LIST_ALBUM, key: a.album, title: a.album, sub: this.source }
    }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  // ---------------- 组件 ----------------

  @Builder
  Header() {
    Column() {
      Row() {
        Column() {
          Row() {
            Text('密纹')
              .fontSize(25)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.c().text)
              .letterSpacing(3)
            Text('·')
              .fontSize(25)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.c().accent)
              .margin({ left: 2, right: 2 })
            Text('音乐')
              .fontSize(25)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.c().text)
              .letterSpacing(3)
          }
          .alignItems(VerticalAlign.Center)

          Text(this.total > 0 ? `${this.total} 首 · 只在你这台设备上` : '把硬盘里的歌，收进自己的盒子')
            .fontSize(9)
            .fontColor(this.c().dim)
            .letterSpacing(0.5)
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('搜 索')
          .fontSize(10)
          .fontColor(this.c().dim)
          .letterSpacing(1)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .border({ width: 0.5, color: this.c().line })
          .onClick(() => this.onGoSearch())
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      if (this.scanning) {
        Row({ space: 8 }) {
          Text('◌')
            .fontSize(11)
            .fontColor(this.c().accent)
          Text(this.scanText)
            .fontSize(9)
            .fontColor(this.c().accent)
            .maxLines(1)
        }
        .margin({ top: 10 })
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 14 })
  }

  @Builder
  DemoNotice() {
    Row({ space: 8 }) {
      Text('示例')
        .fontSize(8)
        .fontColor(this.c().onAccent)
        .padding({ left: 5, right: 5, top: 2, bottom: 2 })
        .backgroundColor(this.c().accent)
      Text('这些是内置示例唱片，用来先把播放器跑通')
        .fontSize(9)
        .fontColor(this.c().dim)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('换成我的')
        .fontSize(9)
        .fontColor(this.c().accent)
        .onClick(() => {
          this.pickFolder();
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: { top: 0.5, bottom: 0.5 }, color: this.c().lineSoft })
  }

  @Builder
  RecentBlock() {
    Column() {
      Row() {
        Text('最近在听')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.c().text)
          .letterSpacing(0.5)
        Blank()
        Text('RECENT')
          .fontSize(7)
          .fontColor(this.c().faint)
          .letterSpacing(1.6)
      }
      .width('100%')
      .margin({ bottom: 12 })

      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.recent, (t: Track, i: number) => {
            Column() {
              CoverArt({
                coverPath: t.coverPath,
                seed: t.album.length > 0 ? t.album : t.title,
                title: t.album.length > 0 ? t.album : t.title,
                subtitle: '',
                dim: false
              })
                .width(104)
              Text(t.title)
                .fontSize(10)
                .fontColor(this.c().text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 7 })
                .width(104)
              Text(t.artist.length > 0 ? t.artist : '未知艺人')
                .fontSize(8)
                .fontColor(this.c().dim)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 2 })
                .width(104)
            }
            .alignItems(HorizontalAlign.Start)
            .onClick(() => {
              this.playRecent(i);
            })
          }, (t: Track) => `recent_${t.uri}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .margin({ top: 18 })
  }

  @Builder
  WallTitle() {
    Row() {
      Text('唱片墙')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.c().text)
        .letterSpacing(0.5)
      Text(`${this.albums.length} 张`)
        .fontSize(9)
        .fontColor(this.c().faint)
        .margin({ left: 8 })
      Blank()
      Text('全部曲目 ›')
        .fontSize(9)
        .fontColor(this.c().dim)
        .onClick(() => this.onGoLibrary())
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 22, bottom: 14 })
  }

  @Builder
  Wall() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
      ForEach(this.albums, (a: Album, i: number) => {
        Column() {
          CoverArt({
            coverPath: a.coverPath,
            seed: a.album,
            title: a.album,
            subtitle: a.artist,
            dim: false
          })
            .width('100%')
          Text(a.album)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.c().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 8 })
          Row() {
            Text(a.artist.length > 0 ? a.artist : '未知艺人')
              .fontSize(8)
              .fontColor(this.c().dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(`${a.count} 首`)
              .fontSize(8)
              .fontColor(this.c().faint)
          }
          .width('100%')
          .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .width(this.itemW())
        .padding({ right: this.colGap() })
        .margin({ bottom: 20 })
        .onClick(() => this.openAlbum(a))
      }, (a: Album) => `album_${a.key}_${a.album}`)
    }
    .width('100%')
    .onAreaChange((oldV: Area, newV: Area) => {
      const w: number = parseFloat(newV.width.toString());
      if (w > 0 && w !== this.wallW) {
        this.wallW = w;
      }
    })
  }

  @Builder
  Footer() {
    Column() {
      Row()
        .width('100%')
        .height(0.5)
        .backgroundColor(this.c().lineSoft)
      Column() {
        Text('零联网 · 零账号 · 不上传任何文件')
          .fontSize(8)
          .fontColor(this.c().dim)
          .letterSpacing(0.8)
        Text(`密纹音乐 v${Const.VERSION} · 本地曲库 ${this.total} 首`)
          .fontSize(7)
          .fontColor(this.c().faint)
          .letterSpacing(0.6)
          .margin({ top: 5 })
      }
      .margin({ top: 14, bottom: 26 })
    }
    .width('100%')
  }

  // ---------------- 尺寸 ----------------

  private cols(): number {
    if (this.bp === Const.BP_LG) {
      return 5;
    }
    if (this.bp === Const.BP_MD) {
      return 4;
    }
    return 2;
  }

  private colGap(): number {
    return this.cols() >= 4 ? 16 : 14;
  }

  private itemW(): number {
    if (this.wallW <= 0) {
      return this.cols() === 2 ? 160 : 120;
    }
    return (this.wallW - this.colGap() * (this.cols() - 1)) / this.cols();
  }

  build() {
    List({ space: 0 }) {
      ListItem() {
        this.Header()
      }

      if (this.total === 0) {
        ListItem() {
          EmptyState({
            title: '还没有唱片',
            hint: '鸿蒙不允许应用自己去翻你的硬盘。\n选一个音乐文件夹，密纹会把它整理成一面唱片墙。',
            actionLabel: '选择音乐文件夹',
            secondaryLabel: '先看看示例曲库',
            onAction: () => {
              this.pickFolder();
            },
            onSecondary: () => {
              this.loadDemo();
            }
          })
        }
      } else {
        if (this.source === Const.SRC_DEMO) {
          ListItem() {
            this.DemoNotice()
          }
        }

        if (this.recent.length > 0) {
          ListItem() {
            this.RecentBlock()
          }
        }

        ListItem() {
          this.WallTitle()
        }

        ListItem() {
          this.Wall()
        }
      }

      ListItem() {
        this.Footer()
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .padding({ left: this.bp === Const.BP_SM ? 20 : 32, right: this.bp === Const.BP_SM ? 20 : 32 })
    .backgroundColor(this.c().bg)
  }
}
