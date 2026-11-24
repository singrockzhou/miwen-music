/**
 * 设计令牌（唯一来源）。
 *
 * 三套主题共用一套结构，切换主题只换这张表，页面里不写死任何色值。
 * 底色永远是近黑/纸白，界面里唯一的高饱和色来自专辑封面——
 * 所以强调色只给"落针点、进度、当前项"这三处用，不铺面积。
 */
export interface Tokens {
  /** 页面底色 */
  bg: string;
  /** 更深一层的底色（沉浸区、播放页） */
  bgDeep: string;
  /** 卡片/浮层底 */
  surface: string;
  /** 次级面（列表 hover、占位封面） */
  surfaceAlt: string;
  /** 发丝分割线 */
  line: string;
  /** 更浅的分割线 */
  lineSoft: string;
  /** 主文字 */
  text: string;
  /** 次级文字 */
  dim: string;
  /** 三级文字（时间、格式） */
  faint: string;
  /** 铜金强调色 */
  accent: string;
  /** 深铜（描边、沟槽） */
  accentDeep: string;
  /** 强调色底（选中块） */
  accentWash: string;
  /** 错误/危险 */
  danger: string;
  /** 强调色上的文字 */
  onAccent: string;
  /** 封面占位里的暗纹 */
  groove: string;
}

const DARK: Tokens = {
  bg: '#0B0B0D',
  bgDeep: '#08080A',
  surface: '#141416',
  surfaceAlt: '#17171A',
  line: '#232327',
  lineSoft: '#1C1C20',
  text: '#F4EFE6',
  dim: '#8E8778',
  faint: '#6E6A61',
  accent: '#C8A96A',
  accentDeep: '#8A6E3E',
  accentWash: '#1F1A12',
  danger: '#C2623A',
  onAccent: '#0B0B0D',
  groove: '#26262B'
};

const PAPER: Tokens = {
  bg: '#FBF9F6',
  bgDeep: '#F4EFE6',
  surface: '#FFFFFF',
  surfaceAlt: '#F4F0E8',
  line: '#E2DBD0',
  lineSoft: '#EDE6D9',
  text: '#17171A',
  dim: '#6C6A63',
  faint: '#8E8778',
  accent: '#A8792E',
  accentDeep: '#C8A96A',
  accentWash: '#F5EBD8',
  danger: '#B4552B',
  onAccent: '#FFFFFF',
  groove: '#E7DFD2'
};

const TAPE: Tokens = {
  bg: '#1A1512',
  bgDeep: '#140F0D',
  surface: '#221B16',
  surfaceAlt: '#2A211A',
  line: '#3A2E24',
  lineSoft: '#302620',
  text: '#F0E3CE',
  dim: '#A08B72',
  faint: '#7E6A55',
  accent: '#C8A96A',
  accentDeep: '#9A7B45',
  accentWash: '#2B2118',
  danger: '#C2623A',
  onAccent: '#1A1512',
  groove: '#3A2E24'
};

/** 黑胶：比暗夜更黑，纸标偏奶白，强调色取唱片标签上的氧化红 */
const VINYL: Tokens = {
  bg: '#08080A',
  bgDeep: '#040405',
  surface: '#121214',
  surfaceAlt: '#19191C',
  line: '#2A2A2F',
  lineSoft: '#1F1F23',
  text: '#EDE7DC',
  dim: '#8B8577',
  faint: '#68635A',
  accent: '#BD5F42',
  accentDeep: '#7E3D2A',
  accentWash: '#1D1310',
  danger: '#D0653F',
  onAccent: '#08080A',
  groove: '#25252A'
};

/** 夜航：深蓝底 + 仪表青，像关了舱灯只有仪表还亮着 */
const NIGHT: Tokens = {
  bg: '#0A1220',
  bgDeep: '#060C17',
  surface: '#101A2B',
  surfaceAlt: '#152238',
  line: '#20304A',
  lineSoft: '#182438',
  text: '#E2EAF5',
  dim: '#8497B0',
  faint: '#63758D',
  accent: '#7E9CBF',
  accentDeep: '#486A90',
  accentWash: '#10202F',
  danger: '#D0704F',
  onAccent: '#06101A',
  groove: '#1B2A40'
};

/** 牛皮纸：整本册子像用牛皮纸印的，强调色是重油墨棕 */
const KRAFT: Tokens = {
  bg: '#EADFC8',
  bgDeep: '#DFD1B6',
  surface: '#F2E9D8',
  surfaceAlt: '#E4D7BD',
  line: '#D2C1A2',
  lineSoft: '#DCCCAF',
  text: '#2E2419',
  dim: '#6B5B45',
  faint: '#8A7860',
  accent: '#8C5A2B',
  accentDeep: '#A8814F',
  accentWash: '#F0E3C9',
  danger: '#A8442A',
  onAccent: '#F7EFDF',
  groove: '#D8C7A8'
};

/**
 * 高对比（无障碍）：纯黑底纯白字 + 高亮黄。
 * 不是"更黑的暗夜"，而是把对比度拉到最满的一组值 ——
 * 弱视用户要的不是氛围，是能看清。
 */
const CONTRAST: Tokens = {
  bg: '#000000',
  bgDeep: '#000000',
  surface: '#0D0D0D',
  surfaceAlt: '#171717',
  line: '#5A5A5A',
  lineSoft: '#3E3E3E',
  text: '#FFFFFF',
  dim: '#DCDCDC',
  faint: '#B8B8B8',
  accent: '#FFD400',
  accentDeep: '#C9A800',
  accentWash: '#1C1700',
  danger: '#FF7A52',
  onAccent: '#000000',
  groove: '#2C2C2C'
};

/** 封面用的六种"唱片封套"底色，按专辑名散列取一个 */
const SLEEVE: string[] = [
  '#2B3A55', '#5A2E3A', '#2E4A3F', '#4B3A66', '#2B6E8F', '#8A4B2B', '#44444F', '#6B5A2E'
];

export class Theme {
  static readonly DARK: string = 'dark';
  static readonly PAPER: string = 'paper';
  static readonly TAPE: string = 'tape';
  static readonly VINYL: string = 'vinyl';
  static readonly NIGHT: string = 'night';
  static readonly KRAFT: string = 'kraft';
  static readonly CONTRAST: string = 'contrast';

  /** 顺序即设置页的排列顺序：三套基础在前，四套 Pro 在后 */
  static readonly KEYS: string[] = [
    Theme.DARK, Theme.PAPER, Theme.TAPE, Theme.VINYL, Theme.NIGHT, Theme.KRAFT, Theme.CONTRAST
  ];
  static readonly LABELS: string[] = ['暗夜', '白纸', '磁带', '黑胶', '夜航', '牛皮纸', '高对比'];
  static readonly ENS: string[] = [
    'NIGHT · 默认', 'PAPER · 浅色', 'TAPE · 拟物',
    'VINYL · 深黑', 'NIGHTFLIGHT · 冷蓝', 'KRAFT · 纸浆', 'CONTRAST · 无障碍'
  ];

  /** 1.0 免费的三套：已经给出去的东西不能收回 */
  static readonly FREE: string[] = [Theme.DARK, Theme.PAPER, Theme.TAPE];

  static of(key: string): Tokens {
    if (key === Theme.PAPER) {
      return PAPER;
    }
    if (key === Theme.TAPE) {
      return TAPE;
    }
    if (key === Theme.VINYL) {
      return VINYL;
    }
    if (key === Theme.NIGHT) {
      return NIGHT;
    }
    if (key === Theme.KRAFT) {
      return KRAFT;
    }
    if (key === Theme.CONTRAST) {
      return CONTRAST;
    }
    return DARK;
  }

  static index(key: string): number {
    const i: number = Theme.KEYS.indexOf(key);
    return i < 0 ? 0 : i;
  }

  static label(key: string): string {
    return Theme.LABELS[Theme.index(key)];
  }

  static en(key: string): string {
    return Theme.ENS[Theme.index(key)];
  }

  /** 浅色主题下封面纹理要压深，否则在白底上会"发灰" */
  static isLight(key: string): boolean {
    return key === Theme.PAPER || key === Theme.KRAFT;
  }

  /** 这套主题是否为 Pro 专享（决定设置页打不打 PRO 角标） */
  static isPro(key: string): boolean {
    return Theme.FREE.indexOf(key) < 0;
  }

  /** 专辑名 → 封套底色（离线可用：不依赖任何网络取色接口） */
  static sleeve(seed: string): string {
    let h: number = 5381;
    for (let i = 0; i < seed.length; i++) {
      h = ((h << 5) + h + seed.charCodeAt(i)) & 0x7fffffff;
    }
    return SLEEVE[h % SLEEVE.length];
  }

  /** 把 16 进制色按比例压暗，用于封面底部压字 */
  static darken(hex: string, ratio: number): string {
    if (hex.length !== 7) {
      return hex;
    }
    const r: number = Math.floor(parseInt(hex.substring(1, 3), 16) * (1 - ratio));
    const g: number = Math.floor(parseInt(hex.substring(3, 5), 16) * (1 - ratio));
    const b: number = Math.floor(parseInt(hex.substring(5, 7), 16) * (1 - ratio));
    return `#${Theme.hex2(r)}${Theme.hex2(g)}${Theme.hex2(b)}`;
  }

  private static hex2(v: number): string {
    const s: string = v.toString(16);
    return s.length === 1 ? `0${s}` : s;
  }
}

/** 主题 key 的 AppStorage 名，页面用 @StorageProp('themeKey') 订阅 */
export const THEME_KEY: string = 'themeKey';

/** 当前曲库来源，切目录/载入示例后变，页面用于判断是否显示示例角标 */
export const SOURCE_KEY: string = 'libSource';

/** 曲库版本号：扫描/清空/载入示例后 +1，列表页据此重新拉数据 */
export const LIB_VERSION_KEY: string = 'libVersion';

/** 断点（sm/md/lg），保证手机/折叠/平板/PC 各自排版 */
export const BP_KEY: string = 'bp';

export function defaultThemeKey(): string {
  return Theme.DARK;
}
