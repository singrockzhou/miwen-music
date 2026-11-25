#ifndef MIWEN_DECODER_H
#define MIWEN_DECODER_H

#include <cstdint>
#include <string>

/**
 * 一条音源的解码结果摘要。
 *
 * 约定：所有解码器统一输出 **交错 float32**（每声道一帧一个 float，范围 [-1,1]）。
 * 理由：三种格式内部表示不同（AIFF 是大端整型、WavPack 支持整型与浮点、ALAC 是整型），
 * 统一到 float 之后 ArkTS 侧只认一种 AudioRenderer 格式，不必为每种格式各写一条通道。
 */
struct AudioInfo {
    bool ok = false;
    int sampleRate = 0;
    int channels = 0;
    int bitsPerSample = 0;
    int64_t totalFrames = 0;
    int64_t durationMs = 0;
    std::string format;   // AIFF / WavPack / ALAC / APE，给界面显示
    std::string error;    // ok=false 时说明原因，原样透给 ArkTS
};

class AudioSource {
public:
    virtual ~AudioSource() = default;

    virtual AudioInfo open(const std::string &path) = 0;

    /** 读 frames 帧到 out（交错 float32，容量 >= frames*channels）。
     *  返回实际读到的帧数；0 = 到底；<0 = 出错。 */
    virtual int64_t read(float *out, int64_t frames) = 0;

    /** 定位到第 frame 帧（相对音频开头），返回实际定位帧；<0 = 出错。 */
    virtual int64_t seek(int64_t frame) = 0;

    virtual void close() = 0;

    /** 诊断信息（生产为空串）。解码链排障期临时通道，格式由各解码器自定。 */
    virtual std::string debugStats() const { return std::string(); }
};

/** 按 magic + 扩展名创建解码器；不认识的格式返回 nullptr。
 *
 *  why 非空时写入失败原因（文件打不开 / 头不足 / magic 与后缀都不匹配），
 *  上层直接展示给用户。以前统一报"尚未接入"，对已接入的格式是误导。 */
AudioSource *CreateSource(const std::string &path, std::string *why = nullptr);

/** 这个扩展名是否由本模块负责解码（ArkTS 侧用同一份白名单做门禁） */
bool NativeHandlesSuffix(const std::string &suffix);

#endif // MIWEN_DECODER_H
