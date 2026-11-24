import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { Const } from '../common/Constants';
import { Fmt } from '../common/Fmt';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { Track, emptyTrack } from '../model/Track';
import { FolderNode, FolderStat, RootDir } from '../model/RootDir';
import { TrackStore } from '../db/TrackStore';
import { PlaylistStore } from '../db/PlaylistStore';
import { PlayerCore } from '../service/PlayerCore';
import { PlayerSnapshot } from '../model/PlayerState';
import { SettingsService } from '../service/SettingsService';
import { ProService } from '../service/ProService';
import { ImportFlow } from '../service/ImportFlow';
import { LibraryService } from '../service/LibraryService';
import { RootService } from '../service/RootService';
import { TrackDataSource } from '../state/ListSources';
import { TrackRow } from '../components/TrackRow';
import { CoverArt } from '../components/CoverArt';
import { EmptyState } from '../components/EmptyState';
import { ActionPanel, ActionItem } from '../components/ActionPanel';

const TAG: string = 'LibraryView';

/**
 * 曲库：搜索 / 排序 / 格式筛选 / 列表与封面墙两种密度。
 *
 * 列表是这个页面的主角：一屏 9~10 行，右侧直接给格式与采样率，
 * 无损党不用点进详情就知道这是不是自己要找的那一版。
 *
 * 分页 + LazyForEach：5000 首的库首屏只查 60 条，滚动到尾部再取下一页。
 */
@Component
export struct LibraryView {
  @State kw: string = '';
  @State sort: string = Const.SORT_RECENT;
  @State view: string = Const.VIEW_LIST;
  @State fmt: string = '';
  @State total: number = 0;
  @State matched: number = 0;
  @State loading: boolean = false;
  @State hasMore: boolean = true;
  @State source: string = Const.SRC_LOCAL;
  @State fmts: string[] = [];
  @State scanning: boolean = false;
  @State scanText: string = '';
  @State menuOpen: boolean = false;
  @State menuTrack: Track = emptyTrack();
  @State menuItems: ActionItem[] = [];
  // ---- 封面墙密度（卡片矩阵）----
  @State density: string = Const.GRID_STD;
  @State gateOpen: boolean = false;
  @State gateItems: ActionItem[] = [];
  @State gatePending: string = '';
  @State curUri: string = '';
  @State nowPlaying: boolean = false;
  // ---- 文件夹视图 ----
  @State roots: RootDir[] = [];
  /** 当前根目录的绝对路径 */
  @State curRoot: string = '';
  /** 当前相对根的目录，空串表示根的顶层 */
  @State curPath: string = '';
  @State folderRows: FolderNode[] = [];
  @State folderTracks: Track[] = [];
  @State folderTotal: number = 0;
  /** 本层直接放的曲目数（不含子目录） */
  @State folderDirect: number = 0;
  @State folderHasMore: boolean = false;
  @State folderLoading: boolean = false;
  /** 索引来自旧版本（没有 folder 字段），需要重扫才能建树 */
  @State folderLegacy: boolean = false;
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('bp') bp: string = Const.BP_SM;
  @StorageProp('proOwned') proOwned: boolean = false;
  @StorageLink('libVersion') @Watch('onLibChanged') libVersion: number = 0;

  private ds: TrackDataSource = new TrackDataSource();
  private pageOffset: number = 0;
  private seq: number = 0;
  private searchTimer: number = -1;
  private core: PlayerCore = PlayerCore.instance();
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private listener: (s: PlayerSnapshot) => void = (s: PlayerSnapshot): void => {
    this.curUri = s.track !== null ? s.track.uri : '';
    this.nowPlaying = s.playing;
  };

  aboutToAppear(): void {
    this.sort = SettingsService.sort();
    this.view = SettingsService.view();
    this.density = SettingsService.gridDensity();
    this.core.onChange(this.listener);
    this.reload(true);
    if (this.view === Const.VIEW_FOLDER) {
      this.loadFolder(true);
    }
  }

  aboutToDisappear(): void {
    this.core.offChange(this.listener);
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
    }
  }

  onLibChanged(): void {
    this.reload(true);
    if (this.view === Const.VIEW_FOLDER) {
      this.loadFolder(true);
    }
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  // ---------------- 数据 ----------------

  private async reload(reset: boolean): Promise<void> {
    if (!TrackStore.ready()) {
      return;
    }
    const mySeq: number = ++this.seq;
    if (reset) {
      this.pageOffset = 0;
      this.hasMore = true;
      this.loading = true;
    }
    try {
      const src: string = SettingsService.source();
      this.source = src;
      const key: string = this.kw.trim();
      if (reset) {
        this.total = await TrackStore.count(src);
        this.fmts = await TrackStore.suffixList(src);
        this.matched = key.length > 0
          ? await TrackStore.searchCount(src, key, this.fmt)
          : await TrackStore.countBySuffix(src, this.fmt);
      }
      const page: Track[] = key.length > 0
        ? await TrackStore.search(src, key, this.pageOffset, Const.PAGE_SIZE, this.fmt)
        : await TrackStore.page(src, this.pageOffset, Const.PAGE_SIZE, this.sort, this.fmt);

      if (mySeq !== this.seq) {
        return; // 已经有更新的查询，丢弃这次结果
      }
      if (reset) {
        this.ds.reset(page);
      } else {
        this.ds.append(page);
      }
      this.pageOffset += page.length;
      this.hasMore = this.pageOffset < this.matched && page.length > 0;
    } catch (e) {
      Logger.error(TAG, `reload failed ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '读取曲库失败，请重试' });
    } finally {
      if (mySeq === this.seq) {
        this.loading = false;
      }
    }
  }

  private scheduleSearch(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
    }
    this.searchTimer = setTimeout(() => {
      this.reload(true);
    }, 260);
  }

  private loadMore(): void {
    if (this.loading || !this.hasMore) {
      return;
    }
    this.loading = true;
    this.reload(false);
  }

  // ---------------- 文件夹 ----------------

  /**
   * 文件夹视图的数据装载。
   *
   * 树在 ArkTS 里建而不是用 SQL 递归：一个曲库的目录数通常几十到几百，
   * 一次把 (folder, count, size) 全查出来再拼层级，比递归 CTE 好调试，
   * 还能顺手把"含子目录总数"和"本层直接数"一起算对。
   */
  private async loadFolder(reset: boolean): Promise<void> {
    if (!TrackStore.ready()) {
      return;
    }
    this.roots = RootService.list();
    if (this.roots.length === 0) {
      this.folderRows = [];
      this.folderTracks = [];
      this.folderTotal = 0;
      this.folderHasMore = false;
      return;
    }
    // 当前根可能被移除过，落到第一根，不要留一个指向已删目录的空视图
    let exists: boolean = false;
    for (const r of this.roots) {
      if (r.path === this.curRoot) {
        exists = true;
      }
    }
    if (!exists) {
      this.curRoot = this.roots[0].path;
      this.curPath = '';
    }
    const src: string = SettingsService.source();
    this.source = src;
    this.folderLoading = true;
    if (reset) {
      const stats: FolderStat[] = await TrackStore.folderStats(src, this.curRoot);
      this.folderRows = LibraryView.buildTree(stats, this.curPath);
      this.folderTotal = await TrackStore.countUnder(src, this.curRoot, this.curPath);
      this.folderDirect = await TrackStore.countInFolder(src, this.curRoot, this.curPath);
      // 老索引没有 folder / root_path：整个根下匹配不到任何记录，
      // 但库里明明有歌 —— 这不是 bug，缺的是一次重扫。直说，并给一键入口。
      const all: number = await TrackStore.count(src);
      this.folderLegacy = this.curPath.length === 0 && this.folderRows.length === 0
        && this.folderTotal === 0 && all > 0;
    }
    const offset: number = reset ? 0 : this.folderTracks.length;
    const page: Track[] = await TrackStore.pageInFolder(src, this.curRoot, this.curPath,
      offset, Const.PAGE_SIZE, this.sort);
    this.folderTracks = reset ? page : this.folderTracks.concat(page);
    this.folderHasMore = this.folderTracks.length < this.folderDirect;
    this.folderLoading = false;
  }

  private loadFolderMore(): void {
    if (this.folderLoading || !this.folderHasMore) {
      return;
    }
    this.loadFolder(false);
  }

  /**
   * 把 (folder → count) 拍平成"当前这一层"的子目录列表。
   * 每个子目录的 total 是含所有子孙的曲目数 —— 用户点进去之前就想知道里面有多少首。
   */
  private static buildTree(stats: FolderStat[], cur: string): FolderNode[] {
    const prefix: string = cur.length > 0 ? `${cur}/` : '';
    const map: Map<string, FolderNode> = new Map<string, FolderNode>();
    for (const s of stats) {
      if (s.folder.length === 0 || s.folder === cur) {
        continue; // 本层直接放的曲目，由 pageInFolder 单独取
      }
      if (cur.length > 0 && !s.folder.startsWith(prefix)) {
        continue;
      }
      const rest: string = cur.length > 0 ? s.folder.substring(prefix.length) : s.folder;
      if (rest.length === 0) {
        continue;
      }
      const cut: number = rest.indexOf('/');
      const head: string = cut >= 0 ? rest.substring(0, cut) : rest;
      const path: string = `${prefix}${head}`;
      let node: FolderNode | undefined = map.get(path);
      if (node === undefined) {
        node = { path: path, name: head, total: 0, direct: 0, subCount: 0, size: 0 };
        map.set(path, node);
      }
      node.total += s.count;
      node.size += s.size;
      if (s.folder === path) {
        node.direct += s.count;
      }
    }
    const list: FolderNode[] = [];
    map.forEach((v: FolderNode) => {
      list.push(v);
    });
    // 直接子目录数：本层节点里，父路径等于自己的有几个
    for (const n of list) {
      let sub: number = 0;
      for (const m of list) {
        if (LibraryView.parentOf(m.path) === n.path) {
          sub++;
        }
      }
      n.subCount = sub;
    }
    list.sort((a: FolderNode, b: FolderNode) => a.name.localeCompare(b.name));
    return list;
  }

  private static parentOf(p: string): string {
    const i: number = p.lastIndexOf('/');
    return i >= 0 ? p.substring(0, i) : '';
  }

  private goPath(p: string): void {
    this.curPath = p;
    this.loadFolder(true);
  }

  private switchRoot(path: string): void {
    if (path === this.curRoot) {
      return;
    }
    this.curRoot = path;
    this.curPath = '';
    this.loadFolder(true);
  }

  private rootName(): string {
    for (const r of this.roots) {
      if (r.path === this.curRoot) {
        return r.name;
      }
    }
    return '音乐';
  }

  private crumbParts(): string[] {
    return this.curPath.length > 0 ? this.curPath.split('/') : [];
  }

  private crumbPath(i: number): string {
    return this.crumbParts().slice(0, i + 1).join('/');
  }

  private async playFolderAll(): Promise<void> {
    // 整棵子树，最多取 500：一次把几千首塞进队列会让续播恢复变慢
    const list: Track[] = await TrackStore.pageUnder(this.source, this.curRoot, this.curPath,
      0, 500, this.sort);
    if (list.length === 0) {
      return;
    }
    await this.core.playList(list, 0);
    router.pushUrl({ url: 'pages/PlayerPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  private async playFolderAt(i: number): Promise<void> {
    if (i < 0 || i >= this.folderTracks.length) {
      return;
    }
    await this.core.playList(this.folderTracks, i);
    router.pushUrl({ url: 'pages/PlayerPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  /** 老索引一键补齐：目录没变，重扫只补 folder 字段 */
  private async rescanForFolders(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.scanText = '正在补齐目录结构…';
    const r = await ImportFlow.rescanAll(this.ctx, (t: string) => {
      this.scanText = t;
    });
    this.scanning = false;
    this.scanText = '';
    promptAction.showToast({ message: r.message, duration: 2400 });
    this.loadFolder(true);
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
    this.reload(true);
    if (this.view === Const.VIEW_FOLDER) {
      this.loadFolder(true);
    }
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
    this.menuTrack = t;
    const fav: boolean = PlaylistStore.isFavorite(t.uri);
    this.menuItems = [
      { label: '播放这首', hint: Fmt.fmt(t.suffix), danger: false },
      { label: '下一首播放', hint: '', danger: false },
      { label: '加入播放队列', hint: '', danger: false },
      { label: fav ? '取消收藏' : '收藏', hint: fav ? '已在收藏' : '', danger: false },
      { label: '查看所属专辑', hint: t.album.length > 0 ? t.album : '未知专辑', danger: false },
      { label: '文件信息', hint: `${Fmt.bytes(t.size)}`, danger: false }
    ];
    this.menuOpen = true;
  }

  private onMenuPick(i: number): void {
    const t: Track = this.menuTrack;
    this.menuOpen = false;
    if (i === 0) {
      const list: Track[] = this.ds.all();
      this.core.playList(list, list.findIndex((x: Track) => x.uri === t.uri));
      router.pushUrl({ url: 'pages/PlayerPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
    } else if (i === 1) {
      this.core.playNext(t);
      promptAction.showToast({ message: '已排到下一首' });
    } else if (i === 2) {
      this.core.addToQueue(t);
      promptAction.showToast({ message: '已加入播放队列' });
    } else if (i === 3) {
      PlaylistStore.toggleFavorite(t).then((v: boolean) => {
        promptAction.showToast({ message: v ? '已收藏' : '已取消收藏' });
      });
    } else if (i === 4) {
      router.pushUrl({
        url: 'pages/ListPage',
        params: {
          kind: Const.LIST_ALBUM,
          key: t.album.length > 0 ? t.album : '未知专辑',
          title: t.album.length > 0 ? t.album : '未知专辑',
          sub: this.source
        }
      }).catch((e: Object) => Logger.warn(TAG, `${e}`));
    } else {
      promptAction.showToast({
        message: `${t.title} · ${Fmt.fmt(t.suffix)} ${Fmt.rate(t.sampleRate)} · ${Fmt.bytes(t.size)}`,
        duration: 3000
      });
    }
  }

  // ---------------- 顶部 ----------------

  @Builder
  Header() {
    Column() {
      Row() {
        Text('曲库')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.c().text)
          .letterSpacing(1.5)
        Text(this.total > 0 ? `${this.total} 首` : '')
          .fontSize(9)
          .fontColor(this.c().faint)
          .margin({ left: 8 })
        Blank()
        Text(this.scanning ? '整理中…' : '选择文件夹')
          .fontSize(9)
          .fontColor(this.c().accent)
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .border({ width: 0.5, color: this.c().line })
          .onClick(() => {
            if (!this.scanning) {
              this.pickFolder();
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 搜索：不画放大镜，靠占位文字说明能搜什么
      // 文件夹视图下收起：搜索按标签走，和"按目录找"是两条不同的路，混在一屏会互相误导
      if (this.view !== Const.VIEW_FOLDER) {
        Row({ space: 8 }) {
          TextInput({ text: this.kw, placeholder: '搜歌名、艺人、专辑' })
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .fontColor(this.c().text)
            .placeholderColor(this.c().faint)
            .placeholderFont({ size: 12 })
            .caretColor(this.c().accent)
            .backgroundColor(this.c().surfaceAlt)
            .borderRadius(0)
            .padding({ left: 10, right: 10 })
            .onChange((v: string) => {
              this.kw = v;
              this.scheduleSearch();
            })
          if (this.kw.length > 0) {
            Text('清空')
              .fontSize(9)
              .fontColor(this.c().dim)
              .padding({ left: 6, right: 2, top: 8, bottom: 8 })
              .onClick(() => {
                this.kw = '';
                this.reload(true);
              })
          }
        }
        .width('100%')
        .margin({ top: 12 })
      }

      // 排序：文字页签 + 一条下划线，不用胶囊按钮
      Row() {
        Scroll() {
          Row({ space: 18 }) {
            ForEach(this.sortLabels(), (label: string, i: number) => {
              // 下划线用 Text 自己的底边框，不用 width('100%') 的 Row：
              // 后者在自动宽度容器里会按父容器的 100% 撑开，把其余页签挤出屏幕。
              Text(label)
                .fontSize(11)
                .fontColor(this.sortKeys()[i] === this.sort ? this.c().text : this.c().faint)
                .padding({ bottom: 6 })
                .border({
                  width: { bottom: 1 },
                  color: { bottom: this.sortKeys()[i] === this.sort ? this.c().accent : Color.Transparent }
                })
                .onClick(() => {
                  this.sort = this.sortKeys()[i];
                  SettingsService.setSort(this.sort);
                  this.reload(true);
                })
            }, (label: string, i: number) => `sort_${i}_${label}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)

        // 三种看法的切换：文字页签，不用图标也不用胶囊
        Row({ space: 12 }) {
          ForEach(this.viewLabels(), (label: string, i: number) => {
            Text(label)
              .fontSize(9)
              .fontColor(this.viewKeys()[i] === this.view ? this.c().accent : this.c().faint)
              .onClick(() => {
                this.setView(this.viewKeys()[i]);
              })
          }, (label: string, i: number) => `vt_${i}`)
        }
        .margin({ left: 14 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 14 })
      // 卡片矩阵：只有封面视图才谈密度
      if (this.view === Const.VIEW_GRID) {
        Row({ space: 14 }) {
          Text('密度')
            .fontSize(9)
            .fontColor(this.c().faint)
            .letterSpacing(0.5)
          ForEach(this.densityLabels(), (label: string, i: number) => {
            Text(label)
              .fontSize(9)
              .fontColor(this.densityKeys()[i] === this.density ? this.c().accent : this.c().faint)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .border({ width: 0.5, color: this.densityKeys()[i] === this.density ? this.c().accentDeep : Color.Transparent })
              .onClick(() => {
                this.pickDensity(this.densityKeys()[i]);
              })
          }, (label: string) => `den_${label}_${this.density}`)
          if (!this.proOwned) {
            Text('大卡 · 密集为 Pro')
              .fontSize(8)
              .fontColor(this.c().faint)
              .margin({ left: 4 })
          }
        }
        .width('100%')
        .margin({ top: 8 })
      }
      // 格式筛选
      if (this.fmts.length > 1 && this.view !== Const.VIEW_FOLDER) {
        Scroll() {
          Row({ space: 14 }) {
            Text('全部')
              .fontSize(9)
              .fontColor(this.fmt === '' ? this.c().accent : this.c().faint)
              .onClick(() => {
                this.fmt = '';
                this.reload(true);
              })
            ForEach(this.fmts, (f: string) => {
              Text(Fmt.fmt(f))
                .fontSize(9)
                .fontColor(this.fmt === f ? this.c().accent : this.c().faint)
                .onClick(() => {
                  this.fmt = this.fmt === f ? '' : f;
                  this.reload(true);
                })
            }, (f: string) => `fmt_${f}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: 8 })
      }

      if (this.scanning) {
        Text(this.scanText)
          .fontSize(9)
          .fontColor(this.c().accent)
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 12 })
  }

  /**
   * 卡片矩阵：三档密度 × 断点列数。
   * 标准档保持历史行为不变（免费版的既得体验不能动），
   * 大卡与密集是 Pro —— 大卡给"墙"的观感，密集给曲库大的人。
   */
  private gridTemplate(): string {
    if (this.density === Const.GRID_BIG) {
      if (this.bp === Const.BP_LG) {
        return '1fr 1fr 1fr';
      }
      if (this.bp === Const.BP_MD) {
        return '1fr 1fr';
      }
      return '1fr';
    }
    if (this.density === Const.GRID_DENSE) {
      if (this.bp === Const.BP_LG) {
        return '1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr';
      }
      if (this.bp === Const.BP_MD) {
        return '1fr 1fr 1fr 1fr 1fr 1fr';
      }
      return '1fr 1fr 1fr';
    }
    if (this.bp === Const.BP_LG) {
      return '1fr 1fr 1fr 1fr 1fr';
    }
    if (this.bp === Const.BP_MD) {
      return '1fr 1fr 1fr 1fr';
    }
    return '1fr 1fr';
  }

  /** 密度行只在封面视图出现：其他两种视图没有"密度"可言 */
  private densityLabels(): string[] {
    return ['大卡', '标准', '密集'];
  }

  private densityKeys(): string[] {
    return [Const.GRID_BIG, Const.GRID_STD, Const.GRID_DENSE];
  }

  private needGate(key: string): boolean {
    return key !== Const.GRID_STD && !this.proOwned;
  }

  /** 大卡 / 密集的门槛：已购直接切；没购先问（试用 / 解锁），不在背后偷偷扣次数 */
  private pickDensity(key: string): void {
    if (!this.needGate(key)) {
      this.applyDensity(key);
      return;
    }
    if (ProService.trialLeft('cardmatrix') <= 0) {
      promptAction.showToast({ message: '封面密度的试用次数用完了' });
      router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
      return;
    }
    this.gatePending = key;
    this.gateItems = [
      { label: `试用一次（还剩 ${ProService.trialLeft('cardmatrix')} 次）`, hint: '', danger: false },
      { label: '去解锁密纹 Pro', hint: `¥${Const.PRO_PRICE_EARLY}`, danger: false }
    ];
    this.gateOpen = true;
  }

  private applyDensity(key: string): void {
    this.density = key;
    SettingsService.setGridDensity(key);
  }

  private onGatePick(i: number): void {
    const key: string = this.gatePending;
    this.gateOpen = false;
    if (key.length === 0) {
      return;
    }
    if (i === 0) {
      if (!ProService.consumeTrial('cardmatrix')) {
        promptAction.showToast({ message: '试用次数用完了' });
        return;
      }
      const left: number = ProService.trialLeft('cardmatrix');
      this.applyDensity(key);
      promptAction.showToast({
        message: left > 0 ? `已用一次试用，剩 ${left} 次` : '这是最后一次试用',
        duration: 2000
      });
      return;
    }
    router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
  }

  private sortKeys(): string[] {
    return [Const.SORT_RECENT, Const.SORT_TITLE, Const.SORT_ARTIST, Const.SORT_RATE];
  }

  private sortLabels(): string[] {
    return ['最近添加', '标题', '艺人', '采样率'];
  }

  private viewKeys(): string[] {
    return [Const.VIEW_LIST, Const.VIEW_GRID, Const.VIEW_FOLDER];
  }

  private viewLabels(): string[] {
    return ['列表', '封面', '文件夹'];
  }

  private setView(v: string): void {
    if (this.view === v) {
      return;
    }
    this.view = v;
    SettingsService.setView(v);
    if (v === Const.VIEW_FOLDER) {
      this.loadFolder(true);
    }
  }

  // ---------------- 文件夹视图 ----------------

  /**
   * 一个目录行。
   *
   * 不用 ▸ 之类的三角符号：U+25B6/25B8 这类字符在部分鸿蒙字体里会落到 emoji 字体，
   * 渲染成彩色图标（之前播放键就是这么变成蓝色的）。层级改用一条短竖线表达。
   */
  @Builder
  FolderRow(i: number) {
    Row({ space: 10 }) {
      Column()
        .width(2)
        .height(26)
        .backgroundColor(this.c().accent)
        .opacity(0.55)
      Column() {
        Text(this.folderRows[i].name)
          .fontSize(13)
          .fontColor(this.c().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.folderRows[i].subCount > 0
          ? `${this.folderRows[i].total} 首 · ${this.folderRows[i].subCount} 个子目录`
          : `${this.folderRows[i].total} 首`)
          .fontSize(9)
          .fontColor(this.c().faint)
          .maxLines(1)
          .width('100%')
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.goPath(this.folderRows[i].path);
    })
  }

  @Builder
  FolderPane() {
    Column() {
      // 多个根才需要根切换；只有一个根时这一排是纯噪音
      if (this.roots.length > 1) {
        Scroll() {
          Row({ space: 16 }) {
            ForEach(this.roots, (r: RootDir) => {
              Text(r.name)
                .fontSize(10)
                .fontColor(r.path === this.curRoot ? this.c().text : this.c().faint)
                .padding({ bottom: 5 })
                .border({
                  width: { bottom: 1 },
                  color: { bottom: r.path === this.curRoot ? this.c().accent : Color.Transparent }
                })
                .onClick(() => this.switchRoot(r.path))
            }, (r: RootDir) => `rt_${r.path}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: 10 })
      }

      // 面包屑 + 整棵子树播放
      Row({ space: 8 }) {
        Scroll() {
          Row({ space: 6 }) {
            Text(this.rootName())
              .fontSize(10)
              .fontColor(this.curPath.length === 0 ? this.c().text : this.c().dim)
              .maxLines(1)
              .onClick(() => this.goPath(''))
            ForEach(this.crumbParts(), (p: string, i: number) => {
              Row({ space: 6 }) {
                Text('›')
                  .fontSize(10)
                  .fontColor(this.c().faint)
                Text(p)
                  .fontSize(10)
                  .fontColor(i === this.crumbParts().length - 1 ? this.c().text : this.c().dim)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => this.goPath(this.crumbPath(i)))
              }
            }, (p: string, i: number) => `cb_${i}_${p}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)

        if (this.folderTotal > 0) {
          Text(`播放全部 ${this.folderTotal}`)
            .fontSize(9)
            .fontColor(this.c().onAccent)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(this.c().accent)
            .onClick(() => this.playFolderAll())
        }
      }
      .width('100%')
      .margin({ top: 12 })

      if (this.folderLegacy) {
        Column() {
          Text('这个目录的索引是旧版本建的')
            .fontSize(11)
            .fontColor(this.c().text)
            .width('100%')
          Text('重扫一次就能按文件夹浏览。文件、标签、歌单都不会变，只是把目录结构补进索引。')
            .fontSize(9)
            .fontColor(this.c().faint)
            .lineHeight(16)
            .width('100%')
            .margin({ top: 6 })
          Text('补齐目录结构')
            .fontSize(10)
            .fontColor(this.c().onAccent)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .backgroundColor(this.c().accent)
            .margin({ top: 10 })
            .onClick(() => this.rescanForFolders())
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ top: 14, bottom: 14 })
      }

      List() {
        ForEach(this.folderRows, (n: FolderNode, i: number) => {
          ListItem() {
            this.FolderRow(i)
          }
          // key 带上 total：重扫后目录路径不变、曲目数变了，
          // 只用 path 当 key 会让这一行沿用旧数字
        }, (n: FolderNode) => `fd_${n.path}_${n.total}`)

        if (this.folderTracks.length > 0) {
          ListItem() {
            Row() {
              Text('本层曲目')
                .fontSize(8)
                .fontColor(this.c().faint)
                .letterSpacing(1.2)
              Blank()
              Text(`${this.folderDirect} 首`)
                .fontSize(8)
                .fontColor(this.c().faint)
            }
            .width('100%')
            .padding({ top: 14, bottom: 8 })
          }
        }

        ForEach(this.folderTracks, (t: Track, i: number) => {
          ListItem() {
            TrackRow({
              track: t,
              active: this.curUri === t.uri,
              playing: this.nowPlaying,
              showCover: true,
              showIndex: false,
              index: i,
              last: i === this.folderTracks.length - 1,
              onTap: () => {
                this.playFolderAt(i);
              },
              onLong: () => {
                this.openMenu(t);
              }
            })
          }
        }, (t: Track) => `ft_${t.uri}`)

        ListItem() {
          Row() {
            Text(this.folderLoading ? '正在读取…' : (this.folderHasMore ? '上滑加载更多' : ' '))
              .fontSize(9)
              .fontColor(this.c().faint)
          }
          .width('100%')
          .height(56)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .cachedCount(6)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ bottom: 64 })
      .onReachEnd(() => {
        this.loadFolderMore();
      })
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ---------------- 列表 ----------------

  @Builder
  RowOfList(t: Track, i: number) {
    TrackRow({
      track: t,
      active: this.curUri === t.uri,
      playing: this.nowPlaying,
      showCover: true,
      showIndex: false,
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

  @Builder
  GridCell(t: Track, i: number) {
    Column() {
      CoverArt({
        coverPath: t.coverPath,
        seed: t.album.length > 0 ? t.album : t.title,
        title: t.album.length > 0 ? t.album : t.title,
        subtitle: t.artist,
        dim: false
      })
        .width('100%')
      Text(t.title)
        .fontSize(11)
        .fontColor(this.c().text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 7 })
      Text(Fmt.rate(t.sampleRate).length > 0 ? `${Fmt.fmt(t.suffix)} · ${Fmt.rate(t.sampleRate)}` : Fmt.fmt(t.suffix))
        .fontSize(8)
        .fontColor(this.c().faint)
        .maxLines(1)
        .margin({ top: 2 })
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.playAt(i);
    })
    .gesture(LongPressGesture({ repeat: false }).onAction(() => {
      this.openMenu(t);
    }))
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.Header()

        if (this.total === 0) {
          Column() {
            EmptyState({
              title: '曲库还是空的',
              hint: '鸿蒙不允许应用自己翻你的硬盘，\n选一个音乐文件夹，剩下的交给密纹。',
              actionLabel: '选择音乐文件夹',
              secondaryLabel: '载入示例曲库',
              onAction: () => {
                this.pickFolder();
              },
              onSecondary: () => {
                LibraryService.loadDemo().then((n: number) => {
                  promptAction.showToast({ message: `已载入 ${n} 首示例` });
                  this.reload(true);
                });
              }
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.view === Const.VIEW_FOLDER) {
          // 放在筛选空态之前：文件夹模式不看 kw / fmt，
          // 否则残留的格式筛选会让整棵目录树"消失"
          this.FolderPane()
        } else if (this.matched === 0) {
          Column() {
            EmptyState({
              title: this.kw.length > 0 ? `没有找到「${this.kw}」` : '这个格式下没有曲目',
              hint: '密纹只搜本机已入库的曲目，\n不会去猜、也不会联网找同名歌。',
              actionLabel: this.kw.length > 0 ? '清空搜索' : '看全部',
              onAction: () => {
                this.kw = '';
                this.fmt = '';
                this.reload(true);
              }
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.view === Const.VIEW_GRID) {
          Grid() {
            LazyForEach(this.ds, (t: Track, i: number) => {
              GridItem() {
                this.GridCell(t, i)
              }
            }, (t: Track) => `${t.uri}_g`)
          }
          .columnsTemplate(this.gridTemplate())
          .columnsGap(14)
          .rowsGap(18)
          .cachedCount(4)
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ bottom: 72 })
          .onReachEnd(() => {
            this.loadMore();
          })
        } else {
          List() {
            LazyForEach(this.ds, (t: Track, i: number) => {
              ListItem() {
                this.RowOfList(t, i)
              }
            }, (t: Track) => `${t.uri}_r`)

            ListItem() {
              Row() {
                Text(this.loading ? '正在读取…' : (this.hasMore ? '上滑加载更多' : `共 ${this.matched} 首，已全部显示`))
                  .fontSize(9)
                  .fontColor(this.c().faint)
                  .letterSpacing(0.5)
              }
              .width('100%')
              .height(56)
              .justifyContent(FlexAlign.Center)
            }
          }
          .width('100%')
          .layoutWeight(1)
          .cachedCount(4)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .padding({ bottom: 64 })
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: this.bp === Const.BP_SM ? 20 : 32, right: this.bp === Const.BP_SM ? 20 : 32 })

      if (this.gateOpen) {
        ActionPanel({
          title: '封面密度',
          subtitle: '大卡与密集是密纹 Pro 功能',
          items: this.gateItems,
          onPick: (i: number) => {
            this.onGatePick(i);
          },
          onClose: () => {
            this.gateOpen = false;
          }
        })
      }
      if (this.menuOpen) {
        ActionPanel({
          title: this.menuTrack.title,
          subtitle: Fmt.meta(this.menuTrack.artist, this.menuTrack.album),
          items: this.menuItems,
          onPick: (i: number) => {
            this.onMenuPick(i);
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
