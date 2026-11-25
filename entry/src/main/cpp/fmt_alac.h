#ifndef MIWEN_FMT_ALAC_H
#define MIWEN_FMT_ALAC_H

#include "decoder.h"

/**
 * ALAC（m4a / mp4 容器），内嵌 Apple 官方解码器（Apache-2.0，见 alac/LICENSE）。
 *
 * 容器里的编码不一定是 ALAC（AAC / MP3 也走 m4a）：
 * - 是 ALAC   → 返回解码器实例；
 * - 不是 ALAC → 返回 nullptr，*why 以「mp4 容器非 ALAC」开头，
 *   PlayerCore.openNative 据此回退 AVPlayer（AAC 这些系统本来就能解）。
 */
AudioSource *CreateAlacSource(const std::string &path, std::string *why = nullptr);

#endif // MIWEN_FMT_ALAC_H
