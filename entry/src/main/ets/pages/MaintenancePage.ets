import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { router, promptAction } from '@kit.ArkUI';
import { writeTags as decWriteTags } from 'libmiwen.so';
import { Const } from '../common/Constants';
import { Fmt } from '../common/Fmt';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { Track } from '../model/Track';
import { FolderStat } from '../model/RootDir';
import { RootService } from '../service/RootService';
import { MaintenanceService, DuplicateGroup, MissingItem } from '../service/MaintenanceService';
import { TrackStore } from '../db/TrackStore';
import { ActionPanel, ActionItem } from '../components/ActionPanel';

const TAG: string = 'MaintenancePage';

/**
 * 曲库维护（第二梯队第 13 / 14 项）。
 *
 * 三个动作都是「只动索引不动文件」：
 * - 重复曲目：同标题 + 同秒级时长 + 同大小成组，可整组清理或逐条移出索引；
 * - 失效路径：文件被移走/删掉后索引还挂着，可以重新定位到新文件或移出索引；
 * - 批量改标签：按文件夹批量改索引里的艺人/专辑；可勾选「回写文件」把修改写进
 *   音频文件本体（v1.5.0：FLAC = Vorbis comment，MP3 = ID3v2.3；音频流字节不动）。
 */
@Entry
@Component
struct MaintenancePage {
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('accentPin') accentPin: string = '';
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bp') bp: string = Const.BP_SM;

  @State busy: boolean = false;
  @State step: string = '';
  @State dupGroups: DuplicateGroup[] = [];
  @State dupScanned: boolean = false;
  @State missing: MissingItem[] = [];
  @State missingScanned: boolean = false;

  /** 批量改标签：文件夹选择面板 */
  @State panelOpen: boolean = false;
  @State panelItems: ActionItem[] = [];
  @State folderKeys: string[] = []; // 'rootPath||folder'
  @State pickedFolder: string = '';
  @State pickedRoot: string = '';
  @State pickedCount: number = 0;
  @State inArtist: string = '';
  @State inAlbum: string = '';
  /** 批量改标签时是否同时回写文件本体（v1.5.0） */
  @State writeBack: boolean = false;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private c(): Tokens {
    return Theme.of(this.themeKey, this.accentPin);
  }

  // ---------------- 重复曲目 ----------------

  private async scanDup(): Promise<void> {
    this.busy = true;
    this.step = '正在比对指纹…';
    try {
      this.dupGroups = await MaintenanceService.findDuplicates('local');
      this.dupScanned = true;
      const n: number = this.dupGroups.reduce((s: number, g: DuplicateGroup) => s + g.tracks.length - 1, 0);
      promptAction.showToast({
        message: this.dupGroups.length > 0 ? `${this.dupGroups.length} 组重复，共 ${n} 条冗余` : '没有发现重复曲目'
      });
    } catch (e) {
      Logger.error(TAG, `dup scan ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '扫描失败，请重试' });
    }
    this.busy = false;
    this.step = '';
  }

  private async pruneGroup(g: DuplicateGroup): Promise<void> {
    const removed: number = await MaintenanceService.pruneDuplicates([g]);
    await this.refreshAfterRemove();
    promptAction.showToast({ message: `已移除 ${removed} 条，保留第一条` });
  }

  private async removeOne(t: Track): Promise<void> {
    await TrackStore.removeUri(t.uri);
    await this.refreshAfterRemove();
    promptAction.showToast({ message: '已从索引移除（文件未动）' });
  }

  private async refreshAfterRemove(): Promise<void> {
    this.dupGroups = await MaintenanceService.findDuplicates('local');
  }

  // ---------------- 失效路径 ----------------

  private async scanMissing(): Promise<void> {
    this.busy = true;
    try {
      this.missing = await MaintenanceService.findMissing('local', (done: number, total: number) => {
        this.step = `检查中 ${done}/${total}`;
      });
      this.missingScanned = true;
      promptAction.showToast({
        message: this.missing.length > 0 ? `${this.missing.length} 条索引指向已不存在的文件` : '索引完整，没有失效条目'
      });
    } catch (e) {
      Logger.error(TAG, `missing scan ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '检查失败，请重试' });
    }
    this.busy = false;
    this.step = '';
  }

  /** 重新定位：文件选择器挑新文件，索引路径/uri 换过去，元数据保留 */
  private async relocate(item: MissingItem): Promise<void> {
    let pickedUri: string = '';
    try {
      const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.ctx);
      const opt: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      const uris: string[] = await dp.select(opt);
      if (!uris || uris.length === 0) {
        return;
      }
      pickedUri = uris[0];
    } catch (e) {
      Logger.warn(TAG, `pick relocate ${JSON.stringify(e)}`);
      return;
    }
    const newPath: string = LibraryPath.toPath(pickedUri);
    if (newPath.length === 0) {
      promptAction.showToast({ message: '拿不到所选文件的本地路径，无法重定位' });
      return;
    }
    let ok: boolean = false;
    try {
      ok = await fs.access(newPath).then((r: Object) => (r as Record<string, boolean>).status ?? false);
    } catch (e) {
      ok = false;
    }
    if (!ok) {
      promptAction.showToast({ message: '所选文件读不到，保持原状' });
      return;
    }
    await TrackStore.relocate(item.track.uri, newPath);
    this.missing = this.missing.filter((m: MissingItem) => m.track.uri !== item.track.uri);
    promptAction.showToast({ message: '已重新定位，元数据保留' });
  }

  // ---------------- 批量改标签 ----------------

  private openFolderPanel(): void {
    const roots = RootService.list();
    const items: ActionItem[] = [];
    const keys: string[] = [];
    for (const r of roots) {
      // folderStats 是同步阻塞查询但量小（每根几十行），可接受
      TrackStore.folderStats('local', r.path).then((stats: FolderStat[]) => {
        for (const s of stats) {
          items.push({
            label: `${r.name}${s.folder.length > 0 ? ' / ' + s.folder : '（根目录）'}`,
            hint: `${s.count} 首`,
            danger: false
          });
          keys.push(`${r.path}||${s.folder}`);
        }
        if (items.length > 0) {
          this.panelItems = items;
          this.folderKeys = keys;
          this.panelOpen = true;
        }
      }).catch((e: Object) => Logger.warn(TAG, `folderStats ${e}`));
    }
  }

  private async pickFolder(key: string): Promise<void> {
    const idx: number = this.folderKeys.indexOf(key);
    if (idx < 0) {
      return;
    }
    this.panelOpen = false;
    const parts: string[] = key.split('||');
    this.pickedRoot = parts[0];
    this.pickedFolder = parts[1];
    this.pickedCount = await TrackStore.countInFolder('local', this.pickedRoot, this.pickedFolder);
    this.inArtist = '';
    this.inAlbum = '';
  }

  private async applyMeta(): Promise<void> {
    if (this.pickedCount <= 0) {
      promptAction.showToast({ message: '先选一个文件夹' });
      return;
    }
    if (this.inArtist.length === 0 && this.inAlbum.length === 0) {
      promptAction.showToast({ message: '艺人 / 专辑至少填一个' });
      return;
    }
    this.busy = true;
    this.step = '更新索引…';
    try {
      const tracks: Track[] = await TrackStore.pageInFolder(
        'local', this.pickedRoot, this.pickedFolder, 0, 2000, Const.SORT_TITLE);
      const uris: string[] = tracks.map((t: Track) => t.uri);
      const n: number = await TrackStore.updateMeta(uris, '', this.inArtist, this.inAlbum);
      let msg = `已更新 ${n} 条索引标签（文件未动）`;
      if (this.writeBack) {
        // v1.5.0：把修改写进文件本体（FLAC/MP3）；一个一个来，失败不中断整批
        let ok: number = 0;
        let skip: number = 0;
        let fail: number = 0;
        let lastErr: string = '';
        this.step = '回写文件…';
        for (const t of tracks) {
          if (t.suffix !== '.flac' && t.suffix !== '.mp3') {
            skip++;
            continue;
          }
          try {
            const payload: string = JSON.stringify({
              artist: this.inArtist,
              album: this.inAlbum
            });
            const why: string = decWriteTags(t.path, payload);
            if (why.length === 0) {
              ok++;
            } else {
              fail++;
              lastErr = why;
            }
          } catch (e) {
            fail++;
            lastErr = JSON.stringify(e);
          }
        }
        msg = `索引 ${n} 条；回写：成功 ${ok}，跳过 ${skip}，失败 ${fail}`;
        if (fail > 0 && lastErr.length > 0) {
          msg += `（${lastErr.substring(0, 40)}）`;
        }
      }
      promptAction.showToast({ message: msg });
    } finally {
      this.busy = false;
    }
  }

  // ---------------- 组件 ----------------

  @Builder
  SectionTitle(cn: string, en: string) {
    Row() {
      Text(cn).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.c().text)
      Text(en).fontSize(9).fontColor(this.c().faint).letterSpacing(1.5).margin({ left: 8 })
    }
    .width('100%')
    .margin({ top: 18, bottom: 8 })
  }

  @Builder
  PrimaryBtn(label: string, onTap: () => void, disabled: boolean) {
    Button(label)
      .fontSize(13)
      .width('100%')
      .height(40)
      .backgroundColor(disabled ? this.c().dim : this.c().accent)
      .fontColor(this.c().bg)
      .opacity(disabled ? 0.5 : 1)
      .onClick(() => {
        if (!disabled) {
          onTap();
        }
      })
  }

  @Builder
  DupGroup(g: DuplicateGroup) {
    Column() {
      Text(`${g.title || '未知标题'}`)
        .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.c().text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`${g.tracks.length} 条 · ${Fmt.bytes(g.size)} · ${Fmt.time(g.dsec * 1000)}`)
        .fontSize(10).fontColor(this.c().dim).margin({ top: 2 })
      ForEach(g.tracks, (t: Track) => {
        Row() {
          Column() {
            Text(t.path.length > 0 ? t.path.substring(t.path.lastIndexOf('/') + 1) : t.uri)
              .fontSize(11).fontColor(this.c().text).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(t.path)
              .fontSize(9).fontColor(this.c().faint).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('移出索引')
            .fontSize(11).fontColor(this.c().accent)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => {
              this.removeOne(t);
            })
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }, (t: Track) => t.uri)
      Text('保留第一条，移除其余')
        .fontSize(11).fontColor(this.c().accent)
        .padding({ top: 6 })
        .onClick(() => {
          this.pruneGroup(g);
        })
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(this.c().surfaceAlt)
    .margin({ bottom: 10 })
  }

  @Builder
  MissingRow(m: MissingItem) {
    Column() {
      Text(`${m.track.title} · ${m.track.artist.length > 0 ? m.track.artist : '未知艺人'}`)
        .fontSize(12).fontColor(this.c().text).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(m.track.path)
        .fontSize(9).fontColor(this.c().faint).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row() {
        Text('重新定位')
          .fontSize(11).fontColor(this.c().accent)
          .padding({ right: 16 })
          .onClick(() => {
            this.relocate(m);
          })
        Text('移出索引')
          .fontSize(11).fontColor(this.c().accent)
          .onClick(() => {
            this.removeOne(m.track);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ top: 6 })
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(this.c().surfaceAlt)
    .margin({ bottom: 10 })
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(24).fontColor(this.c().dim).width(44).height(36)
            .onClick(() => router.back())
          Text('曲库维护')
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.c().text)
          Blank()
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: this.topInset + 8, bottom: 8 })

        Scroll() {
          Column() {
            // ---- 重复曲目 ----
            this.SectionTitle('重复曲目', 'DUPLICATES')
            Text('标题、时长（秒级）与文件大小完全一致才判重；清理只移索引，文件原样保留。')
              .fontSize(10).fontColor(this.c().dim).margin({ bottom: 10 })
            this.PrimaryBtn(this.busy ? this.step : (this.dupScanned ? '重新扫描' : '扫描重复曲目'),
              (): void => {
                this.scanDup();
              }, this.busy)
            if (this.dupScanned && this.dupGroups.length === 0) {
              Text('没有发现重复曲目')
                .fontSize(11).fontColor(this.c().dim).margin({ top: 10 })
            }
            ForEach(this.dupGroups, (g: DuplicateGroup) => {
              this.DupGroup(g)
            }, (g: DuplicateGroup) => `${g.title}#${g.size}#${g.dsec}`)

            // ---- 失效路径 ----
            this.SectionTitle('失效路径', 'BROKEN PATHS')
            Text('文件被移动或删除后，索引还挂着旧路径。重新定位可指到新文件（元数据保留）。')
              .fontSize(10).fontColor(this.c().dim).margin({ bottom: 10 })
            this.PrimaryBtn(this.busy ? this.step : (this.missingScanned ? '重新检查' : '检查失效条目'),
              (): void => {
                this.scanMissing();
              }, this.busy)
            if (this.missingScanned && this.missing.length === 0) {
              Text('索引完整，没有失效条目')
                .fontSize(11).fontColor(this.c().dim).margin({ top: 10 })
            }
            ForEach(this.missing, (m: MissingItem) => {
              this.MissingRow(m)
            }, (m: MissingItem) => m.track.uri)

            // ---- 批量改标签 ----
            this.SectionTitle('批量改索引标签', 'BATCH TAGS')
            Text('按文件夹批量修正索引里的艺人/专辑。可勾选"回写文件"把修改写进音频文件本体（FLAC/MP3；音频流字节不动）。')
              .fontSize(10).fontColor(this.c().dim).margin({ bottom: 10 })
            Button(this.pickedFolder.length === 0 ? '选择文件夹' :
              `${this.pickedFolder.length > 0 && this.pickedFolder === '' ? '根目录' : this.pickedFolder}（${this.pickedCount} 首）· 重选`)
              .fontSize(13).width('100%').height(40)
              .backgroundColor(this.c().surfaceAlt).fontColor(this.c().text)
              .onClick(() => {
                this.openFolderPanel();
              })
            if (this.pickedCount > 0) {
              TextInput({ placeholder: '新艺人（留空不改）', text: this.inArtist })
                .fontSize(13).height(40).margin({ top: 10 })
                .backgroundColor(this.c().surfaceAlt).fontColor(this.c().text)
                .onChange((v: string) => {
                  this.inArtist = v;
                })
              TextInput({ placeholder: '新专辑（留空不改）', text: this.inAlbum })
                .fontSize(13).height(40).margin({ top: 10 })
                .backgroundColor(this.c().surfaceAlt).fontColor(this.c().text)
                .onChange((v: string) => {
                  this.inAlbum = v;
                })
              Row() {
                Text('同时回写到文件（FLAC/MP3）')
                  .fontSize(12).fontColor(this.c().text)
                  .layoutWeight(1)
                Toggle({ type: ToggleType.Checkbox, isOn: this.writeBack })
                  .selectedColor(this.c().accent)
                  .onChange((on: boolean) => {
                    this.writeBack = on;
                  })
              }
              .width('100%')
              .margin({ top: 10 })
              if (this.writeBack) {
                Text('回写直接修改音频文件本体（FLAC = Vorbis comment，MP3 = ID3v2.3），其他格式自动跳过并计数。')
                  .fontSize(10).fontColor(this.c().faint).margin({ top: 6 })
              }
              this.PrimaryBtn(this.busy ? this.step : '应用到所选文件夹', (): void => {
                this.applyMeta();
              }, this.busy)
            }
            Text('').height(40)
          }
          .padding({ left: 16, right: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%').height('100%')

      if (this.panelOpen) {
        ActionPanel({
          title: '选择文件夹',
          items: this.panelItems,
          onPick: (i: number): void => {
            if (i >= 0 && i < this.folderKeys.length) {
              this.pickFolder(this.folderKeys[i]);
            } else {
              this.panelOpen = false;
            }
          },
          onClose: (): void => {
            this.panelOpen = false;
          }
        })
      }
    }
  }
}

/** uri→path 小工具（照 LibraryService.toPath，避免整包依赖） */
class LibraryPath {
  static toPath(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (e) {
      return '';
    }
  }
}
