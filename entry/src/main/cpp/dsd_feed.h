#ifndef MIWEN_DSD_FEED_H
#define MIWEN_DSD_FEED_H

#include <cmath>
#include <cstdint>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/**
 * DSD 位流源的统一抽象：DSF/DFF 的文件位流、DST 解码后的帧、SACD ISO 的帧，
 * 都实现 NextBit(c)，供同一个抽取器消费。
 */
class BitSource {
public:
    virtual ~BitSource() = default;
    /** 取声道 c 的下一个比特：1 / 0；流耗尽返回 -1 */
    virtual int NextBit(int c) = 0;
};

constexpr int kFirTaps = 65;

/** Blackman 窗 sinc 低通：fc 相对中间率 Nyquist 的归一化截止 */
inline void DesignTaps(std::vector<float> &taps, double fcNorm) {
    taps.assign(kFirTaps, 0.0f);
    const int mid = kFirTaps / 2;
    double sum = 0.0;
    for (int k = 0; k < kFirTaps; k++) {
        const int n = k - mid;
        const double x = 2.0 * M_PI * fcNorm * (double) n;
        const double sinc = n == 0 ? 2.0 * fcNorm : std::sin(x) / (M_PI * (double) n);
        const double w = 0.42 - 0.5 * std::cos(2.0 * M_PI * (double) k / (double) (kFirTaps - 1))
            + 0.08 * std::cos(4.0 * M_PI * (double) k / (double) (kFirTaps - 1));
        taps[k] = (float) (sinc * w);
        sum += taps[k];
    }
    if (sum > 1e-9) {
        for (int k = 0; k < kFirTaps; k++) {
            taps[k] = (float) (taps[k] / sum);
        }
    }
}

/**
 * 帧式位流源：一帧一帧地喂 DSD 字节。
 *
 * 帧排布统一为 **按声道字节交错 + 字节内 MSB-first**——DST 解码输出（ffmpeg dstdec 的
 * dsd[(i>>3)*ch] 布局）、SACD ISO 未压缩帧（sacd-ripper dsf.c 轮转取字节已核实）、
 * DFF-DST 帧全是这个排布。
 *
 * 子类实现 PullFrame()：产出一帧（调用 DeliverFrame），返回 false 表示流到底。
 */
class FrameBitSource : public BitSource {
public:
    void InitFrame(int channels, int bytesPerCh) {
        ch_ = channels;
        bpc_ = bytesPerCh;
        buf_.assign((size_t) ch_, {});
        byteAt_.assign((size_t) ch_, 0);
        bitIn_.assign((size_t) ch_, 0);
        frame_.resize((size_t) ch_ * (size_t) bpc_);
    }

    int NextBit(int c) override {
        if (byteAt_[c] >= buf_[c].size()) {
            if (!PullFrame()) {
                return -1;
            }
        }
        const int sub = bitIn_[c]++;
        if (bitIn_[c] == 8) {
            bitIn_[c] = 0;
            byteAt_[c]++;
        }
        return (buf_[c][byteAt_[c]] >> (7 - sub)) & 1;
    }

    /** 帧内跳过 n 字节/声道（n 必须字节对齐：目标比特号是抽取比的倍数时天然满足） */
    void SkipBytesPerCh(int n) {
        for (int c = 0; c < ch_; c++) {
            if (byteAt_[c] + n <= buf_[c].size()) {
                byteAt_[c] += n;
            } else {
                byteAt_[c] = (int) buf_[c].size();
            }
        }
    }

    int channels() const { return ch_; }
    int bytesPerCh() const { return bpc_; }

protected:
    /** 产出一帧；EOF 返回 false */
    virtual bool PullFrame() = 0;

    /** 交给基类一帧交错字节（ch_*bpc_ 字节），拆到各声道缓冲 */
    bool DeliverFrame(const uint8_t *interleaved, size_t bytes) {
        const size_t want = (size_t) ch_ * (size_t) bpc_;
        if (bytes < want) {
            return false;
        }
        for (int c = 0; c < ch_; c++) {
            buf_[c].resize((size_t) bpc_);
            for (int i = 0; i < bpc_; i++) {
                buf_[c][(size_t) i] = interleaved[(size_t) i * (size_t) ch_ + (size_t) c];
            }
            byteAt_[c] = 0;
            bitIn_[c] = 0;
        }
        return true;
    }

    int ch_ = 1;
    int bpc_ = 4704;
    std::vector<uint8_t> frame_;
    std::vector<std::vector<uint8_t>> buf_;
    std::vector<size_t> byteAt_;
    std::vector<int> bitIn_;
};

/**
 * DSD → PCM 两级抽取（从 fmt_dsd.cpp 提升为共享实现）。
 * read(out, frames)：输出 frames 帧（交错 float32）。每输出帧消耗 D 比特/声道。
 */
class Decimator {
public:
    int ch = 1;
    int64_t D = 32;        // 总抽取比（32 → 88.2k，64 → 176.4k）
    int64_t D1 = 8;        // 一级盒式平均长度 = D/4
    int outRate = 88200;
    std::vector<float> taps;

    std::vector<float> boxSum;
    int64_t boxN = 0;
    std::vector<float> ring;
    int ringAt = 0;
    int64_t midCount = 0;
    int midPhase = 0;

    void Init(int channels, int64_t decim) {
        ch = channels;
        D = decim;
        D1 = D / 4;
        if (D1 < 1) {
            D1 = 1;
        }
        boxSum.assign(ch, 0.0f);
        ring.assign((size_t) kFirTaps * ch, 0.0f);
        ringAt = 0;
        midCount = 0;
        midPhase = 0;
        DesignTaps(taps, 0.225);  // fc = 0.45 * outRate（相对中间率归一）
    }

    /** 读 frames 输出帧；耗尽返回剩余（<frames = EOF） */
    int64_t Read(BitSource &br, float *out, int64_t frames) {
        int64_t produced = 0;
        while (produced < frames) {
            if (ProduceFrame(br, out + produced * ch) < 0) {
                break;
            }
            produced++;
        }
        return produced;
    }

    void Reset() {
        std::fill(boxSum.begin(), boxSum.end(), 0.0f);
        boxN = 0;
        std::fill(ring.begin(), ring.end(), 0.0f);
        ringAt = 0;
        midCount = 0;
        midPhase = 0;
    }

private:
    int64_t ProduceFrame(BitSource &br, float *out) {
        for (int sub = 0; sub < 4; sub++) {
            for (int c = 0; c < ch; c++) {
                float s = 0.0f;
                for (int64_t k = 0; k < D1; k++) {
                    const int bit = br.NextBit(c);
                    if (bit < 0) {
                        return -1;
                    }
                    s += bit == 1 ? 1.0f : -1.0f;
                }
                const float mid = s / (float) D1;
                ring[(size_t) ringAt * ch + c] = mid;
            }
            ringAt = (ringAt + 1) % kFirTaps;
            midCount++;
            if (midCount % 4 == 0) {
                for (int c = 0; c < ch; c++) {
                    float acc = 0.0f;
                    for (int k = 0; k < kFirTaps; k++) {
                        const int idx = (ringAt + kFirTaps - 1 - k) % kFirTaps;
                        acc += taps[k] * ring[(size_t) idx * ch + c];
                    }
                    out[c] = acc;
                }
            }
        }
        return 0;
    }
};

#endif // MIWEN_DSD_FEED_H
