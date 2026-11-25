import { Theme, Tokens } from '../common/Theme';

/**
 * 空态 / 错误态。
 *
 * 不放插画：插画会把"现在就能开始"这件事推远。
 * 只留一个与品牌同源的图形（三圈沟槽 + 落针点）、一句话、一个动作。
 * 空态文案全部说白话，不写"暂无数据"。
 */
@Component
export struct EmptyState {
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop actionLabel: string = '';
  @Prop secondaryLabel: string = '';
  @Prop danger: boolean = false;
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('accentPin') accentPin: string = '';
  onAction: () => void = () => {
  };
  onSecondary: () => void = () => {
  };

  private c(): Tokens {
    return Theme.of(this.themeKey, this.accentPin);
  }

  build() {
    Column() {
      // 图形：与播放页同源的"沟槽 + 落针点"
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(96)
          .height(96)
          .fill(Color.Transparent)
          .stroke(this.c().line)
          .strokeWidth(0.8)
        Circle()
          .width(74)
          .height(74)
          .fill(Color.Transparent)
          .stroke(this.c().lineSoft)
          .strokeWidth(0.8)
        Circle()
          .width(52)
          .height(52)
          .fill(Color.Transparent)
          .stroke(this.c().lineSoft)
          .strokeWidth(0.8)
        Circle()
          .width(5)
          .height(5)
          .fill(this.c().accent)
          .offset({ x: -34, y: -34 })
      }
      .width(120)
      .height(120)

      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.danger ? this.c().danger : this.c().text)
        .letterSpacing(0.4)
        .textAlign(TextAlign.Center)
        .margin({ top: 18 })

      Text(this.hint)
        .fontSize(11)
        .fontColor(this.c().dim)
        .lineHeight(20)
        .textAlign(TextAlign.Center)
        .margin({ top: 10 })
        .padding({ left: 12, right: 12 })

      if (this.actionLabel.length > 0) {
        Text(this.actionLabel)
          .fontSize(12)
          .fontColor(this.c().onAccent)
          .letterSpacing(0.6)
          .padding({ left: 26, right: 26, top: 11, bottom: 11 })
          .backgroundColor(this.c().accent)
          .margin({ top: 24 })
          .onClick(() => this.onAction())
      }

      if (this.secondaryLabel.length > 0) {
        Text(this.secondaryLabel)
          .fontSize(11)
          .fontColor(this.c().dim)
          .padding({ left: 18, right: 18, top: 12, bottom: 12 })
          .margin({ top: 6 })
          .onClick(() => this.onSecondary())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 28, bottom: 28 })
  }
}
