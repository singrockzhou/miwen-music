import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { RootDir } from '../model/RootDir';
import { TrackStore } from '../db/TrackStore';
import { LibraryService } from '../service/LibraryService';
import { RootService } from '../service/RootService';
import { ImportFlow } from '../service/ImportFlow';
import { ActionPanel, ActionItem } from '../components/ActionPanel';

const TAG: string = 'RootsPage';

/** 一行根目录的呈现数据 */
interface RootRow {
  root: RootDir;
  /** 这个目录现在还能不能读 */
  alive: boolean;
  /** 库内属于它的曲目数 */
  count: number;
  /** 库内属于它的文件夹数 */
  folders: number;
}

/**
 * 音乐文件夹管理。
 *
 * 这个页面存在的理由：鸿蒙不允许应用全盘扫描，目录授权是唯一入口，
 * 而它恰好又是最容易被用户判定为"这 App 坏了"的地方 ——
 * 重装后授权静默失效、U 盘拔了路径还在、某个目录被改名……
 * 所以这里不藏任何东西：每个目录是否可读、有多少首、怎么救，全写在同一屏。
 *
 * 设计上刻意不做"一键扫描全盘"的假动作 —— 鸿蒙给不了那个能力，
 * 承诺了做不到，比一开始就说清楚更难收场。
 */
@Entry
@Component
struct RootsPage {
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('bp') bp: string = Const.BP_SM;
  // 沉浸式全屏下状态栏会盖住返回栏，必须自己让出安全区
  @StorageProp('topInset') topInset: number = 0;
  @StorageLink('libVersion') @Watch('onLibChanged') libVersion: number = 0;

  @State rows: RootRow[] = [];
  @State loading: boolean = true;
  @State scanning: boolean = false;
  @State scanText: string = '';
  @State panelOpen: boolean = false;
  @State panelMode: string = 'root';
  @State panelItems: ActionItem[] = [];
  @State panelRow: RootRow | null = null;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.load();
  }

  onLibChanged(): void {
    this.load();
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  // ---------------- 数据 ----------------

  private async load(): Promise<void> {
    const roots: RootDir[] = RootService.list();
    const next: RootRow[] = [];
    for (const r of roots) {
      const alive: boolean = await LibraryService.probe(r);
      const count: number = await TrackStore.countInRoot(Const.SRC_LOCAL, r.path);
      const folders: number = await TrackStore.folderCount(Const.SRC_LOCAL, r.path);
      next.push({ root: r, alive: alive, count: count, folders: folders });
    }
    this.rows = next;
    this.loading = false;
    Logger.info(TAG, `loaded ${roots.length} roots`);
  }

  /** 全部曲目数：跨根求和，用当前来源的总数更省一次查询 */
  private totalTracks(): number {
    let n: number = 0;
    for (const r of this.rows) {
      n += r.count;
    }
    return n;
  }

  // ---------------- 动作 ----------------

  private async addFolder(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.scanText = '正在打开文件选择器…';
    const r = await ImportFlow.pickAndAdd(this.ctx, (t: string) => {
      this.scanText = t;
    });
    this.scanning = false;
    this.scanText = '';
    if (r.message !== '没有选择文件夹') {
      promptAction.showToast({ message: r.message, duration: 2400 });
    }
    await this.load();
  }

  private async rescanAll(): Promise<void> {
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
    promptAction.showToast({ message: r.message, duration: 2600 });
    await this.load();
  }

  private async rescanOne(row: RootRow): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.scanText = `正在扫描「${row.root.name}」…`;
    const r = await ImportFlow.scanOne(this.ctx, row.root, (t: string) => {
      this.scanText = t;
    });
    this.scanning = false;
    this.scanText = '';
    promptAction.showToast({ message: r.message, duration: 2400 });
    await this.load();
  }

  /**
   * 重新授权：走一次目录选择，把新 uri 配回旧 path。
   *
   * 这是重装/换机后最有用的一步 —— 数据库里几千首索引都还完整，
   * 只差一个可用的授权。重新授权完直接就能播，不需要重扫。
   */
  private async reauthorize(row: RootRow): Promise<void> {
    let uri: string = '';
    try {
      uri = await LibraryService.pickDirectory(this.ctx);
    } catch (e) {
      Logger.error(TAG, `pick failed ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '打开文件选择器失败，请重试' });
      return;
    }
    if (uri.length === 0) {
      return;
    }
    const picked: string = LibraryService.toPath(uri);
    const st: string = RootService.add(uri);
    if (st === RootService.NESTED) {
      promptAction.showToast({
        message: `「${RootService.baseName(picked)}」已经包含在某个已授权的目录里，不必单独授权`,
        duration: 3200
      });
    } else if (st === RootService.INVALID) {
      promptAction.showToast({ message: '这个目录读不到，换一个试试' });
    } else if (picked === row.root.path) {
      promptAction.showToast({ message: '授权已恢复', duration: 2000 });
    } else {
      // 选错目录必须当场说清楚，否则用户会以为"重新授权成功了但歌还是打不开"
      promptAction.showToast({
        message: `选的是「${RootService.baseName(picked)}」，不是「${row.root.name}」；已作为新目录加入`,
        duration: 3200
      });
    }
    await this.load();
  }

  private openMenu(row: RootRow): void {
    this.panelRow = row;
    this.panelMode = 'root';
    this.panelItems = [
      { label: '重新扫描这个目录', hint: `${row.count} 首`, danger: false },
      {
        label: row.alive ? '重新授权' : '重新授权（当前打不开）',
        hint: row.alive ? '' : '重装后需要',
        danger: false
      },
      { label: '从曲库移除', hint: '不删磁盘文件', danger: true }
    ];
    this.panelOpen = true;
  }

  private onPick(i: number): void {
    const row: RootRow | null = this.panelRow;
    if (this.panelMode === 'remove') {
      this.panelOpen = false;
      if (i === 0 && row !== null) {
        LibraryService.removeRoot(row.root).then(() => {
          promptAction.showToast({ message: `已移除「${row.root.name}」的索引` });
          this.load();
        });
      }
      return;
    }
    this.panelOpen = false;
    if (row === null) {
      return;
    }
    if (i === 0) {
      this.rescanOne(row);
    } else if (i === 1) {
      this.reauthorize(row);
    } else if (i === 2) {
      this.panelMode = 'remove';
      this.panelItems = [
        { label: `移除「${row.root.name}」`, hint: `清掉 ${row.count} 首索引`, danger: true },
        { label: '取消', hint: '', danger: false }
      ];
      this.panelOpen = true;
    }
  }

  // ---------------- 组件 ----------------

  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor(this.c().dim)
        .width(40)
        .onClick(() => router.back())
      Blank()
      Text('FOLDERS')
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
          Text('音乐文件夹')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.c().text)
            .letterSpacing(0.5)
            .width('100%')

          Text(this.rows.length > 0
            ? `${this.rows.length} 个目录 · ${this.totalTracks()} 首`
            : '还没有授权目录')
            .fontSize(9)
            .fontColor(this.c().dim)
            .width('100%')
            .margin({ top: 8 })

          Text('鸿蒙不允许应用自己翻你的硬盘，只能由你指定目录。\n可以加多个：无损放一处、播客放一处，各扫各的，互不影响。')
            .fontSize(9)
            .fontColor(this.c().faint)
            .lineHeight(17)
            .width('100%')
            .margin({ top: 12 })

          Row() {
            Text(this.scanning ? this.scanText : '添加文件夹')
              .fontSize(10)
              .fontColor(this.c().onAccent)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(this.c().accent)
              .onClick(() => {
                if (!this.scanning) {
                  this.addFolder();
                }
              })
            if (this.rows.length > 0) {
              Text('全部重新扫描')
                .fontSize(10)
                .fontColor(this.scanning ? this.c().faint : this.c().dim)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .border({ width: 0.5, color: this.c().line })
                .margin({ left: 8 })
                .onClick(() => {
                  if (!this.scanning) {
                    this.rescanAll();
                  }
                })
            }
          }
          .width('100%')
          .margin({ top: 16 })

          if (this.scanning) {
            Text(this.scanText)
              .fontSize(9)
              .fontColor(this.c().accent)
              .width('100%')
              .margin({ top: 10 })
          }

          // ---- 列表 ----
          List() {
            ForEach(this.rows, (row: RootRow, i: number) => {
              ListItem() {
                Column() {
                  RootCardView({
                    name: row.root.name,
                    path: row.root.path,
                    alive: row.alive,
                    count: row.count,
                    folders: row.folders,
                    onTap: () => {
                      this.openMenu(row);
                    }
                  })
                  if (i < this.rows.length - 1) {
                    Divider()
                      .color(this.c().line)
                      .strokeWidth(0.5)
                  }
                }
                .width('100%')
              }
              // key 必须带上 alive / count：重新授权后 path 不变，
              // 只用 path 当 key 的话 ForEach 会认为"这一项没变"，
              // 复用旧子组件，@Prop 永远不会更新（真机上表现为状态标签一直停在"需重新授权"）
            }, (row: RootRow) => `root_${row.root.path}_${row.alive}_${row.count}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .margin({ top: 6 })

          if (!this.loading && this.rows.length === 0) {
            Text('点上面的「添加文件夹」，选一个放音乐的目录。\n官方推荐：整张专辑的父目录，一次扫完最省事。')
              .fontSize(9)
              .fontColor(this.c().faint)
              .lineHeight(17)
              .width('100%')
              .margin({ top: 6 })
          }

          Text('移除只清密纹的索引，磁盘上的音频文件一首都不会动。')
            .fontSize(8)
            .fontColor(this.c().faint)
            .width('100%')
            .padding({ top: 12, bottom: 80 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: 720 })
      .alignSelf(ItemAlign.Center)
      .padding({
        left: this.bp === Const.BP_SM ? 20 : 32,
        right: this.bp === Const.BP_SM ? 20 : 32,
        top: this.topInset + 4
      })

      if (this.panelOpen) {
        ActionPanel({
          title: this.panelMode === 'remove' ? '确认移除' : (this.panelRow !== null ? this.panelRow.root.name : ''),
          subtitle: this.panelRow !== null ? this.panelRow.root.path : '',
          items: this.panelItems,
          onPick: (i: number) => {
            this.onPick(i);
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

/**
 * 一个根目录卡片。
 *
 * 做成 @Component 而不是 @Builder：@Builder 的入参是按值传的，
 * 父组件重渲染时那份值不会重新灌进去 —— 重新授权后"需重新授权"的标签
 * 就一直挂着不走。@Prop 才会跟着父组件的状态同步。
 */
@Component
struct RootCardView {
  @Prop name: string = '';
  @Prop path: string = '';
  @Prop alive: boolean = true;
  @Prop count: number = 0;
  @Prop folders: number = 0;
  @StorageProp('themeKey') themeKey: string = 'dark';
  onTap: () => void = () => {
  };

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  build() {
    Column() {
      Row() {
        Text(this.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.c().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.alive ? '可读' : '需重新授权')
          .fontSize(8)
          .fontColor(this.alive ? this.c().faint : this.c().accent)
          .letterSpacing(0.8)
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .border({ width: 0.5, color: this.alive ? this.c().line : this.c().accent })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.path)
        .fontSize(8)
        .fontColor(this.c().faint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 5 })

      Row({ space: 10 }) {
        Text(this.count > 0 ? `${this.count} 首` : '未收录')
          .fontSize(9)
          .fontColor(this.c().dim)
        if (this.folders > 0) {
          Text(`· ${this.folders} 个文件夹`)
            .fontSize(9)
            .fontColor(this.c().faint)
        }
        Blank()
        Text('管理')
          .fontSize(9)
          .fontColor(this.c().accent)
      }
      .width('100%')
      .margin({ top: 7 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    // 一个 padding 一次给全：ArkUI 的 padding 是覆盖语义，
    // 连写两次只有最后一次生效（真机上表现为上下留白突然没了）
    .padding({ top: 12, bottom: 12, left: this.alive ? 0 : 10, right: 0 })
    .border({
      width: { left: this.alive ? 0 : 2 },
      color: { left: this.c().accent }
    })
    .onClick(() => this.onTap())
  }
}
