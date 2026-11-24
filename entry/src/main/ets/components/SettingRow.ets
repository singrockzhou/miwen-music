import { Theme, Tokens } from '../common/Theme';

/**
 * 设置页的一行。
 *
 * 之所以做成 @Component 而不是 @Builder：@Builder 的参数按值传递后会被冻结，
 * 曲目数、睡眠定时这类会变的值改了也不会刷新（真机上表现为一直显示 0 首）。
 * 组件的 @Prop 会在父组件重渲染时同步过来。
 */
@Component
export struct SettingRow {
  @Prop label: string;
  @Prop value: string = '';
  @Prop detail: string = '';
  @Prop danger: boolean = false;
  @StorageProp('themeKey') themeKey: string = 'dark';
  onTap: () => void = () => {
  };

  build() {
    Column() {
      Row() {
        Text(this.label)
          .fontSize(12)
          .fontColor(this.danger ? this.c().danger : this.c().text)
        Blank()
        if (this.value.length > 0) {
          Text(this.value)
            .fontSize(10)
            .fontColor(this.c().dim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 190 })
        }
      }
      .width('100%')
      .height(this.detail.length > 0 ? 34 : 48)
      .alignItems(VerticalAlign.Bottom)

      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(9)
          .fontColor(this.c().faint)
          .lineHeight(16)
          .width('100%')
          .margin({ top: 4, bottom: 10 })
      }
    }
    .width('100%')
    .padding({ top: 6 })
    .onClick(() => this.onTap())
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }
}
