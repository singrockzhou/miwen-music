#ifndef MIWEN_FMT_APE_H
#define MIWEN_FMT_APE_H

#include "decoder.h"

/**
 * APE（Monkey's Audio），内嵌官方 MACLib 13.50 SDK（3-Clause BSD，见 ape/License.txt，
 * © 2000-2027 Matthew T. Ashland）。
 *
 * 官方 CAPEDecompress 自带按帧快速 Seek（帧索引来自文件头），无需自己重建解码器。
 * 解码输出与 WAV 同布局：小端交错整型（16→int16、24→3 字节、32→int32）。
 */
AudioSource *CreateApeSource(const std::string &path, std::string *why = nullptr);

#endif // MIWEN_FMT_APE_H
