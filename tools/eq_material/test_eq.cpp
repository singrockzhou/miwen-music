// fmt_eq 引擎单元测试（PC 侧，stub AudioSource）。
// 断言：①EQ off 逐样本旁路（bit-exact）②1k+6dB 时 1kHz 正弦 rms≈0.499、100Hz/8kHz 段≈0.25
// ③PreAmp 乘法 ④seek 状态复位后输出仍连续收敛。
#include "../../entry/src/main/cpp/fmt_eq.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {
constexpr double kSr = 44100.0;

class StubSource : public AudioSource {
public:
    StubSource(double freq) : freq_(freq), pos_(0) {}
    AudioInfo open(const std::string &) override {
        AudioInfo info;
        info.ok = true;
        info.sampleRate = (int) kSr;
        info.channels = 2;
        info.totalFrames = 1LL << 40;
        return info;
    }
    int64_t read(float *out, int64_t frames) override {
        for (int64_t i = 0; i < frames; i++) {
            const double v = 0.25 * std::sqrt(2.0) * std::sin(2.0 * M_PI * freq_ * pos_ / kSr);
            out[i * 2] = (float) v;
            out[i * 2 + 1] = (float) v;
            pos_++;
        }
        return frames;
    }
    int64_t seek(int64_t frame) override { pos_ = frame; return frame; }
    void close() override {}
private:
    double freq_;
    int64_t pos_;
};

double RunRms(EqSource &eq, double freq, int64_t frames, bool skipWarmup) {
    StubSource *src = new StubSource(freq);
    src->open("");
    EqSource runner(src, 2, (int) kSr);
    // 把配置与状态搬进 runner（直接用 eq 的接口不可行——stub 频率不同）。
    // 简化：外层直接构造。这里仅占位（未用）。
    (void) eq;
    std::vector<float> buf((size_t) frames * 2);
    const int64_t got = runner.read(buf.data(), frames);
    (void) skipWarmup;
    double sum = 0;
    int64_t n = 0;
    // 跳过前 0.2s 暂态
    for (int64_t i = (int64_t)(0.2 * kSr); i < got; i++) {
        sum += buf[(size_t) i * 2] * buf[(size_t) i * 2];
        n++;
    }
    return n > 0 ? std::sqrt(sum / (double) n) : 0.0;
}
}  // namespace

int main() {
    // ① EQ off：bit-exact 旁路
    {
        StubSource *src = new StubSource(1000.0);
        src->open("");
        EqSource eq(src, 2, (int) kSr);
        EqSource::Config off;
        off.enabled = false;
        eq.setConfig(off);
        std::vector<float> buf(4096 * 2);
        StubSource *raw = new StubSource(1000.0);
        raw->open("");
        std::vector<float> ref(4096 * 2);
        eq.read(buf.data(), 4096);
        raw->read(ref.data(), 4096);
        delete raw;
        bool same = std::memcmp(buf.data(), ref.data(), buf.size() * sizeof(float)) == 0;
        printf("[1] EQ off bypass bit-exact: %s\n", same ? "PASS" : "FAIL");
    }
    // ② 1k band +6dB：三段频点 rms 与基准比
    {
        const double expect[3] = {0.252, 0.499, 0.252};   // gen_eq_material.py 基准
        const double tones[3] = {100.0, 1000.0, 8000.0};
        const char *names[3] = {"100Hz", "1kHz ", "8kHz "};
        for (int s = 0; s < 3; s++) {
            StubSource *src = new StubSource(tones[s]);
            src->open("");
            EqSource eq(src, 2, (int) kSr);
            EqSource::Config cfg;
            cfg.enabled = true;
            cfg.preampDb = 0.0;
            const double freqs[10] = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
            for (int b = 0; b < 10; b++) {
                EqSource::Band band;
                band.type = 0;
                band.freq = freqs[b];
                band.gainDb = (b == 5) ? 6.0 : 0.0;
                band.q = 1.1;
                cfg.bands.push_back(band);
            }
            eq.setConfig(cfg);
            const int64_t frames = (int64_t) (6.0 * kSr);
            std::vector<float> buf((size_t) frames * 2);
            eq.read(buf.data(), frames);
            double sum = 0;
            int64_t n = 0;
            for (int64_t i = (int64_t)(0.2 * kSr); i < frames; i++) {
                sum += buf[(size_t) i * 2] * buf[(size_t) i * 2];
                n++;
            }
            const double rms = std::sqrt(sum / (double) n);
            const bool pass = std::fabs(rms - expect[s]) < 0.02;
            printf("[2] %s rms=%.3f expect=%.3f: %s\n", names[s], rms, expect[s], pass ? "PASS" : "FAIL");
        }
    }
    // ③ PreAmp -6dB：1kHz rms 减半
    {
        StubSource *src = new StubSource(1000.0);
        src->open("");
        EqSource eq(src, 2, (int) kSr);
        EqSource::Config cfg;
        cfg.enabled = true;
        cfg.preampDb = -6.0;
        EqSource::Band band;
        band.type = 0;
        band.freq = 1000.0;
        band.gainDb = 0.0;
        band.q = 1.1;
        cfg.bands.push_back(band);
        eq.setConfig(cfg);
        const int64_t frames = (int64_t) (6.0 * kSr);
        std::vector<float> buf((size_t) frames * 2);
        eq.read(buf.data(), frames);
        double sum = 0;
        int64_t n = 0;
        for (int64_t i = (int64_t)(0.2 * kSr); i < frames; i++) {
            sum += buf[(size_t) i * 2] * buf[(size_t) i * 2];
            n++;
        }
        const double rms = std::sqrt(sum / (double) n);
        const bool pass = std::fabs(rms - 0.125) < 0.01;
        printf("[3] preamp -6dB rms=%.3f expect=0.125: %s\n", rms, pass ? "PASS" : "FAIL");
    }
    // ④ seek 复位：seek 后读到的样本与新解码位置一致（无旧状态串扰）
    {
        StubSource *src = new StubSource(1000.0);
        src->open("");
        EqSource eq(src, 2, (int) kSr);
        EqSource::Config cfg;
        cfg.enabled = true;
        EqSource::Band band;
        band.type = 0;
        band.freq = 1000.0;
        band.gainDb = 6.0;
        band.q = 1.1;
        cfg.bands.push_back(band);
        eq.setConfig(cfg);
        std::vector<float> buf(4096 * 2);
        eq.read(buf.data(), 4096);
        eq.read(buf.data(), 4096);
        eq.seek(44100);
        eq.read(buf.data(), 4096);
        // 幅度应立即回到滤波稳态（|H|≈2×0.354 峰值），若残留旧状态会明显偏离
        double peak = 0;
        for (size_t i = 0; i < buf.size(); i++) {
            peak = std::max(peak, (double) std::fabs(buf[i]));
        }
        const bool pass = std::fabs(peak - 0.3536 * 1.995) < 0.05;
        printf("[4] seek reset peak=%.3f expect=%.3f: %s\n", peak, 0.3536 * 1.995, pass ? "PASS" : "FAIL");
    }
    return 0;
}
