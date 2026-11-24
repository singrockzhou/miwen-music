/**
 * 播放/暂停图标。
 *
 * 不用字符 '▶' / 'Ⅱ'：'▶' 在鸿蒙上会走 emoji 字体，渲染成系统蓝色圆角方块，
 * 既撞色（Material 蓝）又与「无圆角」的视觉规范冲突。这里全部用形状自绘。
 */
@Component
export struct PlayPauseGlyph {
  @Prop playing: boolean;
  /** 图标整体尺寸（vp），三角形与双竖线都按它等比缩放 */
  @Prop glyph: number;
  @Prop color: string = '#C08A4A';

  build() {
    if (this.playing) {
      Row({ space: this.glyph * 0.16 }) {
        Column()
          .width(this.glyph * 0.1)
          .height(this.glyph * 0.54)
          .backgroundColor(this.color)
        Column()
          .width(this.glyph * 0.1)
          .height(this.glyph * 0.54)
          .backgroundColor(this.color)
      }
      .height(this.glyph * 0.54)
      .justifyContent(FlexAlign.Center)
    } else {
      // 三角形。用 Polygon 而不是 Path：Path 的坐标不随 width/height 缩放，
      // 在真机上会画成一个几乎看不见的小点。
      Column() {
        Polygon({ width: this.glyph * 0.44, height: this.glyph * 0.54 })
          .points([
            [0, 0],
            [0, this.glyph * 0.54],
            [this.glyph * 0.44, this.glyph * 0.27]
          ])
          .fill(this.color)
      }
      .width(this.glyph * 0.54)
      .height(this.glyph * 0.54)
      .alignItems(HorizontalAlign.Center)
    }
  }
}
