/**
 * 展示层格式化。UI 里不出现裸数字。
 */
export class Fmt {
  /** 毫秒 → mm:ss */
  static time(ms: number): string {
    if (ms <= 0 || !isFinite(ms)) {
      return '00:00';
    }
    const total: number = Math.floor(ms / 1000);
    const m: string = Math.floor(total / 60).toString().padStart(2, '0');
    const s: string = (total % 60).toString().padStart(2, '0');
    return `${m}:${s}`;
  }

  /** 采样率 → 44.1 kHz / 96 kHz（无损党一眼要看的东西） */
  static rate(hz: number): string {
    if (hz <= 0) {
      return '';
    }
    const k: number = hz / 1000;
    const txt: string = k % 1 === 0 ? k.toFixed(0) : k.toFixed(1);
    return `${txt} kHz`;
  }

  /** 文件大小 */
  static bytes(n: number): string {
    if (n <= 0) {
      return '—';
    }
    const mb: number = n / 1024 / 1024;
    if (mb >= 1024) {
      return `${(mb / 1024).toFixed(1)} GB`;
    }
    return `${mb >= 100 ? mb.toFixed(0) : mb.toFixed(1)} MB`;
  }

  /** 后缀 → 大写格式标签 */
  static fmt(suffix: string): string {
    if (suffix.length < 2) {
      return 'AUDIO';
    }
    return suffix.substring(1).toUpperCase();
  }

  /** 毫秒 → "1 小时 12 分" / "38 分钟" */
  static span(ms: number): string {
    const min: number = Math.round(ms / 60000);
    if (min < 60) {
      return `${min} 分钟`;
    }
    const h: number = Math.floor(min / 60);
    const m: number = min % 60;
    return m === 0 ? `${h} 小时` : `${h} 小时 ${m} 分`;
  }

  /** 时间戳 → "刚刚 / 3 分钟前 / 昨天 / 11.20" */
  static ago(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const diff: number = Date.now() - ts;
    if (diff < 60000) {
      return '刚刚';
    }
    if (diff < 3600000) {
      return `${Math.floor(diff / 60000)} 分钟前`;
    }
    const d: Date = new Date(ts);
    const today: Date = new Date();
    if (d.toDateString() === today.toDateString()) {
      return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
    }
    return `${d.getMonth() + 1}.${d.getDate()}`;
  }

  /** 一首歌的副信息：艺人 · 专辑（缺哪项都不断句） */
  static meta(artist: string, album: string): string {
    const parts: string[] = [];
    if (artist.length > 0) {
      parts.push(artist);
    }
    if (album.length > 0) {
      parts.push(album);
    }
    return parts.length > 0 ? parts.join(' · ') : '未知艺人';
  }

  /** 取首字，作为无封面时的占位符号 */
  static initial(s: string): string {
    if (s.length === 0) {
      return '·';
    }
    return s.substring(0, 1).toUpperCase();
  }
}
