import { Theme, Tokens } from '../common/Theme';

/** 面板里的一行 */
export interface ActionItem {
  label: string;
  hint: string;
  danger: boolean;
}

/**
 * 长按/更多 面板。
 *
 * 不用系统 ActionMenu：它的圆角卡片 + 系统蓝会和这套"纸面"冲突。
 * 这里是从底部浮起的一整块纸，行与行之间只有发丝线，没有圆角、没有阴影堆叠。
 * 覆盖层的点击关闭自己做，避免弹层穿透到列表。
 */
@Component
export struct ActionPanel {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop items: ActionItem[] = [];
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('accentPin') accentPin: string = '';
  onPick: (index: number) => void = () => {
  };
  onClose: () => void = () => {
  };

  private c(): Tokens {
    return Theme.of(this.themeKey, this.accentPin);
  }

  build() {
    Column() {
      // 遮罩
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#73000000')
        .onClick(() => this.onClose())

      Column() {
        // 抬头
        Row() {
          Column() {
            Text(this.title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.c().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.subtitle)
              .fontSize(9)
              .fontColor(this.c().dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('关闭')
            .fontSize(10)
            .fontColor(this.c().dim)
            .padding({ left: 10, right: 2, top: 8, bottom: 8 })
            .onClick(() => this.onClose())
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 14 })

        Row()
          .width('100%')
          .height(0.5)
          .backgroundColor(this.c().lineSoft)

        ForEach(this.items, (it: ActionItem, i: number) => {
          Row() {
            Text(it.label)
              .fontSize(13)
              .fontColor(it.danger ? this.c().danger : this.c().text)
            Blank()
            Text(it.hint)
              .fontSize(9)
              .fontColor(this.c().faint)
          }
          .width('100%')
          .height(52)
          .padding({ left: 20, right: 20 })
          .onClick(() => this.onPick(i))

          if (i < this.items.length - 1) {
            Row() {
              Row()
                .width('100%')
                .height(0.5)
                .backgroundColor(this.c().lineSoft)
            }
            .width('100%')
            .padding({ left: 20 })
          }
        }, (it: ActionItem, i: number) => `${i}_${it.label}`)

        Row()
          .width('100%')
          .height(0.5)
          .backgroundColor(this.c().lineSoft)

        Text('取消')
          .fontSize(12)
          .fontColor(this.c().dim)
          .width('100%')
          .textAlign(TextAlign.Center)
          .height(50)
          .onClick(() => this.onClose())
      }
      .width('100%')
      .constraintSize({ maxWidth: 620 })
      .alignSelf(ItemAlign.Center)
      .backgroundColor(this.c().surface)
      .border({ width: { top: 0.5 }, color: this.c().line })
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 24 })))
    }
    .width('100%')
    .height('100%')
  }
}
