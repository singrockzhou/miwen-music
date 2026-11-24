import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { Logger } from '../common/Logger';
import { Const } from '../common/Constants';
import { TrackStore } from '../db/TrackStore';
import { PlaylistStore } from '../db/PlaylistStore';
import { StatsStore } from '../db/StatsStore';
import { PlayerCore } from '../service/PlayerCore';
import { SettingsService } from '../service/SettingsService';
import { ProService } from '../service/ProService';
import { LibraryService } from '../service/LibraryService';
import { RootService } from '../service/RootService';
import { RootDir } from '../model/RootDir';
import { Theme } from '../common/Theme';

const TAG: string = 'EntryAbility';

/**
 * 启动入口：全应用唯一允许做"初始化副作用"的地方。
 *
 * 顺序不能换：
 * 设置 → 曲库表 → 收藏/歌单表 → 播放内核（要读上次的队列）→ 首次启动补示例 → 加载页面。
 * 任何一步提前，页面就会读到未初始化的单例。
 */
export default class EntryAbility extends UIAbility {
  /** 卡片点了播放键会带 method 进来，等内核就绪再执行 */
  private pendingMethod: string = '';
  /** 主窗口引用：切主题时要靠它改系统栏图标颜色 */
  private win: window.Window | null = null;
  private readonly themeHook: (key: string) => void = (key: string) => {
    this.applyBars(key);
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const m: string = want.parameters?.['method'] as string ?? '';
    if (m.length > 0) {
      this.pendingMethod = m;
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    // 1. 设置（主题、来源、上次的队列都从这里读）
    try {
      await SettingsService.init(this.context);
      SettingsService.onThemeChange(this.themeHook);
      // Pro 授权要在任何页面首帧之前落进 AppStorage，否则设置页会先闪一下"未解锁"
      ProService.restoreToStorage();
      // 主题里后四套是 Pro 专享：撤销授权后不能让人继续白用。
      // 只在启动时回退一次，不在 setTheme 里拦 —— 否则买断后当场切主题会被判失败。
      const tk: string = SettingsService.theme();
      if (Theme.isPro(tk) && !ProService.isPro()) {
        SettingsService.setTheme(Theme.DARK);
        Logger.info(TAG, `pro theme ${tk} locked, fallback to dark`);
      }
    } catch (e) {
      Logger.error(TAG, `settings init failed ${JSON.stringify(e)}`);
    }

    // 2. 两张表
    try {
      await TrackStore.init(this.context);
      await PlaylistStore.init(this.context);
      await StatsStore.init(this.context);
      // 索引被清过/换过机后统计里会留孤儿 uri，静默清一次
      await StatsStore.pruneDead();
    } catch (e) {
      Logger.error(TAG, `db init failed ${JSON.stringify(e)}`);
    }

    // 3. 播放内核
    try {
      await PlayerCore.instance().init(this.context);
    } catch (e) {
      Logger.error(TAG, `player init failed ${JSON.stringify(e)}`);
    }

    // 3.5 1.0 → 1.1 索引补齐：老记录的 root_path / folder 都是空的，
    // 不补的话"音乐文件夹"页会把有歌的目录显示成 0 首，文件夹树也建不出来。
    // 只在恰好一个根时做：多个根无从判断归属，猜错比空着更糟。
    try {
      const roots: RootDir[] = RootService.list();
      const orphans: number = await TrackStore.orphanCount(Const.SRC_LOCAL);
      if (roots.length === 1 && orphans > 0) {
        const fixed: number = await TrackStore.adoptOrphans(Const.SRC_LOCAL, roots[0].path);
        Logger.info(TAG, `adopted ${fixed}/${orphans} orphan tracks`);
      }
    } catch (e) {
      Logger.warn(TAG, `adopt orphans failed ${JSON.stringify(e)}`);
    }

    // 4. 首次启动：曲库空的就先放一份示例唱片，避免开局是一面空墙
    try {
      const local: number = await TrackStore.count(Const.SRC_LOCAL);
      const demo: number = await TrackStore.count(Const.SRC_DEMO);
      if (local === 0 && demo === 0 && !SettingsService.demoSeeded()) {
        await LibraryService.loadDemo();
        SettingsService.setSource(Const.SRC_DEMO);
        Logger.info(TAG, 'first launch: demo library seeded');
      }
    } catch (e) {
      Logger.error(TAG, `seed failed ${JSON.stringify(e)}`);
    }

    // 5. 首屏
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error(TAG, `loadContent failed ${err.code}`);
        return;
      }
      this.applyWindow(windowStage);
    });

    // 6. 卡片带过来的动作
    if (this.pendingMethod === 'toggle') {
      PlayerCore.instance().toggle();
      this.pendingMethod = '';
    }
  }

  /**
   * 沉浸式 + 安全区。
   *
   * 播放页要"整块黑"，必须让内容顶到状态栏，所以开全屏；
   * 开了全屏就必须自己算安全区，否则标题会被状态栏压住。
   * 算出来的值写 AppStorage，页面用 @StorageProp 订阅。
   */
  private applyWindow(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).catch((e: Object) => Logger.warn(TAG, `${e}`));
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const avoid: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const top: number = avoid.topRect.height / density;
      const bottom: number = avoid.bottomRect.height / density;
      AppStorage.setOrCreate('topInset', top > 0 ? top : 0);
      AppStorage.setOrCreate('bottomInset', bottom > 0 ? bottom : 0);
      this.win = win;
      this.applyBars(SettingsService.theme());
    } catch (e) {
      Logger.warn(TAG, `applyWindow failed ${JSON.stringify(e)}`);
      AppStorage.setOrCreate('topInset', 0);
      AppStorage.setOrCreate('bottomInset', 0);
    }
  }

  /**
   * 状态栏/导航栏的图标颜色。
   *
   * 页面里的配色靠 AppStorage 换，但系统栏图标归窗口管，
   * 不跟着换的话「白纸」主题下就是白字压白底，等于看不见。
   */
  private applyBars(themeKey: string): void {
    const win: window.Window | null = this.win;
    if (win === null) {
      return;
    }
    const light: boolean = Theme.isLight(themeKey);
    win.setWindowSystemBarProperties({
      statusBarContentColor: light ? '#1B1916' : '#F4EFE6',
      navigationBarContentColor: light ? '#1B1916' : '#F4EFE6'
    }).catch((e: Object) => Logger.warn(TAG, `bars ${e}`));
  }

  onBackground(): void {
    // 后台播放靠长时任务，不靠 Ability 存活；这里只把队列落盘
    PlayerCore.instance().saveNow();
  }

  onDestroy(): void {
    PlayerCore.instance().saveNow();
    Logger.info(TAG, 'destroy');
  }
}
