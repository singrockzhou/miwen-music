import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';
import { Track } from '../model/Track';
import { DupFingerprint, TrackStore } from '../db/TrackStore';

const TAG: string = 'MaintenanceService';

/** 一组重复曲目：指纹相同（标题 + 秒级时长 + 文件大小）的所有条目 */
export interface DuplicateGroup {
  title: string;
  dsec: number;
  size: number;
  tracks: Track[];
}

export interface MissingItem {
  track: Track;
}

export interface DupScanOutcome {
  groups: DuplicateGroup[];
}

/**
 * 曲库维护（第二梯队第 13 / 14 项）：重复曲目检测、失效路径、批量改索引标签。
 *
 * 全部只动索引不动文件——这是应用「只读不写用户文件」定位的延伸：
 * 移除的只是数据库里的行，磁盘上的音乐原样保留。
 */
export class MaintenanceService {
  /** 重复检测：SQL 粗筛指纹组，再逐组回查完整条目 */
  static async findDuplicates(source: string): Promise<DuplicateGroup[]> {
    const fps: DupFingerprint[] = await TrackStore.dupFingerprints(source);
    const groups: DuplicateGroup[] = [];
    for (const fp of fps) {
      const tracks: Track[] = await TrackStore.listByFingerprint(source, fp);
      if (tracks.length > 1) {
        groups.push({ title: fp.title, dsec: fp.dsec, size: fp.size, tracks: tracks });
      }
    }
    Logger.info(TAG, `dup scan: ${groups.length} groups`);
    return groups;
  }

  /** 一键清理：每组保留第一条（CUE 分轨跟整轨走），其余从索引移除 */
  static async pruneDuplicates(groups: DuplicateGroup[], keepFirst: boolean = true): Promise<number> {
    let removed: number = 0;
    for (const g of groups) {
      // 每组先保留一个「文件代表」：按路径去重后留下的第一个
      const seenPath: Map<string, boolean> = new Map();
      for (const t of g.tracks) {
        if (keepFirst && !seenPath.has(t.path)) {
          seenPath.set(t.path, true);
          continue;
        }
        await TrackStore.removeUri(t.uri);
        removed++;
      }
    }
    Logger.info(TAG, `dup prune: removed ${removed}`);
    return removed;
  }

  /** 逐条 access 检查文件是否还在盘上；onProgress 供 UI 显示进度 */
  static async findMissing(source: string, onProgress: (done: number, total: number) => void):
    Promise<MissingItem[]> {
    const all: Track[] = await TrackStore.dumpAll(source);
    const out: MissingItem[] = [];
    const checked: Map<string, boolean> = new Map(); // 同文件的多条 CUE 分轨只查一次
    let done: number = 0;
    for (const t of all) {
      done++;
      if (done % 50 === 0) {
        onProgress(done, all.length);
      }
      if (checked.has(t.path)) {
        if (checked.get(t.path) === false) {
          out.push({ track: t });
        }
        continue;
      }
      let exists: boolean = true;
      try {
        exists = await fs.access(t.path).then((r: Object) => (r as Record<string, boolean>).status ?? true);
      } catch (e) {
        exists = false;
      }
      checked.set(t.path, exists);
      if (!exists) {
        out.push({ track: t });
      }
    }
    onProgress(all.length, all.length);
    Logger.info(TAG, `missing scan: ${out.length} of ${all.length}`);
    return out;
  }
}
