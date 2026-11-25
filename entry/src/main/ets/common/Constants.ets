/**
 * 全局常量。所有"魔法数字"集中在这里，业务代码不写字面量。
 */
export class Const {
  static readonly APP_NAME: string = '密纹音乐';
  static readonly APP_EN: string = 'LOCAL RECORD STORE';
  static readonly VERSION: string = '1.3.3';

  /** preferences 文件名 */
  static readonly PREF_NAME: string = 'miwen_pref';
  /** 主题：dark / paper / tape */
  static readonly KEY_THEME: string = 'theme';
  /** 上次授权的目录 URI（多根生效后只作为第一根的镜像，兼容老读取方） */
  static readonly KEY_LIB_URI: string = 'library_dir_uri';
  /** 全部音乐根目录（RootDir[] 的 JSON） */
  static readonly KEY_ROOTS: string = 'library_roots';
  /** 当前曲库来源：local / demo */
  static readonly KEY_SOURCE: string = 'library_source';
  /** 播放模式 */
  static readonly KEY_MODE: string = 'play_mode';
  /** 断点续播：队列 uri 列表（JSON 数组）、下标、位置 */
  static readonly KEY_QUEUE: string = 'queue_uris';
  static readonly KEY_QUEUE_INDEX: string = 'queue_index';
  static readonly KEY_POSITION: string = 'queue_position';
  /** 曲库页排序方式 */
  static readonly KEY_SORT: string = 'sort_mode';
  /** 曲库页视图：grid / list */
  static readonly KEY_VIEW: string = 'view_mode';
  /** 封面墙密度：big / std / dense（大卡与密集是 Pro） */
  static readonly KEY_GRID_DENSITY: string = 'grid_density';
  /** 示例曲库是否已装载（只自动装一次） */
  static readonly KEY_DEMO_SEEDED: string = 'demo_seeded';

  // ---- 密纹 Pro ----
  /** 是否已解锁（'1' / '0'） */
  static readonly KEY_PRO_OWNED: string = 'pro_owned';
  /** 解锁日期 yyyy-MM-dd */
  static readonly KEY_PRO_SINCE: string = 'pro_since';
  /** 是否开发版授权（未接应用市场支付时的本地体验授权，用于区分正版购买） */
  static readonly KEY_PRO_DEV: string = 'pro_dev_grant';
  /** 直出模式：关闭系统音效链 */
  static readonly KEY_DIRECT: string = 'direct_mode';
  /** 无缝播放：off / gapless / fade */
  static readonly KEY_GAPLESS: string = 'gapless_mode';
  /** 桌面歌词开关（走 AVSession 系统桌面歌词） */
  static readonly KEY_DESK_LYRIC: string = 'desk_lyric';
  /** Pro 常规价 / 早鸟价（元，仅用于界面展示，实际扣费以应用市场商品配置为准） */
  static readonly PRO_PRICE: number = 28;
  static readonly PRO_PRICE_EARLY: number = 18;

  /** AVSession 标签，全进程唯一 */
  static readonly SESSION_TAG: string = 'miwen_audio_session';

  /** 曲库分页大小：首屏只要 60，滚动再加载 */
  static readonly PAGE_SIZE: number = 60;
  /** 断点续播最多记住多少首 */
  static readonly QUEUE_REMEMBER: number = 120;

  /** 曲库来源 */
  static readonly SRC_LOCAL: string = 'local';
  static readonly SRC_DEMO: string = 'demo';
  /** 示例数据 uri 前缀 */
  static readonly DEMO_SCHEME: string = 'demo://miwen/';

  /**
   * 支持的扩展名。
   * 注意：这是"扫得到"的格式，不等于"播得动"。
   * 播放能力以真机实测为准，APE/DSD 需要自解或转 PCM。
   */
  static readonly AUDIO_SUFFIX: string[] = [
    '.mp3', '.flac', '.m4a', '.aac', '.wav', '.ogg', '.mka', '.ape',
    // 全格式识别层（第二梯队第 7/11 项）：先扫进来、明确标记"暂不支持"，
    // 每接通一种原生解码就从 UNDECODED 挪走一个
    '.dsf', '.dff', '.iso', '.wv', '.aiff', '.aif', '.aifc'
  ];
  /** CUE 描述文件扩展名 */
  static readonly CUE_SUFFIX: string = '.cue';
  /**
   * 这些格式识别入库但系统解码器播不动（鸿蒙 AVPlayer 对 APE/DSD/WavPack/AIFF 无解）。
   * 点播时给"为什么播不了"的明确话术，而不是笼统的格式错误。
   *
   * AIFF/AIFC 已由 libmiwen.so 原生解码接过（v1.3.0）、WavPack 已接过（v1.3.1）、
   * ALAC/m4a 已接过（v1.3.2）、APE 已接过（v1.3.3），从这里移出；
   * 但能否真播仍由 NativePlayer.handles(suffix) 决定，两处口径必须一致。
   */
  static readonly UNDECODED_SUFFIX: string[] = [
    '.dsf', '.dff', '.iso'
  ];
  /** 扫描时跳过的目录名（彩铃/录音这类短音频重灾区） */
  static readonly SKIP_DIRS: string[] = ['Sounds', 'SoundRecorder'];
  /** 小于 30KB 的音频基本是铃声碎片，不入库 */
  static readonly MIN_BYTES: number = 30 * 1024;
  /** 封面缓存子目录名（放 context.cacheDir 下） */
  static readonly COVER_DIR: string = 'covers';

  /** 排序方式 */
  static readonly SORT_RECENT: string = 'recent';
  static readonly SORT_TITLE: string = 'title';
  static readonly SORT_ARTIST: string = 'artist';
  static readonly SORT_RATE: string = 'rate';

  /** 视图方式 */
  static readonly VIEW_GRID: string = 'grid';
  static readonly VIEW_LIST: string = 'list';
  /** 按文件夹浏览（标签乱了也能找到歌） */
  static readonly VIEW_FOLDER: string = 'folder';

  /** 封面墙密度 */
  static readonly GRID_BIG: string = 'big';
  static readonly GRID_STD: string = 'std';
  static readonly GRID_DENSE: string = 'dense';

  /** 无缝播放（第二梯队第 8 项）：off 关 / gapless 预加载切流 / fade 交叉淡入淡出 */
  static readonly GAP_OFF: string = 'off';
  static readonly GAP_SEAMLESS: string = 'gapless';
  static readonly GAP_FADE: string = 'fade';
  /** 预加载提前量：剩余 2.5s 开始准备下一曲的 AVPlayer */
  static readonly GAP_PRELOAD_MS: number = 2500;
  /** 淡入淡出时长 */
  static readonly FADE_MS: number = 3000;

  /** 目录只读：读不到文件时按内核错误码区分"没权限"和"文件没了" */
  static readonly ERR_NO_PERMISSION: number = 13900001;

  /** 播放模式 */
  static readonly MODE_LOOP: string = 'loop';
  static readonly MODE_SINGLE: string = 'single';
  static readonly MODE_SHUFFLE: string = 'shuffle';

  /** 播放状态 */
  static readonly ST_IDLE: string = 'idle';
  static readonly ST_LOADING: string = 'loading';
  static readonly ST_BUFFERING: string = 'buffering';
  static readonly ST_PLAYING: string = 'playing';
  static readonly ST_PAUSED: string = 'paused';
  static readonly ST_ERROR: string = 'error';

  /** 列表页种类 */
  static readonly LIST_ALBUM: string = 'album';
  static readonly LIST_PLAYLIST: string = 'playlist';
  static readonly LIST_FAVORITE: string = 'favorite';
  static readonly LIST_RECENT: string = 'recent';
  static readonly LIST_QUEUE: string = 'queue';

  /** 音频焦点被压低时的音量（导航播报不能直接暂停音乐） */
  static readonly DUCK_VOLUME: number = 0.3;

  /** 布局断点 */
  static readonly BP_SM: string = 'sm';
  static readonly BP_MD: string = 'md';
  static readonly BP_LG: string = 'lg';

  /** 播放页尺寸（vp） */
  static readonly PLAYER_RING: number = 300;
  static readonly PLAYER_COVER: number = 236;
}
