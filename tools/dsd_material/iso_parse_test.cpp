// PC 端 v1.5.0 素材回归测试：用设备端同一份源码（fmt_dsd.cpp / fmt_iso.cpp）直接打开
// DST 压缩 DFF 与 SACD ISO，输出三段 RMS 阶梯与未压缩基准（0.177 / 0.354 / 0.530）比对。
// 编译（DevEco 自带 LLVM，宿主 Windows 目标）：
//   clang++ -O2 -std=c++17 -I<cpp目录> iso_parse_test.cpp <cpp目录>/fmt_dsd.cpp <cpp目录>/fmt_iso.cpp <cpp目录>/fmt_dst.cpp -o iso_parse_test
#include "fmt_dsd.h"
#include "fmt_iso.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

bool ReadRms(AudioSource *src, int sr, int ch, double *rms3) {
    std::vector<float> buf((size_t) sr * ch);
    for (int seg = 0; seg < 3; seg++) {
        double sum = 0.0;
        int64_t n = 0;
        int64_t need = sr;
        while (need > 0) {
            const int64_t got = src->read(buf.data(), need);
            if (got <= 0) {
                break;
            }
            for (int64_t i = 0; i < got * ch; i++) {
                sum += (double) buf[(size_t) i] * buf[(size_t) i];
            }
            n += got * ch;
            need -= got;
        }
        rms3[seg] = n > 0 ? std::sqrt(sum / (double) n) : 0.0;
    }
    return true;
}

void ExpectLadder(const char *what, const double *rms, double tol) {
    const double base[3] = {0.177, 0.354, 0.530};
    bool ok = true;
    for (int i = 0; i < 3; i++) {
        if (std::fabs(rms[i] - base[i]) > tol) {
            ok = false;
        }
    }
    std::printf("%s rms=%.3f/%.3f/%.3f %s\n", what, rms[0], rms[1], rms[2],
                ok ? "PASS" : "FAIL");
}

}  // namespace

int main() {
    std::string why;

    // 1) DST 压缩 DFF（单声道 6s，三段各 2s：读前 3 秒 = 0.25/0.25/0.5 段）
    {
        AudioSource *src = CreateDffSource("dsd-dst-1.dff", &why);
        if (src == nullptr) {
            std::printf("dsd-dst-1.dff OPEN FAIL: %s\n", why.c_str());
            return 1;
        }
        AudioInfo info = src->open("dsd-dst-1.dff");
        if (!info.ok) {
            std::printf("dsd-dst-1.dff open fail: %s\n", info.error.c_str());
            return 1;
        }
        std::printf("dsd-dst-1.dff ok: sr=%d ch=%d dur=%lldms fmt=%s\n",
                    info.sampleRate, info.channels, (long long) info.durationMs,
                    info.format.c_str());
        double rms[3];
        ReadRms(src, info.sampleRate, info.channels, rms);
        ExpectLadder("dsd-dst-1.dff", rms, 0.02);  // 前 3 秒 = 0.177/0.177/0.354
        // seek 到 4.5 秒（0.75 段中段）再读 1 秒
        const int64_t target = (int64_t) (4.5 * info.sampleRate);
        if (src->seek(target) < 0) {
            std::printf("dsd-dst-1.dff seek FAIL\n");
            return 1;
        }
        double sum = 0.0;
        int64_t n = 0;
        std::vector<float> buf((size_t) info.sampleRate * info.channels);
        for (int64_t need = info.sampleRate; need > 0;) {
            const int64_t got = src->read(buf.data(), need);
            if (got <= 0) {
                break;
            }
            for (int64_t i = 0; i < got * info.channels; i++) {
                sum += (double) buf[(size_t) i] * buf[(size_t) i];
            }
            n += got;
            need -= got;
        }
        const double rmsSeek = n > 0 ? std::sqrt(sum / (double) n) : 0.0;
        std::printf("dsd-dst-1.dff seek@4.5s rms=%.3f %s\n", rmsSeek,
                    std::fabs(rmsSeek - 0.530) < 0.03 ? "PASS" : "FAIL");
        delete src;
    }

    // 2) FIR 预测 DFF（10 帧，coeff=8：RMS 应与未压缩一致）
    {
        AudioSource *src = CreateDffSource("dsd-dst-fir.dff", &why);
        if (src == nullptr) {
            std::printf("dsd-dst-fir.dff OPEN FAIL: %s\n", why.c_str());
            return 1;
        }
        AudioInfo info = src->open("dsd-dst-fir.dff");
        if (!info.ok) {
            std::printf("dsd-dst-fir.dff open fail: %s\n", info.error.c_str());
            return 1;
        }
        std::printf("dsd-dst-fir.dff ok: sr=%d ch=%d dur=%lldms\n",
                    info.sampleRate, info.channels, (long long) info.durationMs);
        double rms[3];
        ReadRms(src, info.sampleRate, info.channels, rms);
        std::printf("dsd-dst-fir.dff rms=%.3f/%.3f/%.3f（10帧≈1.3s，第3段不满）\n",
                    rms[0], rms[1], rms[2]);
        delete src;
    }

    // 3) SACD ISO（立体声 6s，三段各 2s；读 6 秒 = 0.177/0.354/0.530）
    {
        SacdIsoInfo info = ParseSacdIso("sacd-test.iso");
        if (!info.ok) {
            std::printf("sacd-test.iso PARSE FAIL: %s\n", info.error.c_str());
            return 1;
        }
        std::printf("sacd-test.iso ok: album=%s artist=%s tracks=%zu dst=%d\n",
                    info.album.c_str(), info.artist.c_str(), info.tracks.size(),
                    info.dst ? 1 : 0);
        if (info.tracks.empty()) {
            return 1;
        }
        AudioSource *src = CreateSacdIsoSource("sacd-test.iso", 0, &why);
        if (src == nullptr) {
            std::printf("sacd-test.iso OPEN FAIL: %s\n", why.c_str());
            return 1;
        }
        AudioInfo ai = src->open("sacd-test.iso");
        if (!ai.ok) {
            std::printf("sacd-test.iso open fail: %s\n", ai.error.c_str());
            return 1;
        }
        std::printf("sacd-test.iso track0: sr=%d ch=%d dur=%lldms fmt=%s\n",
                    ai.sampleRate, ai.channels, (long long) ai.durationMs,
                    ai.format.c_str());
        double rms[3];
        ReadRms(src, ai.sampleRate, ai.channels, rms);
        ExpectLadder("sacd-test.iso", rms, 0.02);
        // seek 到 4.5 秒读 1 秒（0.75 段）
        const int64_t target = (int64_t) (4.5 * ai.sampleRate);
        if (src->seek(target) < 0) {
            std::printf("sacd-test.iso seek FAIL\n");
            return 1;
        }
        double sum = 0.0;
        int64_t n = 0;
        std::vector<float> buf((size_t) ai.sampleRate * ai.channels);
        for (int64_t need = ai.sampleRate; need > 0;) {
            const int64_t got = src->read(buf.data(), need);
            if (got <= 0) {
                break;
            }
            for (int64_t i = 0; i < got * ai.channels; i++) {
                sum += (double) buf[(size_t) i] * buf[(size_t) i];
            }
            n += got;
            need -= got;
        }
        const double rmsSeek = n > 0 ? std::sqrt(sum / (double) n) : 0.0;
        std::printf("sacd-test.iso seek@4.5s rms=%.3f %s\n", rmsSeek,
                    std::fabs(rmsSeek - 0.530) < 0.03 ? "PASS" : "FAIL");
        delete src;
    }

    std::printf("ALL DONE\n");
    return 0;
}
