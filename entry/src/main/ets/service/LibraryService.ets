import { fileIo as fs, fileUri, picker, fileShare } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { taskpool } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { RawTag, Track, emptyTag } from '../model/Track';
import { RootDir } from '../model/RootDir';
import { TrackStore } from '../db/TrackStore';
import { StatsStore } from '../db/StatsStore';
import { parseTags, HEAD_BYTES } from './TagParser';
import { DemoLibrary } from './DemoLibrary';
import { SettingsService } from './SettingsService';
import { RootService } from './RootService';
import { CueService } from './CueService';

const TAG: string = 'LibraryService';

/** 扫描进度回调：已处理 / 总数 / 已入库 */
export type ScanProgress = (done: number, total: number, added: number) => void;

/** 一轮多根扫描的结果 */
export interface ScanSummary {
  /** 入库（含更新）总数 */
  added: number;
  /** 这次读不到的根目录绝对路径 */
  dead: string[];
}

/**
 * 曲库服务：选目录 → 持久授权 → 递归扫描 → 解析标签 → 入库。
 *
 * 关键点：鸿蒙第三方拿不到全盘扫描，只能由用户选目录。
 * 所以"重选目录"不是异常分支，而是必须设计好的主流程 ——
 * 空态、引导、进度、失败重试都属于核心功能，不是边角料。
 *
 * 1.1 起支持多根目录：根列表的真源在 RootService，这里只负责按根扫。
 */
export class LibraryService {
  private static cancelFlag: boolean = false;

  static cancelScan(): void {
    LibraryService.cancelFlag = true;
  }

  /**
   * 选择音乐目录并持久化授权。返回目录 URI，用户取消则返回空串。
   *
   * 这里**只**做"选目录 + 存授权"，不往根列表里加：
   * 加不加、能不能加（嵌套/重复）由调用方按 RootService.add 的返回值决定，
   * 否则"重新授权"这条路径也会被当成"新增目录"处理。
   */
  static async pickDirectory(ctx: common.UIAbilityContext): Promise<string> {
    const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const opt: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    opt.maxSelectNumber = 1;
    // VERIFY: DocumentSelectMode.FOLDER 在部分 SDK 上不存在，报错则退化为选文件
    opt.selectMode = picker.DocumentSelectMode.FOLDER;
    const uris: string[] = await dp.select(opt);
    if (!uris || uris.length === 0) {
      return '';
    }
    const dirUri: string = uris[0];
    await LibraryService.persist(dirUri);
    Logger.info(TAG, `picked ${dirUri}`);
    return dirUri;
  }

  /**
   * 持久化 URI 授权：不做这一步，用户下次打开就得重新选。
   * 需要受限权限 ohos.permission.FILE_ACCESS_PERSIST（AGC 申请）。
   */
  private static async persist(uri: string): Promise<void> {
    try {
      const policy: fileShare.PolicyInfo = {
        uri: uri,
        operationMode: fileShare.OperationMode.READ_MODE
      };
      await fileShare.persistPermission([policy]);
    } catch (e) {
      Logger.error(TAG, `persistPermission failed: ${JSON.stringify(e)}`);
    }
  }

  static restoreUri(): string {
    return SettingsService.libUri();
  }

  static toPath(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (e) {
      Logger.error(TAG, `uri to path failed: ${uri}`);
      return '';
    }
  }

  // ---------------- 扫描 ----------------

  /**
   * 目录还能不能读。
   * 一定要"真的去 list 一下"再判断：重装后 preferences 里的 uri 还在，
   * 但文件授权已经失效，光看字符串是看不出来的。
   */
  static async probe(root: RootDir): Promise<boolean> {
    if (root.path.length === 0) {
      return false;
    }
    try {
      await fs.listFile(root.path, { recursion: false, listNum: 1 });
      return true;
    } catch (e) {
      const code: number = (e as BusinessError).code;
      Logger.warn(TAG, `probe ${root.path} failed code=${code}`);
      return false;
    }
  }

  /**
   * 扫一个根目录。返回入库数；目录不可读返回 -1。
   * 用 -1 而不是 0：用户需要区分"这个文件夹里没歌"和"这个文件夹打不开了"，
   * 两句话对应两种完全不同的下一步动作。
   */
  static async scanRoot(ctx: common.Context, root: RootDir,
    onProgress: ScanProgress): Promise<number> {
    const rootPath: string = root.path;
    if (rootPath.length === 0 || !(await LibraryService.probe(root))) {
      return -1;
    }
    LibraryService.cancelFlag = false;
    const files: string[] = await LibraryService.listAudio(rootPath);
    Logger.info(TAG, `found ${files.length} audio files under ${rootPath}`);
    let done: number = 0;
    let added: number = 0;
    for (const rel of files) {
      if (LibraryService.cancelFlag) {
        break;
      }
      try {
        const t: Track | null = await LibraryService.buildTrack(ctx, rootPath, rel);
        if (t !== null) {
          await TrackStore.upsert(t);
          added++;
        }
      } catch (e) {
        Logger.warn(TAG, `skip ${rel}: ${JSON.stringify(e)}`);
      }
      done++;
      if (done % 5 === 0 || done === files.length) {
        onProgress(done, files.length, added);
      }
      // 每 20 个文件让一次主线程，列表和进度条才不会被 IO 顶住
      if (done % 20 === 0) {
        await LibraryService.yieldUI();
      }
    }
    // CUE 整轨分轨（密纹 Pro）：音频扫完才有配对对象，所以放在最后
    try {
      added += await CueService.scanCues(rootPath);
    } catch (e) {
      Logger.warn(TAG, `cue scan failed ${JSON.stringify(e)}`);
    }
    return added;
  }

  /**
   * 扫全部根。
   * 单个根失败不中断整轮：一个 U 盘拔了，不该让另外两个目录也扫不了。
   */
  static async scanAll(ctx: common.Context, roots: RootDir[],
    onProgress: ScanProgress): Promise<ScanSummary> {
    const dead: string[] = [];
    let total: number = 0;
    for (const root of roots) {
      const n: number = await LibraryService.scanRoot(ctx, root, (d: number, t: number, a: number) => {
        onProgress(d, t, total + a);
      });
      if (n < 0) {
        dead.push(root.path);
        Logger.warn(TAG, `root unreadable: ${root.path}`);
      } else {
        // 扫描是 upsert，不是清空重来，所以这里记的是"这次见过的数量"
        total += n;
        RootService.setCount(root.path, n);
      }
    }
    return { added: total, dead: dead };
  }

  private static async yieldUI(): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), 0);
    });
  }

  /** 递归列出音频文件（返回相对路径） */
  private static async listAudio(root: string): Promise<string[]> {
    const names: string[] = await fs.listFile(root, {
      recursion: true,
      listNum: 0,
      filter: { suffix: Const.AUDIO_SUFFIX }
    });
    return names.filter((n: string) => {
      for (const s of Const.SKIP_DIRS) {
        if (n.indexOf(`/${s}/`) >= 0 || n.startsWith(`${s}/`)) {
          return false;
        }
      }
      return true;
    });
  }

  /** 单文件 → Track。读不到标签就用文件名，绝不整条丢弃 */
  private static async buildTrack(ctx: common.Context, rootPath: string, rel: string): Promise<Track | null> {
    // listFile 递归返回的相对路径两种形态都见过（带前导 / 与不带），统一抹平
    const relClean: string = rel.startsWith('/') ? rel.substring(1) : rel;
    const base: string = rootPath.endsWith('/') ? rootPath.substring(0, rootPath.length - 1) : rootPath;
    const path: string = `${base}/${relClean}`;
    const stat: fs.Stat = fs.statSync(path);
    // 目录名恰好带音频后缀（如"cue-fix.wav"目录）会被 listFile 带进来，这里剔除
    if (!stat.isFile()) {
      return null;
    }
    if (stat.size < Const.MIN_BYTES) {
      return null;
    }
    const suffix: string = path.substring(path.lastIndexOf('.')).toLowerCase();
    const nameNoExt: string = path.substring(path.lastIndexOf('/') + 1, path.lastIndexOf('.'));
    // 相对根的目录，根下直接放的是空串 —— 文件夹视图按这个字段建树
    const cut: number = relClean.lastIndexOf('/');
    const folder: string = cut >= 0 ? relClean.substring(0, cut) : '';

    let tag: RawTag = emptyTag();
    const file: fs.File = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const head: ArrayBuffer = new ArrayBuffer(Math.min(stat.size, HEAD_BYTES));
      await fs.read(file.fd, head, { offset: 0, length: head.byteLength });
      tag = await LibraryService.parseInWorker(head, suffix);
    } catch (e) {
      Logger.warn(TAG, `read head failed: ${rel}`);
    } finally {
      await fs.close(file);
    }

    const coverPath: string = tag.cover !== null
      ? await LibraryService.saveCover(ctx, path, stat.mtime, tag.cover, tag.coverMime)
      : '';

    return {
      id: 0,
      uri: fileUri.getUriFromPath(path),
      path: path,
      title: tag.title.length > 0 ? tag.title : nameNoExt,
      artist: tag.artist,
      album: tag.album,
      duration: 0,
      sampleRate: tag.sampleRate,
      bitrate: 0,
      suffix: suffix,
      size: stat.size,
      mtime: stat.mtime * 1000,
      coverPath: coverPath,
      folder: folder,
      rootPath: base,
      source: Const.SRC_LOCAL,
      cueStart: -1,
      cueEnd: -1
    };
  }

  /** 标签解析丢到 worker，主线程只做 IO */
  private static async parseInWorker(buf: ArrayBuffer, suffix: string): Promise<RawTag> {
    try {
      const ret: Object = await taskpool.execute(parseTags, buf, suffix);
      return ret as RawTag;
    } catch (e) {
      Logger.warn(TAG, `tag parse failed: ${JSON.stringify(e)}`);
      return emptyTag();
    }
  }

  /** 封面落盘到 cacheDir/covers，文件名用 路径+时间戳 做稳定散列 */
  private static async saveCover(ctx: common.Context, path: string, mtime: number,
    data: Uint8Array, mime: string): Promise<string> {
    try {
      const dir: string = `${ctx.cacheDir}/${Const.COVER_DIR}`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      const ext: string = mime.indexOf('png') >= 0 ? '.png' : '.jpg';
      const name: string = `${LibraryService.hash(path)}_${mtime}${ext}`;
      const filePath: string = `${dir}/${name}`;
      if (fs.accessSync(filePath)) {
        return filePath;
      }
      const file: fs.File = await fs.open(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try {
        await fs.write(file.fd, data.buffer);
      } finally {
        await fs.close(file);
      }
      return filePath;
    } catch (e) {
      Logger.warn(TAG, `save cover failed: ${JSON.stringify(e)}`);
      return '';
    }
  }

  /** djb2，够用且不引入额外依赖 */
  private static hash(s: string): string {
    let h: number = 5381;
    for (let i = 0; i < s.length; i++) {
      h = ((h << 5) + h + s.charCodeAt(i)) & 0x7fffffff;
    }
    return h.toString(16);
  }

  // ---------------- 示例曲库 ----------------

  /** 装载示例曲库并切到 demo 来源 */
  static async loadDemo(): Promise<number> {
    await TrackStore.clearSource(Const.SRC_DEMO);
    const n: number = await DemoLibrary.seed();
    SettingsService.setSource(Const.SRC_DEMO);
    SettingsService.setDemoSeeded();
    SettingsService.bumpLibrary();
    return n;
  }

  /** 清空当前来源的索引（不动磁盘上的文件，只清数据库） */
  static async clear(source: string): Promise<void> {
    await TrackStore.clearSource(source);
    // 索引没了统计就成了对不上号的旧数字，一并清掉
    await StatsStore.clearAll();
    SettingsService.bumpLibrary();
  }

  /**
   * 移除一个根目录：从列表里拿掉，并清掉它名下的索引。
   *
   * 只清这个根 —— 别的目录一首都不能动。但如果这是最后一个根，
   * 就把 local 来源整个清掉：老版本升级上来的曲目 root_path 是空的，
   * 光按 root_path 删会剩一堆孤儿行，列表里就会出现"已经删了的目录里的歌"。
   */
  static async removeRoot(root: RootDir): Promise<void> {
    await TrackStore.clearRoot(root.path);
    RootService.remove(root.path);
    if (RootService.count() === 0) {
      await TrackStore.clearSource(Const.SRC_LOCAL);
    }
    SettingsService.bumpLibrary();
  }
}
