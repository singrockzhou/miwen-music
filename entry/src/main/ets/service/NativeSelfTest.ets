import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';
import { NativePlayer } from './NativePlayer';

const TAG: string = 'NativeSelfTest';

/**
 * 原生解码自检。
 *
 * 为什么要自造素材：AIFF 是极少见的收藏格式，要求验收的人先去找一个 .aiff 等于把
 * "能不能播"这件事推给用户。这里现场生成一个 8 秒、每 2 秒换一次频率的 AIFF
 * （440 / 660 / 880 / 1100 Hz），落进沙箱再走真实的 open → AudioRenderer 链路：
 * 听到四个音说明解码、字节序、声道都对；只听得到噪声或音高不对，就是字节序或位深写错了。
 *
 * 生成而不内置二进制素材，还有个好处：仓库里不多一个 1.4 MB 的测试文件。
 */
export class NativeSelfTest {

  private static readonly RATE: number = 44100;
  private static readonly CH: number = 2;
  private static readonly SECONDS: number = 8;
  private static readonly NAME: string = 'native-probe.aiff';

  /** 44100 Hz 的 80 位扩展精度表示（AIFF 的采样率不是整数，是 1+15+64 位的浮点） */
  private static readonly RATE_44100: number[] = [0x40, 0x0E, 0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

  /** 生成 AIFF 到沙箱，返回路径 */
  static makeAiff(ctx: common.UIAbilityContext): string {
    const path: string = `${ctx.filesDir}/${NativeSelfTest.NAME}`;
    const rate: number = NativeSelfTest.RATE;
    const ch: number = NativeSelfTest.CH;
    const frames: number = rate * NativeSelfTest.SECONDS;
    const dataBytes: number = frames * ch * 2;

    // 12（FORM 头） + 26（COMM 8+18） + 16（SSND 8+8） + 数据
    const buf: ArrayBuffer = new ArrayBuffer(54 + dataBytes);
    const view: DataView = new DataView(buf);
    const u8: Uint8Array = new Uint8Array(buf);

    const putAscii = (off: number, s: string): void => {
      for (let i = 0; i < s.length; i++) {
        u8[off + i] = s.charCodeAt(i);
      }
    };

    putAscii(0, 'FORM');
    view.setUint32(4, 4 + 26 + 16 + dataBytes, false);
    putAscii(8, 'AIFF');

    putAscii(12, 'COMM');
    view.setUint32(16, 18, false);
    view.setUint16(20, ch, false);
    view.setUint32(22, frames, false);
    view.setUint16(26, 16, false);
    for (let i = 0; i < 10; i++) {
      u8[28 + i] = NativeSelfTest.RATE_44100[i];
    }

    putAscii(38, 'SSND');
    view.setUint32(42, 8 + dataBytes, false);
    view.setUint32(46, 0, false);
    view.setUint32(50, 0, false);

    const freqs: number[] = [440, 660, 880, 1100];
    let off: number = 54;
    for (let i = 0; i < frames; i++) {
      const seg: number = Math.floor(i / rate);
      const f: number = freqs[seg < freqs.length ? seg : freqs.length - 1];
      const t: number = i / rate;
      const v: number = Math.sin(2 * Math.PI * f * t) * 0.45;
      const iv: number = v < 0 ? Math.round(v * 32768) : Math.round(v * 32767);
      view.setInt16(off, iv, false);
      view.setInt16(off + 2, iv, false);
      off += 4;
    }

    const file: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, buf);
    fs.closeSync(file);
    Logger.info(TAG, `aiff written ${path} ${buf.byteLength} bytes`);
    return path;
  }

  /**
   * 走完整链路：生成素材 → 原生打开 → AudioRenderer 播放。
   * 返回一句可直接 toast 的结论；失败时给出具体原因。
   */
  static async run(ctx: common.UIAbilityContext): Promise<string> {
    const path: string = NativeSelfTest.makeAiff(ctx);
    const player: NativePlayer = new NativePlayer();
    if (!player.open(path)) {
      return `原生解码失败：${player.errorText()}`;
    }
    const dur: number = player.getDurationMs();
    player.setEndCallback(() => {
      Logger.info(TAG, 'self test finished');
      player.stop();
    });
    const started: boolean = await player.start();
    if (!started) {
      return `音频输出启动失败：${player.errorText()}`;
    }
    Logger.info(TAG, `playing ${path} dur=${dur}ms decoder=${NativePlayer.version()}`);
    return `原生解码已启动：${NativePlayer.version()} · ${dur}ms`;
  }
}
