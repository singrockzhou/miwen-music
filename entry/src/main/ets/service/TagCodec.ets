import { util } from '@kit.ArkTS';
import { RawTag, emptyTag } from '../model/Track';

/**
 * 标签解析实现（普通模块，不跑在 taskpool 里）。
 *
 * 单独拆出来的原因很硬：@Concurrent 函数只允许使用"导入的变量或局部变量"，
 * 同文件里的普通函数不算，编译期直接报 "Concurrent function should only use import variable"。
 *
 * 系统不提供音频标签 API，只能自己解。
 *
 * 设计原则：
 * 1. 永不 throw —— 解析失败就返回空标签，用文件名兜底；
 * 2. 只读文件头部（默认 1MB），够覆盖 ID3 头 + 常见内嵌封面；
 * 3. 放在 taskpool 里跑（@Concurrent 顶层函数），主线程只管 IO。
 *
 * P0 支持：ID3v2.3/2.4（MP3）、FLAC 的 STREAMINFO + VORBIS_COMMENT。
 * MP4/M4A 的 ilst 与 APE 的 APEv2 留给 P1；解析不出来时用文件名兜底，
 * UI 上不会出现空白行。
 */

export function decodeTags(buf: ArrayBuffer, suffix: string): RawTag {
  const bytes: Uint8Array = new Uint8Array(buf);
  const s: string = suffix.toLowerCase();
  if (s === '.flac') {
    return parseFlac(bytes);
  }
  return parseId3(bytes);
}

// ---------------- ID3v2 ----------------

function parseId3(buf: Uint8Array): RawTag {
  const tag: RawTag = emptyTag();
  if (buf.length < 10) {
    return tag;
  }
  if (!(buf[0] === 0x49 && buf[1] === 0x44 && buf[2] === 0x33)) { // 'ID3'
    return tag;
  }
  const ver: number = buf[3];
  const flags: number = buf[5];
  const tagSize: number = ver >= 4 ? syncSafe(buf, 6) : be32(buf, 6);
  let pos: number = 10;
  if ((flags & 0x10) !== 0) {
    pos += 10; // footer
  }
  const end: number = Math.min(buf.length, 10 + tagSize);
  const idLen: number = ver <= 2 ? 3 : 4; // v2.2 的帧 id 只有 3 字节
  const headLen: number = ver <= 2 ? 6 : 10;

  while (pos + headLen <= end) {
    let id: string = '';
    for (let i = 0; i < idLen; i++) {
      id += String.fromCharCode(buf[pos + i]);
    }
    if (buf[pos] === 0) {
      break; // padding
    }
    let frameSize: number = 0;
    if (ver <= 2) {
      frameSize = (buf[pos + 3] << 16) | (buf[pos + 4] << 8) | buf[pos + 5];
    } else if (ver >= 4) {
      frameSize = syncSafe(buf, pos + 4);
    } else {
      frameSize = be32(buf, pos + 4);
    }
    const bodyStart: number = pos + headLen;
    if (frameSize <= 0 || bodyStart + frameSize > buf.length) {
      break;
    }
    const body: Uint8Array = buf.subarray(bodyStart, bodyStart + frameSize);

    if (id === 'TIT2' || id === 'TT2') {
      tag.title = readTextFrame(body);
    } else if (id === 'TPE1' || id === 'TP1') {
      tag.artist = readTextFrame(body);
    } else if (id === 'TALB' || id === 'TAL') {
      tag.album = readTextFrame(body);
    } else if (id === 'USLT' || id === 'ULT') {
      // 非同步歌词：很多老 MP3 的歌词只有内嵌这一份，磁盘上没有同名 .lrc
      const ly: string = readUslt(body);
      if (ly.length > 0) {
        tag.lyric = ly;
      }
    } else if (id === 'APIC' || id === 'PIC') {
      const pic: PicResult | null = readApic(body, ver);
      if (pic !== null) {
        tag.cover = pic.data;
        tag.coverMime = pic.mime;
      }
    }
    pos = bodyStart + frameSize;
  }
  return tag;
}

function syncSafe(b: Uint8Array, off: number): number {
  return ((b[off] & 0x7f) << 21) | ((b[off + 1] & 0x7f) << 14) |
    ((b[off + 2] & 0x7f) << 7) | (b[off + 3] & 0x7f);
}

function be32(b: Uint8Array, off: number): number {
  return ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) >>> 0;
}

function decode(enc: string, data: Uint8Array): string {
  try {
    return util.TextDecoder.create(enc).decodeToString(data);
  } catch (e) {
    return '';
  }
}

function readTextFrame(body: Uint8Array): string {
  if (body.length < 2) {
    return '';
  }
  const enc: number = body[0];
  const data: Uint8Array = body.subarray(1);
  let text: string = '';
  if (enc === 0) {
    // 中文 MP3 大量是 GBK 冒充 ISO-8859-1，先试 GB18030 再退 UTF-8
    text = decode('gb18030', data);
    if (text.length === 0) {
      text = decode('utf-8', data);
    }
  } else if (enc === 1) {
    const le: boolean = data.length > 1 && data[0] === 0xFF && data[1] === 0xFE;
    text = le ? decode('utf-16le', data.subarray(2)) : decode('utf-16be', data.subarray(2));
  } else if (enc === 2) {
    text = decode('utf-16be', data);
  } else {
    text = decode('utf-8', data);
  }
  return clean(text);
}

interface PicResult {
  mime: string;
  data: Uint8Array;
}

/**
 * USLT 帧：编码(1) + 语言(3) + 内容描述(以 \0 结尾) + 歌词正文。
 * 描述串的终止符宽度跟着编码走：UTF-16 是两字节 00 00，其余是一字节 00。
 */
function readUslt(body: Uint8Array): string {
  if (body.length < 4) {
    return '';
  }
  const enc: number = body[0];
  let i: number = 4; // 编码 1 + 语言 3
  const term: number = enc === 1 || enc === 2 ? 2 : 1;
  // 先跳过内容描述（不少写入器会填"lyrics"或空串）
  while (i + term <= body.length) {
    if (body[i] === 0 && (term === 1 || body[i + 1] === 0)) {
      i += term;
      break;
    }
    i++;
  }
  if (i >= body.length) {
    return '';
  }
  const text: Uint8Array = body.subarray(i);
  let s: string = '';
  if (enc === 1) {
    const le: boolean = text.length > 1 && text[0] === 0xFF && text[1] === 0xFE;
    s = le ? decode('utf-16le', text.subarray(2)) : decode('utf-16be', text.subarray(2));
  } else if (enc === 2) {
    s = decode('utf-16be', text);
  } else if (enc === 0) {
    s = decode('gb18030', text);
    if (s.length === 0) {
      s = decode('utf-8', text);
    }
  } else {
    s = decode('utf-8', text);
  }
  return s.replace(/\u0000/g, '').trim();
}

/**
 * 整个 ID3v2 标签的字节长度（含 10 字节头），0 表示不是 ID3。
 *
 * 需要它的原因很具体：封面常常几百 KB，歌词帧排在封面后面。
 * 只读固定 1MB 会漏掉歌词，所以先看头里的长度再决定读多少。
 */
export function id3TagBytes(buf: Uint8Array): number {
  if (buf.length < 10 || !(buf[0] === 0x49 && buf[1] === 0x44 && buf[2] === 0x33)) {
    return 0;
  }
  const ver: number = buf[3];
  const size: number = ver >= 4 ? syncSafe(buf, 6) : be32(buf, 6);
  return 10 + size;
}

function readApic(body: Uint8Array, ver: number): PicResult | null {
  if (body.length < 4) {
    return null;
  }
  const enc: number = body[0];
  let i: number = 1;
  let mime: string = '';
  if (ver <= 2) {
    // v2.2 的 PIC：格式固定 3 字节（JPG/PNG）
    mime = 'image/jpeg';
    i = 4;
  } else {
    let start: number = 1;
    while (i < body.length && body[i] !== 0) {
      i++;
    }
    mime = ascii(body, start, i);
    i++; // 跳过 \0
  }
  i++; // picture type
  const term: number = enc === 1 || enc === 2 ? 2 : 1;
  while (i + term <= body.length) {
    if (body[i] === 0 && (term === 1 || body[i + 1] === 0)) {
      i += term;
      break;
    }
    i++;
  }
  if (i >= body.length) {
    return null;
  }
  return { mime: mime.length > 0 ? mime : 'image/jpeg', data: body.subarray(i) };
}

function ascii(b: Uint8Array, from: number, to: number): string {
  let s: string = '';
  for (let i = from; i < to; i++) {
    s += String.fromCharCode(b[i]);
  }
  return s;
}

// ---------------- FLAC ----------------

function parseFlac(buf: Uint8Array): RawTag {
  const tag: RawTag = emptyTag();
  if (buf.length < 8 || buf[0] !== 0x66 || buf[1] !== 0x4C) { // 'fLaC'
    return tag;
  }
  let pos: number = 4;
  while (pos + 4 <= buf.length) {
    const head: number = buf[pos];
    const last: boolean = (head & 0x80) !== 0;
    const type: number = head & 0x7F;
    const len: number = (buf[pos + 1] << 16) | (buf[pos + 2] << 8) | buf[pos + 3];
    const bodyStart: number = pos + 4;
    if (bodyStart + len > buf.length) {
      break;
    }
    if (type === 0 && len >= 18) {
      // STREAMINFO：采样率占第 10~12 字节的高 20 位
      const b: Uint8Array = buf.subarray(bodyStart, bodyStart + 18);
      tag.sampleRate = ((b[10] << 12) | (b[11] << 4) | (b[12] >> 4)) >>> 0;
    } else if (type === 4) {
      const b: Uint8Array = buf.subarray(bodyStart, bodyStart + len);
      let p: number = 0;
      const vendorLen: number = be32(b, p);
      p += 4 + vendorLen;
      if (p + 4 > b.length) {
        break;
      }
      const count: number = be32(b, p);
      p += 4;
      for (let k = 0; k < count && p + 4 <= b.length; k++) {
        const itemLen: number = be32(b, p);
        p += 4;
        if (p + itemLen > b.length) {
          break;
        }
        const item: string = decode('utf-8', b.subarray(p, p + itemLen));
        const eq: number = item.indexOf('=');
        if (eq > 0) {
          const key: string = item.substring(0, eq).toUpperCase();
          const val: string = clean(item.substring(eq + 1));
          if (key === 'TITLE') {
            tag.title = val;
          } else if (key === 'ARTIST') {
            tag.artist = val;
          } else if (key === 'ALBUM') {
            tag.album = val;
          } else if (key === 'LYRICS' || key === 'UNSYNCEDLYRICS' || key === 'UNSYNCED LYRICS' ||
            key === 'LYRIC') {
            // 不同写入器用的键不同：foobar 写 LYRICS，Kid3 写 UNSYNCEDLYRICS
            if (val.length > 0) {
              tag.lyric = val;
            }
          }
        }
        p += itemLen;
      }
    }
    pos = bodyStart + len;
    if (last) {
      break;
    }
  }
  return tag;
}

function clean(s: string): string {
  return s.replace(/\u0000/g, '').trim();
}
