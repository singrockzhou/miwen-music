import { RawTag } from '../model/Track';
import { decodeTags } from './TagCodec';

/**
 * 标签解析（并发入口）。
 *
 * 真正的解析逻辑在 TagCodec 里：@Concurrent 函数体里只能引用导入的变量/函数，
 * 所以这里只保留一层转调，把解码丢到 taskpool，主线程继续扫描与入库。
 */
export const HEAD_BYTES: number = 1024 * 1024;

@Concurrent
export function parseTags(buf: ArrayBuffer, suffix: string): RawTag {
  return decodeTags(buf, suffix);
}
