#ifndef MIWEN_FMT_DST_H
#define MIWEN_FMT_DST_H

#include <cstdint>
#include <string>

/**
 * DST（Direct Stream Transfer，ISO/IEC 14496-3 Subpart 10）无损解压。
 * 移植自 ffmpeg libavcodec/dstdec.c（LGPL-2.1+，Peter Ross），逻辑逐段对应。
 *
 * 输入：一个 DST 帧的原始字节（DFF 的 'DSTF' 载荷，或 SACD ISO 的 DST 帧载荷）；
 * 输出：解码后的 DSD，**按声道字节交错、MSB-first**——与 SACD 未压缩帧排布一致
 *       （已对照 sacd-ripper dsf.c 的轮转取字节逻辑与 dstdec 的输出索引核实）。
 *
 * 帧长口径：物理事实是每帧每声道 37632 bit = 4704 字节 @2.8224MHz（2.8224Mbit/s ÷ 75fps）。
 * 注意 ffmpeg dstdec 的 DST_SAMPLES_PER_FRAME 宏是"字节率"口径（sample_rate*8/44100），
 * 别照抄它的 ×8 表达式——按 DSD 位率算会得到 8 倍帧长（本仓库在 DFF 时长上踩过同款坑）。
 */
class DstDecoder {
public:
    /** channels 1..6；bitsPerFramePerCh：每帧每声道 DSD 比特数（64fs = 37632） */
    void Init(int channels, int64_t bitsPerFramePerCh);

    /** 解码一帧。成功返回 true 并填 out（bitsPerFramePerCh/8 * channels 字节，交错 MSB-first）。
     *  失败时 why（可空）给出原因，上层原样透给用户。 */
    bool Decode(const uint8_t *data, size_t size, uint8_t *out, std::string *why);

    int bytesPerCh() const { return bytesPerCh_; }
    int channels() const { return channels_; }

private:
    int channels_ = 1;
    int bytesPerCh_ = 4704;   // 每帧每声道字节数
    int64_t samplesPerFrame_ = 37632;  // 每帧每声道 DSD 比特数
};

#endif // MIWEN_FMT_DST_H
