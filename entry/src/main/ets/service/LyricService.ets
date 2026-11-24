import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Const } from '../common/Constants';
import { LrcLine, LrcParser } from '../common/Lrc';
import { Logger } from '../common/Logger';
import { Track } from '../model/Track';
import { decodeTags, id3TagBytes } from './TagCodec';
import { DemoLibrary } from './DemoLibrary';
import { SettingsService } from './SettingsService';

const TAG: string = 'LyricService';

/** 歌词来源 */
export const LRC_NONE: string = 'none';
export const LRC_FILE: string = 'lrc';
export const LRC_EMBED: string = 'embed';

/** 一次取词的结果：有时间轴的用 lines，纯文本用 plain */
export interface LyricDoc {
  lines: LrcLine[];
  plain: string[];
  source: string;
  /** 假 = 有词但没有时间轴，不能逐行高亮 */
  synced: boolean;
  hasTrans: boolean;
  /** 原始 LRC 文本（仅 synced 时有值），给 AVSession 系统桌面歌词用 */
  raw: string;
  /**
   * CUE 虚拟轨专用：磁盘上确实有整轨 LRC，但**这一轨的时间窗内一句词都没有**。
   * 与「压根没有歌词」不是一回事，页面要分开说，否则用户会以为读词失败。
   */
  cueEmpty: boolean;
}

/**
 * 歌词服务。
 *
 * 三条取词顺序，先本地后文件内嵌，永不联网：
 * 1. 同名 .lrc（最准，用户自己放过）；
 * 2. 文件内嵌（ID3 USLT / FLAC LYRICS）—— 这是"老歌歌词常嵌在标签里"的正解；
 * 3. 示例曲目自带的几行示例词（只用于验收）。
 *
 * 偏移是**按曲目**记的：同一批文件里，往往只有那一张专辑的轴是歪的，
 * 做一个全局偏移刻度盘，会让用户每换一首都要重调一次。
 */
export class LyricService {
  static readonly STEP: number = 500;
  static readonly MAX: number = 5000;
  /** 读内嵌歌词时最多读多少：封面再大也不能把内存撑爆 */
  private static readonly MAX_TAG: number = 8 * 1024 * 1024;
  private static readonly FIRST: number = 16 * 1024;

  static empty(): LyricDoc {
    return {
      lines: [], plain: [], source: LRC_NONE, synced: false, hasTrans: false, raw: '', cueEmpty: false
    };
  }

  static async load(t: Track | null, pro: boolean): Promise<LyricDoc> {
    if (t === null) {
      return LyricService.empty();
    }
    let text: string = '';
    let source: string = LRC_NONE;

    if (t.uri.startsWith(Const.DEMO_SCHEME)) {
      text = DemoLibrary.lrcFor(t.uri);
      if (text.length > 0) {
        source = LRC_FILE;
      }
    } else {
      const dot: number = t.path.lastIndexOf('.');
      const lrcPath: string = dot > 0 ? `${t.path.substring(0, dot)}.lrc` : '';
      try {
        if (lrcPath.length > 0 && fs.accessSync(lrcPath)) {
          text = fs.readTextSync(lrcPath);
          source = LRC_FILE;
        }
      } catch (e) {
        Logger.warn(TAG, `lrc read failed ${JSON.stringify(e)}`);
      }
      // 内嵌歌词读取算 Pro：文件内嵌解析要按标签长度读全量头部，成本明显高于读一个 .lrc
      if (text.length === 0 && pro) {
        text = await LyricService.embedded(t);
        if (text.length > 0) {
          source = LRC_EMBED;
        }
      }
    }

    const doc: LyricDoc = LyricService.empty();
    doc.source = source;
    if (text.length === 0) {
      return doc;
    }
    if (LrcParser.isTimed(text)) {
      // CUE 虚拟轨：同名 .lrc 是整轨的，轴相对文件头，而 position 相对片头（cueStart）。
      // 不裁窗就会三轨同唱第 1 行（真机验证报告 11.7）。裁在解析之前，
      // doc.raw 也跟着变成裁剪后的文本 —— 桌面歌词整份推送与逐行推送才同一个坐标系。
      if (t.cueStart >= 0) {
        text = LrcParser.slice(text, t.cueStart, t.cueEnd);
        if (text.length === 0) {
          // 这一轨的时间窗里一句词都没有：按无词处理，走清词分支，不残留上一轨的词
          doc.cueEmpty = true;
          Logger.info(TAG, `cue lrc empty in [${t.cueStart},${t.cueEnd})`);
          return doc;
        }
      }
      doc.lines = LrcParser.parse(text);
      doc.synced = doc.lines.length > 0;
      doc.raw = text;
      doc.hasTrans = pro && LrcParser.hasTrans(doc.lines);
      if (!doc.hasTrans) {
        // 未解锁时不留半截译文：要么整行双语，要么就是单语，不能出现"只有几句有译文"
        for (const l of doc.lines) {
          l.trans = '';
        }
      }
    } else {
      doc.plain = LrcParser.parsePlain(text);
      doc.synced = false;
    }
    return doc;
  }

  // ---------------- 内嵌歌词 ----------------

  /**
   * 从文件里读内嵌歌词。
   *
   * 关键在"读多少"：标签长度写在 ID3 头里，封面常有两三百 KB，
   * 歌词帧往往排在封面之后 —— 固定读 1MB 会漏。所以先读头算出总长，
   * 再决定读多少（上限 8MB，防止畸形文件把内存吃光）。
   */
  static async embedded(t: Track): Promise<string> {
    if (t.path.length === 0) {
      return '';
    }
    let file: fs.File | null = null;
    try {
      file = await fs.open(t.path, fs.OpenMode.READ_ONLY);
      const head: ArrayBuffer = new ArrayBuffer(Math.min(t.size > 0 ? t.size : LyricService.FIRST, LyricService.FIRST));
      const n: number = await fs.read(file.fd, head, { offset: 0, length: head.byteLength });
      const bytes: Uint8Array = new Uint8Array(head, 0, n);
      const suffix: string = t.suffix.length > 0 ? t.suffix : LyricService.suffixOf(t.path);
      let want: number = LyricService.FIRST;
      if (suffix.toLowerCase() !== '.flac') {
        const tagBytes: number = id3TagBytes(bytes);
        if (tagBytes <= 0) {
          return '';
        }
        want = Math.min(tagBytes, LyricService.MAX_TAG);
      } else {
        // FLAC 的 VORBIS_COMMENT 紧跟 STREAMINFO，前 1MB 足够
        want = Math.min(t.size > 0 ? t.size : LyricService.FIRST, 1024 * 1024);
      }
      if (want > n) {
        const full: ArrayBuffer = new ArrayBuffer(want);
        // 已读到的先拷进去，避免同一个 fd 再从头读一遍
        new Uint8Array(full).set(bytes);
        await fs.read(file.fd, full, { offset: n, length: want - n });
        const tag = decodeTags(full, suffix);
        return tag.lyric;
      }
      const tag = decodeTags(head.slice(0, n), suffix);
      return tag.lyric;
    } catch (e) {
      Logger.warn(TAG, `embedded lyric failed ${JSON.stringify(e)}`);
      return '';
    } finally {
      if (file !== null) {
        await fs.close(file);
      }
    }
  }

  private static suffixOf(path: string): string {
    const dot: number = path.lastIndexOf('.');
    return dot > 0 ? path.substring(dot) : '';
  }

  // ---------------- 偏移 ----------------

  static offset(uri: string): number {
    const v: number = parseInt(SettingsService.getStr(LyricService.keyOf(uri), '0'), 10);
    return isNaN(v) ? 0 : v;
  }

  /** 正数 = 歌词推迟显示。夹在 ±5 秒，再大就不是"微调"了 */
  static bump(uri: string, delta: number): number {
    const next: number = Math.max(-LyricService.MAX, Math.min(LyricService.MAX,
      LyricService.offset(uri) + delta));
    SettingsService.setStr(LyricService.keyOf(uri), next.toString());
    return next;
  }

  static reset(uri: string): void {
    SettingsService.setStr(LyricService.keyOf(uri), '0');
  }

  static fmtOffset(ms: number): string {
    if (ms === 0) {
      return '0';
    }
    const sign: string = ms > 0 ? '+' : '−';
    const abs: number = Math.abs(ms);
    return `${sign}${(abs / 1000).toFixed(1)}s`;
  }

  /** 用 uri 的散列做键：uri 很长（file://docs/...），直接当 key 会让 preferences 膨胀 */
  private static keyOf(uri: string): string {
    let h: number = 5381;
    for (let i = 0; i < uri.length; i++) {
      h = ((h << 5) + h + uri.charCodeAt(i)) & 0x7fffffff;
    }
    return `lrc_off_${h.toString(16)}`;
  }

  // ---------------- 自检 ----------------

  /**
   * 歌词链路自检：造一个带 USLT 帧的 ID3v2.3 文件，再走真实的"打开文件 → 解析标签"路径。
   *
   * 为什么要造文件：设备上现成的曲目不一定带歌词，而"读内嵌歌词"这条路径
   * 如果只在代码里看着对，等于没验。这个自检把"字节 → 帧 → 文本"整条链跑一遍，
   * 结果写在设置页和 hilog 里，用户自己也能复现。
   */
  static async selfCheck(ctx: common.Context): Promise<string> {
    const lyric: string = '[00:00.50]自检歌词第一行\n[00:01.50]self check line two\n[00:02.50]双语测试行\n';
    const bytes: Uint8Array = LyricService.buildId3(lyric);
    const path: string = `${ctx.cacheDir}/lyric_probe.mp3`;
    const file: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer.slice(0, bytes.length) as ArrayBuffer);
    } finally {
      fs.closeSync(file);
    }
    const t: Track = {
      id: -1, uri: `file://${path}`, path: path, title: 'probe', artist: '', album: '',
      duration: 0, sampleRate: 0, bitrate: 0, suffix: '.mp3', size: bytes.length, mtime: 0,
      coverPath: '', folder: '', rootPath: '', source: Const.SRC_LOCAL, cueStart: -1, cueEnd: -1
    };
    const got: string = await LyricService.embedded(t);
    const lines: LrcLine[] = LrcParser.parse(got);
    const ok: boolean = lines.length === 3;
    const trans: boolean = LrcParser.hasTrans(lines);
    Logger.info(TAG, `lyric self check: ${lines.length} lines, trans=${trans}, ok=${ok}`);
    if (!ok) {
      return `内嵌歌词读取失败（${got.length} 字节）`;
    }
    return `内嵌 ✓ ${lines.length} 行${trans ? ' · 双语 ✓' : ''}`;
  }

  /** 拼一个最小可用的 ID3v2.3：TIT2 + USLT，编码统一 UTF-8 */
  private static buildId3(lyric: string): Uint8Array {
    const enc: util.TextEncoder = new util.TextEncoder();
    const title: Uint8Array = enc.encodeInto('lyric probe');
    const body: Uint8Array = enc.encodeInto(lyric);

    const tit2: Uint8Array = LyricService.frame('TIT2', LyricService.concat(
      new Uint8Array([3]), title));
    const uslt: Uint8Array = LyricService.frame('USLT', LyricService.concat(
      new Uint8Array([3, 0x65, 0x6E, 0x67, 0]), body));

    const frames: Uint8Array = LyricService.concat(tit2, uslt);
    const head: Uint8Array = new Uint8Array(10);
    head[0] = 0x49;
    head[1] = 0x44;
    head[2] = 0x33;
    head[3] = 3;
    const size: number = frames.length;
    head[6] = (size >> 21) & 0x7f;
    head[7] = (size >> 14) & 0x7f;
    head[8] = (size >> 7) & 0x7f;
    head[9] = size & 0x7f;
    return LyricService.concat(head, frames);
  }

  private static frame(id: string, body: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(10 + body.length);
    for (let i = 0; i < 4; i++) {
      out[i] = id.charCodeAt(i);
    }
    out[4] = (body.length >> 24) & 0xff;
    out[5] = (body.length >> 16) & 0xff;
    out[6] = (body.length >> 8) & 0xff;
    out[7] = body.length & 0xff;
    out.set(body, 10);
    return out;
  }

  private static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }
}

