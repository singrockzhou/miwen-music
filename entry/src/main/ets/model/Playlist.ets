/** 歌单（本地手建，不上传、不共享） */
export interface Playlist {
  id: number;
  name: string;
  count: number;
  updatedAt: number;
}

export function emptyPlaylist(): Playlist {
  return { id: 0, name: '', count: 0, updatedAt: 0 };
}

/** 备份/导出用的歌单快照：名字 + 曲目 uri（顺序即播放顺序） */
export interface PlaylistDump {
  name: string;
  uris: string[];
}
