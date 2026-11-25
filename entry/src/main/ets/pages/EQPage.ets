import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { Theme, Tokens } from '../common/Theme';
import { ProService } from '../service/ProService';
import { PlayerCore } from '../service/PlayerCore';
import { EqState } from '../service/NativePlayer';
import { EqConfig, EqBand } from 'libmiwen.so';

const TAG: string = 'EQPage';

interface PresetDef {
  key: string;
  label: string;
  gains: number[];
}

/**
 * 预设表（v1.8.0）。10 段频点 31–16k，与官方 AudioSuite 内置预设同源口径
 * （BALLADS/CLASSICAL/POP/RB/ROCK/JAZZ/DANCE 的增益表取自官方文档，
 * 见 docs/密纹音乐-EQ参数化均衡器可行性说明.md 证据 #3）；
 * 人声/低音/高音为自定义曲线。
 */
const PRESETS: PresetDef[] = [
  { key: 'flat', label: '平直', gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
  { key: 'pop', label: '流行', gains: [5, 2, 1, -1, -5, -5, -2, 1, 2, 4] },
  { key: 'rock', label: '摇滚', gains: [6, 4, 4, 2, 0, 1, 3, 3, 5, 4] },
  { key: 'jazz', label: '爵士', gains: [2, 0, 2, 3, 6, 5, -1, 3, 4, 4] },
  { key: 'classical', label: '古典', gains: [2, 3, 2, 1, 0, 0, -5, -5, -5, -6] },
  { key: 'dance', label: '电子', gains: [4, 3, 2, -3, 0, 0, 5, 4, 2, 0] },
  { key: 'vocal', label: '人声', gains: [-2, -1, 0, 2, 4, 4, 3, 2, 1, 0] },
  { key: 'bass', label: '低音', gains: [7, 6, 4, 2, 1, 0, 0, 0, 0, 0] },
  { key: 'treble', label: '高音', gains: [0, 0, 0, 0, 0, 1, 2, 4, 6, 7] }
];

const BAND_LABELS: string[] = ['31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];
const TYPE_LABELS: string[] = ['峰型', '低架', '高架'];

/**
 * 均衡器页（v1.8.0，Pro）。
 *
 * 两个 tab：图形（10 段固定频点调增益）与参数（每段可调类型/频点/Q——参数化口径，
 * 系统任何版本都不提供，见可行性说明）。所有改动实时应用：
 * - 原生解码通道（无损/DSD）立即生效，native 侧 256 帧系数插值防爆音；
 * - AVPlayer 通道（MP3/AAC 回退）拿不到 PCM，EQ 不覆盖——页面文案如实说明。
 * EQ 关闭（或全零增益）时 native 逐样本旁路，与直出模式逐字节等价。
 */
@Entry
@Component
struct EQPage {
  @State eqOn: boolean = false;
  @State preamp: number = 0;
  @State presetKey: string = 'flat';
  @State bands: EqBand[] = EqState.defaultConfig().bands;
  @State tab: number = 0;          // 0 图形 / 1 参数
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('accentPin') accentPin: string = '';
  @StorageProp('proOwned') proOwned: boolean = false;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;

  private core: PlayerCore = PlayerCore.instance();
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    // 内核的会话级配置是真源（setEq 总是同时更新会话与持久化）
    const saved: EqConfig = this.core.getEq();
    this.eqOn = saved.enabled;
    this.preamp = saved.preamp;
    this.presetKey = saved.preset ?? 'custom';
    this.bands = saved.bands.slice();
  }

  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.Friction })
      .slide(SlideEffect.Right)
    PageTransitionExit({ duration: 240, curve: Curve.Friction })
      .slide(SlideEffect.Right)
  }

  private c(): Tokens {
    return Theme.of(this.themeKey, this.accentPin);
  }

  /** 把当前状态应用回内核（持久化 + 实时生效都在 setEq 里完成） */
  private apply(): void {
    const cfg: EqConfig = {
      enabled: this.eqOn,
      preamp: this.preamp,
      preset: this.presetKey,
      bands: this.bands.slice()
    };
    this.core.setEq(cfg);
  }

  private setBand(i: number, patch: EqBand): void {
    const next: EqBand[] = this.bands.slice();
    next[i] = patch;
    this.bands = next;
    this.presetKey = 'custom';
    this.apply();
  }

  private applyPreset(p: PresetDef): void {
    const freqs: number[] = EqState.freqs();
    const next: EqBand[] = [];
    for (let i = 0; i < 10; i++) {
      next.push({ type: 0, freq: freqs[i], gain: p.gains[i], q: 1.1 });
    }
    this.bands = next;
    this.presetKey = p.key;
    if (!this.eqOn) {
      this.eqOn = true;  // 选预设即视为启用
    }
    this.apply();
  }

  private presetLabel(): string {
    if (this.presetKey === 'custom') {
      return '自定义';
    }
    for (const p of PRESETS) {
      if (p.key === this.presetKey) {
        return p.label;
      }
    }
    return '平直';
  }

  /** 频点 slider 的对数映射：pos 0..100 → 20Hz..20kHz（5 个数量级） */
  private posToFreq(pos: number): number {
    return Math.round(20.0 * Math.pow(1000.0, pos / 100.0));
  }

  private freqToPos(freq: number): number {
    return Math.round(100.0 * Math.log(Math.max(20, freq) / 20.0) / Math.log(1000.0));
  }

  /** Q slider 的对数映射：pos 0..100 → 0.2..20 */
  private posToQ(pos: number): number {
    return Math.round(0.2 * Math.pow(100.0, pos / 100.0) * 100) / 100;
  }

  private qToPos(q: number): number {
    return Math.round(100.0 * Math.log(Math.max(0.2, q) / 0.2) / Math.log(100.0));
  }

  build() {
    Stack() {
      Column() {
        // 顶栏
        Row() {
          Text('‹')
            .fontSize(26)
            .fontColor(this.c().dim)
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .onClick(() => router.back())
          Column() {
            Text('均衡器')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.c().text)
              .letterSpacing(1.2)
            Text('EQUALIZER')
              .fontSize(6)
              .fontColor(this.c().faint)
              .letterSpacing(2.4)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 6 })
          Blank()
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 6 })

        Scroll() {
          Column() {
            // ---- 总开关 ----
            Row() {
              Column() {
                Text('启用均衡器')
                  .fontSize(12)
                  .fontColor(this.c().text)
                Text(this.eqOn ? '调音生效中 · ' + this.presetLabel() : '关闭 = 逐样本旁路，与直出模式等价')
                  .fontSize(9)
                  .fontColor(this.c().faint)
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.eqOn })
                .selectedColor(this.c().accent)
                .onChange((on: boolean) => {
                  this.eqOn = on;
                  this.apply();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 10 })

            Divider().color(this.c().lineSoft).strokeWidth(0.5)

            // ---- PreAmp ----
            Column() {
              Row() {
                Text('前置增益 PreAmp')
                  .fontSize(12)
                  .fontColor(this.c().text)
                Blank()
                Text(`${this.preamp >= 0 ? '+' : ''}${this.preamp.toFixed(1)} dB`)
                  .fontSize(11)
                  .fontColor(this.preamp > 0 ? this.c().danger : this.c().dim)
              }
              .width('100%')
              Slider({ value: this.preamp, min: -18, max: 18, step: 0.5 })
                .selectedColor(this.c().accent)
                .trackColor(this.c().lineSoft)
                .width('100%')
                .onChange((v: number) => {
                  this.preamp = v;
                  this.apply();
                })
              Text('正增益有削波风险，用负值预留动态余量')
                .fontSize(9)
                .fontColor(this.c().faint)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 12 })

            Divider().color(this.c().lineSoft).strokeWidth(0.5)

            // ---- 预设 ----
            Column() {
              Text('预设')
                .fontSize(12)
                .fontColor(this.c().text)
                .margin({ bottom: 8 })
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(PRESETS, (p: PresetDef) => {
                  Text(p.label)
                    .fontSize(10)
                    .fontColor(this.presetKey === p.key ? this.c().onAccent : this.c().dim)
                    .backgroundColor(this.presetKey === p.key ? this.c().accent : this.c().surfaceAlt)
                    .borderRadius(12)
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .margin({ right: 6, bottom: 6 })
                    .onClick(() => {
                      this.applyPreset(p);
                    })
                }, (p: PresetDef) => p.key)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 12 })

            Divider().color(this.c().lineSoft).strokeWidth(0.5)

            // ---- 增益柱状示意 ----
            Row() {
              ForEach(this.bands, (b: EqBand, i: number) => {
                Column() {
                  Column()
                    .width(10)
                    .height(this.barHeight(b.gain))
                    .backgroundColor(b.gain >= 0 ? this.c().accent : this.c().dim)
                    .borderRadius(2)
                  Text(BAND_LABELS[i])
                    .fontSize(7)
                    .fontColor(this.c().faint)
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
              }, (b: EqBand, i: number) => `${i}_${b.gain}_${b.freq}_${b.q}_${b.type}`)
            }
            .width('100%')
            .height(70)
            .alignItems(VerticalAlign.Bottom)
            .padding({ left: 16, right: 16, top: 12 })

            Divider().color(this.c().lineSoft).strokeWidth(0.5)

            // ---- tab ----
            Row() {
              Text('图形 10 段')
                .fontSize(11)
                .fontColor(this.tab === 0 ? this.c().accent : this.c().dim)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .border({ width: { bottom: 2 }, color: this.tab === 0 ? this.c().accent : this.c().lineSoft })
                .onClick(() => {
                  this.tab = 0;
                })
              Text('参数 PEQ')
                .fontSize(11)
                .fontColor(this.tab === 1 ? this.c().accent : this.c().dim)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ left: 8 })
                .border({ width: { bottom: 2 }, color: this.tab === 1 ? this.c().accent : this.c().lineSoft })
                .onClick(() => {
                  this.tab = 1;
                })
              Blank()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10 })

            if (this.tab === 0) {
              // 图形 10 段：每段一行 slider
              Column() {
                ForEach(this.bands, (b: EqBand, i: number) => {
                  Row() {
                    Text(BAND_LABELS[i])
                      .fontSize(10)
                      .fontColor(this.c().dim)
                      .width(34)
                    Slider({ value: b.gain, min: -12, max: 12, step: 0.5 })
                      .selectedColor(this.c().accent)
                      .trackColor(this.c().lineSoft)
                      .layoutWeight(1)
                      .onChange((v: number) => {
                        if (Math.abs(v - this.bands[i].gain) > 0.01) {
                          this.setBand(i, {
                            type: this.bands[i].type,
                            freq: this.bands[i].freq,
                            gain: v,
                            q: this.bands[i].q
                          });
                        }
                      })
                    Text(`${b.gain >= 0 ? '+' : ''}${b.gain.toFixed(1)}`)
                      .fontSize(9)
                      .fontColor(this.c().dim)
                      .width(38)
                      .textAlign(TextAlign.End)
                  }
                  .width('100%')
                  .padding({ top: 4, bottom: 4 })
                }, (b: EqBand, i: number) => `g_${i}_${b.freq}_${b.q}_${b.type}_${b.gain}`)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 6, bottom: 12 })
            } else {
              // 参数 PEQ：类型 / 频点 / Q 可调
              Column() {
                ForEach(this.bands, (b: EqBand, i: number) => {
                  Column() {
                    Row() {
                      ForEach([0, 1, 2], (t: number) => {
                        Text(TYPE_LABELS[t])
                          .fontSize(8)
                          .fontColor(b.type === t ? this.c().onAccent : this.c().dim)
                          .backgroundColor(b.type === t ? this.c().accent : this.c().surfaceAlt)
                          .borderRadius(8)
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .margin({ right: 4 })
                          .onClick(() => {
                            this.setBand(i, {
                              type: t,
                              freq: b.freq,
                              gain: b.gain,
                              q: b.q
                            });
                          })
                      }, (t: number) => `${i}_t${t}`)
                      Blank()
                      Text(BAND_LABELS[i] + (Math.abs(b.freq - EqState.freqs()[i]) > 0.5
                        ? `→${this.fmtFreq(b.freq)}` : ''))
                        .fontSize(9)
                        .fontColor(this.c().faint)
                    }
                    .width('100%')
                    Row() {
                      Text('频点')
                        .fontSize(8)
                        .fontColor(this.c().faint)
                        .width(30)
                      Slider({ value: this.freqToPos(b.freq), min: 0, max: 100, step: 1 })
                        .selectedColor(this.c().accent)
                        .trackColor(this.c().lineSoft)
                        .layoutWeight(1)
                        .onChange((v: number) => {
                          const f: number = this.posToFreq(v);
                          if (Math.abs(f - this.bands[i].freq) > 0.5) {
                            this.setBand(i, { type: b.type, freq: f, gain: b.gain, q: b.q });
                          }
                        })
                      Text(this.fmtFreq(b.freq))
                        .fontSize(8)
                        .fontColor(this.c().dim)
                        .width(52)
                        .textAlign(TextAlign.End)
                    }
                    .width('100%')
                    .padding({ top: 2 })
                    Row() {
                      Text('Q 值')
                        .fontSize(8)
                        .fontColor(this.c().faint)
                        .width(30)
                      Slider({ value: this.qToPos(b.q), min: 0, max: 100, step: 1 })
                        .selectedColor(this.c().accent)
                        .trackColor(this.c().lineSoft)
                        .layoutWeight(1)
                        .onChange((v: number) => {
                          const q: number = this.posToQ(v);
                          if (Math.abs(q - this.bands[i].q) > 0.005) {
                            this.setBand(i, { type: b.type, freq: b.freq, gain: b.gain, q: q });
                          }
                        })
                      Text(b.q.toFixed(2))
                        .fontSize(8)
                        .fontColor(this.c().dim)
                        .width(52)
                        .textAlign(TextAlign.End)
                    }
                    .width('100%')
                    .padding({ top: 2 })
                  }
                  .width('100%')
                  .padding({ top: 8, bottom: 8, left: 4, right: 4 })
                  .border({ width: { bottom: 0.5 }, color: this.c().faint })
                }, (b: EqBand, i: number) => `p_${i}_${b.freq}_${b.q}_${b.type}_${b.gain}`)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 6, bottom: 12 })
            }

            Divider().color(this.c().lineSoft).strokeWidth(0.5)

            // ---- 覆盖范围与重置 ----
            Column() {
              Text('覆盖范围与边界')
                .fontSize(10)
                .fontColor(this.c().dim)
                .fontWeight(FontWeight.Medium)
              Text('仅原生解码通道生效：FLAC / WAV / AIFF / WavPack / ALAC / APE / DSD（dsf·dff·DST）/ SACD ISO。MP3、AAC 走系统播放器，拿不到音频数据，不覆盖；切到这两类格式时 EQ 自动失效，切回无损即恢复。EQ 关闭时与直出模式逐字节等价。')
                .fontSize(9)
                .fontColor(this.c().faint)
                .margin({ top: 5 })
                .lineHeight(14)
              Text('恢复平直')
                .fontSize(11)
                .fontColor(this.c().onAccent)
                .backgroundColor(this.c().accentDeep)
                .borderRadius(14)
                .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                .margin({ top: 10 })
                .onClick(() => {
                  this.applyPreset(PRESETS[0]);
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 24 })
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset, bottom: this.bottomInset })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.c().bg)
  }

  private barHeight(gain: number): number {
    // ±12dB 映射到 4..58vp，零增益 31（中线占位）
    return Math.max(4, Math.min(58, 31 + gain * 2.2));
  }

  private fmtFreq(f: number): string {
    if (f >= 1000) {
      return `${(f / 1000).toFixed(f >= 10000 ? 0 : 1)}k`;
    }
    return `${Math.round(f)}`;
  }

}
