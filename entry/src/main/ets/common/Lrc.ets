export interface LrcLine {
  /** 毫秒 */
  time: number;
  text: string;
  /** 译文/第二行：同一时间戳连续出现两次时的后一行，没有就是空串 */
  trans: string;
}

/**
 * 极简 LRC 解析：支持 [mm:ss.xx]、"一行多时间戳"，以及双语双行。
 *
 * 双语双行不是另造格式：市面上双语歌词的标准写法就是**同一时间戳连写两行**
 * （第一行原文、第二行译文）。所以"识别双语"= 识别同一时间戳出现了两次，
 * 不需要任何额外标记，也不会误伤普通歌词。
 *
 * 只做本地 .lrc 与文件内嵌文本，不联网抓歌词、不解析商用歌词站格式 ——
 * 这条红线决定了这个 App 能不能过审。
 */
export class LrcParser {
  static parse(content: string): LrcLine[] {
    const out: LrcLine[] = [];
    const byTime: Map<number, number> = new Map<number, number>();
    const rows: string[] = content.split('\n');
    for (const row of rows) {
      const times: number[] = LrcParser.timesOf(row);
      if (times.length === 0) {
        continue;
      }
      const body: string = row.replace(new RegExp('\\[[0-9]{1,3}:[0-9]{2}(?:[.:][0-9]{1,3})?\\]', 'g'), '').trim();
      if (body.length === 0) {
        continue;
      }
      for (const t of times) {
        const at: number | undefined = byTime.get(t);
        if (at !== undefined && out[at].trans.length === 0) {
          // 同一时间戳的第二行 = 译文。第三行起忽略：再多就不是双语歌词了
          out[at].trans = body;
        } else {
          byTime.set(t, out.length);
          out.push({ time: t, text: body, trans: '' });
        }
      }
    }
    out.sort((a: LrcLine, b: LrcLine) => a.time - b.time);
    return out;
  }

  /** 有至少一行带时间戳，才算"能逐行高亮"的歌词 */
  static isTimed(content: string): boolean {
    const rows: string[] = content.split('\n');
    for (const row of rows) {
      if (LrcParser.timesOf(row).length > 0) {
        return true;
      }
    }
    return false;
  }

  /** 无时间轴的纯文本歌词：按行切开，剔掉 [ar:] 这类元信息与空行 */
  static parsePlain(content: string): string[] {
    const out: string[] = [];
    const rows: string[] = content.replace(/\r/g, '').split('\n');
    for (const row of rows) {
      const s: string = row.trim();
      if (s.length === 0) {
        continue;
      }
      // [xx:yy] 形式但不是时间（ar/ti/al/by/offset）→ 元信息
      if (s.startsWith('[') && s.indexOf(':') > 0 && !LrcParser.isTimeTag(s)) {
        continue;
      }
      out.push(s);
    }
    return out;
  }

  private static isTimeTag(s: string): boolean {
    return new RegExp('^\\[[0-9]{1,3}:[0-9]{2}(?:[.:][0-9]{1,3})?\\]').test(s);
  }

  private static timesOf(row: string): number[] {
    const out: number[] = [];
    const reg: RegExp = new RegExp('\\[([0-9]{1,3}):([0-9]{2})(?:[.:]([0-9]{1,3}))?\\]', 'g');
    let m: RegExpExecArray | null = reg.exec(row);
    while (m !== null) {
      const min: number = parseInt(m[1], 10);
      const sec: number = parseInt(m[2], 10);
      const frac: string = m[3] === undefined ? '' : m[3];
      const ms: number = frac.length === 0 ? 0 : parseInt(frac.padEnd(3, '0').substring(0, 3), 10);
      out.push(min * 60000 + sec * 1000 + ms);
      m = reg.exec(row);
    }
    return out;
  }

  /**
   * 按时间窗裁剪并平移，返回新的 LRC 文本（CUE 虚拟轨专用）。
   *
   * 问题的形状：同名 `.lrc` 是针对**整轨文件**写的，行时间相对文件头；
   * 而虚拟轨的 `position` 是相对片头（`seek(cueStart)` 之后 `currentTime - cueStart`）。
   * 两者差一个 `cueStart`，不处理的结果就是三个虚拟轨都从第 1 行开始唱
   * （真机验证报告 11.7 记录，截屏 W3：第三轨开头仍显示「低频探针」）。
   *
   * 做法：取 `[startMs, endMs)` 窗口内的行，时间逐行减去 `startMs`；
   * 窗口外的行直接丢掉 —— 跨到别轨去的那一句本来就不属于这一轨，
   * 保留反而会让第 1 轨唱出第 2 轨的词。`endMs <= startMs` 表示"到文件尾"（末轨）。
   *
   * 输出用 2 位小数（10ms）。这不是随手选的：系统桌面歌词的时间戳解析只在
   * `[mm:ss.xx]` 这种形态上验证过（11.3 的逐行高亮就是用这种格式跑通的），
   * 换成 3 位小数没有必要去赌系统侧解析。
   *
   * 已知不支持：`[offset:±N]` 标签。当前整条解析链都不处理它，
   * 带 offset 的音源会出现整体偏移，与本次的"分轨串词"是两件事。
   */
  static slice(content: string, startMs: number, endMs: number): string {
    const lines: LrcLine[] = LrcParser.parse(content);
    const out: string[] = [];
    for (const l of lines) {
      if (l.time < startMs) {
        continue;
      }
      if (endMs > startMs && l.time >= endMs) {
        continue;
      }
      const tag: string = LrcParser.stamp(l.time - startMs);
      out.push(`${tag}${l.text}`);
      // 双语：同时间戳再写一行，parse 时会重新合并成 text + trans
      if (l.trans.length > 0) {
        out.push(`${tag}${l.trans}`);
      }
    }
    return out.join('\n');
  }

  /** 毫秒 → `[mm:ss.cc]`；四舍五入到 10ms（歌词精度足够，格式与已验证的一致） */
  private static stamp(ms: number): string {
    const cs: number = Math.round(Math.max(0, ms) / 10);
    const frac: string = (cs % 100).toString().padStart(2, '0');
    const sec: string = (Math.floor(cs / 100) % 60).toString().padStart(2, '0');
    const min: string = Math.floor(cs / 6000).toString().padStart(2, '0');
    return `[${min}:${sec}.${frac}]`;
  }

  /** 二分找当前行；没有则返回 -1 */
  static indexAt(lines: LrcLine[], ms: number): number {
    if (lines.length === 0) {
      return -1;
    }
    let lo: number = 0;
    let hi: number = lines.length - 1;
    let ans: number = -1;
    while (lo <= hi) {
      const mid: number = Math.floor((lo + hi) / 2);
      if (lines[mid].time <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /** 有没有任何一行带译文 */
  static hasTrans(lines: LrcLine[]): boolean {
    for (const l of lines) {
      if (l.trans.length > 0) {
        return true;
      }
    }
    return false;
  }
}
