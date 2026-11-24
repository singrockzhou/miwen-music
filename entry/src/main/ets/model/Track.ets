/**
 * 曲目模型。字段刻意保持扁平，方便直接映射 RDB 表。
 */
export interface Track {
  /** RDB 自增 id，入库后回填 */
  id: number;
  /** 原始 file:// URI（示例曲目为 demo:// 前缀），唯一键 */
  uri: string;
  /** 绝对路径，播放与读取都用它；示例曲目为空 */
  path: string;
  title: string;
  artist: string;
  album: string;
  /** 毫秒，0 表示尚未解析（起播后由 AVPlayer 回填） */
  duration: number;
  /** Hz，0 表示未知 */
  sampleRate: number;
  /** kbps，0 表示未知 */
  bitrate: number;
  /** 扩展名，含点 */
  suffix: string;
  size: number;
  mtime: number;
  /** 封面缓存路径，空表示用程序化封套 */
  coverPath: string;
  /**
   * 相对所属根目录的文件夹路径（不含文件名，根下直接放的是空串）。
   * 只依赖标签时，一张标签全空的专辑会全部落进"未知专辑"，
   * 而磁盘上的目录结构永远是准的 —— 文件夹视图就是靠这个字段还原的。
   */
  folder: string;
  /** 所属根目录的绝对路径，用于多根分组与"按根移除索引" */
  rootPath: string;
  /** 来源：local（用户目录）/ demo（示例数据） */
  source: string;
  /**
   * CUE 分轨起点（毫秒），-1 表示不是分轨。
   * 分轨曲目的 path 仍指向整轨音频文件，播放时由内核映射显示时长与进度。
   */
  cueStart: number;
  /** CUE 分轨终点（毫秒），-1 表示到文件自然结束 */
  cueEnd: number;
}

/** 一张唱片：按 album 聚合出来的封套 */
export interface Album {
  album: string;
  artist: string;
  /** 组内第一张有封面的图 */
  coverPath: string;
  count: number;
  /** 组内最高采样率，用于"96kHz"角标 */
  sampleRate: number;
  /** 组内第一种格式 */
  suffix: string;
  /** 总时长 */
  duration: number;
  /** 代表曲目 uri，用于稳定 key */
  key: string;
}

/** TagParser 的返回值：解析不出来的字段留空，绝不 throw */
export interface RawTag {
  title: string;
  artist: string;
  album: string;
  sampleRate: number;
  /** 封面原始字节，由 LibraryService 落盘到 cacheDir */
  cover: Uint8Array | null;
  coverMime: string;
  /** 内嵌歌词原文（ID3 USLT / FLAC LYRICS），可能带时间轴也可能不带 */
  lyric: string;
}

export function emptyTag(): RawTag {
  return {
    title: '', artist: '', album: '', sampleRate: 0,
    cover: null, coverMime: '', lyric: ''
  };
}

export function emptyTrack(): Track {
  return {
    id: 0,
    uri: '',
    path: '',
    title: '',
    artist: '',
    album: '',
    duration: 0,
    sampleRate: 0,
    bitrate: 0,
    suffix: '',
    size: 0,
    mtime: 0,
    coverPath: '',
    folder: '',
    rootPath: '',
    source: '',
    cueStart: -1,
    cueEnd: -1
  };
}
