import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { RootDir } from '../model/RootDir';
import { LibraryService } from './LibraryService';
import { SettingsService } from './SettingsService';

const TAG: string = 'RootService';

/**
 * 多根目录管理。
 *
 * 单目录不够用的原因很具体：发烧友的磁盘上，无损在一处、播客在一处、
 * 新下的单曲在下载目录，而标签常常是乱的 —— 只有目录结构是可信的。
 *
 * 三条原则：
 * 1. 根目录列表是曲库的"真源"，扫描只往这个列表里加，不偷偷替换；
 * 2. 按 path 判重，不按 uri —— 重装后 uri 会变，path 不会；
 * 3. 移除根目录只清它的索引，不碰磁盘文件，也不碰别的根。
 */
export class RootService {
  /** add() 的结果 */
  static readonly ADDED: string = 'added';
  static readonly EXISTS: string = 'exists';
  /** 新目录是某个已有根的子目录 —— 加进来会让同一首歌被算两遍 */
  static readonly NESTED: string = 'nested';
  static readonly INVALID: string = 'invalid';

  /** 读全部根目录；首次调用时顺带把老版本的单目录迁移过来 */
  static list(): RootDir[] {
    const raw: string = SettingsService.getStr(Const.KEY_ROOTS, '');
    const out: RootDir[] = [];
    if (raw.length > 0) {
      try {
        const arr: RootDir[] = JSON.parse(raw) as RootDir[];
        for (const r of arr) {
          // 老数据可能缺字段，补齐再交出去，避免 UI 上出现 undefined
          out.push(RootService.normalize(r));
        }
      } catch (e) {
        Logger.warn(TAG, `parse roots failed: ${JSON.stringify(e)}`);
      }
    }
    if (out.length === 0) {
      const legacy: string = SettingsService.libUri();
      if (legacy.length > 0) {
        const r: RootDir = RootService.build(legacy, 0);
        if (r.path.length > 0) {
          out.push(r);
          RootService.save(out);
          Logger.info(TAG, 'migrated legacy single root');
        }
      }
    }
    // 历史遗留的嵌套根：父目录已经授权时，子目录不该再单独占一行。
    // 只从列表里摘掉，索引不动 —— 父目录下次重扫会把 root_path 改写过来。
    const clean: RootDir[] = out.filter((r: RootDir) => {
      for (const o of out) {
        if (o.path !== r.path && r.path.startsWith(`${o.path}/`)) {
          return false;
        }
      }
      return true;
    });
    if (clean.length !== out.length) {
      Logger.info(TAG, `dropped ${out.length - clean.length} nested roots`);
      RootService.save(clean);
    }
    return clean;
  }

  static count(): number {
    return RootService.list().length;
  }

  private static normalize(r: RootDir): RootDir {
    const uri: string = r.uri !== undefined && r.uri !== null ? r.uri : '';
    let path: string = r.path !== undefined && r.path !== null ? r.path : '';
    if (path.length === 0 && uri.length > 0) {
      path = LibraryService.toPath(uri);
    }
    const name: string = r.name !== undefined && r.name !== null && r.name.length > 0
      ? r.name
      : RootService.baseName(path);
    const addedAt: number = r.addedAt !== undefined && r.addedAt !== null ? r.addedAt : 0;
    const count: number = r.count !== undefined && r.count !== null ? r.count : 0;
    return { uri: uri, path: path, name: name, addedAt: addedAt, count: count };
  }

  private static build(uri: string, count: number): RootDir {
    const path: string = LibraryService.toPath(uri);
    return { uri: uri, path: path, name: RootService.baseName(path), addedAt: Date.now(), count: count };
  }

  /** 取路径最后一段做显示名；根路径（/）退化成整串 */
  static baseName(path: string): string {
    if (path.length === 0) {
      return '未命名目录';
    }
    const p: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const i: number = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }

  private static save(list: RootDir[]): void {
    try {
      SettingsService.setStr(Const.KEY_ROOTS, JSON.stringify(list));
    } catch (e) {
      Logger.warn(TAG, `save roots failed: ${JSON.stringify(e)}`);
    }
    // 单目录字段同步成第一项，老代码（设置页摘要、播控面板）读它仍然有值
    SettingsService.setLibUri(list.length > 0 ? list[0].uri : '');
  }

  /**
   * 加入一个根目录。
   *
   * 三种边界都要挡住，否则索引里会出现"同一首歌属于两个目录"：
   * 1. path 已存在（重装后重新授权同一个目录，uri 变了）→ 只更新 uri，不新增；
   * 2. 新目录是已有根的子目录 → 拒绝。已在的那棵树下已经把它扫进去了；
   * 3. 新目录是已有根的父目录 → 允许，并把被包含的子根删掉，否则重扫时两边都写一遍。
   */
  static add(uri: string): string {
    const path: string = LibraryService.toPath(uri);
    if (path.length === 0) {
      return RootService.INVALID;
    }
    const list: RootDir[] = RootService.list();
    for (const r of list) {
      if (r.path === path) {
        if (r.uri !== uri) {
          Logger.info(TAG, `re-authorize ${path}`);
          r.uri = uri;
          RootService.save(list);
        }
        return RootService.EXISTS;
      }
      if (path.startsWith(`${r.path}/`)) {
        Logger.warn(TAG, `nested root rejected: ${path} under ${r.path}`);
        return RootService.NESTED;
      }
    }
    // 新根是某些已有根的父目录：把它们收编，避免重复扫描
    const keep: RootDir[] = list.filter((r: RootDir) => !r.path.startsWith(`${path}/`));
    if (keep.length !== list.length) {
      Logger.info(TAG, `merged ${list.length - keep.length} nested roots into ${path}`);
    }
    keep.push(RootService.build(uri, 0));
    RootService.save(keep);
    SettingsService.setSource(Const.SRC_LOCAL);
    return RootService.ADDED;
  }

  static remove(path: string): RootDir[] {
    const list: RootDir[] = RootService.list().filter((r: RootDir) => r.path !== path);
    RootService.save(list);
    return list;
  }

  static setCount(path: string, count: number): void {
    const list: RootDir[] = RootService.list();
    let hit: boolean = false;
    for (const r of list) {
      if (r.path === path) {
        r.count = count;
        hit = true;
      }
    }
    if (hit) {
      RootService.save(list);
    }
  }

  /** 找出某个 path 对应的根（曲目按根分组时用） */
  static findByPath(path: string): RootDir | null {
    for (const r of RootService.list()) {
      if (r.path === path) {
        return r;
      }
    }
    return null;
  }

  /** 给定绝对路径，判断它属于哪个根，返回相对根的目录（不含文件名） */
  static folderOf(root: RootDir, absPath: string): string {
    if (root.path.length === 0 || absPath.length <= root.path.length) {
      return '';
    }
    const prefix: string = root.path.endsWith('/') ? root.path : `${root.path}/`;
    if (!absPath.startsWith(prefix)) {
      return '';
    }
    const rel: string = absPath.substring(prefix.length);
    const i: number = rel.lastIndexOf('/');
    return i >= 0 ? rel.substring(0, i) : '';
  }
}
