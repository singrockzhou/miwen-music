import { mediaquery } from '@kit.ArkUI';
import { Const } from './Constants';
import { BP_KEY } from './Theme';
import { Logger } from './Logger';

const TAG: string = 'UiEnv';

/**
 * 布局断点。
 *
 * 为什么不每页各听一次窗口：监听器是全局资源，页面来回切会越挂越多。
 * 这里只在启动时挂两个查询，结果写 AppStorage，页面用 @StorageProp('bp') 订阅。
 *
 * sm < 600vp ≤ md < 840vp ≤ lg
 * 对应：手机 / 折叠展开·小平板 / 平板·鸿蒙 PC
 */
export class UiEnv {
  private static inited: boolean = false;
  private static mdOn: boolean = false;
  private static lgOn: boolean = false;

  static init(): void {
    if (UiEnv.inited) {
      return;
    }
    UiEnv.inited = true;
    AppStorage.setOrCreate(BP_KEY, Const.BP_SM);
    try {
      const md: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(600vp<=width)');
      UiEnv.mdOn = md.matches;
      md.on('change', (r: mediaquery.MediaQueryResult) => {
        UiEnv.mdOn = r.matches;
        UiEnv.apply();
      });
      const lg: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(840vp<=width)');
      UiEnv.lgOn = lg.matches;
      lg.on('change', (r: mediaquery.MediaQueryResult) => {
        UiEnv.lgOn = r.matches;
        UiEnv.apply();
      });
      UiEnv.apply();
    } catch (e) {
      Logger.warn(TAG, `matchMedia failed, fallback sm: ${JSON.stringify(e)}`);
    }
  }

  private static apply(): void {
    let bp: string = Const.BP_SM;
    if (UiEnv.lgOn) {
      bp = Const.BP_LG;
    } else if (UiEnv.mdOn) {
      bp = Const.BP_MD;
    }
    AppStorage.setOrCreate(BP_KEY, bp);
  }

  /** 封面墙列数：手机 2 列（封面够大才有"唱片"感），平板铺 4~5 列 */
  static columns(bp: string): number {
    if (bp === Const.BP_LG) {
      return 5;
    }
    if (bp === Const.BP_MD) {
      return 4;
    }
    return 2;
  }

  /** Grid 的 columnsTemplate */
  static gridTemplate(bp: string): string {
    const n: number = UiEnv.columns(bp);
    let t: string = '1fr';
    for (let i = 1; i < n; i++) {
      t += ' 1fr';
    }
    return t;
  }

  /** 页面左右留白：小屏 20，大屏收到 32 并限制内容宽 */
  static pagePadding(bp: string): number {
    return bp === Const.BP_SM ? 20 : 32;
  }

  /** 设置/收藏这类表单页的最大内容宽，避免在 PC 上被拉成一条 */
  static contentMax(bp: string): number {
    return bp === Const.BP_SM ? 0 : 760;
  }

  /** 播放页是否为左右分栏（平板/PC） */
  static playerSplit(bp: string): boolean {
    return bp !== Const.BP_SM;
  }
}
