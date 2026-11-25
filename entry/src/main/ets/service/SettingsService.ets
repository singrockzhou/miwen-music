import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { Const } from '../common/Constants';
import { Logger } from '../common/Logger';
import { SOURCE_KEY, THEME_KEY, Theme } from '../common/Theme';

const TAG: string = 'SettingsService';

/**
 * 设置存储。
 *
 * preferences 是同步读、异步写的：读走 getSync 保证首帧就能拿到主题，
 * 写走 putSync + flush（flush 不 await，丢一次无所谓，下次写会补上）。
 *
 * 主题和曲库来源同时写到 AppStorage：页面靠 @StorageProp 订阅，
 * 不订阅的话切主题要杀进程才生效。
 */
export class SettingsService {
  private static pref: preferences.Preferences | null = null;

  static async init(ctx: common.Context): Promise<void> {
    if (SettingsService.pref !== null) {
      return;
    }
    SettingsService.pref = await preferences.getPreferences(ctx, Const.PREF_NAME);
    AppStorage.setOrCreate(THEME_KEY, SettingsService.theme());
    AppStorage.setOrCreate(Theme.ACCENT_PIN_KEY, SettingsService.accentPin());
    AppStorage.setOrCreate(SOURCE_KEY, SettingsService.source());
    AppStorage.setOrCreate('libVersion', 0);
  }

  private static raw(key: string, def: string): string {
    if (SettingsService.pref === null) {
      return def;
    }
    try {
      const v: preferences.ValueType = SettingsService.pref.getSync(key, def);
      return typeof v === 'string' ? v as string : def;
    } catch (e) {
      Logger.warn(TAG, `read ${key} failed`);
      return def;
    }
  }

  private static write(key: string, value: string): void {
    if (SettingsService.pref === null) {
      return;
    }
    try {
      SettingsService.pref.putSync(key, value);
      SettingsService.pref.flush().catch((e: Object) => Logger.warn(TAG, `flush ${key} ${e}`));
    } catch (e) {
      Logger.warn(TAG, `write ${key} failed`);
    }
  }

  /** 通用读写：给 ProService 这类"附加模块"用，避免每个模块各开一个 preferences 实例 */
  static getStr(key: string, def: string): string {
    return SettingsService.raw(key, def);
  }

  static setStr(key: string, value: string): void {
    SettingsService.write(key, value);
  }

  // ---------- 外观 ----------

  static theme(): string {
    return SettingsService.raw(Const.KEY_THEME, 'dark');
  }

  static setTheme(key: string): void {
    SettingsService.write(Const.KEY_THEME, key);
    AppStorage.setOrCreate(THEME_KEY, key);
    // 页面靠 @StorageProp 换配色，但状态栏图标颜色在窗口层，
    // 只有 Ability 能改，所以这里回调出去（浅色主题必须把图标改深）。
    SettingsService.themeHooks.forEach((fn: (key: string) => void) => fn(key));
  }

  private static themeHooks: Array<(key: string) => void> = [];

  static onThemeChange(fn: (key: string) => void): void {
    SettingsService.themeHooks.push(fn);
  }

  // ---------- 钉住的强调色 ----------

  /** '' = 跟随主题；'#RRGGBB' = 用户钉住的封套色。非法值按跟随主题处理 */
  static accentPin(): string {
    return SettingsService.raw(Const.KEY_ACCENT_PIN, '');
  }

  static setAccentPin(hex: string): void {
    const v: string = Theme.isHex(hex) ? hex : '';
    SettingsService.write(Const.KEY_ACCENT_PIN, v);
    AppStorage.setOrCreate(Theme.ACCENT_PIN_KEY, v);
  }

  // ---------- 曲库 ----------

  static source(): string {
    return SettingsService.raw(Const.KEY_SOURCE, Const.SRC_LOCAL);
  }

  static setSource(src: string): void {
    SettingsService.write(Const.KEY_SOURCE, src);
    AppStorage.setOrCreate(SOURCE_KEY, src);
  }

  static libUri(): string {
    return SettingsService.raw(Const.KEY_LIB_URI, '');
  }

  static setLibUri(uri: string): void {
    SettingsService.write(Const.KEY_LIB_URI, uri);
  }

  static demoSeeded(): boolean {
    return SettingsService.raw(Const.KEY_DEMO_SEEDED, '0') === '1';
  }

  static setDemoSeeded(): void {
    SettingsService.write(Const.KEY_DEMO_SEEDED, '1');
  }

  // ---------- 播放 ----------

  static mode(): string {
    return SettingsService.raw(Const.KEY_MODE, Const.MODE_LOOP);
  }

  static setMode(mode: string): void {
    SettingsService.write(Const.KEY_MODE, mode);
  }

  static sort(): string {
    return SettingsService.raw(Const.KEY_SORT, Const.SORT_RECENT);
  }

  static setSort(sort: string): void {
    SettingsService.write(Const.KEY_SORT, sort);
  }

  static view(): string {
    return SettingsService.raw(Const.KEY_VIEW, Const.VIEW_GRID);
  }

  static setView(view: string): void {
    SettingsService.write(Const.KEY_VIEW, view);
  }

  /** 封面墙密度（大卡 / 标准 / 密集），标准是免费默认 */
  static gridDensity(): string {
    return SettingsService.raw(Const.KEY_GRID_DENSITY, Const.GRID_STD);
  }

  static setGridDensity(v: string): void {
    SettingsService.write(Const.KEY_GRID_DENSITY, v);
  }

  // ---------- 直出模式 ----------

  /** 直出：关掉系统音效链（Histen / 杜比等），PCM 原样送输出 */
  static direct(): boolean {
    return SettingsService.raw(Const.KEY_DIRECT, '0') === '1';
  }

  static setDirect(on: boolean): void {
    SettingsService.write(Const.KEY_DIRECT, on ? '1' : '0');
  }

  // ---------- 无缝播放 / 桌面歌词 ----------

  /** 无缝播放模式：off / gapless（预加载切流）/ fade（交叉淡入淡出） */
  static gapless(): string {
    return SettingsService.raw(Const.KEY_GAPLESS, Const.GAP_OFF);
  }

  static setGapless(v: string): void {
    SettingsService.write(Const.KEY_GAPLESS, v);
  }

  static deskLyric(): boolean {
    return SettingsService.raw(Const.KEY_DESK_LYRIC, '0') === '1';
  }

  static setDeskLyric(on: boolean): void {
    SettingsService.write(Const.KEY_DESK_LYRIC, on ? '1' : '0');
  }

  // ---------- 断点续播 ----------

  static queueUris(): string {
    return SettingsService.raw(Const.KEY_QUEUE, '');
  }

  static queueIndex(): number {
    const n: number = parseInt(SettingsService.raw(Const.KEY_QUEUE_INDEX, '0'), 10);
    return isNaN(n) ? 0 : n;
  }

  static queuePosition(): number {
    const n: number = parseInt(SettingsService.raw(Const.KEY_POSITION, '0'), 10);
    return isNaN(n) ? 0 : n;
  }

  static saveQueue(uris: string, index: number, position: number): void {
    SettingsService.write(Const.KEY_QUEUE, uris);
    SettingsService.write(Const.KEY_QUEUE_INDEX, index.toString());
    SettingsService.write(Const.KEY_POSITION, Math.floor(position).toString());
  }

  // ---------- 服务卡片 ----------

  /**
   * 卡片跨进程：FormExtensionAbility 与 UIAbility 是两个进程，只共享沙箱里的 preferences。
   * 这里把当前曲目写进 preferences，卡片侧 onAddForm/onUpdateForm 读它；
   * UI 侧拿到 formId 后请求刷新。拿不到 formId（用户没加卡片）就静默跳过。
   */
  static saveCard(title: string, artist: string, playing: boolean): void {
    SettingsService.write('card_title', title);
    SettingsService.write('card_artist', artist);
    SettingsService.write('card_playing', playing ? 'true' : 'false');
  }

  static cardFormId(): string {
    return SettingsService.raw('card_form_id', '');
  }

  static setCardFormId(id: string): void {
    SettingsService.write('card_form_id', id);
  }

  static pushCard(): void {
    const id: string = SettingsService.cardFormId();
    if (id.length === 0) {
      return;
    }
    const data: Record<string, string> = {
      'title': SettingsService.raw('card_title', '密纹音乐'),
      'artist': SettingsService.raw('card_artist', '桌面即控制台'),
      'playing': SettingsService.raw('card_playing', 'false'),
      'hint': '打开唱片库'
    };
    formProvider.updateForm(id, formBindingData.createFormBindingData(data))
      .catch((e: Object) => Logger.warn(TAG, `form update ${e}`));
  }

  // ---------- 通知 UI ----------

  /** 曲库变了：扫描完成 / 清空 / 载入示例。列表页据此重拉。 */
  static bumpLibrary(): void {
    const v: number = AppStorage.get<number>('libVersion') ?? 0;
    AppStorage.setOrCreate('libVersion', v + 1);
  }
}
