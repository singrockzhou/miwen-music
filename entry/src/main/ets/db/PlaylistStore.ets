import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { Playlist, PlaylistDump } from '../model/Playlist';
import { Track } from '../model/Track';
import { TrackStore } from './TrackStore';

const TAG: string = 'PlaylistStore';

/**
 * 收藏 / 歌单 / 最近播放。
 *
 * 只存 uri，不存整条曲目：曲目元数据将来会因为改标签而变化，
 * 存副本就会出现"歌单里还是旧标题"这种对不上的问题。
 */
export class PlaylistStore {
  private static store: relationalStore.RdbStore | null = null;
  private static favSet: Set<string> = new Set<string>();

  static async init(context: common.Context): Promise<void> {
    if (PlaylistStore.store !== null) {
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: 'miwen.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const db: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    PlaylistStore.store = db;

    await db.executeSql('CREATE TABLE IF NOT EXISTS favorite (uri TEXT PRIMARY KEY, added_at INTEGER NOT NULL)');
    await db.executeSql(
      'CREATE TABLE IF NOT EXISTS playlist (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)'
    );
    await db.executeSql(
      'CREATE TABLE IF NOT EXISTS playlist_track (playlist_id INTEGER NOT NULL, uri TEXT NOT NULL, ord INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(playlist_id, uri))'
    );
    await db.executeSql('CREATE TABLE IF NOT EXISTS recent (uri TEXT PRIMARY KEY, played_at INTEGER NOT NULL)');

    await PlaylistStore.loadFavorites();
    Logger.info(TAG, `ready, favorites=${PlaylistStore.favSet.size}`);
  }

  private static get db(): relationalStore.RdbStore {
    if (PlaylistStore.store === null) {
      throw new Error('PlaylistStore 未初始化');
    }
    return PlaylistStore.store;
  }

  private static async loadFavorites(): Promise<void> {
    const set: Set<string> = new Set<string>();
    const rs: relationalStore.ResultSet = await PlaylistStore.db.querySql('SELECT uri FROM favorite');
    while (rs.goToNextRow()) {
      set.add(rs.getString(rs.getColumnIndex('uri')));
    }
    rs.close();
    PlaylistStore.favSet = set;
  }

  // ---------------- 收藏 ----------------

  static isFavorite(uri: string): boolean {
    return PlaylistStore.favSet.has(uri);
  }

  static favoriteCount(): number {
    return PlaylistStore.favSet.size;
  }

  /** 返回切换后的状态：true = 已收藏 */
  static async toggleFavorite(t: Track): Promise<boolean> {
    const now: boolean = PlaylistStore.favSet.has(t.uri);
    if (now) {
      await PlaylistStore.db.executeSql('DELETE FROM favorite WHERE uri = ?', [t.uri]);
      PlaylistStore.favSet.delete(t.uri);
      return false;
    }
    await PlaylistStore.db.executeSql('INSERT OR REPLACE INTO favorite (uri, added_at) VALUES (?, ?)',
      [t.uri, Date.now()]);
    PlaylistStore.favSet.add(t.uri);
    return true;
  }

  static async favoriteTracks(): Promise<Track[]> {
    const uris: string[] = [];
    const rs: relationalStore.ResultSet =
      await PlaylistStore.db.querySql('SELECT uri FROM favorite ORDER BY added_at DESC LIMIT 500');
    while (rs.goToNextRow()) {
      uris.push(rs.getString(rs.getColumnIndex('uri')));
    }
    rs.close();
    return TrackStore.listByUris(uris);
  }

  // ---------------- 最近播放 ----------------

  static async addRecent(t: Track): Promise<void> {
    const now: number = Date.now();
    await PlaylistStore.db.executeSql('INSERT OR REPLACE INTO recent (uri, played_at) VALUES (?, ?)',
      [t.uri, now]);
    // 只留最近 50 条，表不会无限长
    await PlaylistStore.db.executeSql(
      'DELETE FROM recent WHERE uri NOT IN (SELECT uri FROM recent ORDER BY played_at DESC LIMIT 50)'
    );
  }

  static async recentTracks(limit: number): Promise<Track[]> {
    const uris: string[] = [];
    const rs: relationalStore.ResultSet =
      await PlaylistStore.db.querySql('SELECT uri FROM recent ORDER BY played_at DESC LIMIT ?', [limit]);
    while (rs.goToNextRow()) {
      uris.push(rs.getString(rs.getColumnIndex('uri')));
    }
    rs.close();
    return TrackStore.listByUris(uris);
  }

  static async clearRecent(): Promise<void> {
    await PlaylistStore.db.executeSql('DELETE FROM recent');
  }

  // ---------------- 歌单 ----------------

  static async playlists(): Promise<Playlist[]> {
    const rs: relationalStore.ResultSet = await PlaylistStore.db.querySql(
      `SELECT p.id AS id, p.name AS name, p.updated_at AS updated_at, COUNT(t.uri) AS cnt
       FROM playlist p LEFT JOIN playlist_track t ON t.playlist_id = p.id
       GROUP BY p.id ORDER BY p.updated_at DESC`
    );
    const list: Playlist[] = [];
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')),
        count: rs.getLong(rs.getColumnIndex('cnt')),
        updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
      });
    }
    rs.close();
    return list;
  }

  static async createPlaylist(name: string): Promise<number> {
    const now: number = Date.now();
    const values: relationalStore.ValuesBucket = {
      'name': name,
      'created_at': now,
      'updated_at': now
    };
    return await PlaylistStore.db.insert('playlist', values);
  }

  static async renamePlaylist(id: number, name: string): Promise<void> {
    await PlaylistStore.db.executeSql('UPDATE playlist SET name = ?, updated_at = ? WHERE id = ?',
      [name, Date.now(), id]);
  }

  static async deletePlaylist(id: number): Promise<void> {
    await PlaylistStore.db.executeSql('DELETE FROM playlist WHERE id = ?', [id]);
    await PlaylistStore.db.executeSql('DELETE FROM playlist_track WHERE playlist_id = ?', [id]);
  }

  static async playlistName(id: number): Promise<string> {
    const rs: relationalStore.ResultSet =
      await PlaylistStore.db.querySql('SELECT name FROM playlist WHERE id = ?', [id]);
    let name: string = '';
    if (rs.goToFirstRow()) {
      name = rs.getString(rs.getColumnIndex('name'));
    }
    rs.close();
    return name;
  }

  static async addToPlaylist(playlistId: number, tracks: Track[]): Promise<void> {
    if (tracks.length === 0) {
      return;
    }
    let ord: number = 0;
    const rs: relationalStore.ResultSet =
      await PlaylistStore.db.querySql('SELECT MAX(ord) AS m FROM playlist_track WHERE playlist_id = ?',
        [playlistId]);
    if (rs.goToFirstRow()) {
      ord = rs.getLong(rs.getColumnIndex('m')) + 1;
    }
    rs.close();
    for (const t of tracks) {
      await PlaylistStore.db.executeSql(
        'INSERT OR REPLACE INTO playlist_track (playlist_id, uri, ord) VALUES (?, ?, ?)',
        [playlistId, t.uri, ord]
      );
      ord++;
    }
    await PlaylistStore.db.executeSql('UPDATE playlist SET updated_at = ? WHERE id = ?',
      [Date.now(), playlistId]);
  }

  static async removeFromPlaylist(playlistId: number, uri: string): Promise<void> {
    await PlaylistStore.db.executeSql('DELETE FROM playlist_track WHERE playlist_id = ? AND uri = ?',
      [playlistId, uri]);
    await PlaylistStore.db.executeSql('UPDATE playlist SET updated_at = ? WHERE id = ?',
      [Date.now(), playlistId]);
  }

  static async playlistTracks(playlistId: number): Promise<Track[]> {
    const uris: string[] = [];
    const rs: relationalStore.ResultSet =
      await PlaylistStore.db.querySql(
        'SELECT uri FROM playlist_track WHERE playlist_id = ? ORDER BY ord ASC', [playlistId]);
    while (rs.goToNextRow()) {
      uris.push(rs.getString(rs.getColumnIndex('uri')));
    }
    rs.close();
    return TrackStore.listByUris(uris);
  }

  // ---------------- 备份 / 恢复 ----------------

  /** 收藏的 uri 列表（按加入时间倒序），备份用 */
  static async favoriteUris(): Promise<string[]> {
    const out: string[] = [];
    const rs: relationalStore.ResultSet =
      await PlaylistStore.db.querySql('SELECT uri FROM favorite ORDER BY added_at DESC');
    while (rs.goToNextRow()) {
      out.push(rs.getString(rs.getColumnIndex('uri')));
    }
    rs.close();
    return out;
  }

  static async recentUris(): Promise<string[]> {
    const out: string[] = [];
    const rs: relationalStore.ResultSet =
      await PlaylistStore.db.querySql('SELECT uri FROM recent ORDER BY played_at DESC');
    while (rs.goToNextRow()) {
      out.push(rs.getString(rs.getColumnIndex('uri')));
    }
    rs.close();
    return out;
  }

  /** 全部歌单 + 各自的 uri（顺序即 ord） */
  static async allWithTracks(): Promise<PlaylistDump[]> {
    const list: Playlist[] = await PlaylistStore.playlists();
    const out: PlaylistDump[] = [];
    for (const p of list) {
      const uris: string[] = [];
      const rs: relationalStore.ResultSet = await PlaylistStore.db.querySql(
        'SELECT uri FROM playlist_track WHERE playlist_id = ? ORDER BY ord ASC', [p.id]);
      while (rs.goToNextRow()) {
        uris.push(rs.getString(rs.getColumnIndex('uri')));
      }
      rs.close();
      out.push({ name: p.name, uris: uris });
    }
    return out;
  }

  /**
   * 恢复收藏：合并而不是覆盖。
   * 覆盖会让"先听了一阵子、再恢复一份旧备份"的用户丢掉这段时间的新收藏，
   * 而他的本意几乎不可能是"丢掉新的"。
   */
  static async mergeFavorites(uris: string[]): Promise<number> {
    let n: number = 0;
    for (const u of uris) {
      if (PlaylistStore.favSet.has(u)) {
        continue;
      }
      await PlaylistStore.db.executeSql('INSERT OR REPLACE INTO favorite (uri, added_at) VALUES (?, ?)',
        [u, Date.now()]);
      PlaylistStore.favSet.add(u);
      n++;
    }
    return n;
  }

  static async mergeRecent(uris: string[]): Promise<number> {
    let n: number = 0;
    for (const u of uris) {
      await PlaylistStore.db.executeSql('INSERT OR IGNORE INTO recent (uri, played_at) VALUES (?, ?)',
        [u, Date.now()]);
      n++;
    }
    return n;
  }

  /** 恢复歌单：同名歌单已存在时追加曲目，不新建一条同名记录 */
  static async mergePlaylist(name: string, uris: string[]): Promise<boolean> {
    const rs: relationalStore.ResultSet =
      await PlaylistStore.db.querySql('SELECT id FROM playlist WHERE name = ? LIMIT 1', [name]);
    let id: number = -1;
    if (rs.goToFirstRow()) {
      id = rs.getLong(rs.getColumnIndex('id'));
    }
    rs.close();
    const created: boolean = id < 0;
    if (created) {
      id = await PlaylistStore.createPlaylist(name);
    }
    let ord: number = 0;
    const rs2: relationalStore.ResultSet =
      await PlaylistStore.db.querySql('SELECT MAX(ord) AS m FROM playlist_track WHERE playlist_id = ?', [id]);
    if (rs2.goToFirstRow()) {
      ord = rs2.getLong(rs2.getColumnIndex('m')) + 1;
    }
    rs2.close();
    for (const u of uris) {
      await PlaylistStore.db.executeSql(
        'INSERT OR IGNORE INTO playlist_track (playlist_id, uri, ord) VALUES (?, ?, ?)', [id, u, ord]);
      ord++;
    }
    await PlaylistStore.db.executeSql('UPDATE playlist SET updated_at = ? WHERE id = ?', [Date.now(), id]);
    return created;
  }
}
