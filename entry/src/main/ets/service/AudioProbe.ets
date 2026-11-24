import { audio } from '@kit.AudioKit';
import { Logger } from '../common/Logger';

const TAG: string = 'AudioProbe';

/** 一次音频能力探测的结果 */
export interface AudioProbeReport {
  /** 系统对该 StreamUsage 实际开放的音效模式，如 "NONE / DEFAULT" */
  modes: string;
  /** 是否存在参数化音效（频段增益）通道 */
  eq: boolean;
  /** 一句话结论 */
  note: string;
}

/**
 * 音频能力探测。
 *
 * 为什么要有这个东西：产品规划里最容易翻车的一条是"加个 10 段 EQ"。
 * 鸿蒙给第三方开放的音频音效接口只有 AudioEffectMode 两态（EFFECT_NONE / EFFECT_DEFAULT），
 * 也就是"用系统音效"或"绕开系统音效"；SDK 里没有 AudioEffectManager、没有频段增益 API，
 * AudioLoopbackEqualizerPreset 只作用于耳返，不作用于播放链路。
 *
 * 所以这个 App 不承诺"调曲线"，只做能真做到的事：直出（旁路系统音效）。
 * 这个探测把上述结论在真机上跑一次，输出到 hilog 和设置页，避免以后被"文档说可以"骗。
 *
 * 若将来系统开放了参数化音效，这里会直接读到多于两种模式，Equals 判断自然会把 eq 置 true。
 */
export class AudioProbe {

  static async inspect(): Promise<AudioProbeReport> {
    // 注意：这个接口在 AudioStreamManager 上，不在 AudioManager 上。
    // 文档标题容易看错，编译期报 "does not exist on type AudioManager" 就是这个原因。
    const stream: audio.AudioStreamManager = audio.getAudioManager().getStreamManager();
    let modes: string = '读取失败';
    let count: number = 0;
    try {
      const arr: audio.AudioEffectInfoArray =
        await stream.getAudioEffectInfoArray(audio.StreamUsage.STREAM_USAGE_MUSIC);
      const out: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push(arr[i] === audio.AudioEffectMode.EFFECT_NONE ? 'NONE' : 'DEFAULT');
      }
      count = out.length;
      modes = out.length > 0 ? out.join(' / ') : '空';
    } catch (e) {
      Logger.warn(TAG, `getAudioEffectInfoArray failed ${JSON.stringify(e)}`);
    }

    // 只有"关/默认"两态 → 没有可供第三方调参的通道。
    // 将来系统如果开放多档模式或频段接口，这里会随之变成 true。
    let eq: boolean = false;
    if (count > 2) {
      eq = true;
    }

    let note: string = '未取到系统音效信息';
    if (count > 0) {
      note = eq
        ? '系统开放了多档音效模式'
        : '仅开放「关/默认」两态，无频段增益通道';
    }

    Logger.info(TAG, `modes=${modes} count=${count} eq=${eq}`);
    return { modes: modes, eq: eq, note: note };
  }
}
