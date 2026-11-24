import { Track } from './Track';

/**
 * UI 只消费这一份快照。
 *
 * 为什么不让页面直接读 PlayerCore 的字段：
 * 播放位置每秒变十几次，页面各读各的会漏更新、顺序也会乱；
 * 内核只负责在"真的变了"的时候推一份新对象出来，页面整体替换即可。
 */
export interface PlayerSnapshot {
  track: Track | null;
  /** idle / loading / buffering / playing / paused / error */
  status: string;
  playing: boolean;
  /** 毫秒 */
  position: number;
  duration: number;
  index: number;
  total: number;
  /** loop / single / shuffle */
  mode: string;
  /** 当前曲目是否已收藏 */
  favorite: boolean;
  /** 非空表示需要就地提示的异常文案 */
  error: string;
  /** 当前是否在放示例数据（没有真实文件，用计时器驱动） */
  isDemo: boolean;
  /** A-B 循环：A 点毫秒，未设为 -1；B 点未设为 -1 */
  abA: number;
  abB: number;
}

export function emptySnapshot(): PlayerSnapshot {
  return {
    track: null,
    status: 'idle',
    playing: false,
    position: 0,
    duration: 0,
    index: -1,
    total: 0,
    mode: 'loop',
    favorite: false,
    error: '',
    isDemo: false,
    abA: -1,
    abB: -1
  };
}
