import { common } from '@kit.AbilityKit';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { RootDir } from '../model/RootDir';
import { LibraryService, ScanSummary } from './LibraryService';
import { RootService } from './RootService';
import { SettingsService } from './SettingsService';

const TAG: string = 'ImportFlow';

export interface ImportResult {
  ok: boolean;
  /** 新增/更新的曲目数 */
  added: number;
  /** 给用户看的一句话，成功失败都用它 */
  message: string;
}

/**
 * "选目录 → 扫描 → 入库" 的完整流程。
 *
 * 首页空态、曲库页、设置页三处都会触发，抽出来只写一遍：
 * 三处各写一份，最容易出现的 bug 是"某处忘了切 source，扫完还是空列表"。
 *
 * 多根之后的拆法：
 * - pickAndAdd：只扫"刚加的那个根"。加一个目录不该让已有 3000 首重扫一遍。
 * - rescanAll：用户在根目录管理页主动点"全部重新扫描"时才走这里。
 */
export class ImportFlow {

  /** 选一个新文件夹并只扫它 */
  static async pickAndAdd(ctx: common.UIAbilityContext,
    onProgress: (text: string) => void): Promise<ImportResult> {
    let uri: string = '';
    try {
      uri = await LibraryService.pickDirectory(ctx);
    } catch (e) {
      Logger.error(TAG, `pick failed ${JSON.stringify(e)}`);
      return { ok: false, added: 0, message: '打开文件选择器失败，请重试' };
    }
    if (uri.length === 0) {
      return { ok: false, added: 0, message: '没有选择文件夹' };
    }
    const path: string = LibraryService.toPath(uri);
    const st: string = RootService.add(uri);
    if (st === RootService.NESTED) {
      // 目录树里"父目录"已经被授权过，再加子目录只会让同一首歌归属打架
      return {
        ok: false,
        added: 0,
        message: '这个文件夹已经在某个已授权的目录里了，不必单独添加'
      };
    }
    if (st === RootService.INVALID) {
      return { ok: false, added: 0, message: '这个目录读不到，换一个试试' };
    }
    const root: RootDir | null = RootService.findByPath(path);
    if (root === null) {
      return { ok: false, added: 0, message: '这个目录读不到，换一个试试' };
    }
    return await ImportFlow.scanOne(ctx, root, onProgress);
  }

  /** 扫单个已知根（重新授权后也走这条） */
  static async scanOne(ctx: common.UIAbilityContext, root: RootDir,
    onProgress: (text: string) => void): Promise<ImportResult> {
    SettingsService.setSource(Const.SRC_LOCAL);
    onProgress('正在读取目录…');
    try {
      let lastTick: number = 0;
      const added: number = await LibraryService.scanRoot(ctx, root,
        (done: number, total: number, ok: number) => {
          const now: number = Date.now();
          if (now - lastTick < 120 && done < total) {
            return;
          }
          lastTick = now;
          onProgress(total === 0
            ? '这个文件夹里没有可识别的音频'
            : `正在整理 ${done}/${total} · 已收录 ${ok}`);
        });
      SettingsService.bumpLibrary();
      if (added < 0) {
        return { ok: false, added: 0, message: `「${root.name}」打不开了，需要重新授权` };
      }
      if (added === 0) {
        return { ok: false, added: 0, message: '没找到能播的音频文件（支持 mp3/flac/m4a/aac/wav/ogg）' };
      }
      return { ok: true, added: added, message: `「${root.name}」已收录 ${added} 首` };
    } catch (e) {
      Logger.error(TAG, `scan failed ${JSON.stringify(e)}`);
      return { ok: false, added: 0, message: '扫描失败，请确认目录权限后重试' };
    }
  }

  /** 全部根重新扫描 */
  static async rescanAll(ctx: common.UIAbilityContext,
    onProgress: (text: string) => void): Promise<ImportResult> {
    const roots: RootDir[] = RootService.list();
    if (roots.length === 0) {
      return { ok: false, added: 0, message: '还没有音乐文件夹' };
    }
    SettingsService.setSource(Const.SRC_LOCAL);
    onProgress('正在重新扫描…');
    try {
      let lastTick: number = 0;
      const sum: ScanSummary = await LibraryService.scanAll(ctx, roots,
        (done: number, total: number, ok: number) => {
          const now: number = Date.now();
          if (now - lastTick < 120 && done < total) {
            return;
          }
          lastTick = now;
          onProgress(`正在整理 ${done}/${total} · 已收录 ${ok}`);
        });
      SettingsService.bumpLibrary();
      if (sum.dead.length > 0) {
        // 死目录不静默：用户需要知道"哪一个"失效了，否则只会觉得歌莫名少了几百首
        return {
          ok: sum.added > 0,
          added: sum.added,
          message: `${sum.dead.length} 个文件夹需要重新授权，其余已收录 ${sum.added} 首`
        };
      }
      return {
        ok: sum.added > 0,
        added: sum.added,
        message: sum.added > 0 ? `已收录 ${sum.added} 首` : '没有发现新文件'
      };
    } catch (e) {
      Logger.error(TAG, `rescan failed ${JSON.stringify(e)}`);
      return { ok: false, added: 0, message: '扫描失败，请确认目录权限后重试' };
    }
  }
}
