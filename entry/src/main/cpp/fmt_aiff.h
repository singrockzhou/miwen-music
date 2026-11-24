#ifndef MIWEN_FMT_AIFF_H
#define MIWEN_FMT_AIFF_H

#include "decoder.h"

/** AIFF / AIFC（PCM 容器）。AIFC 的 sowt（小端 PCM）与 fl32/FL32（浮点）一并支持。 */
AudioSource *CreateAiffSource(const std::string &path);

#endif // MIWEN_FMT_AIFF_H
