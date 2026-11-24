import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { SettingsService } from './SettingsService';

const TAG: string = 'ProService';

/** Pro 状态进 AppStorage，页面用 @StorageProp('proOwned') 订阅，买完立刻刷新 */
export const PRO_KEY: string = 'proOwned';

/**
 * 密纹 Pro 授权。
 *
 * 三种状态：
 * - 未购：Pro 功能点下去弹购买面板；
 * - 正版：走华为应用市场 IAP 的非消耗型商品（一次买断），凭证本地缓存后永久离线可用；
 * - 开发版授权：还没配商品时，用来在真机上把"锁 → 面板 → 解锁 → 功能可用"这条链走通。
 *
 * 为什么要区分正版和开发版：两者都让功能可用，但设置页必须如实显示来源，
 * 否则会拿一台"看着已购、其实没付钱"的机器去做验收，把结论骗了。
 */
export class ProService {

  static isPro(): boolean {
    return SettingsService.getStr(Const.KEY_PRO_OWNED, '0') === '1';
  }

  /** 解锁日期，未购返回空串 */
  static since(): string {
    return SettingsService.getStr(Const.KEY_PRO_SINCE, '');
  }

  static isDevGrant(): boolean {
    return SettingsService.getStr(Const.KEY_PRO_DEV, '0') === '1';
  }

  /**
   * 开发版体验授权。
   * 真机验收用：不产生任何扣费，也不联网。正式上架前必须删掉入口（或加 isDebug 判断）。
   */
  static grantDev(): void {
    const d: string = ProService.today();
    SettingsService.setStr(Const.KEY_PRO_OWNED, '1');
    SettingsService.setStr(Const.KEY_PRO_SINCE, d);
    SettingsService.setStr(Const.KEY_PRO_DEV, '1');
    AppStorage.setOrCreate(PRO_KEY, true);
    Logger.info(TAG, `dev grant at ${d}`);
  }

  /** 撤销授权，用于反复走验收流程 */
  static revoke(): void {
    SettingsService.setStr(Const.KEY_PRO_OWNED, '0');
    SettingsService.setStr(Const.KEY_PRO_SINCE, '');
    SettingsService.setStr(Const.KEY_PRO_DEV, '0');
    AppStorage.setOrCreate(PRO_KEY, false);
    Logger.info(TAG, 'revoked');
  }

  /** 启动时把已存的授权灌进 AppStorage，页面首帧就能拿到正确状态 */
  static restoreToStorage(): void {
    AppStorage.setOrCreate(PRO_KEY, ProService.isPro());
  }

  static today(): string {
    const d: Date = new Date();
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    return `${d.getFullYear()}-${m < 10 ? '0' : ''}${m}-${day < 10 ? '0' : ''}${day}`;
  }

  // ---------------- 试用 ----------------

  /** 每个功能最多能试几次。3 次足够让人判断"值不值"，又不至于变成免费版 */
  static readonly TRIAL_MAX: number = 3;

  static trialLeft(feature: string): number {
    const used: number = parseInt(SettingsService.getStr(`trial_${feature}`, '0'), 10);
    const n: number = isNaN(used) ? 0 : used;
    return Math.max(0, ProService.TRIAL_MAX - n);
  }

  /**
   * 消耗一次试用。已经买断的直接放行（不扣次数）。
   * 返回 true = 本次可以使用。
   */
  static consumeTrial(feature: string): boolean {
    if (ProService.isPro()) {
      return true;
    }
    const left: number = ProService.trialLeft(feature);
    if (left <= 0) {
      return false;
    }
    SettingsService.setStr(`trial_${feature}`, (ProService.TRIAL_MAX - left + 1).toString());
    Logger.info(TAG, `trial ${feature} used, left ${left - 1}`);
    return true;
  }
}
