import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Track } from '../model/Track';
import { PlayerCore } from './PlayerCore';
import { RootService } from './RootService';
import { RootDir } from '../model/RootDir';

const TAG: string = 'SelfTest';
const RAW_NAME: string = 'selftest.wav';
const LRC_NAME: string = 'selftest.lrc';

/**
 * 自检歌词：同一时间戳写两行 = 双语双行。
 * 用 4 秒音频卡 4 句，正好能在播放页看到"当前行 + 译文 + 下一行"三段式，
 * 也能用来验时间轴 ±0.5s 微调到底有没有生效。
 */
const LRC_TEXT: string =
  '[00:00.30]唱针落进沟槽\n[00:00.30]The needle drops\n' +
  '[00:01.30]四秒的扫频测试\n[00:01.30]Four seconds of sweep\n' +
  '[00:02.30]听到这一段就说明解码通了\n[00:02.30]If you hear this, decoding works\n' +
  '[00:03.30]密纹 · 只读本地\n[00:03.30]Miwen · local only\n';

/**
 * 播放自检。
 *
 * 示例曲目走的是计时器引擎（不产生真实音频），所以「示例能播」并不等于
 * AVPlayer 这条链路通了。这里把内置的 4 秒测试音从 rawfile 落到沙箱，
 * 再走一遍真实的 openReal：fs.open → fdSrc → prepared → playing，
 * 用来在任意设备上确认解码、音频焦点、AVSession 都是活的。
 */
export class SelfTest {
  static async play(ctx: common.UIAbilityContext): Promise<string> {
    const path: string = `${ctx.filesDir}/${RAW_NAME}`;
    let needCopy: boolean = true;
    try {
      const st: fs.Stat = fs.statSync(path);
      needCopy = st.size <= 0;
    } catch (e) {
      needCopy = true;
    }
    if (needCopy) {
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(RAW_NAME);
      const file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      fs.closeSync(file);
      Logger.info(TAG, `copied rawfile -> ${path} (${bytes.length} bytes)`);
    }
    const stat: fs.Stat = fs.statSync(path);

    // 顺手落一份同名 .lrc：这样"播放自检"同时成了歌词链路（解析 + 双语 + 偏移）的现场样本，
    // 不需要用户先去找一首带歌词的歌。
    try {
      const lrcPath: string = `${ctx.filesDir}/${LRC_NAME}`;
      const lf: fs.File = fs.openSync(lrcPath,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(lf.fd, LRC_TEXT);
      fs.closeSync(lf);
    } catch (e) {
      Logger.warn(TAG, `write lrc failed ${JSON.stringify(e)}`);
    }

    // 同理给已授权曲库里的本地整轨也落一份演示 .lrc（演示词是我们自己造的验收材料，
    // 直接覆盖；时间戳严格递增、每时间戳一行——系统桌面歌词的解析器按时间戳建表，
    // 同时间戳双语双行会让它的行索引错乱，实测高亮卡在第 1 行不跟进度）：
    // 桌面歌词 / 锁屏歌词 / 双语渲染的内容全部来自本地文件，这段让验收不需要自己准备歌词。
    try {
      const demoLrc: string =
        '[00:00.50]低频探针 440 赫兹 / 440 Hz probe\n' +
        '[00:03.50]中频 660 赫兹 / 660 Hz probe\n' +
        '[00:06.50]高频 880 赫兹 / 880 Hz probe\n' +
        '[00:09.50]无缝与分轨 · 验收中 / Seamless & cue test\n';
      const roots: string[] = RootService.list().map((r: RootDir): string => r.path);
      if (roots.length === 0) {
        Logger.info(TAG, 'demo lrc skipped: no authorized root');
      }
      for (const rp of roots) {
        const target: string = `${rp}/cue-fix.wav/cue-fix.lrc`;
        try {
          const lf2: fs.File = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          fs.writeSync(lf2.fd, demoLrc);
          fs.closeSync(lf2);
          Logger.info(TAG, `demo lrc -> ${target}`);
        } catch (e) {
          // 目录不可写/不存在就算了，验收材料而已
        }
      }
    } catch (e) {
      Logger.warn(TAG, `demo lrc skipped ${JSON.stringify(e)}`);
    }

    const t: Track = {
      id: -1,
      uri: fileUri.getUriFromPath(path),
      path: path,
      title: '播放自检',
      artist: '内置扫频 4 秒',
      album: '自检',
      duration: 0,
      sampleRate: 22050,
      bitrate: 352,
      suffix: '.wav',
      size: stat.size,
      mtime: 0,
      coverPath: '',
      folder: '',
      rootPath: '',
      source: Const.SRC_LOCAL,
      cueStart: -1,
      cueEnd: -1
    };
    // 追加到队尾再起播：不能直接 setQueue([t], 0)，那会把用户正在听的队列冲掉
    const list: Track[] = PlayerCore.instance().queueTracks().slice(0);
    list.push(t);
    PlayerCore.instance().setQueue(list, list.length - 1);
    await PlayerCore.instance().playAt(list.length - 1);
    return path;
  }
}
