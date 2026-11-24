import { router, promptAction } from '@kit.ArkUI';
import { Const } from '../common/Constants';
import { Fmt } from '../common/Fmt';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { Track, emptyTrack } from '../model/Track';
import { TrackStore } from '../db/TrackStore';
import { PlaylistStore } from '../db/PlaylistStore';
import { PlayerCore } from '../service/PlayerCore';
import { PlayerSnapshot } from '../model/PlayerState';
import { SettingsService } from '../service/SettingsService';
import { TrackDataSource } from '../state/ListSources';
import { TrackRow } from '../components/TrackRow';
import { EmptyState } from '../components/EmptyState';
import { ActionPanel, ActionItem } from '../components/ActionPanel';

const TAG: string = 'ListPage';

interface ListParams {
  kind: string;
  key: string;
  title: string;
  sub: string;
}

/**
 * 通用列表页：专辑 / 歌单 / 收藏 / 最近 / 队列 共用一套。
 *
 * 五种来源的差别只在"怎么取数据"和"能不能删"，版式完全一样，
 * 所以不复制五个页面 —— 复制出来的后果是同一个间距要改五遍。
 */
@Entry
@Component
struct ListPage {
  @State kind: string = Const.LIST_ALBUM;
  @State title: string = '';
  @State sub: string = '';
  @State listKey: string = '';
  @State count: number = 0;
  @State totalMs: number = 0;
  @State curUri: string = '';
  @State panelOpen: boolean = false;
  @State panelItems: ActionItem[] = [];
  @State panelTrack: Track = emptyTrack();
  @State empty: boolean = false;
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('bp') bp: string = Const.BP_SM;
  @StorageProp('topInset') topInset: number = 0;

  private ds: TrackDataSource = new TrackDataSource();
  private core: PlayerCore = PlayerCore.instance();

  private listener: (s: PlayerSnapshot) => void = (s: PlayerSnapshot): void => {
    this.curUri = s.track !== null ? s.track.uri : '';
  };

  aboutToAppear(): void {
    let p: ListParams = { kind: Const.LIST_ALBUM, key: '', title: '曲目', sub: '' };
    try {
      const raw: ListParams = router.getParams() as ListParams;
      if (raw.kind.length > 0) {
        p = raw;
      }
    } catch (e) {
      Logger.warn(TAG, 'no params, fallback');
    }
    this.kind = p.kind;
    this.listKey = p.key;
    this.title = p.title;
    this.sub = p.sub;
    this.core.onChange(this.listener);
    this.load();
  }

  aboutToDisappear(): void {
    this.core.offChange(this.listener);
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  private async load(): Promise<void> {
    let list: Track[] = [];
    if (this.kind === Const.LIST_ALBUM) {
      const src: string = this.sub.length > 0 ? this.sub : SettingsService.source();
      list = await TrackStore.albumTracks(src, this.listKey);
    } else if (this.kind === Const.LIST_PLAYLIST) {
      const id: number = parseInt(this.listKey, 10);
      list = await PlaylistStore.playlistTracks(isNaN(id) ? 0 : id);
      if (this.title.length === 0) {
        this.title = await PlaylistStore.playlistName(id);
      }
    } else if (this.kind === Const.LIST_FAVORITE) {
      list = await PlaylistStore.favoriteTracks();
    } else if (this.kind === Const.LIST_RECENT) {
      list = await PlaylistStore.recentTracks(100);
    } else {
      list = this.core.queueTracks().slice(0);
    }
    let ms: number = 0;
    for (const t of list) {
      ms += t.duration;
    }
    this.totalMs = ms;
    this.count = list.length;
    this.empty = list.length === 0;
    this.ds.reset(list);
  }

  private async playAt(i: number): Promise<void> {
    const list: Track[] = this.ds.all();
    if (i < 0 || i >= list.length) {
      return;
    }
    await this.core.playList(list, i);
    router.pushUrl({ url: 'pages/PlayerPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  private openMenu(t: Track): void {
    this.panelTrack = t;
    const fav: boolean = PlaylistStore.isFavorite(t.uri);
    const items: ActionItem[] = [
      { label: '播放这首', hint: Fmt.fmt(t.suffix), danger: false },
      { label: '下一首播放', hint: '', danger: false },
      { label: fav ? '取消收藏' : '收藏', hint: '', danger: false }
    ];
    if (this.kind === Const.LIST_PLAYLIST) {
      items.push({ label: '从这个歌单移除', hint: '', danger: true });
    }
    if (this.kind === Const.LIST_QUEUE) {
      items.push({ label: '从队列移除', hint: '', danger: true });
    }
    items.push({ label: '文件信息', hint: Fmt.bytes(t.size), danger: false });
    this.panelItems = items;
    this.panelOpen = true;
  }

  private async onPanelPick(i: number): Promise<void> {
    const t: Track = this.panelTrack;
    this.panelOpen = false;
    const list: Track[] = this.ds.all();
    if (i === 0) {
      await this.playAt(list.findIndex((x: Track) => x.uri === t.uri));
      return;
    }
    if (i === 1) {
      this.core.playNext(t);
      promptAction.showToast({ message: '已排到下一首' });
      return;
    }
    if (i === 2) {
      await PlaylistStore.toggleFavorite(t);
      promptAction.showToast({ message: PlaylistStore.isFavorite(t.uri) ? '已收藏' : '已取消收藏' });
      return;
    }
    const removeLabel: number = 3;
    if (this.kind === Const.LIST_PLAYLIST && i === removeLabel) {
      const id: number = parseInt(this.listKey, 10);
      await PlaylistStore.removeFromPlaylist(isNaN(id) ? 0 : id, t.uri);
      promptAction.showToast({ message: '已从歌单移除' });
      this.load();
      return;
    }
    if (this.kind === Const.LIST_QUEUE && i === removeLabel) {
      const idx: number = list.findIndex((x: Track) => x.uri === t.uri);
      this.core.removeAt(idx);
      this.load();
      return;
    }
    promptAction.showToast({
      message: `${t.title} · ${Fmt.fmt(t.suffix)} ${Fmt.rate(t.sampleRate)} · ${Fmt.bytes(t.size)}`,
      duration: 2800
    });
  }

  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor(this.c().dim)
        .width(40)
        .onClick(() => router.back())
      Blank()
      // 标题下面的大字已经写了「播放队列」，这里再来一遍就重复了，改成英文小标
      Text(this.kind === Const.LIST_QUEUE ? 'QUEUE' : this.kind === Const.LIST_PLAYLIST ? 'PLAYLIST' : 'ALBUM')
        .fontSize(8)
        .fontColor(this.c().faint)
        .letterSpacing(1.6)
      Blank()
      Text('')
        .width(40)
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.TopBar()

        Column() {
          Text(this.title)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.c().text)
            .letterSpacing(0.5)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Row({ space: 8 }) {
            Text(this.sub.length > 0 && this.kind === Const.LIST_ALBUM ? this.sub : `${this.count} 首 · ${Fmt.span(this.totalMs)}`)
              .fontSize(9)
              .fontColor(this.c().dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.kind === Const.LIST_ALBUM && this.count > 0) {
              Text(`· ${this.count} 首 · ${Fmt.span(this.totalMs)}`)
                .fontSize(9)
                .fontColor(this.c().faint)
            }
          }
          .width('100%')
          .margin({ top: 8 })

          Row() {
            Text('播放全部')
              .fontSize(10)
              .fontColor(this.c().onAccent)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(this.c().accent)
              .onClick(() => this.playAt(0))
            Text('随机')
              .fontSize(10)
              .fontColor(this.c().dim)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .border({ width: 0.5, color: this.c().line })
              .margin({ left: 8 })
              .onClick(() => {
                if (this.count > 0) {
                  this.playAt(Math.floor(Math.random() * this.count));
                }
              })
            Blank()
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('100%')
        .padding({ bottom: 6 })

        if (this.empty) {
          Column() {
            EmptyState({
              title: this.kind === Const.LIST_QUEUE ? '队列是空的' : '这里还没有曲目',
              hint: this.kind === Const.LIST_PLAYLIST
                ? '在曲库里长按一首歌，选择「加入歌单」。'
                : '从曲库里挑几首开始吧。',
              actionLabel: '返回',
              onAction: () => router.back()
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            LazyForEach(this.ds, (t: Track, i: number) => {
              ListItem() {
                TrackRow({
                  track: t,
                  active: this.curUri === t.uri,
                  showCover: this.kind === Const.LIST_ALBUM,
                  showIndex: this.kind !== Const.LIST_ALBUM,
                  index: i,
                  last: i === this.ds.size() - 1,
                  onTap: () => {
                    this.playAt(i);
                  },
                  onLong: () => {
                    this.openMenu(t);
                  }
                })
              }
            }, (t: Track) => `${this.kind}_${t.uri}`)
          }
          .width('100%')
          .layoutWeight(1)
          .cachedCount(6)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .padding({ bottom: 40 })
        }
      }
      .width('100%')
      .height('100%')
      .padding({
        left: this.bp === Const.BP_SM ? 20 : 40,
        right: this.bp === Const.BP_SM ? 20 : 40,
        top: this.topInset + 4
      })

      if (this.panelOpen) {
        ActionPanel({
          title: this.panelTrack.title,
          subtitle: Fmt.meta(this.panelTrack.artist, this.panelTrack.album),
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
