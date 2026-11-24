import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Const } from '../common/Constants';
import { Fmt } from '../common/Fmt';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { Playlist } from '../model/Playlist';
import { Track, emptyTrack } from '../model/Track';
import { PlaylistStore } from '../db/PlaylistStore';
import { PlayerCore } from '../service/PlayerCore';
import { PlayerSnapshot } from '../model/PlayerState';
import { MigrateService, SaveOutcome } from '../service/MigrateService';
import { ProService } from '../service/ProService';
import { TrackRow } from '../components/TrackRow';
import { EmptyState } from '../components/EmptyState';
import { ActionPanel, ActionItem } from '../components/ActionPanel';

const TAG: string = 'CollectionView';

/**
 * 收藏 / 歌单 / 最近播放。
 *
 * 三块共用一份"曲目行"，但语义不同：
 * 收藏是"我挑过的"，歌单是"我编过顺序的"，最近是"我刚听过的"。
 * 都存 uri，不存曲目副本 —— 改标签不会让这里对不上。
 */
@Component
export struct CollectionView {
  @State tab: number = 0;
  @State favs: Track[] = [];
  @State playlists: Playlist[] = [];
  @State recents: Track[] = [];
  @State creating: boolean = false;
  @State newName: string = '';
  @State editingId: number = -1;
  @State editName: string = '';
  @State menuOpen: boolean = false;
  @State menuTitle: string = '';
  @State menuSub: string = '';
  @State menuItems: ActionItem[] = [];
  @State menuAction: number = 0;
  @State menuPlaylist: number = 0;
  @State menuTrack: Track = emptyTrack();
  @State curUri: string = '';
  onGoLibrary: () => void = () => {
  };
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('bp') bp: string = Const.BP_SM;
  @StorageLink('libVersion') @Watch('reload') libVersion: number = 0;

  private core: PlayerCore = PlayerCore.instance();
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private listener: (s: PlayerSnapshot) => void = (s: PlayerSnapshot): void => {
    this.curUri = s.track !== null ? s.track.uri : '';
  };

  aboutToAppear(): void {
    this.core.onChange(this.listener);
    this.reload();
  }

  aboutToDisappear(): void {
    this.core.offChange(this.listener);
  }

  private async reload(): Promise<void> {
    this.favs = await PlaylistStore.favoriteTracks();
    this.playlists = await PlaylistStore.playlists();
    this.recents = await PlaylistStore.recentTracks(50);
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  // ---------------- 动作 ----------------

  private async playList(list: Track[], i: number): Promise<void> {
    if (list.length === 0) {
      return;
    }
    await this.core.playList(list, i);
    router.pushUrl({ url: 'pages/PlayerPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  private openPlaylist(p: Playlist): void {
    router.pushUrl({
      url: 'pages/ListPage',
      params: { kind: Const.LIST_PLAYLIST, key: p.id.toString(), title: p.name, sub: `${p.count} 首` }
    }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  private async createPlaylist(): Promise<void> {
    const name: string = this.newName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '先给歌单起个名字' });
      return;
    }
    await PlaylistStore.createPlaylist(name);
    this.newName = '';
    this.creating = false;
    this.reload();
  }

  private trackMenu(t: Track, inFav: boolean): void {
    this.menuTrack = t;
    this.menuAction = 0;
    this.menuTitle = t.title;
    this.menuSub = Fmt.meta(t.artist, t.album);
    this.menuItems = [
      { label: '播放这首', hint: '', danger: false },
      { label: '下一首播放', hint: '', danger: false },
      { label: '加入播放队列', hint: '', danger: false },
      { label: '加入歌单…', hint: '', danger: false },
      { label: inFav ? '取消收藏' : '收藏', hint: '', danger: inFav }
    ];
    this.menuOpen = true;
  }

  private playlistMenu(p: Playlist): void {
    this.menuPlaylist = p.id;
    this.menuAction = 1;
    this.menuTitle = p.name;
    this.menuSub = `${p.count} 首 · ${Fmt.ago(p.updatedAt)}`;
    this.menuItems = [
      { label: '重命名', hint: '', danger: false },
      { label: '导出为 M3U', hint: ProService.isPro() ? '' : 'PRO', danger: false },
      { label: '删除歌单', hint: '不删除文件', danger: true }
    ];
    this.menuOpen = true;
  }

  /** 导出：真源在 MigrateService，这里只负责把"哪首歌单"传进去 */
  private exportPlaylist(id: number, name: string): void {
    if (!ProService.isPro()) {
      promptAction.showToast({ message: '导出歌单是密纹 Pro 功能，可在 设置 → 数据与迁移 试用 3 次', duration: 3200 });
      return;
    }
    PlaylistStore.playlistTracks(id).then((tracks: Track[]) => {
      return MigrateService.exportM3u(this.ctx, name, tracks.map((t: Track) => t.uri));
    }).then((r: SaveOutcome) => {
      if (r.message.length > 0) {
        promptAction.showToast({ message: r.message, duration: 3200 });
      }
      Logger.info(TAG, `export playlist ${name} ok=${r.ok}`);
    }).catch((e: Object) => {
      promptAction.showToast({ message: '导出失败，请重试' });
      Logger.warn(TAG, `export failed ${e}`);
    });
  }

  private onPick(i: number): void {
    this.menuOpen = false;
    if (this.menuAction === 0) {
      const t: Track = this.menuTrack;
      if (i === 0) {
        const list: Track[] = this.tab === 0 ? this.favs : this.recents;
        this.playList(list, list.findIndex((x: Track) => x.uri === t.uri));
      } else if (i === 1) {
        this.core.playNext(t);
        promptAction.showToast({ message: '已排到下一首' });
      } else if (i === 2) {
        this.core.addToQueue(t);
        promptAction.showToast({ message: '已加入播放队列' });
      } else if (i === 3) {
        this.openAddToPlaylist(t);
      } else {
        PlaylistStore.toggleFavorite(t).then(() => {
          promptAction.showToast({ message: PlaylistStore.isFavorite(t.uri) ? '已收藏' : '已取消收藏' });
          this.reload();
        });
      }
      return;
    }
    // 歌单
    if (i === 0) {
      this.editingId = this.menuPlaylist;
      this.editName = this.menuTitle;
    } else if (i === 1) {
      this.exportPlaylist(this.menuPlaylist, this.menuTitle);
    } else {
      PlaylistStore.deletePlaylist(this.menuPlaylist).then(() => {
        promptAction.showToast({ message: '歌单已删除，文件还在' });
        this.reload();
      });
    }
  }

  /** 加入歌单：没有歌单就先建一个，避免"空菜单" */
  private async openAddToPlaylist(t: Track): Promise<void> {
    let list: Playlist[] = await PlaylistStore.playlists();
    if (list.length === 0) {
      await PlaylistStore.createPlaylist('我的歌单');
      list = await PlaylistStore.playlists();
    }
    const items: ActionItem[] = [];
    for (const p of list) {
      items.push({ label: p.name, hint: `${p.count} 首`, danger: false });
    }
    this.menuTrack = t;
    this.menuAction = 2;
    this.menuItems = items;
    this.menuTitle = '加入歌单';
    this.menuSub = t.title;
    this.menuOpen = true;
  }

  private async addToPlaylistAt(index: number): Promise<void> {
    const list: Playlist[] = await PlaylistStore.playlists();
    if (index < 0 || index >= list.length) {
      return;
    }
    await PlaylistStore.addToPlaylist(list[index].id, [this.menuTrack]);
    promptAction.showToast({ message: `已加入「${list[index].name}」` });
    this.reload();
  }

  // ---------------- 组件 ----------------

  @Builder
  SegTabs() {
    Row({ space: 22 }) {
      ForEach(['收藏', '歌单', '最近'], (label: string, i: number) => {
        // 同 LibraryView 的排序页签：下划线挂在内容自身的底边框上。
        Row({ space: 5 }) {
          Text(label)
            .fontSize(12)
            .fontColor(this.tab === i ? this.c().text : this.c().faint)
            .letterSpacing(0.5)
          Text(this.countOf(i))
            .fontSize(8)
            .fontColor(this.c().faint)
        }
        .padding({ bottom: 7 })
        .border({
          width: { bottom: 1 },
          color: { bottom: this.tab === i ? this.c().accent : Color.Transparent }
        })
        .onClick(() => {
          this.tab = i;
        })
      }, (label: string, i: number) => `ctab_${i}_${label}`)
      Blank()
    }
    .width('100%')
    .padding({ top: 12, bottom: 4 })
  }

  private countOf(i: number): string {
    if (i === 0) {
      return this.favs.length > 0 ? `${this.favs.length}` : '';
    }
    if (i === 1) {
      return this.playlists.length > 0 ? `${this.playlists.length}` : '';
    }
    return this.recents.length > 0 ? `${this.recents.length}` : '';
  }

  @Builder
  PlayAllBar(label: string, count: number, onPlay: () => void, onShuffle: () => void) {
    Row() {
      Text(label)
        .fontSize(10)
        .fontColor(this.c().onAccent)
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.c().accent)
        .onClick(onPlay)
      Text('随机')
        .fontSize(10)
        .fontColor(this.c().dim)
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .border({ width: 0.5, color: this.c().line })
        .margin({ left: 8 })
        .onClick(onShuffle)
      Blank()
      Text(`${count} 首 · ${Fmt.span(this.sumOf(this.tab))}`)
        .fontSize(8)
        .fontColor(this.c().faint)
    }
    .width('100%')
    .padding({ top: 10, bottom: 6 })
  }

  private sumOf(tab: number): number {
    const list: Track[] = tab === 0 ? this.favs : this.recents;
    let sum: number = 0;
    for (const t of list) {
      sum += t.duration;
    }
    return sum;
  }

  @Builder
  FavList() {
    if (this.favs.length === 0) {
      EmptyState({
        title: '还没有收藏',
        hint: '在曲库里长按任意一首，或者点播放页的收藏键，\n它就留在这里了。',
        actionLabel: '去曲库看看',
        onAction: () => {
          this.onGoLibrary();
        }
      })
    } else {
      this.PlayAllBar('播放全部', this.favs.length, () => {
        this.playList(this.favs, 0);
      }, () => {
        const i: number = Math.floor(Math.random() * this.favs.length);
        this.playList(this.favs, i);
      })

      ForEach(this.favs, (t: Track, i: number) => {
        TrackRow({
          track: t,
          active: this.curUri === t.uri,
          showCover: true,
          last: i === this.favs.length - 1,
          onTap: () => {
            this.playList(this.favs, i);
          },
          onLong: () => {
            this.trackMenu(t, true);
          }
        })
      }, (t: Track) => `fav_${t.uri}`)
    }
  }

  @Builder
  PlaylistList() {
    Column() {
      if (this.creating) {
        Row({ space: 10 }) {
          TextInput({ text: this.newName, placeholder: '歌单名字' })
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .fontColor(this.c().text)
            .placeholderColor(this.c().faint)
            .caretColor(this.c().accent)
            .backgroundColor(this.c().surfaceAlt)
            .borderRadius(0)
            .onChange((v: string) => {
              this.newName = v;
            })
          Text('建立')
            .fontSize(10)
            .fontColor(this.c().onAccent)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.c().accent)
            .onClick(() => {
              this.createPlaylist();
            })
          Text('取消')
            .fontSize(10)
            .fontColor(this.c().dim)
            .onClick(() => {
              this.creating = false;
              this.newName = '';
            })
        }
        .width('100%')
        .padding({ top: 12, bottom: 6 })
      } else {
        Text('+ 新建歌单')
          .fontSize(11)
          .fontColor(this.c().accent)
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .onClick(() => {
            this.creating = true;
          })
      }

      if (this.playlists.length === 0) {
        EmptyState({
          title: '还没有歌单',
          hint: '歌单只存在这台设备上，\n可以按场景编：通勤、夜里、开车。',
          actionLabel: '',
          onAction: () => {
          }
        })
      } else {
        ForEach(this.playlists, (p: Playlist, i: number) => {
          Column() {
            if (this.editingId === p.id) {
              Row({ space: 10 }) {
                TextInput({ text: this.editName })
                  .layoutWeight(1)
                  .height(34)
                  .fontSize(12)
                  .fontColor(this.c().text)
                  .backgroundColor(this.c().surfaceAlt)
                  .borderRadius(0)
                  .onChange((v: string) => {
                    this.editName = v;
                  })
                Text('保存')
                  .fontSize(10)
                  .fontColor(this.c().accent)
                  .onClick(() => {
                    const name: string = this.editName.trim();
                    if (name.length > 0) {
                      PlaylistStore.renamePlaylist(p.id, name).then(() => {
                        this.editingId = -1;
                        this.reload();
                      });
                    }
                  })
                Text('取消')
                  .fontSize(10)
                  .fontColor(this.c().dim)
                  .onClick(() => {
                    this.editingId = -1;
                  })
              }
              .width('100%')
              .height(56)
            } else {
              Row() {
                Column() {
                  Text(p.name)
                    .fontSize(13)
                    .fontColor(this.c().text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${p.count} 首 · ${Fmt.ago(p.updatedAt)}`)
                    .fontSize(9)
                    .fontColor(this.c().dim)
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('⋯')
                  .fontSize(16)
                  .fontColor(this.c().faint)
                  .width(40)
                  .textAlign(TextAlign.End)
                  .onClick(() => {
                    this.playlistMenu(p);
                  })
              }
              .width('100%')
              .height(58)
              .onClick(() => {
                this.openPlaylist(p);
              })
            }

            if (i < this.playlists.length - 1) {
              Row()
                .width('100%')
                .height(0.5)
                .backgroundColor(this.c().lineSoft)
            }
          }
        }, (p: Playlist) => `pl_${p.id}_${p.updatedAt}`)
      }
    }
    .width('100%')
  }

  @Builder
  RecentList() {
    if (this.recents.length === 0) {
      EmptyState({
        title: '还没有播放记录',
        hint: '最近播放只记在这台设备上，最多 50 首，\n永远不会上传。',
        actionLabel: '',
        onAction: () => {
        }
      })
    } else {
      Row() {
        Text('清空记录')
          .fontSize(10)
          .fontColor(this.c().dim)
          .padding({ top: 12, bottom: 8 })
          .onClick(() => {
            PlaylistStore.clearRecent().then(() => {
              this.reload();
              promptAction.showToast({ message: '记录已清空' });
            });
          })
        Blank()
        Text('只存在本机')
          .fontSize(8)
          .fontColor(this.c().faint)
          .padding({ top: 12, bottom: 8 })
      }
      .width('100%')

      ForEach(this.recents, (t: Track, i: number) => {
        TrackRow({
          track: t,
          active: this.curUri === t.uri,
          showCover: true,
          last: i === this.recents.length - 1,
          onTap: () => {
            this.playList(this.recents, i);
          },
          onLong: () => {
            this.trackMenu(t, PlaylistStore.isFavorite(t.uri));
          }
        })
      }, (t: Track) => `rec_${t.uri}`)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row() {
          Text('我的')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.c().text)
            .letterSpacing(1.5)
          Blank()
          Text('COLLECTION')
            .fontSize(7)
            .fontColor(this.c().faint)
            .letterSpacing(1.8)
        }
        .width('100%')
        .padding({ top: 10 })

        this.SegTabs()

        Scroll() {
          Column() {
            if (this.tab === 0) {
              this.FavList()
            } else if (this.tab === 1) {
              this.PlaylistList()
            } else {
              this.RecentList()
            }
            Blank().height(80)
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
      .padding({ left: this.bp === Const.BP_SM ? 20 : 32, right: this.bp === Const.BP_SM ? 20 : 32 })

      if (this.menuOpen) {
        ActionPanel({
          title: this.menuTitle,
          subtitle: this.menuSub,
          items: this.menuItems,
          onPick: (i: number) => {
            if (this.menuAction === 2) {
              this.menuOpen = false;
              this.addToPlaylistAt(i);
              return;
            }
            this.onPick(i);
          },
          onClose: () => {
            this.menuOpen = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.c().bg)
  }
}
