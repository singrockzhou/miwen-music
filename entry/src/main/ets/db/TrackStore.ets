import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Album, Track } from '../model/Track';
import { FolderStat } from '../model/RootDir';

const TAG: string = 'TrackStore';

/** 路径索引的一行：只够做歌单导入的匹配，不带其他字段 */
export interface PathRow {
  path: string;
  uri: string;
}

/** 重复指纹（第二梯队第 13 项）：标题 + 秒级时长 + 文件大小 */
export interface DupFingerprint {
  title: string;
  dsec: number;
  size: number;
  count: number;
}

/**
 * 曲库索引。
 *
 * 三条硬规矩：
 * 1. 所有列表都走分页查询，禁止全量 SELECT —— 5000 首一次读出来首屏必然掉帧；
 * 2. uri 唯一，重复扫同一个目录不会产生重复行，也不会换 id；
 * 3. 列表先出、标签后台补：入库时 title 先用文件名，封面和艺人都可以后补。
 */
export class TrackStore {
  private static store: relationalStore.RdbStore | null = null;

  static async init(context: common.Context): Promise<void> {
    if (TrackStore.store !== null) {
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: 'miwen.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const db: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    TrackStore.store = db;

    await db.executeSql(
      `CREATE TABLE IF NOT EXISTS track (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         uri TEXT NOT NULL UNIQUE,
         path TEXT NOT NULL DEFAULT '',
         title TEXT NOT NULL DEFAULT '',
         artist TEXT NOT NULL DEFAULT '',
         album TEXT NOT NULL DEFAULT '',
         duration INTEGER NOT NULL DEFAULT 0,
         sample_rate INTEGER NOT NULL DEFAULT 0,
         bitrate INTEGER NOT NULL DEFAULT 0,
         suffix TEXT NOT NULL DEFAULT '',
         size INTEGER NOT NULL DEFAULT 0,
         mtime INTEGER NOT NULL DEFAULT 0,
         cover_path TEXT NOT NULL DEFAULT '',
         folder TEXT NOT NULL DEFAULT '',
         root_path TEXT NOT NULL DEFAULT '',
         source TEXT NOT NULL DEFAULT 'local',
         cue_start INTEGER NOT NULL DEFAULT -1,
         cue_end INTEGER NOT NULL DEFAULT -1
       )`
    );
    // 老库升级：folder / root_path 是 1.1 才加的列。
    // ALTER 成功说明是从旧版本升上来的，这时索引里的 folder 全是空串，
    // 只能靠一次重扫补齐 —— 但绝不能因为补不齐就把"文件已失效"丢给用户。
    await TrackStore.ensureColumn(db, 'folder');
    await TrackStore.ensureColumn(db, 'root_path');
    await TrackStore.ensureIntColumn(db, 'cue_start');
    await TrackStore.ensureIntColumn(db, 'cue_end');
    await db.executeSql('CREATE INDEX IF NOT EXISTS idx_track_src ON track(source, mtime)');
    await db.executeSql('CREATE INDEX IF NOT EXISTS idx_track_album ON track(album)');
    await db.executeSql('CREATE INDEX IF NOT EXISTS idx_track_folder ON track(source, root_path, folder)');
    Logger.info(TAG, 'rdb ready');
  }

  /** 加列；已存在会抛错，这里当成"无需迁移"正常吞掉 */
  private static async ensureColumn(db: relationalStore.RdbStore, col: string): Promise<void> {
    try {
      await db.executeSql(`ALTER TABLE track ADD COLUMN ${col} TEXT NOT NULL DEFAULT ''`);
      Logger.info(TAG, `migrated column ${col}`);
    } catch (e) {
      // 列已存在，属于正常路径，不打 warn 免得日志里全是噪音
    }
  }

  /** 加数值列；已存在会抛错，这里当成"无需迁移"正常吞掉 */
  private static async ensureIntColumn(db: relationalStore.RdbStore, col: string): Promise<void> {
    try {
      await db.executeSql(`ALTER TABLE track ADD COLUMN ${col} INTEGER NOT NULL DEFAULT -1`);
      Logger.info(TAG, `migrated column ${col}`);
    } catch (e) {
      // 列已存在，属于正常路径
    }
  }

  static ready(): boolean {
    return TrackStore.store !== null;
  }

  private static get db(): relationalStore.RdbStore {
    if (TrackStore.store === null) {
      throw new Error('TrackStore 未初始化');
    }
    return TrackStore.store;
  }

  // ---------------- 写 ----------------

  /** 以 uri 为唯一键写入；冲突时更新元数据，不动 id */
  static async upsert(t: Track): Promise<void> {
    // REPLACE 而不是 ON CONFLICT：老版本 SQLite 的 upsert 语法不保证可用，
    // 而 id 不参与任何外键（歌单/收藏都按 uri 关联），换 id 无副作用。
    await TrackStore.db.executeSql(
      `INSERT OR REPLACE INTO track (uri, path, title, artist, album, duration, sample_rate,
                                     bitrate, suffix, size, mtime, cover_path, folder, root_path,
                                     source, cue_start, cue_end)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [t.uri, t.path, t.title, t.artist, t.album, t.duration, t.sampleRate, t.bitrate,
        t.suffix, t.size, t.mtime, t.coverPath, t.folder, t.rootPath, t.source,
        t.cueStart, t.cueEnd]
    );
  }

  /** 起播后由 AVPlayer 回填真实时长 */
  static async updateDuration(uri: string, duration: number): Promise<void> {
    if (duration <= 0) {
      return;
    }
    await TrackStore.db.executeSql('UPDATE track SET duration = ? WHERE uri = ?', [duration, uri]);
  }

  /** 按绝对路径找整轨（CUE 配对用）；找不到返回 null */
  static async findByPath(path: string): Promise<Track | null> {
    const rs: relationalStore.ResultSet =
      await TrackStore.db.querySql('SELECT * FROM track WHERE path = ? AND cue_start < 0 LIMIT 1', [path]);
    const t: Track | null = rs.goToNextRow() ? TrackStore.readRow(rs) : null;
    rs.close();
    return t;
  }

  /** 按文件名兜底找整轨（CUE 的 FILE 行可能带各种前缀）；找不到返回 null */
  static async findByBaseName(name: string): Promise<Track | null> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      'SELECT * FROM track WHERE cue_start < 0 AND path LIKE ? ORDER BY length(path) LIMIT 1',
      [`%/${name}`]
    );
    const t: Track | null = rs.goToNextRow() ? TrackStore.readRow(rs) : null;
    rs.close();
    return t;
  }

  static async clearSource(source: string): Promise<void> {
    await TrackStore.db.executeSql('DELETE FROM track WHERE source = ?', [source]);
  }

  // ---------------- 读 ----------------

  static async count(source: string): Promise<number> {
    const rs: relationalStore.ResultSet =
      await TrackStore.db.querySql('SELECT COUNT(*) AS c FROM track WHERE source = ?', [source]);
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  static async page(source: string, offset: number, size: number, sort: string,
    suffix: string = ''): Promise<Track[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT * FROM track WHERE source = ? AND (? = '' OR suffix = ?)
       ORDER BY ${TrackStore.orderBy(sort)} LIMIT ? OFFSET ?`,
      [source, suffix, suffix, size, offset]
    );
    const list: Track[] = [];
    while (rs.goToNextRow()) {
      list.push(TrackStore.readRow(rs));
    }
    rs.close();
    return list;
  }

  /** 搜索：标题/艺人/专辑/文件名 模糊匹配，仍然分页 */
  static async search(source: string, keyword: string, offset: number, size: number,
    suffix: string = ''): Promise<Track[]> {
    const like: string = `%${keyword}%`;
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT * FROM track
       WHERE source = ? AND (title LIKE ? OR artist LIKE ? OR album LIKE ? OR path LIKE ?)
         AND (? = '' OR suffix = ?)
       ORDER BY title COLLATE NOCASE ASC LIMIT ? OFFSET ?`,
      [source, like, like, like, like, suffix, suffix, size, offset]
    );
    const list: Track[] = [];
    while (rs.goToNextRow()) {
      list.push(TrackStore.readRow(rs));
    }
    rs.close();
    return list;
  }

  static async searchCount(source: string, keyword: string, suffix: string = ''): Promise<number> {
    const like: string = `%${keyword}%`;
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT COUNT(*) AS c FROM track
       WHERE source = ? AND (title LIKE ? OR artist LIKE ? OR album LIKE ? OR path LIKE ?)
         AND (? = '' OR suffix = ?)`,
      [source, like, like, like, like, suffix, suffix]
    );
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 当前来源的格式种类（按数量降序），用于筛选条 */
  static async suffixList(source: string): Promise<string[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT suffix FROM track WHERE source = ? AND suffix <> ''
       GROUP BY suffix ORDER BY COUNT(*) DESC LIMIT 8`,
      [source]
    );
    const list: string[] = [];
    while (rs.goToNextRow()) {
      list.push(rs.getString(rs.getColumnIndex('suffix')));
    }
    rs.close();
    return list;
  }

  /** 按格式计数；suffix 为空表示全部 */
  static async countBySuffix(source: string, suffix: string): Promise<number> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT COUNT(*) AS c FROM track WHERE source = ? AND (? = '' OR suffix = ?)`,
      [source, suffix, suffix]
    );
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 封面墙：按专辑聚合，一张"唱片"一条 */
  static async albums(source: string, limit: number): Promise<Album[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT CASE WHEN TRIM(album) = '' THEN '未知专辑' ELSE album END AS gname,
              MAX(artist) AS artist, MAX(cover_path) AS cover_path, COUNT(*) AS cnt,
              MAX(sample_rate) AS rate, MIN(suffix) AS suffix,
              SUM(duration) AS total, MIN(uri) AS k
       FROM track WHERE source = ?
       GROUP BY gname
       ORDER BY MAX(mtime) DESC LIMIT ?`,
      [source, limit]
    );
    const list: Album[] = [];
    while (rs.goToNextRow()) {
      list.push({
        album: rs.getString(rs.getColumnIndex('gname')),
        artist: rs.getString(rs.getColumnIndex('artist')),
        coverPath: rs.getString(rs.getColumnIndex('cover_path')),
        count: rs.getLong(rs.getColumnIndex('cnt')),
        sampleRate: rs.getLong(rs.getColumnIndex('rate')),
        suffix: rs.getString(rs.getColumnIndex('suffix')),
        duration: rs.getLong(rs.getColumnIndex('total')),
        key: rs.getString(rs.getColumnIndex('k'))
      });
    }
    rs.close();
    return list;
  }

  static async albumTracks(source: string, album: string): Promise<Track[]> {
    const unknown: string = '未知专辑';
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT * FROM track
       WHERE source = ? AND (album = ? OR (? = ? AND TRIM(album) = ''))
       ORDER BY mtime ASC, title COLLATE NOCASE ASC`,
      [source, album, album, unknown]
    );
    const list: Track[] = [];
    while (rs.goToNextRow()) {
      list.push(TrackStore.readRow(rs));
    }
    rs.close();
    return list;
  }

  /** 按 uri 批量取，并保持传入顺序（收藏、歌单、队列都靠它） */
  static async listByUris(uris: string[]): Promise<Track[]> {
    if (uris.length === 0) {
      return [];
    }
    const found: Map<string, Track> = new Map<string, Track>();
    const chunk: number = 200;
    for (let start = 0; start < uris.length; start += chunk) {
      const slice: string[] = uris.slice(start, start + chunk);
      let marks: string = '?';
      for (let i = 1; i < slice.length; i++) {
        marks += ',?';
      }
      const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
        `SELECT * FROM track WHERE uri IN (${marks})`, slice
      );
      while (rs.goToNextRow()) {
        const t: Track = TrackStore.readRow(rs);
        found.set(t.uri, t);
      }
      rs.close();
    }
    const list: Track[] = [];
    for (const u of uris) {
      const t: Track | undefined = found.get(u);
      if (t !== undefined) {
        list.push(t);
      }
    }
    return list;
  }

  /** 格式分布，设置页用 */
  static async suffixStats(source: string): Promise<string[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT UPPER(SUBSTR(suffix, 2)) AS f, COUNT(*) AS c
       FROM track WHERE source = ? AND suffix <> ''
       GROUP BY f ORDER BY c DESC LIMIT 6`,
      [source]
    );
    const list: string[] = [];
    while (rs.goToNextRow()) {
      list.push(`${rs.getString(rs.getColumnIndex('f'))} ${rs.getLong(rs.getColumnIndex('c'))}`);
    }
    rs.close();
    return list;
  }

  static async totalBytes(source: string): Promise<number> {
    const rs: relationalStore.ResultSet =
      await TrackStore.db.querySql('SELECT SUM(size) AS s FROM track WHERE source = ?', [source]);
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('s'));
    }
    rs.close();
    return n;
  }

  // ---------------- 文件夹视图 ----------------

  /**
   * 把某个根下的 folder 拍平成聚合结果。
   *
   * 不在 SQL 里递归拼树：SQLite 递归 CTE 在 RDB 封装上层数越多越难调试，
   * 而一个曲库的目录数量通常在几十到几百，一次查完在 ArkTS 里建树更可控，
   * 也能顺手把"子目录数"和"本层曲目数"一起算出来。
   */
  static async folderStats(source: string, rootPath: string): Promise<FolderStat[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT folder, COUNT(*) AS c, SUM(size) AS sz
       FROM track WHERE source = ? AND root_path = ?
       GROUP BY folder`,
      [source, rootPath]
    );
    const list: FolderStat[] = [];
    while (rs.goToNextRow()) {
      list.push({
        folder: rs.getString(rs.getColumnIndex('folder')),
        count: rs.getLong(rs.getColumnIndex('c')),
        size: rs.getLong(rs.getColumnIndex('sz'))
      });
    }
    rs.close();
    return list;
  }

  /** 某个根下全部文件夹（用于根列表卡片的"含 N 个文件夹"） */
  static async folderCount(source: string, rootPath: string): Promise<number> {
    // CASE ... ELSE NULL：根下直接放的曲目 folder 是空串，不该算成"一个文件夹"
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT COUNT(DISTINCT CASE WHEN folder <> '' THEN folder ELSE NULL END) AS c
       FROM track WHERE source = ? AND root_path = ?`,
      [source, rootPath]
    );
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 某根下全部曲目（无根过滤时用 root_path = '' 兼容老数据） */
  static async countInRoot(source: string, rootPath: string): Promise<number> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      'SELECT COUNT(*) AS c FROM track WHERE source = ? AND root_path = ?', [source, rootPath]
    );
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /**
   * 某个文件夹**本层直接**的曲目（不含子目录）。
   * 想听整棵树用 pageUnder。
   */
  static async pageInFolder(source: string, rootPath: string, folder: string, offset: number,
    size: number, sort: string): Promise<Track[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT * FROM track WHERE source = ? AND root_path = ? AND folder = ?
       ORDER BY ${TrackStore.orderBy(sort)} LIMIT ? OFFSET ?`,
      [source, rootPath, folder, size, offset]
    );
    const list: Track[] = [];
    while (rs.goToNextRow()) {
      list.push(TrackStore.readRow(rs));
    }
    rs.close();
    return list;
  }

  static async countInFolder(source: string, rootPath: string, folder: string): Promise<number> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      'SELECT COUNT(*) AS c FROM track WHERE source = ? AND root_path = ? AND folder = ?',
      [source, rootPath, folder]
    );
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 整棵子树：folder 等于自己或以 `folder/` 开头。空 folder 表示整个根。 */
  static async pageUnder(source: string, rootPath: string, folder: string, offset: number,
    size: number, sort: string): Promise<Track[]> {
    const prefix: string = folder.length > 0 ? `${folder}/%` : '%';
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT * FROM track
       WHERE source = ? AND root_path = ? AND (? = '' OR folder = ? OR folder LIKE ?)
       ORDER BY ${TrackStore.orderBy(sort)} LIMIT ? OFFSET ?`,
      [source, rootPath, folder, folder, prefix, size, offset]
    );
    const list: Track[] = [];
    while (rs.goToNextRow()) {
      list.push(TrackStore.readRow(rs));
    }
    rs.close();
    return list;
  }

  static async countUnder(source: string, rootPath: string, folder: string): Promise<number> {
    const prefix: string = folder.length > 0 ? `${folder}/%` : '%';
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT COUNT(*) AS c FROM track
       WHERE source = ? AND root_path = ? AND (? = '' OR folder = ? OR folder LIKE ?)`,
      [source, rootPath, folder, folder, prefix]
    );
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 只清某个根的索引；根目录被移除时调用，别的根一首都不动 */
  static async clearRoot(rootPath: string): Promise<void> {
    await TrackStore.db.executeSql('DELETE FROM track WHERE root_path = ?', [rootPath]);
  }

  /** root_path 还是空串的老记录有多少条 */
  static async orphanCount(source: string): Promise<number> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT COUNT(*) AS c FROM track WHERE source = ? AND root_path = ''`, [source]
    );
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /**
   * 1.0 → 1.1 升级时补一次归属：把 root_path 为空的记录认给唯一的根。
   *
   * 为什么必须在应用层算 folder：SQLite 没有"从右往左找斜杠"的函数，
   * 靠 rtrim + replace 拼出来的表达式错一个字符就会把整库的 folder 写歪，
   * 而这里只有升级后第一次会跑，几千条放在一个事务里也就一瞬。
   *
   * 只在"恰好一个根"时调用 —— 多个根时无从判断哪首属于哪个目录，
   * 猜错了比空着更糟。
   */
  static async adoptOrphans(source: string, rootPath: string): Promise<number> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT uri, path FROM track WHERE source = ? AND root_path = ''`, [source]
    );
    const uris: string[] = [];
    const folders: string[] = [];
    const prefix: string = rootPath.endsWith('/') ? rootPath : `${rootPath}/`;
    while (rs.goToNextRow()) {
      const p: string = rs.getString(rs.getColumnIndex('path'));
      uris.push(rs.getString(rs.getColumnIndex('uri')));
      if (p.startsWith(prefix)) {
        const rel: string = p.substring(prefix.length);
        const cut: number = rel.lastIndexOf('/');
        folders.push(cut >= 0 ? rel.substring(0, cut) : '');
      } else {
        // 路径不在这个根下（用户换过目录），folder 留空，交由重扫修正
        folders.push('');
      }
    }
    rs.close();
    if (uris.length === 0) {
      return 0;
    }
    const db: relationalStore.RdbStore = TrackStore.db;
    db.beginTransaction();
    try {
      for (let i = 0; i < uris.length; i++) {
        await db.executeSql('UPDATE track SET root_path = ?, folder = ? WHERE uri = ?',
          [rootPath, folders[i], uris[i]]);
      }
      db.commit();
    } catch (e) {
      db.rollBack();
      Logger.warn(TAG, `adopt orphans failed ${JSON.stringify(e)}`);
      return 0;
    }
    Logger.info(TAG, `adopted ${uris.length} orphan rows`);
    return uris.length;
  }

  // ---------------- 迁移：导入匹配 / 备份导出 ----------------

  /**
   * 导出整库（备份用）。
   * 唯一一处允许绕过分页的地方：备份本来就要全量，而且只在用户主动点"备份"时跑一次。
   */
  static async dumpAll(source: string): Promise<Track[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      'SELECT * FROM track WHERE source = ? ORDER BY id ASC', [source]
    );
    const out: Track[] = [];
    while (rs.goToNextRow()) {
      out.push(TrackStore.readRow(rs));
    }
    rs.close();
    return out;
  }

  /** 只取 path/uri 两张列，给歌单导入做路径匹配，避免把整个 Track 拉进内存 */
  static async pathIndex(source: string): Promise<PathRow[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      'SELECT path, uri FROM track WHERE source = ?', [source]
    );
    const out: PathRow[] = [];
    while (rs.goToNextRow()) {
      out.push({
        path: rs.getString(rs.getColumnIndex('path')),
        uri: rs.getString(rs.getColumnIndex('uri'))
      });
    }
    rs.close();
    return out;
  }

  static async listByPaths(paths: string[], source: string): Promise<Track[]> {
    if (paths.length === 0) {
      return [];
    }
    const out: Track[] = [];
    // 一次查一条：SQLite 的 IN 长度上限是 999，分批比拼长串安全
    for (let i = 0; i < paths.length; i += 200) {
      const chunk: string[] = paths.slice(i, i + 200);
      const marks: string = chunk.map(() => '?').join(',');
      const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
        `SELECT * FROM track WHERE source = ? AND path IN (${marks})`, [source].concat(chunk)
      );
      while (rs.goToNextRow()) {
        out.push(TrackStore.readRow(rs));
      }
      rs.close();
    }
    return out;
  }

  /** 批量写入（恢复备份用）：整批一个事务，失败整体回滚，不留半套索引 */
  static async upsertMany(tracks: Track[]): Promise<number> {
    if (tracks.length === 0) {
      return 0;
    }
    const db: relationalStore.RdbStore = TrackStore.db;
    db.beginTransaction();
    let n: number = 0;
    try {
      for (const t of tracks) {
        await db.executeSql(
          `INSERT OR REPLACE INTO track (uri, path, title, artist, album, duration, sample_rate,
                                         bitrate, suffix, size, mtime, cover_path, folder, root_path, source)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [t.uri, t.path, t.title, t.artist, t.album, t.duration, t.sampleRate,
            t.bitrate, t.suffix, t.size, t.mtime, t.coverPath, t.folder, t.rootPath, t.source]
        );
        n++;
      }
      db.commit();
    } catch (e) {
      db.rollBack();
      Logger.warn(TAG, `upsertMany failed ${JSON.stringify(e)}`);
      return 0;
    }
    return n;
  }

  // ---------------- 内部 ----------------

  /**
   * 排序拼串。只允许内部常量进来，绝不把用户输入拼进 SQL。
   */
  private static orderBy(sort: string): string {
    if (sort === Const.SORT_TITLE) {
      return 'title COLLATE NOCASE ASC';
    }
    if (sort === Const.SORT_ARTIST) {
      return 'artist COLLATE NOCASE ASC, album COLLATE NOCASE ASC, id ASC';
    }
    if (sort === Const.SORT_RATE) {
      return 'sample_rate DESC, title COLLATE NOCASE ASC';
    }
    return 'mtime DESC, id DESC';
  }

  // ---------------- 曲库维护（第二梯队第 13 / 14 项）----------------

  /**
   * 重复指纹候选组：标题 + 秒级时长 + 文件大小完全一致才成组。
   * 时长用秒级容差——同一文件复制出来毫秒数可能差个位数，秒级归一能兜住；
   * 只在 SQL 里做粗筛，精确成组交给上层按指纹回查。
   */
  static async dupFingerprints(source: string): Promise<DupFingerprint[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT title, CAST(duration / 1000 AS INTEGER) AS dsec, size, COUNT(*) AS c
       FROM track WHERE source = ? AND cue_start < 0
       GROUP BY title, dsec, size HAVING COUNT(*) > 1
       ORDER BY c DESC, title COLLATE NOCASE LIMIT 200`,
      [source]);
    const out: DupFingerprint[] = [];
    while (rs.goToNextRow()) {
      out.push({
        title: rs.getString(rs.getColumnIndex('title')),
        dsec: rs.getLong(rs.getColumnIndex('dsec')),
        size: rs.getLong(rs.getColumnIndex('size')),
        count: rs.getLong(rs.getColumnIndex('c'))
      });
    }
    rs.close();
    return out;
  }

  /** 按指纹回查组内曲目（含 CUE 分轨——分轨与整轨指向同一文件，一并呈现） */
  static async listByFingerprint(source: string, fp: DupFingerprint): Promise<Track[]> {
    const rs: relationalStore.ResultSet = await TrackStore.db.querySql(
      `SELECT * FROM track WHERE source = ? AND title = ? AND size = ?
         AND CAST(duration / 1000 AS INTEGER) = ?
       ORDER BY cue_start ASC, id ASC`,
      [source, fp.title, fp.size, fp.dsec]);
    const out: Track[] = [];
    while (rs.goToNextRow()) {
      out.push(TrackStore.readRow(rs));
    }
    rs.close();
    return out;
  }

  /** 从索引移除单条（重复清理 / 失效条目清理共用） */
  static async removeUri(uri: string): Promise<void> {
    await TrackStore.db.executeSql('DELETE FROM track WHERE uri = ?', [uri]);
  }

  /**
   * 失效路径重定位：换新文件后路径与 uri 都要换，元数据保留。
   * root_path / folder 按"清空孤儿"口径处理：新路径的根由下次重扫认领，
   * 先挂到孤儿区，避免伪造 root 导致文件夹视图错分组。
   */
  static async relocate(uri: string, newPath: string): Promise<void> {
    const newUri: string = fileUri.getUriFromPath(newPath);
    await TrackStore.db.executeSql(
      'UPDATE track SET path = ?, uri = ?, root_path = ?, folder = ? WHERE uri = ?',
      [newPath, newUri, '', '', uri]);
  }

  /** 批量修正索引内标签（不改文件）：空串字段表示不改 */
  static async updateMeta(uris: string[], title: string, artist: string, album: string): Promise<number> {
    const sets: string[] = [];
    const args: relationalStore.ValueType[] = [];
    if (title.length > 0) {
      sets.push('title = ?');
      args.push(title);
    }
    if (artist.length > 0) {
      sets.push('artist = ?');
      args.push(artist);
    }
    if (album.length > 0) {
      sets.push('album = ?');
      args.push(album);
    }
    if (sets.length === 0 || uris.length === 0) {
      return 0;
    }
    const marks: string = uris.map((u: string) => '?').join(',');
    for (const u of uris) {
      args.push(u);
    }
    await TrackStore.db.executeSql(
      `UPDATE track SET ${sets.join(', ')} WHERE uri IN (${marks})`, args);
    return uris.length;
  }

  private static readRow(rs: relationalStore.ResultSet): Track {
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      uri: rs.getString(rs.getColumnIndex('uri')),
      path: rs.getString(rs.getColumnIndex('path')),
      title: rs.getString(rs.getColumnIndex('title')),
      artist: rs.getString(rs.getColumnIndex('artist')),
      album: rs.getString(rs.getColumnIndex('album')),
      duration: rs.getLong(rs.getColumnIndex('duration')),
      sampleRate: rs.getLong(rs.getColumnIndex('sample_rate')),
      bitrate: rs.getLong(rs.getColumnIndex('bitrate')),
      suffix: rs.getString(rs.getColumnIndex('suffix')),
      size: rs.getLong(rs.getColumnIndex('size')),
      mtime: rs.getLong(rs.getColumnIndex('mtime')),
      coverPath: rs.getString(rs.getColumnIndex('cover_path')),
      folder: rs.getString(rs.getColumnIndex('folder')),
      rootPath: rs.getString(rs.getColumnIndex('root_path')),
      source: rs.getString(rs.getColumnIndex('source')),
      cueStart: rs.getLong(rs.getColumnIndex('cue_start')),
      cueEnd: rs.getLong(rs.getColumnIndex('cue_end'))
    };
  }
}
