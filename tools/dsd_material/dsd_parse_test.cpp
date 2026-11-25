// PC 端 DSD 解析回归测试：直接用 fmt_dsd.cpp 打开真实 DSF/DFF 文件，
// 输出三段 RMS 与基准（0.177 / 0.354 / 0.530）比对。
// 编译：clang++ -O2 -std=c++17 -I../../entry/src/main/cpp dsd_parse_test.cpp ../../entry/src/main/cpp/fmt_dsd.cpp -o dsd_parse_test
#include "fmt_dsd.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 3) {
        std::printf("usage: dsd_parse_test <dsf|dff> <file>\n");
        return 1;
    }
    const std::string kind = argv[1];
    std::string why;
    AudioSource *src = kind == "dff" ? CreateDffSource(argv[2], &why) : CreateDsfSource(argv[2], &why);
    if (src == nullptr) {
        std::printf("OPEN FAIL: %s\n", why.c_str());
        return 2;
    }
    std::printf("open ok\n");
    // 分三段各读 1 秒算 RMS
    const int sr = 88200;
    const int ch = 2;
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
        const double rms = n > 0 ? std::sqrt(sum / (double) n) : 0.0;
        std::printf("seg%d rms=%.3f (frames=%lld)\n", seg, rms, (long long) (n / ch));
    }
    delete src;
    return 0;
}
