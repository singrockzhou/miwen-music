import { Const } from '../common/Constants';
import { Track } from '../model/Track';
import { TrackStore } from '../db/TrackStore';
import { Logger } from '../common/Logger';

const TAG: string = 'DemoLibrary';

/**
 * 示例曲库。
 *
 * 存在的意义：鸿蒙拿不到全盘音乐，用户第一次打开时曲库必然是空的。
 * 空屏既没法验收播放器，也没法验收列表与封面墙——所以内置一小份"唱片"，
 * 让所有交互在没有任何本地文件时也能走通。
 *
 * 三条自我约束：
 * 1. 数据完全本地、写死，不联网、不内置任何真实音频；
 * 2. 示例曲目 uri 用 demo:// 前缀，PlayerCore 据此走计时器引擎，不碰 AVPlayer；
 * 3. 设置页可一键清空，真实目录扫描完成后自动切回 local。
 */
interface DemoSpec {
  title: string;
  artist: string;
  album: string;
  /** 秒 */
  seconds: number;
  rate: number;
  suffix: string;
  lrc: string;
}

const BASE_MTIME: number = 1732000000000;

function s(title: string, artist: string, album: string, seconds: number,
  rate: number, suffix: string, lrc: string): DemoSpec {
  return { title: title, artist: artist, album: album, seconds: seconds, rate: rate, suffix: suffix, lrc: lrc };
}

const SPECS: DemoSpec[] = [
  // 《沟槽》—— 整张都在讲"针落下去"这件事
  s('落针', '密纹室内乐团', '沟槽', 262, 96000, '.flac',
    '[00:00.00]密纹音乐 · 示例唱片\n[00:06.00]唱针落下之前，房间是静的\n[00:18.00]第一圈沟槽里藏着上一年的雨\n[00:34.00]我们把它转成 33 又三分之一\n[00:52.00]慢慢听，不着急\n[01:10.00]— 示例歌词 · 仅用于演示滚动 —'),
  s('一圈半', '密纹室内乐团', '沟槽', 214, 96000, '.flac',
    '[00:00.00]一圈半之后才听见人声\n[00:16.00]像有人在隔壁翻一本旧书\n[00:40.00]页脚折了角，就不再有下文'),
  s('沟槽里的雨', '密纹室内乐团', '沟槽', 298, 192000, '.flac', ''),
  s('33⅓', '密纹室内乐团', '沟槽', 186, 44100, '.mp3', ''),

  // 《夜航西飞》
  s('夜航', '木星频率', '夜航西飞', 246, 48000, '.flac',
    '[00:00.00]跑道灯一盏一盏往后退\n[00:14.00]云层之上没有方向，只有频率\n[00:38.00]我把音量调到刚好盖住引擎\n[01:02.00]然后闭上眼睛\n[01:26.00]— 示例歌词 —'),
  s('电离层', '木星频率', '夜航西飞', 322, 96000, '.flac', ''),
  s('三千赫兹', '木星频率', '夜航西飞', 198, 44100, '.m4a', ''),
  s('返航', '木星频率', '夜航西飞', 274, 48000, '.flac', ''),

  // 《磁带年代》
  s('卡带 A 面', '旧日电波', '磁带年代', 232, 44100, '.mp3',
    '[00:00.00]A 面第一首总是最好听的\n[00:12.00]因为录它的时候，电池还是新的\n[00:36.00]后来就慢慢变慢，慢慢变哑'),
  s('快进', '旧日电波', '磁带年代', 167, 44100, '.mp3', ''),
  s('消磁', '旧日电波', '磁带年代', 289, 44100, '.mp3', ''),

  // 《白纸》
  s('白纸', '陈默', '白纸', 208, 96000, '.flac',
    '[00:00.00]一张白纸也有它的重量\n[00:20.00]你不写，它就一直是新的\n[00:44.00]— 示例歌词 —'),
  s('铅笔线', '陈默', '白纸', 176, 44100, '.wav', ''),
  s('留白', '陈默', '白纸', 254, 96000, '.flac', ''),
  s('折角', '陈默', '白纸', 192, 44100, '.mp3', ''),

  // 《铜与纸》
  s('铜', '密纹三重奏', '铜与纸', 241, 192000, '.flac', ''),
  s('纸', '密纹三重奏', '铜与纸', 205, 96000, '.flac', ''),
  s('针尖', '密纹三重奏', '铜与纸', 187, 96000, '.flac', ''),
  s('静电场', '密纹三重奏', '铜与纸', 312, 192000, '.flac', ''),

  // 《雨落在旧城区》
  s('骑楼', '林深', '雨落在旧城区', 226, 48000, '.m4a', ''),
  s('雨棚', '林深', '雨落在旧城区', 194, 44100, '.mp3', ''),
  s('末班车', '林深', '雨落在旧城区', 268, 48000, '.flac', '')
];

/** uri → 歌词，播放页按 uri 取，模拟"本地同名 .lrc" */
const LRC: Map<string, string> = new Map<string, string>();

export class DemoLibrary {
  /** 生成示例曲目（不入库），id 依次为负，避免和真实自增 id 撞 */
  static tracks(): Track[] {
    const list: Track[] = [];
    LRC.clear();
    for (let i = 0; i < SPECS.length; i++) {
      const sp: DemoSpec = SPECS[i];
      const uri: string = `${Const.DEMO_SCHEME}${i + 1}`;
      // 按码率粗估大小：无损 0.55 系数、有损固定 320kbps
      const bytesPerSec: number = sp.suffix === '.mp3' || sp.suffix === '.m4a'
        ? 40000 : sp.rate * 2 * 0.55;
      list.push({
        id: -(i + 1),
        uri: uri,
        path: '',
        title: sp.title,
        artist: sp.artist,
        album: sp.album,
        duration: sp.seconds * 1000,
        sampleRate: sp.rate,
        bitrate: sp.suffix === '.mp3' || sp.suffix === '.m4a' ? 320 : 0,
        suffix: sp.suffix,
        size: Math.floor(bytesPerSec * sp.seconds),
        mtime: BASE_MTIME - i * 3600000,
        coverPath: '',
        folder: '',
        rootPath: '',
        source: Const.SRC_DEMO,
        cueStart: -1,
        cueEnd: -1
      });
      if (sp.lrc.length > 0) {
        LRC.set(uri, sp.lrc);
      }
    }
    return list;
  }

  static lrcFor(uri: string): string {
    if (LRC.size === 0) {
      DemoLibrary.tracks();
    }
    const v: string | undefined = LRC.get(uri);
    return v === undefined ? '' : v;
  }

  /** 首次启动装载：示例曲库进 RDB，之后所有查询与真实曲库同一条路径 */
  static async seed(): Promise<number> {
    const list: Track[] = DemoLibrary.tracks();
    for (const t of list) {
      await TrackStore.upsert(t);
    }
    Logger.info(TAG, `seeded ${list.length} demo tracks`);
    return list.length;
  }

  static count(): number {
    return SPECS.length;
  }
}
