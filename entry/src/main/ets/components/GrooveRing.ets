import { Tokens, Theme } from '../common/Theme';

/**
 * 沟槽进度环。
 *
 * 这是"密纹"这个名字唯一必须落到像素上的地方，所以它不是普通的圆环进度条：
 * - 3 圈不等距沟槽（间距不均，像唱片母版的纹路，不是同心装饰）；
 * - 进度直接长在最外圈沟槽上，不另起一条弧；
 * - 落针点落在进度末端，就是唱针此刻的位置。
 *
 * 用 Canvas 而不是 Progress：Progress 的圆环端点永远是圆的，且没法画出不等距的多圈。
 * 只在进度/主题变化时重绘，不挂每帧动画。
 */
@Component
export struct GrooveRing {
  @Prop @Watch('redraw') progress: number = 0;
  @Prop diameter: number = 300;
  @Prop coverSize: number = 236;
  @StorageProp('themeKey') @Watch('redraw') themeKey: string = 'dark';

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  redraw(): void {
    if (!this.ready) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const s: number = this.diameter;
    const cx: number = s / 2;
    const cy: number = s / 2;
    const line: number = 0.8;
    ctx.clearRect(0, 0, s, s);

    // 1. 三圈不等距沟槽：0.98 / 0.90 / 0.835，间距刻意不均
    const radii: number[] = [s * 0.49, s * 0.45, s * 0.4175];
    for (let i = 0; i < radii.length; i++) {
      ctx.beginPath();
      ctx.lineWidth = line;
      ctx.strokeStyle = i === 0 ? this.c().accentDeep : this.c().groove;
      ctx.arc(cx, cy, radii[i], 0, Math.PI * 2);
      ctx.stroke();
    }

    // 2. 进度长在最外圈：从 12 点方向顺时针
    const outer: number = s * 0.49;
    const p: number = Math.max(0, Math.min(1, this.progress));
    if (p > 0) {
      ctx.beginPath();
      ctx.lineWidth = 2;
      ctx.lineCap = 'round';
      ctx.strokeStyle = this.c().accent;
      ctx.arc(cx, cy, outer, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * p);
      ctx.stroke();
    }

    // 3. 落针点：唱针此刻的位置，也是唯一的实心圆
    const ang: number = -Math.PI / 2 + Math.PI * 2 * p;
    const nx: number = cx + outer * Math.cos(ang);
    const ny: number = cy + outer * Math.sin(ang);
    ctx.beginPath();
    ctx.fillStyle = this.c().accent;
    ctx.arc(nx, ny, 3.2, 0, Math.PI * 2);
    ctx.fill();
  }

  build() {
    Canvas(this.ctx)
      .width(this.diameter)
      .height(this.diameter)
      .onReady(() => {
        this.ready = true;
        this.redraw();
      })
      .onAreaChange(() => {
        this.redraw();
      })
  }
}
