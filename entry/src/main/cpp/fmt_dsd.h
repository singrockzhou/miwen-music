#ifndef MIWEN_FMT_DSD_H
#define MIWEN_FMT_DSD_H

#include "decoder.h"

#include <string>

/**
 * DSD（dsf / dff）直读，软解转 PCM。
 *
 * 解码路径：1-bit DSD 流 → 两级抽取 → 88.2k/176.4k 交错 float32：
 *   第一级：长度 D/4 的盒式平均（boxcar，滑动和，O(1) 每比特）；
 *   第二级：65 抽头 Blackman-sinc FIR 在 4×输出率上再做 4:1 抽取。
 * 质量口径如实标注：软解（非 DoP 硬件直通），能听、无啸叫，但不是发烧级滤波链。
 *
 * 支持：
 *   - DSF：'DSD ' + 'fmt ' + 'data'，块内按声道分段（blockSize），比特 LSB 在前；
 *   - DFF：FRM8 容器，FSnn/CHNL/CMPR，PCM 交织（每帧每声道 1 字节），比特 MSB 在前；
 *   - DFF-DST：'DST ' 块（FRTE + DSTF 帧索引），走 fmt_dst 无损解压后再抽取。
 * 不支持（给明确话术）：
 *   - 3 声道以上的 DFF；SACD ISO 见 fmt_iso（按曲目虚拟化后播放）。
 */
AudioSource *CreateDsfSource(const std::string &path, std::string *why);

AudioSource *CreateDffSource(const std::string &path, std::string *why);

#endif // MIWEN_FMT_DSD_H
