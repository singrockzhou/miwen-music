import { Track, emptyTrack } from '../model/Track';
import { Theme, Tokens } from '../common/Theme';
import { Fmt } from '../common/Fmt';
import { CoverArt } from './CoverArt';

/**
 * 曲目行：一屏要能看见格式与采样率。
 *
 * 密度优先：标题一行、副信息一行、右侧格式/采样率 + 时长；
 * 正在播放的那一行标题转铜色，并在最左侧压一条 2×14 的实心短线，
 * 不做整行高亮（整行高亮会破坏"纸面"的干净感）。
 */
@Component
export struct TrackRow {
  @Prop track: Track = emptyTrack();
  @Prop active: boolean = false;
  @Prop playing: boolean = false;
  @Prop showCover: boolean = true;
  @Prop showIndex: boolean = false;
  @Prop index: number = 0;
  @Prop last: boolean = false;
  @StorageProp('themeKey') themeKey: string = 'dark';

  onTap: () => void = () => {
  };
  onLong: () => void = () => {
  };

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  private metaLine(): string {
    const t: Track = this.track;
    return Fmt.meta(t.artist, t.album);
  }

  private formatLine(): string {
    const t: Track = this.track;
    const rate: string = Fmt.rate(t.sampleRate);
    return rate.length > 0 ? `${Fmt.fmt(t.suffix)} · ${rate}` : Fmt.fmt(t.suffix);
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        // 左：封面 或 序号
        if (this.showCover) {
          Stack() {
            CoverArt({
              coverPath: this.track.coverPath,
              seed: this.track.album.length > 0 ? this.track.album : this.track.title,
              title: this.track.album.length > 0 ? this.track.album : this.track.title,
              subtitle: '',
              compact: true
            })
            if (this.active) {
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor('#4D000000')
            }
          }
          .width(42)
          .height(42)
        } else {
          Text(this.showIndex ? (this.index + 1).toString().padStart(2, '0') : '')
            .fontSize(10)
            .fontColor(this.active ? this.c().accent : this.c().faint)
            .width(22)
            .textAlign(TextAlign.Center)
        }

        // 中：标题 + 副信息
        Column() {
          Row({ space: 6 }) {
            if (this.active) {
              Row()
                .width(2)
                .height(11)
                .backgroundColor(this.c().accent)
            }
            Text(this.track.title.length > 0 ? this.track.title : '未命名曲目')
              .fontSize(13)
              .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.active ? this.c().accent : this.c().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')

          Text(this.metaLine())
            .fontSize(9)
            .fontColor(this.c().dim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 右：格式 + 采样率 + 时长
        Column() {
          Text(this.formatLine())
            .fontSize(8)
            .fontColor(this.c().faint)
            .letterSpacing(0.3)
          Text(Fmt.time(this.track.duration))
            .fontSize(9)
            .fontColor(this.c().faint)
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)

      if (!this.last) {
        Row() {
          Row()
            .width('100%')
            .height(0.5)
            .backgroundColor(this.c().lineSoft)
        }
        .width('100%')
        .padding({ left: this.showCover ? 54 : 34 })
      }
    }
    .width('100%')
    .onClick(() => this.onTap())
    .gesture(LongPressGesture({ repeat: false }).onAction(() => this.onLong()))
  }
}
