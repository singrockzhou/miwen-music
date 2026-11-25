/**
 * 原生解码器（libmiwen.so）的 ArkTS 声明。
 *
 * 统一输出交错 float32；read 返回的 ArrayBuffer 长度 = 实际帧数 × 声道数 × 4，
 * 到底时返回 null（不是空 buffer），调用方据此收尾。
 */
export interface DecodedInfo {
  ok: boolean;
  /** 句柄，close 时必须原样传回；open 失败时为 0 */
  id: number;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  totalFrames: number;
  durationMs: number;
  /** AIFF / AIFC/sowt / AIFC/float32 ... 给界面显示 */
  format: string;
  /** ok 为 false 时说明原因（中文，可直接展示） */
  error: string;
}

/** 打开文件并解析格式头。同步调用，只读文件头，不整文件加载。 */
export const open: (path: string) => DecodedInfo;

/** 读 frames 帧；返回 null 表示已到文件尾或出错。 */
export const read: (id: number, frames: number) => ArrayBuffer | null;

/** 定位到第 frame 帧，返回实际帧号；-1 表示句柄无效。 */
export const seek: (id: number, frame: number) => number;

/** 释放句柄。重复调用安全。 */
export const close: (id: number) => void;

/** 该扩展名是否由本模块负责解码（与内核门禁共用一份白名单）。 */
export const handles: (suffix: string) => boolean;

/** 版本串，用于确认设备上装的是哪个版本的解码器。 */
export const version: () => string;

/** 解码器诊断串（生产环境为空串），排障期由电平日志带出。 */
export const stats: (id: number) => string;

/** 变速不变调（WSOLA）：0.5~2.0，1.0 直通。随时切换，不需要重建解码器。 */
export const setRate: (id: number, rate: number) => void;
