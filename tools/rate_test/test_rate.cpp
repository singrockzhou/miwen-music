// WSOLA PC 端验证（Windows 主机直跑）：读 WAV → RateSource 1.5× → 写 WAV。
// 断言：输出时长 ≈ 30/1.5 = 20s；三段内容边界前移（10s 源内容出现在 ~6.67s 处）。
#include "../../entry/src/main/cpp/fmt_rate.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

class WavSource : public AudioSource {
public:
    ~WavSource() override {
        close();
    }

    AudioInfo open(const std::string &path) override {
        FILE *f = std::fopen(path.c_str(), "rb");
        if (f == nullptr) {
            info_.error = "open failed";
            return info_;
        }
        uint8_t head[44];
        if (std::fread(head, 1, 44, f) != 44 || std::memcmp(head, "RIFF", 4) != 0 ||
            std::memcmp(head + 8, "WAVE", 4) != 0) {
            std::fclose(f);
            info_.error = "not wav";
            return info_;
        }
        std::memcpy(&sampleRate_, head + 24, 4);
        std::memcpy(&bits_, head + 34, 2);
        // 找 data 块（44 字节标准头直接用）
        std::memcpy(&dataBytes_, head + 40, 4);
        channels_ = head[22] | (head[23] << 8);
        f_ = f;
        info_.ok = true;
        info_.sampleRate = sampleRate_;
        info_.channels = channels_;
        info_.bitsPerSample = bits_;
        info_.totalFrames = dataBytes_ / (channels_ * 4);
        info_.durationMs = info_.totalFrames * 1000 / sampleRate_;
        return info_;
    }

    int64_t read(float *out, int64_t frames) override {
        const int64_t bytesPerFrame = channels_ * 4;
        const int64_t want = frames * bytesPerFrame;
        int64_t got = 0;
        while (got < want) {
            const size_t r = std::fread((char *) out + got, 1, (size_t) (want - got), f_);
            if (r == 0) {
                break;
            }
            got += r;
        }
        return got / bytesPerFrame;
    }

    int64_t seek(int64_t frame) override {
        std::fseek(f_, 44 + frame * channels_ * 4, SEEK_SET);
        return frame;
    }

    void close() override {
        if (f_ != nullptr) {
            std::fclose(f_);
            f_ = nullptr;
        }
    }

private:
    FILE *f_ = nullptr;
    AudioInfo info_;
    int sampleRate_ = 44100;
    int channels_ = 1;
    int bits_ = 32;
    int64_t dataBytes_ = 0;
};

}  // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        std::printf("usage: test_rate <in.wav> <out.wav> [rate]\n");
        return 1;
    }
    const double rate = argc >= 4 ? std::atof(argv[3]) : 1.5;

    WavSource *wav = new WavSource();
    const AudioInfo info = wav->open(argv[1]);
    if (!info.ok) {
        std::printf("FAIL open: %s\n", info.error.c_str());
        return 1;
    }
    std::printf("in: %dHz %dch %lld frames %.2fs\n", info.sampleRate, info.channels,
                (long long) info.totalFrames, info.totalFrames * 1000.0 / info.sampleRate / 1000.0);

    RateSource *rs = new RateSource(wav, info.channels, info.sampleRate);
    rs->open(argv[1]);
    rs->setRate(rate);

    std::vector<float> all;
    std::vector<float> buf(8192 * info.channels);
    int64_t total = 0;
    int64_t eofPos = -1;
    for (;;) {
        const int64_t got = rs->read(buf.data(), 8192);
        if (got <= 0) {
            eofPos = total;
            break;
        }
        all.insert(all.end(), buf.begin(), buf.begin() + got * info.channels);
        total += got;
    }
    const double outSec = total / (double) info.sampleRate;
    const double expectSec = info.totalFrames / (double) info.sampleRate / rate;
    std::printf("out: %lld frames = %.3fs (expect ~%.3fs)\n", (long long) total, outSec, expectSec);

    // 三段 RMS（输出时间轴上的段边界 = 源边界 / rate）
    const double inSec = info.totalFrames / (double) info.sampleRate;
    const double b1 = 10.0 / rate, b2 = 20.0 / rate;
    auto rmsOf = [&](double t0, double t1) {
        const int64_t i0 = (int64_t) (t0 * info.sampleRate) * info.channels;
        const int64_t i1 = (int64_t) (t1 * info.sampleRate) * info.channels;
        double s = 0;
        int64_t n = 0;
        for (int64_t i = i0; i < i1 && i < (int64_t) all.size(); i++) {
            s += all[i] * all[i];
            n++;
        }
        return n > 0 ? std::sqrt(s / n) : 0.0;
    };
    std::printf("rms: [0~%.2fs]=%.3f [%.2f~%.2fs]=%.3f [%.2f~%.2fs]=%.3f\n",
                b1, rmsOf(0, b1), b1, b2, rmsOf(b1, b2), b2, outSec, rmsOf(b2, outSec));

    // 断言
    bool ok = true;
    if (std::fabs(outSec - expectSec) / expectSec > 0.03) {
        std::printf("FAIL duration: got %.3fs expect %.3fs\n", outSec, expectSec);
        ok = false;
    }
    // 段幅度阶梯（与源一致 0.177/0.354/0.530 的相对关系）
    const double r1 = rmsOf(0, b1), r2 = rmsOf(b1, b2), r3 = rmsOf(b2, outSec);
    if (r1 < 0.05 || r2 < r1 * 1.5 || r3 < r2 * 1.2) {
        std::printf("FAIL segments: %.3f %.3f %.3f\n", r1, r2, r3);
        ok = false;
    }

    // 写出 WAV（f32le）
    FILE *f = std::fopen(argv[2], "wb");
    const uint32_t dataLen = (uint32_t) all.size() * 4;
    const uint32_t riff = 36 + dataLen;
    const uint32_t sr = info.sampleRate;
    const uint32_t byteRate = sr * info.channels * 4;
    uint8_t h[44] = {'R', 'I', 'F', 'F'};
    std::memcpy(h + 4, &riff, 4);
    std::memcpy(h + 8, "WAVEfmt ", 8);
    const uint32_t fmtLen = 16;
    std::memcpy(h + 16, &fmtLen, 4);
    const uint16_t fmt = 3, ch = info.channels;
    std::memcpy(h + 20, &fmt, 2);
    std::memcpy(h + 22, &ch, 2);
    std::memcpy(h + 24, &sr, 4);
    std::memcpy(h + 28, &byteRate, 4);
    const uint16_t align = info.channels * 4, bw = 32;
    std::memcpy(h + 32, &align, 2);
    std::memcpy(h + 34, &bw, 2);
    std::memcpy(h + 36, "data", 4);
    std::memcpy(h + 40, &dataLen, 4);
    std::fwrite(h, 1, 44, f);
    std::fwrite(all.data(), 4, all.size(), f);
    std::fclose(f);
    std::printf("%s (eof at frame %lld)\n", ok ? "PASS" : "FAIL", (long long) eofPos);
    return ok ? 0 : 1;
}
