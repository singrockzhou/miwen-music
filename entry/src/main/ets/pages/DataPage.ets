import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { Playlist } from '../model/Playlist';
import { Track } from '../model/Track';
import { PlaylistStore } from '../db/PlaylistStore';
import { ProService } from '../service/ProService';
import { ImportOutcome, MigrateService, RestoreOutcome, SaveOutcome } from '../service/MigrateService';
import { ActionPanel, ActionItem } from '../components/ActionPanel';
import { SettingRow } from '../components/SettingRow';

const TAG: string = 'DataPage';

/**
 * 数据与迁移。
 *
 * 这一页只干四件事：导入歌单、导出歌单、备份、恢复。做成独立页面而不是塞进设置里，
 * 是因为这四件事都有"选文件 → 等进度 → 看结果"的完整流程，
 * 混在一长串开关里会让人以为点一下就已经完成了。
 */
@Entry
@Component
struct DataPage {
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('proOwned') proOwned: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bp') bp: string = Const.BP_SM;

  @State busy: boolean = false;
  @State step: string = '';
  @State lastResult: string = '';
  @State panelOpen: boolean = false;
  @State panelItems: ActionItem[] = [];
  /** trial = 试用/解锁；export = 选歌单 */
  @State panelMode: string = 'trial';
  @State pendingKey: string = '';
  @State exportIds: number[] = [];
  @State exportNames: string[] = [];
  @State exportCounts: number[] = [];

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  // ---------------- 门禁 ----------------

  /**
   * 未解锁时给 3 次试用，用完才拦。
   * 直接弹购买页最省事，但用户连"备份出来是什么样"都没见过就被要求掏钱，
   * 转化只会更差 —— 让他先看见文件真的躺在自己盘上。
   */
  private gate(key: string): void {
    if (this.proOwned) {
      this.runAction(key);
      return;
    }
    const left: number = ProService.trialLeft(key);
    if (left <= 0) {
      promptAction.showToast({ message: '试用次数用完了，解锁后不再限制' });
      router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
      return;
    }
    this.pendingKey = key;
    this.panelMode = 'trial';
    this.panelItems = [
      { label: `试用一次（还剩 ${left} 次）`, hint: '', danger: false },
      { label: '去解锁密纹 Pro', hint: `¥${Const.PRO_PRICE_EARLY}`, danger: false }
    ];
    this.panelOpen = true;
  }

  private runAction(key: string): void {
    if (this.busy) {
      return;
    }
    if (key === 'import') {
      this.doImport();
    } else if (key === 'export') {
      this.openExport();
    } else if (key === 'backup') {
      this.doBackup();
    } else {
      this.doRestore();
    }
  }

  // ---------------- 动作 ----------------

  private async doImport(): Promise<void> {
    this.busy = true;
    this.lastResult = '';
    let r: ImportOutcome = { ok: false, matched: 0, total: 0, playlist: '', message: '导入失败' };
    try {
      r = await MigrateService.importPlaylist(this.ctx, (t: string) => {
        this.step = t;
      });
    } catch (e) {
      Logger.error(TAG, `import failed ${JSON.stringify(e)}`);
      r.message = `导入失败：${e}`;
    } finally {
      this.busy = false;
      this.step = '';
    }
    this.lastResult = r.message;
    promptAction.showToast({ message: r.message, duration: 3200 });
    Logger.info(TAG, `import ok=${r.ok} ${r.matched}/${r.total}`);
  }

  private async openExport(): Promise<void> {
    const list: Playlist[] = await PlaylistStore.playlists();
    const ids: number[] = [];
    const names: string[] = [];
    const counts: number[] = [];
    const items: ActionItem[] = [];
    for (const p of list) {
      ids.push(p.id);
      names.push(p.name);
      counts.push(p.count);
      items.push({ label: p.name, hint: `${p.count} 首`, danger: false });
    }
    // 收藏与最近也是"歌单"，一起给出口：很多人真正想带走的就是这两个
    const fav: number = PlaylistStore.favoriteCount();
    if (fav > 0) {
      ids.push(-1);
      names.push('收藏');
      counts.push(fav);
      items.push({ label: '收藏', hint: `${fav} 首`, danger: false });
    }
    if (items.length === 0) {
      promptAction.showToast({ message: '还没有歌单可以导出' });
      return;
    }
    this.exportIds = ids;
    this.exportNames = names;
    this.exportCounts = counts;
    this.panelMode = 'export';
    this.panelItems = items;
    this.panelOpen = true;
  }

  private async doExport(index: number): Promise<void> {
    const id: number = this.exportIds[index];
    const name: string = this.exportNames[index];
    this.busy = true;
    this.lastResult = '';
    try {
      let uris: string[] = [];
      if (id < 0) {
        uris = await PlaylistStore.favoriteUris();
      } else {
        const tracks: Track[] = await PlaylistStore.playlistTracks(id);
        uris = tracks.map((t: Track) => t.uri);
      }
      const r: SaveOutcome = await MigrateService.exportM3u(this.ctx, name, uris);
      this.lastResult = r.message;
      promptAction.showToast({ message: r.message, duration: 3200 });
    } catch (e) {
      // 未捕获的 async 异常会静默停在"正在处理"，用户只觉得点了没反应 —— 必须兜住
      Logger.error(TAG, `export failed ${JSON.stringify(e)}`);
      this.lastResult = `导出失败：${e}`;
      promptAction.showToast({ message: '导出失败，请重试', duration: 2800 });
    } finally {
      this.busy = false;
    }
  }

  private async doBackup(): Promise<void> {
    this.busy = true;
    this.lastResult = '';
    let r: SaveOutcome = { ok: false, message: '备份失败' };
    try {
      r = await MigrateService.backup(this.ctx, (t: string) => {
        this.step = t;
      });
    } catch (e) {
      Logger.error(TAG, `backup failed ${JSON.stringify(e)}`);
      r.message = `备份失败：${e}`;
    } finally {
      this.busy = false;
      this.step = '';
    }
    this.lastResult = r.message;
    promptAction.showToast({ message: r.message, duration: 3400 });
  }

  private async doRestore(): Promise<void> {
    this.busy = true;
    this.lastResult = '';
    let r: RestoreOutcome = { ok: false, tracks: 0, favorites: 0, playlists: 0, message: '恢复失败' };
    try {
      r = await MigrateService.restore(this.ctx, (t: string) => {
        this.step = t;
      });
    } catch (e) {
      Logger.error(TAG, `restore failed ${JSON.stringify(e)}`);
      r.message = `恢复失败：${e}`;
    } finally {
      this.busy = false;
      this.step = '';
    }
    this.lastResult = r.message;
    promptAction.showToast({ message: r.message, duration: 3400 });
  }

  private onPanelPick(i: number): void {
    this.panelOpen = false;
    if (this.panelMode === 'export') {
      this.doExport(i);
      return;
    }
    if (this.panelMode === 'trial') {
      if (i === 0) {
        if (!ProService.consumeTrial(this.pendingKey)) {
          promptAction.showToast({ message: '试用次数用完了' });
          return;
        }
        this.runAction(this.pendingKey);
      } else {
        router.pushUrl({ url: 'pages/ProPage' }).catch((e: Object) => Logger.warn(TAG, `${e}`));
      }
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
      Text('DATA')
        .fontSize(8)
        .fontColor(this.c().faint)
        .letterSpacing(1.8)
      Blank()
      Text('')
        .width(40)
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }

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

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.TopBar()

        Scroll() {
          Column() {
            Text('数据与迁移')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.c().text)
              .letterSpacing(1)
              .width('100%')
              .margin({ top: 6 })

            Text('歌单跟着文件走，索引和收藏留在本地。全程不联网、不上传，只在你和这块磁盘之间搬。')
              .fontSize(10)
              .fontColor(this.c().dim)
              .lineHeight(17)
              .width('100%')
              .margin({ top: 8 })

            // ---- 歌单文件 ----
            this.SectionTitle('歌单文件', 'PLAYLIST FILES')
            this.Divider()
            SettingRow({
              label: '导入歌单文件',
              value: 'M3U · M3U8 · PLS',
              detail: '先按完整路径匹配，再按文件名兜底。匹配不上的会如实告诉你有几首',
              onTap: () => this.gate('import')
            })
            this.Divider()
            SettingRow({
              label: '导出歌单',
              value: this.proOwned ? '' : 'PRO',
              detail: '存成标准 .m3u，别的播放器也认；路径用绝对路径，换机后照样能对上',
              onTap: () => this.gate('export')
            })

            // ---- 备份 ----
            this.SectionTitle('备份', 'BACKUP')
            this.Divider()
            SettingRow({
              label: '备份到文件',
              value: this.proOwned ? '' : 'PRO',
              detail: '单个 zip：曲库索引 + 歌单 + 收藏 + 设置。不含音频——音频本来就在你的盘上',
              onTap: () => this.gate('backup')
            })
            this.Divider()
            SettingRow({
              label: '从备份恢复',
              value: '',
              detail: '合并策略：同名的歌单追加曲目，已有的收藏不覆盖。恢复不会删掉你现在的东西',
              onTap: () => this.gate('restore')
            })

            // ---- 曲库维护 ----
            this.SectionTitle('曲库维护', 'LIBRARY CARE')
            this.Divider()
            SettingRow({
              label: '重复曲目 · 失效路径 · 批量改标签',
              value: '',
              detail: '重复检测与清理、失效文件重新定位、按文件夹批量修正索引标签。只动索引不动文件',
              onTap: () => router.pushUrl({ url: 'pages/MaintenancePage' })
                  .catch((e: Object) => Logger.warn(TAG, `${e}`))
            })

            // ---- 进度 / 结果 ----
            if (this.busy || this.step.length > 0 || this.lastResult.length > 0) {
              Column() {
                Row() {
                  Column()
                    .width(2)
                    .height(20)
                    .backgroundColor(this.busy ? this.c().accent : this.c().line)
                  Text(this.busy ? (this.step.length > 0 ? this.step : '正在处理…') : this.lastResult)
                    .fontSize(10)
                    .fontColor(this.busy ? this.c().accent : this.c().dim)
                    .lineHeight(16)
                    .layoutWeight(1)
                    .margin({ left: 10 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .backgroundColor(this.c().surfaceAlt)
              .margin({ top: 16 })
            }

            // ---- 说明 ----
            this.SectionTitle('说明', 'NOTES')
            this.Divider()
            Column({ space: 10 }) {
              Text('1 · 备份里没有音频。你换机时需要先把音乐文件夹拷到新机器，再选一次目录、恢复备份 —— 顺序反了会看到一堆"已失效"。')
                .fontSize(9)
                .fontColor(this.c().faint)
                .lineHeight(16)
              Text('2 · 根目录授权不随备份迁移。授权绑的是设备与签名，任何应用都做不到跨设备复制。')
                .fontSize(9)
                .fontColor(this.c().faint)
                .lineHeight(16)
              Text('3 · 导入的 m3u 若来自别的播放器，路径通常指向那台机器的目录；这时会退化成"按文件名唯一匹配"，重名的曲目会被跳过，不会乱配。')
                .fontSize(9)
                .fontColor(this.c().faint)
                .lineHeight(16)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ top: 10, bottom: 90 })
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
      .padding({
        left: this.bp === Const.BP_SM ? 20 : 32,
        right: this.bp === Const.BP_SM ? 20 : 32,
        top: this.topInset + 4
      })

      if (this.panelOpen) {
        ActionPanel({
          title: this.panelMode === 'export' ? '导出哪个歌单' : '密纹 Pro 功能',
          subtitle: this.panelMode === 'export'
            ? '导出为标准 .m3u 文件'
            : (this.pendingKey === 'import' ? '导入歌单文件' :
              (this.pendingKey === 'export' ? '导出歌单' :
                (this.pendingKey === 'backup' ? '备份到文件' : '从备份恢复'))),
          items: this.panelItems,
          onPick: (i: number) => this.onPanelPick(i),
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
