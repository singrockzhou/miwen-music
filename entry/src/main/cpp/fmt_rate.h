#ifndef MIWEN_FMT_RATE_H
#define MIWEN_FMT_RATE_H

#include "decoder.h"

#include <vector>

/**
 * WSOLA 变速链（Pro 2.0 变速不变调）。
 *
 * 包住任意 AudioSource：rate = 1.0 时直通（零开销）；rate != 1.0 时对交错 float32
 * 做时域拉伸——输出帧数变了，音高不动。算法是 WSOLA（波形相似叠加）：
 * 每个输出窗在前一窗的"自然接续点"附近搜索最相似的起点，再与上一窗的尾巴
 * 交叉淡入淡出拼接。听感比朴素的"跳样本/重采样"干净得多，音乐场景足够。
 *
 * 参数取舍（真机 44.1k 实测调过）：
 * - 窗长 L=2048（约 46ms）、半窗 H=1024、搜索半径 tauMax=256（约 5.8ms）：
 *   窗太短会"水声/颤音"，太长瞬态发糊；256 帧搜索半径覆盖人声与器乐的周期。
 * - 搜索步长 2：质量与 CPU 的折中，arm64 上单窗 ~1M 次乘加毫无压力。
 * - rate 支持 0.5~2.0；0.5 以下人声已经不可懂，2.0 以上失去音乐意义。
 *
 * 位置口径：本类是"输出帧 ≠ 源帧"的唯一来源，ArkTS 侧用 gotFrames*rate 折算
 * 回源时间轴（见 NativePlayer.srcFrames），seek 时本类整体复位。
 */
class RateSource : public AudioSource {
public:
    /** 接管 inner 的生命周期（close 时一并 delete） */
    RateSource(AudioSource *inner, int channels, int sampleRate);
    ~RateSource() override;

    AudioInfo open(const std::string &path) override;
    int64_t read(float *out, int64_t frames) override;
    int64_t seek(int64_t frame) override;
    void close() override;
    std::string debugStats() const override;

    void setRate(double rate);

private:
    /** 产出一个 WSOLA 窗（约 H 帧）到 outBuf_；输入耗尽时冲洗剩余并置 flushed_ */
    void produceOne();

    /** 确保输入缓冲至少有 n 帧；输入源耗尽时置 eofIn_ 并返回是否凑够 */
    bool ensureInput(int64_t nFrames);

    /** 压缩缓冲：把已消费的前段丢弃，避免长曲内存无界增长 */
    void compact();

    AudioSource *inner_;
    int ch_;
    int sampleRate_;
    double rate_;
    AudioInfo info_;

    // 输入侧（源时间轴，单位：帧）
    std::vector<float> inBuf_;   // 从 inPos_ 起的未消费输入（交错 float32）
    int64_t inFrames_;           // inBuf_ 实际容纳的帧数
    int64_t inPos_;              // 理想接续点（下一窗的基准）
    bool eofIn_;
    double hopErr_;              // inputHop 的小数累加（0.75× 这类非整数步进）

    // 输出侧
    std::vector<float> outBuf_;
    int64_t outFrames_;
    int64_t outPos_;
    bool flushed_;

    // 上一窗的尾巴：H 帧长，用于相似度匹配与交叉淡入淡出
    std::vector<float> tail_;
    bool tailValid_;
};

#endif // MIWEN_FMT_RATE_H
