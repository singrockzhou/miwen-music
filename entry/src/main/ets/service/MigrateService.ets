import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Track } from '../model/Track';
import { PlaylistDump } from '../model/Playlist';
import { PathRow, TrackStore } from '../db/TrackStore';
import { PlaylistStore } from '../db/PlaylistStore';
import { SettingsService } from './SettingsService';

const TAG: string = 'MigrateService';

const BACKUP_NAME: string = 'miwen-backup.json';
const ZIP_IN: string = 'miwen-backup.zip';

export interface ImportOutcome {
  ok: boolean;
  /** 命中并写入歌单的曲目数 */
  matched: number;
  /** 歌单文件里的条目总数 */
  total: number;
  /** 新歌单名 */
  playlist: string;
  message: string;
}

export interface SaveOutcome {
  ok: boolean;
  message: string;
}

export interface RestoreOutcome {
  ok: boolean;
  tracks: number;
  favorites: number;
  playlists: number;
  message: string;
}

/** 备份文件里的曲目行（比 Track 少 id，避免恢复后 id 冲突） */
interface BackupTrack {
  uri: string;
  path: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  sampleRate: number;
  bitrate: number;
  suffix: string;
  size: number;
  mtime: number;
  coverPath: string;
  folder: string;
  rootPath: string;
  /** 旧备份没有这个字段，恢复时按本地处理 */
  source: string;
}

interface BackupSettings {
  theme: string;
  sort: string;
  view: string;
  mode: string;
  direct: boolean;
}

interface BackupFile {
  app: string;
  kind: string;
  version: number;
  createdAt: number;
  settings: BackupSettings;
  tracks: BackupTrack[];
  favorites: string[];
  recent: string[];
  playlists: PlaylistDump[];
}

/**
 * 迁移：歌单文件导入导出 + 整库备份恢复。
 *
 * 这一块解决的是"十年歌单"的焦虑，所以有三条硬约束：
 * 1. **不联网**：整个流程只在本地文件与沙箱之间搬字节；
 * 2. **不删文件**：恢复是合并（merge）不是覆盖，导入失败绝不改动现有歌单；
 * 3. **可解释**：命中几首、漏几首、为什么漏，都要如实报给用户，
 *    不能只弹一句"导入完成"—— 只导入了一半却不说，比失败更糟。
 */
export class MigrateService {

  // ---------------- 解析 ----------------

  /** M3U / M3U8 / PLS → 条目路径数组（保持文件里的顺序） */
  static parsePlaylist(text: string, ext: string): string[] {
    const out: string[] = [];
    const s: string = text.replace(/\r/g, '');
    if (ext.toLowerCase() === '.pls') {
      const rows: string[] = s.split('\n');
      for (const row of rows) {
        const t: string = row.trim();
        const eq: number = t.indexOf('=');
        if (eq <= 0) {
          continue;
        }
        const key: string = t.substring(0, eq).trim().toLowerCase();
        if (!key.startsWith('file')) {
          continue;
        }
        const v: string = t.substring(eq + 1).trim();
        if (v.length > 0) {
          out.push(v);
        }
      }
      return out;
    }
    const rows: string[] = s.split('\n');
    for (const row of rows) {
      const t: string = row.trim();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      out.push(t);
    }
    return out;
  }

  /** 从 #PLAYLIST:名字 / 文件名 里取一个歌单名 */
  static playlistNameOf(text: string, fileName: string): string {
    const rows: string[] = text.replace(/\r/g, '').split('\n');
    for (const row of rows) {
      const t: string = row.trim();
      if (t.toUpperCase().startsWith('#PLAYLIST:')) {
        const v: string = t.substring(10).trim();
        if (v.length > 0) {
          return v;
        }
      }
    }
    const dot: number = fileName.lastIndexOf('.');
    const base: string = dot > 0 ? fileName.substring(0, dot) : fileName;
    return base.length > 0 ? base : '导入的歌单';
  }

  /**
   * 条目 → 绝对路径。
   * 三件事必须做：file:// 转路径、反斜杠转正斜杠、百分号解码（中文文件名在 m3u 里常是 %E4%B8...）。
   */
  static toPath(entry: string): string {
    let s: string = entry.trim();
    if (s.startsWith('file://')) {
      try {
        s = new fileUri.FileUri(s).path;
      } catch (e) {
        s = s.substring(7);
      }
    }
    s = s.replace(/\\/g, '/');
    if (s.indexOf('%') >= 0) {
      try {
        s = decodeURIComponent(s);
      } catch (e) {
        // 不是合法编码就原样用，别为了"看起来对"把路径改坏
      }
    }
    return s;
  }

  // ---------------- 导入 ----------------

  static async importPlaylist(ctx: common.UIAbilityContext, onStep: (t: string) => void): Promise<ImportOutcome> {
    let uri: string = '';
    try {
      const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const opt: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['歌单文件 (.m3u, .m3u8, .pls)|.m3u,.m3u8,.pls'];
      const uris: string[] = await dp.select(opt);
      if (!uris || uris.length === 0) {
        return { ok: false, matched: 0, total: 0, playlist: '', message: '没有选择文件' };
      }
      uri = uris[0];
    } catch (e) {
      Logger.error(TAG, `pick playlist failed ${JSON.stringify(e)}`);
      return { ok: false, matched: 0, total: 0, playlist: '', message: '打开文件选择器失败，请重试' };
    }

    onStep('正在读取歌单…');
    let text: string = '';
    try {
      text = await MigrateService.readText(uri);
    } catch (e) {
      Logger.warn(TAG, `read playlist failed ${JSON.stringify(e)}`);
      return { ok: false, matched: 0, total: 0, playlist: '', message: '读不到这个文件，可能是编码或权限问题' };
    }
    const ext: string = MigrateService.extOf(uri);
    const entries: string[] = MigrateService.parsePlaylist(text, ext);
    if (entries.length === 0) {
      return { ok: false, matched: 0, total: 0, playlist: '', message: '文件里没有可识别的曲目条目' };
    }

    onStep(`正在匹配 ${entries.length} 首…`);
    const hits: string[] = await MigrateService.match(entries);
    if (hits.length === 0) {
      return {
        ok: false, matched: 0, total: entries.length, playlist: '',
        message: `${entries.length} 个条目一首都没匹配上：路径可能来自另一台设备`
      };
    }
    const name: string = MigrateService.playlistNameOf(text, MigrateService.baseName(uri));
    onStep('正在建立歌单…');
    await PlaylistStore.mergePlaylist(name, hits);
    const miss: number = entries.length - hits.length;
    return {
      ok: true,
      matched: hits.length,
      total: entries.length,
      playlist: name,
      message: miss === 0
        ? `「${name}」已建立，${hits.length} 首全部命中`
        : `「${name}」已建立：命中 ${hits.length} 首，${miss} 首在曲库里找不到`
    };
  }

  /**
   * 按路径匹配，逐级降级：
   * 1. 完整路径一致（同机导入 / 同目录结构）；
   * 2. 文件名唯一命中（换机、换根目录后最常见的形态）。
   * 不做"猜歌手和标题"的模糊匹配 —— 猜错会把歌单配成一锅粥，宁可留空。
   */
  private static async match(entries: string[]): Promise<string[]> {
    const idx: PathRow[] = await TrackStore.pathIndex(Const.SRC_LOCAL);
    const byPath: Map<string, string> = new Map<string, string>();
    const byBase: Map<string, string[]> = new Map<string, string[]>();
    for (const r of idx) {
      byPath.set(r.path, r.uri);
      const b: string = MigrateService.baseName(r.path).toLowerCase();
      const arr: string[] | undefined = byBase.get(b);
      if (arr === undefined) {
        byBase.set(b, [r.uri]);
      } else {
        arr.push(r.uri);
      }
    }
    const hits: string[] = [];
    for (const e of entries) {
      const p: string = MigrateService.toPath(e);
      if (p.length === 0 || p.startsWith('http')) {
        continue;
      }
      const exact: string | undefined = byPath.get(p);
      if (exact !== undefined) {
        hits.push(exact);
        continue;
      }
      const arr: string[] | undefined = byBase.get(MigrateService.baseName(p).toLowerCase());
      if (arr !== undefined && arr.length === 1) {
        hits.push(arr[0]);
      }
    }
    return hits;
  }

  // ---------------- 导出 ----------------

  /** 导出一个歌单为 .m3u（UTF-8，路径为绝对路径，别的播放器也能读） */
  static async exportM3u(ctx: common.UIAbilityContext, name: string,
    uris: string[]): Promise<SaveOutcome> {
    const all: Track[] = await TrackStore.listByUris(uris);
    // 示例唱片没有磁盘路径（path 为空），写进 m3u 就是一行空路径 ——
    // 别的播放器读到只会报错。导出前剔掉并如实报数。
    const tracks: Track[] = all.filter((t: Track) => t.path.length > 0);
    const skipped: number = all.length - tracks.length;
    if (tracks.length === 0) {
      return {
        ok: false,
        message: all.length === 0
          ? '这个歌单还是空的'
          : `这个歌单里的 ${all.length} 首都是示例唱片，没有可导出的文件路径`
      };
    }
    const text: string = MigrateService.buildM3u(name, tracks);
    const safe: string = MigrateService.safeName(name);
    const target: string = await MigrateService.savePick(ctx, `${safe}.m3u`, '.m3u');
    if (target.length === 0) {
      return { ok: false, message: '没有选择保存位置' };
    }
    try {
      const f: fs.File = await fs.open(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        await fs.write(f.fd, text);
      } finally {
        await fs.close(f);
      }
    } catch (e) {
      Logger.error(TAG, `write m3u failed ${JSON.stringify(e)}`);
      return { ok: false, message: '写入失败，换一个目录试试' };
    }
    Logger.info(TAG, `exported ${tracks.length} to ${target} skipped=${skipped}`);
    return {
      ok: true,
      message: skipped > 0
        ? `已导出 ${tracks.length} 首到 ${safe}.m3u（跳过 ${skipped} 首示例唱片）`
        : `已导出 ${tracks.length} 首到 ${safe}.m3u`
    };
  }

  static buildM3u(name: string, tracks: Track[]): string {
    let s: string = `#EXTM3U\n#PLAYLIST:${name}\n`;
    for (const t of tracks) {
      const sec: number = Math.max(0, Math.round(t.duration / 1000));
      const meta: string = t.artist.length > 0 ? `${t.artist} - ${t.title}` : t.title;
      s += `#EXTINF:${sec},${meta}\n${t.path}\n`;
    }
    return s;
  }

  // ---------------- 备份 ----------------

  /**
   * 备份成单个 zip：索引 + 歌单 + 收藏 + 设置，不含音频。
   *
   * 不含音频是刻意的：音频本来就在用户自己盘上，塞进备份只会让文件变成几个 GB，
   * 而"换机"真正会丢的是索引与歌单，不是文件本身。
   */
  static async backup(ctx: common.UIAbilityContext, onStep: (t: string) => void): Promise<SaveOutcome> {
    onStep('正在打包索引…');
    const tracks: Track[] = await TrackStore.dumpAll(Const.SRC_LOCAL);
    const demo: Track[] = await TrackStore.dumpAll(Const.SRC_DEMO);
    const favorites: string[] = await PlaylistStore.favoriteUris();
    const recent: string[] = await PlaylistStore.recentUris();
    const playlists: PlaylistDump[] = await PlaylistStore.allWithTracks();

    const file: BackupFile = {
      app: Const.APP_NAME,
      kind: 'backup',
      version: 1,
      createdAt: Date.now(),
      settings: {
        theme: SettingsService.theme(),
        sort: SettingsService.sort(),
        view: SettingsService.view(),
        mode: SettingsService.mode(),
        direct: SettingsService.direct()
      },
      tracks: MigrateService.toBackup(tracks.concat(demo)),
      favorites: favorites,
      recent: recent,
      playlists: playlists
    };

    const dir: string = `${ctx.cacheDir}/bk_src`;
    const zip: string = `${ctx.cacheDir}/${ZIP_IN}`;
    try {
      MigrateService.clearDir(dir);
      MigrateService.clearFile(zip);
      fs.mkdirSync(dir);
      const f: fs.File = fs.openSync(`${dir}/${BACKUP_NAME}`,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(file));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      Logger.error(TAG, `stage backup failed ${JSON.stringify(e)}`);
      return { ok: false, message: '准备备份文件失败' };
    }

    onStep('正在压缩…');
    try {
      await zlib.compressFile(dir, zip, { level: zlib.CompressLevel.COMPRESS_LEVEL_BEST_COMPRESSION });
    } catch (e) {
      Logger.error(TAG, `zip failed ${JSON.stringify(e)}`);
      return { ok: false, message: '压缩失败，可能是缓存空间不足' };
    }

    const target: string = await MigrateService.savePick(ctx, ZIP_IN, '.zip');
    if (target.length === 0) {
      return { ok: false, message: '没有选择保存位置' };
    }
    try {
      await MigrateService.copyFile(zip, target);
    } catch (e) {
      Logger.error(TAG, `copy zip failed ${JSON.stringify(e)}`);
      return { ok: false, message: '写入备份文件失败，换一个目录试试' };
    }
    Logger.info(TAG, `backup done: ${file.tracks.length} tracks, ${playlists.length} playlists`);
    return {
      ok: true,
      message: `已备份 ${file.tracks.length} 首索引 · ${playlists.length} 个歌单 · ${favorites.length} 条收藏`
    };
  }

  static async restore(ctx: common.UIAbilityContext, onStep: (t: string) => void): Promise<RestoreOutcome> {
    let uri: string = '';
    try {
      const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const opt: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['密纹备份 (.zip)|.zip'];
      const uris: string[] = await dp.select(opt);
      if (!uris || uris.length === 0) {
        return { ok: false, tracks: 0, favorites: 0, playlists: 0, message: '没有选择文件' };
      }
      uri = uris[0];
    } catch (e) {
      Logger.error(TAG, `pick backup failed ${JSON.stringify(e)}`);
      return { ok: false, tracks: 0, favorites: 0, playlists: 0, message: '打开文件选择器失败，请重试' };
    }

    onStep('正在解压…');
    const zip: string = `${ctx.cacheDir}/${ZIP_IN}`;
    const out: string = `${ctx.cacheDir}/bk_out`;
    let json: string = '';
    try {
      MigrateService.clearFile(zip);
      await MigrateService.copyFile(uri, zip);
      MigrateService.clearDir(out);
      fs.mkdirSync(out);
      await zlib.decompressFile(zip, out, { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION });
      json = MigrateService.findBackup(out);
    } catch (e) {
      Logger.error(TAG, `unzip failed ${JSON.stringify(e)}`);
      return { ok: false, tracks: 0, favorites: 0, playlists: 0, message: '解压失败：这不是密纹导出的备份文件' };
    }
    if (json.length === 0) {
      return {
        ok: false, tracks: 0, favorites: 0, playlists: 0,
        message: '压缩包里没找到 miwen-backup.json，不是密纹的备份'
      };
    }
    Logger.info(TAG, `backup json at ${json}`);

    onStep('正在恢复索引…');
    let data: BackupFile;
    let text: string = '';
    try {
      text = MigrateService.readTextPath(json);
    } catch (e) {
      Logger.error(TAG, `read backup failed ${JSON.stringify(e)} at ${json}`);
      return { ok: false, tracks: 0, favorites: 0, playlists: 0, message: '读不出备份内容，请重试' };
    }
    try {
      data = JSON.parse(text) as BackupFile;
    } catch (e) {
      Logger.error(TAG, `parse backup failed ${JSON.stringify(e)}`);
      return { ok: false, tracks: 0, favorites: 0, playlists: 0, message: '备份内容损坏，无法解析' };
    }
    if (data.kind !== 'backup' || data.tracks === undefined) {
      return { ok: false, tracks: 0, favorites: 0, playlists: 0, message: '备份格式不对，无法恢复' };
    }

    const tracks: Track[] = [];
    for (const b of data.tracks) {
      tracks.push(MigrateService.toTrack(b));
    }
    const n: number = await TrackStore.upsertMany(tracks);
    const fav: number = await PlaylistStore.mergeFavorites(data.favorites !== undefined ? data.favorites : []);
    if (data.recent !== undefined) {
      await PlaylistStore.mergeRecent(data.recent);
    }
    let pl: number = 0;
    if (data.playlists !== undefined) {
      for (const p of data.playlists) {
        const created: boolean = await PlaylistStore.mergePlaylist(p.name, p.uris);
        if (created) {
          pl++;
        }
      }
    }
    // 设置只恢复"看得见的偏好"，不碰 Pro 授权与根目录（前者是钱，后者绑设备）
    if (data.settings !== undefined) {
      SettingsService.setSort(data.settings.sort);
      SettingsService.setMode(data.settings.mode);
    }
    SettingsService.bumpLibrary();
    Logger.info(TAG, `restore done: tracks=${n} fav=${fav} playlists=${pl}`);
    return {
      ok: true,
      tracks: n,
      favorites: fav,
      playlists: pl,
      message: `已恢复 ${n} 首索引 · 新增 ${fav} 条收藏 · ${pl} 个新歌单`
    };
  }

  // ---------------- 工具 ----------------

  private static toBackup(tracks: Track[]): BackupTrack[] {
    const out: BackupTrack[] = [];
    for (const t of tracks) {
      out.push({
        uri: t.uri, path: t.path, title: t.title, artist: t.artist, album: t.album,
        duration: t.duration, sampleRate: t.sampleRate, bitrate: t.bitrate,
        suffix: t.suffix, size: t.size, mtime: t.mtime, coverPath: t.coverPath,
        folder: t.folder, rootPath: t.rootPath, source: t.source
      });
    }
    return out;
  }

  private static toTrack(b: BackupTrack): Track {
    return {
      id: 0,
      uri: b.uri,
      path: b.path,
      title: b.title !== undefined ? b.title : '',
      artist: b.artist !== undefined ? b.artist : '',
      album: b.album !== undefined ? b.album : '',
      duration: b.duration !== undefined ? b.duration : 0,
      sampleRate: b.sampleRate !== undefined ? b.sampleRate : 0,
      bitrate: b.bitrate !== undefined ? b.bitrate : 0,
      suffix: b.suffix !== undefined ? b.suffix : '',
      size: b.size !== undefined ? b.size : 0,
      mtime: b.mtime !== undefined ? b.mtime : 0,
      coverPath: b.coverPath !== undefined ? b.coverPath : '',
      folder: b.folder !== undefined ? b.folder : '',
      rootPath: b.rootPath !== undefined ? b.rootPath : '',
      // 来源必须原样带回来：示例唱片若被标成本地，就会混进真实曲库，播放走错路径
      source: b.source !== undefined && b.source.length > 0 ? b.source : Const.SRC_LOCAL,
      // CUE 分轨不入备份：.cue 是磁盘上的派生数据，重扫即可重建，备份里只存源头
      cueStart: -1,
      cueEnd: -1
    };
  }

  private static async savePick(ctx: common.UIAbilityContext, name: string, suffix: string): Promise<string> {
    try {
      const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const opt: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opt.newFileNames = [name];
      opt.fileSuffixChoices = [suffix];
      const uris: string[] = await dp.save(opt);
      return uris && uris.length > 0 ? uris[0] : '';
    } catch (e) {
      Logger.error(TAG, `save picker failed ${JSON.stringify(e)}`);
      return '';
    }
  }

  private static async readText(uri: string): Promise<string> {
    const f: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const st: fs.Stat = await fs.stat(f.fd);
      const size: number = Math.min(st.size, 4 * 1024 * 1024);
      const buf: ArrayBuffer = new ArrayBuffer(size);
      await fs.read(f.fd, buf, { offset: 0, length: size });
      return MigrateService.decode(buf);
    } finally {
      await fs.close(f);
    }
  }

  /** m3u 有 UTF-8 也有 GBK，两种都试：先 UTF-8，出现替换字符再退回 GB18030 */
  private static decode(buf: ArrayBuffer): string {
    const utf8: string = MigrateService.decodeAs(buf, 'utf-8');
    if (utf8.indexOf('\uFFFD') < 0) {
      return utf8;
    }
    const gbk: string = MigrateService.decodeAs(buf, 'gb18030');
    return gbk.length > 0 ? gbk : utf8;
  }

  private static decodeAs(buf: ArrayBuffer, enc: string): string {
    try {
      return util.TextDecoder.create(enc).decodeToString(new Uint8Array(buf));
    } catch (e) {
      return '';
    }
  }

  /** 逐块复制：只在这两个位置之间搬字节，不整文件读进内存 */
  private static async copyFile(src: string, dest: string): Promise<void> {
    const rf: fs.File = await fs.open(src, fs.OpenMode.READ_ONLY);
    const df: fs.File = await fs.open(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      const chunk: number = 64 * 1024;
      let pos: number = 0;
      while (true) {
        const buf: ArrayBuffer = new ArrayBuffer(chunk);
        const n: number = await fs.read(rf.fd, buf, { offset: pos, length: chunk });
        if (n <= 0) {
          break;
        }
        await fs.write(df.fd, n === chunk ? buf : buf.slice(0, n));
        pos += n;
      }
    } finally {
      await fs.close(rf);
      await fs.close(df);
    }
  }

  /**
   * 解压后先认固定文件名，再退回遍历。
   * listFileSync 在不同版本里返回的名字可能带相对前缀，所以每个候选都要真去 access 一次，
   * 光拼字符串会把「不存在的路径」当成结果，后面 readTextSync 就报 13900002。
   */
  private static findBackup(dir: string): string {
    const direct: string = `${dir}/${BACKUP_NAME}`;
    if (MigrateService.exist(direct)) {
      return direct;
    }
    const hits: string[] = [];
    try {
      const names: string[] = fs.listFileSync(dir, { recursion: true, filter: { suffix: ['.json'] } });
      Logger.info(TAG, `scan ${dir}: ${names.length} json -> ${names.join(' | ')}`);
      for (const n of names) {
        const full: string = n.startsWith('/') ? n : `${dir}/${n}`;
        if (MigrateService.exist(full)) {
          hits.push(full);
          continue;
        }
        const cut: number = n.lastIndexOf('/');
        const alt: string = `${dir}/${cut >= 0 ? n.substring(cut + 1) : n}`;
        if (MigrateService.exist(alt)) {
          hits.push(alt);
        }
      }
    } catch (e) {
      Logger.warn(TAG, `scan backup dir failed ${JSON.stringify(e)}`);
    }
    for (const p of hits) {
      if (p.indexOf(BACKUP_NAME) >= 0) {
        return p;
      }
    }
    return hits.length > 0 ? hits[0] : '';
  }

  private static exist(p: string): boolean {
    try {
      return fs.accessSync(p);
    } catch (e) {
      return false;
    }
  }

  private static readTextPath(p: string): string {
    const f: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
    try {
      const st: fs.Stat = fs.statSync(f.fd);
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      fs.readSync(f.fd, buf);
      return MigrateService.decode(buf);
    } finally {
      fs.closeSync(f);
    }
  }

  private static clearDir(dir: string): void {
    try {
      if (fs.accessSync(dir)) {
        fs.rmdirSync(dir);
      }
    } catch (e) {
      Logger.warn(TAG, `clear dir ${dir} failed`);
    }
  }

  private static clearFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      Logger.warn(TAG, `clear file ${path} failed`);
    }
  }

  static baseName(path: string): string {
    const p: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const i: number = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }

  private static extOf(uriOrPath: string): string {
    const p: string = MigrateService.toPath(uriOrPath);
    const dot: number = p.lastIndexOf('.');
    return dot > 0 ? p.substring(dot) : '';
  }

  /** 文件名里不能出现路径分隔符与冒号，否则系统会把它当目录 */
  private static safeName(name: string): string {
    return name.replace(/[/\\:*?"<>|]/g, '_');
  }
}
