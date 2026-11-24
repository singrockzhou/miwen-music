import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Track } from '../model/Track';
import { TrackStore } from '../db/TrackStore';

const TAG: string = 'CueService';

/** 一条 CUE 轨：起止时间片 + 标签 */
export interface CueEntry {
  no: number;
  title: string;
  performer: string;
  startMs: number;
  /** -1 = 到文件自然结束（由最后一轨兜底） */
  endMs: number;
}

/** 一张 CUE：对应一个音频文件 */
export interface CueSheet {
  file: string;
  album: string;
  albumArtist: string;
  tracks: CueEntry[];
}

/**
 * CUE 整轨分轨（密纹 Pro）。
 *
 * 一张整轨 FLAC/WAV + 一个 CUE 是发烧友标准收藏形态。
 * 解析 CUE 只是文本处理，真正的分轨是"虚拟轨"：
 * 每条轨仍然指向整轨文件，只是带上起止时间片，播放时由内核 seek 定位。
 * 这样不产生任何文件副本，也不要求系统解码器支持整轨拆分。
 *
 * 只认 INDEX 01（轨起点）；INDEX 00 是 pregap，不参与分段。
 * 末轨的 endMs 留 -1，播放到文件自然结束。
 */
export class CueService {
  /** 解析 CUE 文本。解析不出任何轨返回 null，绝不 throw */
  static parse(text: string): CueSheet | null {
    const sheet: CueSheet = { file: '', album: '', albumArtist: '', tracks: [] };
    let cur: CueEntry | null = null;
    const lines: string[] = text.split(/\r?\n/);
    for (const raw of lines) {
      const line: string = raw.trim();
      if (line.length === 0 || line.startsWith('REM')) {
        continue;
      }
      const sp: number = line.indexOf(' ');
      if (sp <= 0) {
        continue;
      }
      const key: string = line.substring(0, sp).toUpperCase();
      // 值去掉两侧引号
      let val: string = line.substring(sp + 1).trim();
      if (val.startsWith('"')) {
        const end: number = val.indexOf('"', 1);
        val = end > 0 ? val.substring(1, end) : val.substring(1);
      } else {
        const sp2: number = val.indexOf(' ');
        if (sp2 > 0) {
          val = val.substring(0, sp2); // TRACK 01 AUDIO / INDEX 01 1:23:45
        }
      }
      if (key === 'FILE') {
        sheet.file = val;
        continue;
      }
      if (key === 'PERFORMER') {
        if (cur === null) {
          sheet.albumArtist = val;
        } else {
          cur.performer = val;
        }
        continue;
      }
      if (key === 'TITLE') {
        if (cur === null) {
          sheet.album = val;
        } else {
          cur.title = val;
        }
        continue;
      }
      if (key === 'TRACK') {
        const no: number = parseInt(val, 10);
        cur = { no: isNaN(no) ? sheet.tracks.length + 1 : no, title: '', performer: '', startMs: -1, endMs: -1 };
        sheet.tracks.push(cur);
        continue;
      }
      if (key === 'INDEX' && cur !== null) {
        // 只有 INDEX 01 是轨起点；INDEX 00 是 pregap
        const rest: string = line.substring(line.lastIndexOf(' ') + 1).trim();
        const ms: number = CueService.cueTimeToMs(rest);
        if (ms >= 0) {
          cur.startMs = ms;
        }
        continue;
      }
    }
    // 校验：有文件、有轨、每轨都有起点；前轨终点 = 后轨起点
    if (sheet.file.length === 0 || sheet.tracks.length === 0) {
      return null;
    }
    for (let i = 0; i < sheet.tracks.length; i++) {
      if (sheet.tracks[i].startMs < 0) {
        return null;
      }
      if (i > 0) {
        sheet.tracks[i - 1].endMs = sheet.tracks[i].startMs;
      }
    }
    return sheet;
  }

  /** mm:ss:ff（ff 为 1/75 秒）→ 毫秒；容忍 mm:ss 与纯秒 */
  private static cueTimeToMs(s: string): number {
    const parts: string[] = s.split(':');
    if (parts.length < 2) {
      return -1;
    }
    const mm: number = parseInt(parts[0], 10);
    const ss: number = parseInt(parts[1], 10);
    const ff: number = parts.length > 2 ? parseInt(parts[2], 10) : 0;
    if (isNaN(mm) || isNaN(ss)) {
      return -1;
    }
    return (mm * 60 + ss) * 1000 + (isNaN(ff) ? 0 : Math.round(ff * 1000 / 75));
  }

  /** CUE 文本解码：UTF-8 失败退 GB18030（国内老 CUE 多是 GBK） */
  static decode(buf: ArrayBuffer): string {
    try {
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } catch (e) {
      try {
        return util.TextDecoder.create('gb18030').decodeToString(new Uint8Array(buf));
      } catch (e2) {
        return '';
      }
    }
  }

  /**
   * 扫一个根目录下的全部 CUE，为每张配对的整轨生成虚拟轨入库。
   * 单张失败不影响下一张；返回生成的虚拟轨数。
   */
  static async scanCues(rootPath: string): Promise<number> {
    let added: number = 0;
    let cueFiles: string[] = [];
    try {
      cueFiles = await fs.listFile(rootPath, {
        recursion: true,
        listNum: 0,
        filter: { suffix: [Const.CUE_SUFFIX] }
      });
    } catch (e) {
      Logger.warn(TAG, `list cue failed ${JSON.stringify(e)}`);
      return 0;
    }
    for (const rel of cueFiles) {
      try {
        added += await CueService.handleOne(rootPath, rel);
      } catch (e) {
        Logger.warn(TAG, `cue ${rel} failed ${JSON.stringify(e)}`);
      }
    }
    if (added > 0) {
      Logger.info(TAG, `cue scan: ${cueFiles.length} sheets, ${added} virtual tracks`);
    }
    return added;
  }

  private static async handleOne(rootPath: string, rel: string): Promise<number> {
    const base: string = rootPath.endsWith('/') ? rootPath.substring(0, rootPath.length - 1) : rootPath;
    const cuePath: string = `${base}/${rel.startsWith('/') ? rel.substring(1) : rel}`;
    const stat: fs.Stat = fs.statSync(cuePath);
    if (stat.size <= 0 || stat.size > 1024 * 1024) {
      return 0;
    }
    const file: fs.File = fs.openSync(cuePath, fs.OpenMode.READ_ONLY);
    let text: string = '';
    try {
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      text = CueService.decode(buf);
    } finally {
      fs.closeSync(file);
    }
    const sheet: CueSheet | null = CueService.parse(text);
    if (sheet === null) {
      Logger.warn(TAG, `cue not parseable: ${rel}`);
      return 0;
    }
    // FILE 行是相对 cue 所在目录的路径（也可能带子目录、反斜杠）。
    // 三级配对：同目录 → 同目录纯文件名 → 按文件名全根兜底（部分设备的文件
    // 传输会把目标目录化，cue 与音频往往不落在同一层，按 FILE 行硬配必失败）。
    const cueDir: string = cuePath.substring(0, cuePath.lastIndexOf('/') + 1);
    const fname: string = sheet.file.replace(/\\/g, '/').substring(sheet.file.replace(/\\/g, '/').lastIndexOf('/') + 1);
    let audio: Track | null = null;
    const tryPaths: string[] = [cueDir + sheet.file.replace(/\\/g, '/'), cueDir + fname];
    for (const ap of tryPaths) {
      try {
        if (fs.accessSync(ap)) {
          audio = await TrackStore.findByPath(ap);
          if (audio !== null) {
            break;
          }
        }
      } catch (e) {
        // 该候选路径不可访问，试下一个
      }
    }
    if (audio === null) {
      audio = await TrackStore.findByBaseName(fname);
    }
    if (audio === null) {
      // 整轨还没扫进来（cue 先于音频处理、或音频在别的根），下一轮重扫会补上
      Logger.warn(TAG, `cue audio not indexed yet: ${sheet.file}`);
      return 0;
    }
    let n: number = 0;
    for (let i = 0; i < sheet.tracks.length; i++) {
      const e: CueEntry = sheet.tracks[i];
      const t: Track = {
        id: 0,
        // uri 带轨号保证唯一且稳定；重复扫不产生重复行
        uri: `${audio.uri}?cue=${i + 1}`,
        path: audio.path,
        title: e.title.length > 0 ? e.title : `${audio.title} · 第 ${i + 1} 轨`,
        artist: e.performer.length > 0 ? e.performer : (sheet.albumArtist.length > 0 ? sheet.albumArtist : audio.artist),
        album: sheet.album.length > 0 ? sheet.album : audio.album,
        // 时长未知时先 0，起播后由内核按时间片回填
        duration: e.endMs > e.startMs ? e.endMs - e.startMs : 0,
        sampleRate: audio.sampleRate,
        bitrate: audio.bitrate,
        suffix: audio.suffix,
        size: audio.size,
        mtime: audio.mtime,
        coverPath: audio.coverPath,
        folder: audio.folder,
        rootPath: audio.rootPath,
        source: audio.source,
        cueStart: e.startMs,
        cueEnd: e.endMs
      };
      await TrackStore.upsert(t);
      n++;
    }
    return n;
  }
}
