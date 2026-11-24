import { fileUri } from '@kit.CoreFileKit';
import { Theme, Tokens } from '../common/Theme';
import { Fmt } from '../common/Fmt';

/**
 * 封面。
 *
 * 真实曲目有内嵌封面就直接显示；没有的话不摆灰色占位图，而是按专辑名
 * 生成一张"唱片封套"：底色取自六种旧纸/油墨色，叠 4 圈铜色沟槽，
 * 左下角压一行专辑名，左上角一枚首字。
 *
 * 这样做的原因很实际：本地曲库覆盖率极低，灰方块会把整面墙变成"未加载"的观感；
 * 程序化封套是纯本地绘制，不联网取色、不占存储，也让每张"唱片"有身份。
 */
@Component
export struct CoverArt {
  @Prop coverPath: string = '';
  @Prop seed: string = '';
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop ratio: number = 1;
  @Prop dim: boolean = false;
  /**
   * 小尺寸封套（列表行 42vp、迷你条 38vp）用。
   * 这个尺寸下 9vp 的专辑名 + 7vp 艺人只够糊成一团墨点，刊头必须整块去掉，
   * 只留底色、沟槽和一枚小首字——远看还是"一张唱片"，近看也不会脏。
   */
  @Prop compact: boolean = false;
  @StorageProp('themeKey') themeKey: string = 'dark';

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  private uri(): string {
    return this.coverPath.length > 0 ? fileUri.getUriFromPath(this.coverPath) : '';
  }

  @Builder
  Sleeve() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 底色：唯一的高饱和色源
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.sleeve(this.seed.length > 0 ? this.seed : this.title))

      // 沟槽：3 圈不等距细线，小尺寸下只剩"纹"的暗示
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width('78%')
          .height('78%')
          .fill(Color.Transparent)
          .stroke('#59C8A96A')
          .strokeWidth(0.6)
        Circle()
          .width('60%')
          .height('60%')
          .fill(Color.Transparent)
          .stroke('#40C8A96A')
          .strokeWidth(0.6)
        Circle()
          .width('44%')
          .height('44%')
          .fill(Color.Transparent)
          .stroke('#2EC8A96A')
          .strokeWidth(0.6)
      }
      .width('100%')
      .height('100%')

      // 首字：像封套上的烫印，压得很低
      Stack({ alignContent: Alignment.Center }) {
        Text(Fmt.initial(this.title))
          .fontSize(this.compact ? 17 : (this.ratio > 1.2 ? 92 : 58))
          .fontWeight(FontWeight.Bold)
          .fontColor('#F4EFE6')
          .opacity(this.compact ? 0.26 : 0.16)
      }
      .width('100%')
      .height('100%')

      // 左下角刊头：小尺寸下整块省掉
      if (!this.compact) {
        Column() {
          Row()
            .width(18)
            .height(1)
            .backgroundColor('#B3C8A96A')
          Text(this.title)
            .fontSize(9)
            .fontColor('#F4EFE6')
            .opacity(0.92)
            .letterSpacing(0.6)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(7)
              .fontColor('#F4EFE6')
              .opacity(0.56)
              .letterSpacing(0.4)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 10, right: 10, bottom: 9 })
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.uri().length > 0) {
        Image(this.uri())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.Medium)
          .backgroundColor(this.c().surfaceAlt)
      } else {
        this.Sleeve()
      }

      // 极细描边：浅色主题下没有它，封套会"糊"进纸白底
      Column()
        .width('100%')
        .height('100%')
        .border({ width: 0.5, color: '#1FFFFFFF' })

      if (this.dim) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
      }
    }
    .width('100%')
    .aspectRatio(1)
    .backgroundColor(this.c().surfaceAlt)
    .clip(true)
  }
}
