/**
 * 一个被授权的音乐根目录。
 *
 * 为什么要存 uri 和 path 两份：
 * - uri 是鸿蒙授权的载体，读文件必须用它换出来的 path；
 * - path 是"这个目录到底是哪个目录"的身份，重装后 uri 会变、path 不变，
 *   靠 path 才能把新授权配回旧索引，而不是把整个库重扫一遍。
 */
export interface RootDir {
  /** 授权 URI（file://docs/...） */
  uri: string;
  /** 绝对路径，用于判重与展示 */
  path: string;
  /** 目录名，取 path 最后一段 */
  name: string;
  /** 加入时间（毫秒） */
  addedAt: number;
  /** 上次扫描入库数，0 表示还没扫过 */
  count: number;
}

/** 文件夹树里的一层 */
export interface FolderNode {
  /** 相对根的完整路径，根下第一层为 'Rock'，再深为 'Rock/Classic' */
  path: string;
  /** 本层显示的目录名 */
  name: string;
  /** 该目录（含所有子目录）的曲目数 */
  total: number;
  /** 只算本层直接放的曲目数 */
  direct: number;
  /** 子目录个数 */
  subCount: number;
  /** 该目录（含子目录）总字节数 */
  size: number;
}

/** 一个文件夹的原始聚合：只算它自己直接放的曲目 */
export interface FolderStat {
  /** 相对根的路径，根下直接放的是空串 */
  folder: string;
  count: number;
  size: number;
}

export function emptyRoot(): RootDir {
  return { uri: '', path: '', name: '', addedAt: 0, count: 0 };
}

export function emptyFolder(): FolderNode {
  return { path: '', name: '', total: 0, direct: 0, subCount: 0, size: 0 };
}
