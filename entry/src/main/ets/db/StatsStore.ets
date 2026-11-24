import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { Track } from '../model/Track';
import { TrackStore } from './TrackStore';

const TAG: string = 'StatsStore';

/** 最常听的一行 */
export interface TopPlay {
  uri: string;
  title: string;
  artist: string;
  plays: number;
  ms: number;
}

/** 按日聚合一格 */
export interface DayPlay {
  day: string;
  plays: number;
}

/** 总览 */
export interface StatsOverall {
  plays: number;
  listenMs: number;
  tracks: number;
  days: number;
  firstTs: number;
}

/**
 * 播放统计。
 *
 * 只有两类事件，全部纯本地：
 * - start：每次起播记一条（播放次数的口径）；
 * - listen：收听毫秒的落库（累计时长的口径），由内核在换歌/暂停/退出时 flush。
 *
 * 为什么不用"播放完成"当口径：长曲中途切走是常态，按完成算会严重低估；
 * 按"起了播"算次数、按真实推进算时长，两个数字各自如实。
 * 表永远只增不改，聚合全走 SQL GROUP BY，曲库再大也不拖页面。
 */
export class StatsStore {
  private static store: relationalStore.RdbStore | null = null;

  static async init(context: common.Context): Promise<void> {
    if (StatsStore.store !== null) {
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: 'miwen.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const db: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    StatsStore.store = db;
    await db.executeSql(
      `CREATE TABLE IF NOT EXISTS play_log (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         kind TEXT NOT NULL,
         uri TEXT NOT NULL,
         ts INTEGER NOT NULL,
         ms INTEGER NOT NULL DEFAULT 0
       )`
    );
    await db.executeSql('CREATE INDEX IF NOT EXISTS idx_play_uri ON play_log(kind, uri)');
    await db.executeSql('CREATE INDEX IF NOT EXISTS idx_play_ts ON play_log(ts)');
    Logger.info(TAG, 'ready');
  }

  private static get db(): relationalStore.RdbStore {
    if (StatsStore.store === null) {
      throw new Error('StatsStore 未初始化');
    }
    return StatsStore.store;
  }

  // ---------------- 写 ----------------

  static async recordStart(uri: string): Promise<void> {
    await StatsStore.db.executeSql('INSERT INTO play_log (kind, uri, ts, ms) VALUES (?, ?, ?, ?)',
      ['start', uri, Date.now(), 0]);
  }

  static async addListen(uri: string, ms: number): Promise<void> {
    if (ms <= 0) {
      return;
    }
    await StatsStore.db.executeSql('INSERT INTO play_log (kind, uri, ts, ms) VALUES (?, ?, ?, ?)',
      ['listen', uri, Date.now(), Math.floor(ms)]);
  }

  /** 统计数据只属于自己：清空曲库索引时一并清掉，避免留下对不上号的旧数字 */
  static async clearAll(): Promise<void> {
    await StatsStore.db.executeSql('DELETE FROM play_log');
    Logger.info(TAG, 'cleared');
  }

  // ---------------- 读 ----------------

  static async overall(): Promise<StatsOverall> {
    const out: StatsOverall = { plays: 0, listenMs: 0, tracks: 0, days: 0, firstTs: 0 };
    // 每个数字一条独立查询。曾试过把四个聚合写成一条带子查询的 SELECT，
    // 真机上子查询列全部返回 0 而 MIN 列正常 —— 与其猜 rdb 的查询改写行为，不如老实拆开。
    out.plays = await StatsStore.scalarInt("SELECT COUNT(*) AS n FROM play_log WHERE kind = 'start'");
    out.listenMs = await StatsStore.scalarInt("SELECT COALESCE(SUM(ms), 0) AS n FROM play_log WHERE kind = 'listen'");
    out.tracks = await StatsStore.scalarInt("SELECT COUNT(DISTINCT uri) AS n FROM play_log WHERE kind = 'start'");
    out.firstTs = await StatsStore.scalarInt('SELECT COALESCE(MIN(ts), 0) AS n FROM play_log');
    // 收听天数按本地日历日在算 —— 真机验证发现 rdb 的 date(...,'localtime') 返回 NULL，
    // 天数与柱状图因此全为 0，所以桶不放在 SQL 里做，改在 TS 里按本地时区分。
    const rs2: relationalStore.ResultSet = await StatsStore.db.querySql(
      "SELECT DISTINCT ts FROM play_log WHERE kind = 'start'"
    );
    const seen: Set<string> = new Set<string>();
    while (rs2.goToNextRow()) {
      seen.add(StatsStore.dayKey(rs2.getLong(rs2.getColumnIndex('ts'))));
    }
    rs2.close();
    out.days = seen.size;
    Logger.info(TAG, `overall plays=${out.plays} ms=${out.listenMs} tracks=${out.tracks} days=${out.days}`);
    return out;
  }

  /** 单值查询：聚合结果永远是一行一列 */
  private static async scalarInt(sql: string): Promise<number> {
    const rs: relationalStore.ResultSet = await StatsStore.db.querySql(sql);
    let n: number = 0;
    if (rs.goToNextRow()) {
      n = rs.getLong(0);
    }
    rs.close();
    return n;
  }

  /** 本地时区的 yyyy-MM-dd，按日聚合的桶键 */
  private static dayKey(ts: number): string {
    const d: Date = new Date(ts);
    return `${d.getFullYear()}-${(d.getMonth() + 1).toString().padStart(2, '0')}-${d.getDate().toString().padStart(2, '0')}`;
  }

  /** 最常听：按起播次数排，并列时按收听时长 */
  static async topTracks(limit: number): Promise<TopPlay[]> {
    const out: TopPlay[] = [];
    const rs: relationalStore.ResultSet = await StatsStore.db.querySql(
      `SELECT l.uri,
              COUNT(*) AS plays,
              COALESCE((SELECT SUM(ms) FROM play_log WHERE kind = 'listen' AND uri = l.uri), 0) AS ms,
              COALESCE(MAX(t.title), l.uri) AS title,
              COALESCE(MAX(t.artist), '') AS artist
         FROM play_log l
         LEFT JOIN track t ON t.uri = l.uri
        WHERE l.kind = 'start'
        GROUP BY l.uri
        ORDER BY plays DESC, ms DESC
        LIMIT ?`,
      [limit]
    );
    while (rs.goToNextRow()) {
      out.push({
        uri: rs.getString(rs.getColumnIndex('uri')),
        title: rs.getString(rs.getColumnIndex('title')),
        artist: rs.getString(rs.getColumnIndex('artist')),
        plays: rs.getLong(rs.getColumnIndex('plays')),
        ms: rs.getLong(rs.getColumnIndex('ms'))
      });
    }
    rs.close();
    return out;
  }

  /** 最近 N 天，每天一行（没有播放的天也要占位，柱状图才不会错位）。
   *  日桶在 TS 里算：真机上 date(...,'localtime') 不可靠（见 overall 注释）。 */
  static async daily(days: number): Promise<DayPlay[]> {
    const map: Map<string, number> = new Map<string, number>();
    const rs: relationalStore.ResultSet = await StatsStore.db.querySql(
      'SELECT ts FROM play_log WHERE kind = ? AND ts >= ?',
      ['start', Date.now() - days * 86400000]
    );
    while (rs.goToNextRow()) {
      const key: string = StatsStore.dayKey(rs.getLong(rs.getColumnIndex('ts')));
      map.set(key, (map.get(key) ?? 0) + 1);
    }
    rs.close();
    const out: DayPlay[] = [];
    for (let i = days - 1; i >= 0; i--) {
      const d: Date = new Date(Date.now() - i * 86400000);
      const key: string = `${d.getFullYear()}-${(d.getMonth() + 1).toString().padStart(2, '0')}-${d.getDate().toString().padStart(2, '0')}`;
      const n: number = map.get(key) ?? 0;
      out.push({ day: key, plays: n });
    }
    return out;
  }

  /** 最近在听：去重后的起播序列，前端只取前几条 */
  static async recentStarts(limit: number): Promise<TopPlay[]> {
    const out: TopPlay[] = [];
    const seen: Set<string> = new Set<string>();
    const rs: relationalStore.ResultSet = await StatsStore.db.querySql(
      `SELECT l.uri, l.ts AS plays,
              COALESCE(t.title, l.uri) AS title,
              COALESCE(t.artist, '') AS artist,
              COALESCE((SELECT SUM(ms) FROM play_log WHERE kind = 'listen' AND uri = l.uri), 0) AS ms
         FROM play_log l
         LEFT JOIN track t ON t.uri = l.uri
        WHERE l.kind = 'start'
        ORDER BY l.ts DESC
        LIMIT 200`
    );
    while (rs.goToNextRow()) {
      const uri: string = rs.getString(rs.getColumnIndex('uri'));
      if (seen.has(uri)) {
        continue;
      }
      seen.add(uri);
      out.push({
        uri: uri,
        title: rs.getString(rs.getColumnIndex('title')),
        artist: rs.getString(rs.getColumnIndex('artist')),
        plays: rs.getLong(rs.getColumnIndex('plays')),
        ms: rs.getLong(rs.getColumnIndex('ms'))
      });
      if (out.length >= limit) {
        break;
      }
    }
    rs.close();
    return out;
  }

  /** 索引清了统计还在会导致"有统计无曲目"，这里把孤儿 uri 摘掉 */
  static async pruneDead(): Promise<number> {
    const alive: string[] = [];
    const rs: relationalStore.ResultSet = await StatsStore.db.querySql(
      'SELECT DISTINCT uri FROM play_log'
    );
    while (rs.goToNextRow()) {
      alive.push(rs.getString(rs.getColumnIndex('uri')));
    }
    rs.close();
    const tracks: Track[] = await TrackStore.listByUris(alive);
    const keep: Set<string> = new Set<string>(tracks.map((t: Track) => t.uri));
    let removed: number = 0;
    for (const uri of alive) {
      if (!keep.has(uri)) {
        await StatsStore.db.executeSql('DELETE FROM play_log WHERE uri = ?', [uri]);
        removed++;
      }
    }
    if (removed > 0) {
      Logger.info(TAG, `pruned ${removed} dead uris`);
    }
    return removed;
  }
}
