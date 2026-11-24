import { Album, Track } from '../model/Track';

/**
 * LazyForEach 数据源。
 *
 * 为什么不直接 ForEach(this.tracks)：
 * 5000 首的曲库用 ForEach 会一次性创建全部节点，首屏必崩。
 * LazyForEach 只创建可视区 + cachedCount 内的节点。
 *
 * 整表替换而不是增量 diff：切排序、切来源、搜索都会改变整张列表，
 * 增量对不齐反而更容易闪烁。
 */

export class TrackDataSource implements IDataSource {
  private rows: Track[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): Track {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((x: DataChangeListener) => x !== listener);
  }

  reset(rows: Track[]): void {
    this.rows = rows;
    this.listeners.forEach((l: DataChangeListener) => l.onDataReloaded());
  }

  append(rows: Track[]): void {
    const start: number = this.rows.length;
    this.rows = this.rows.concat(rows);
    this.listeners.forEach((l: DataChangeListener) => l.onDataAdd(start));
  }

  size(): number {
    return this.rows.length;
  }

  at(index: number): Track {
    return this.rows[index];
  }

  /** 交给播放内核建队列；调用方只读 */
  all(): Track[] {
    return this.rows;
  }
}

export class AlbumDataSource implements IDataSource {
  private rows: Album[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): Album {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((x: DataChangeListener) => x !== listener);
  }

  reset(rows: Album[]): void {
    this.rows = rows;
    this.listeners.forEach((l: DataChangeListener) => l.onDataReloaded());
  }

  size(): number {
    return this.rows.length;
  }
}
