#ifndef MIWEN_FMT_WAVPACK_H
#define MIWEN_FMT_WAVPACK_H

#include "decoder.h"

#include <string>

/** WavPack（.wv / .wvc 校正文件），内部用官方 libwavpack 5.8.1（BSD-3）。 */
AudioSource *CreateWavpackSource(const std::string &path);

#endif // MIWEN_FMT_WAVPACK_H
