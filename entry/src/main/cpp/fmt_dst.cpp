#include "fmt_dst.h"

#include <cstring>
#include <vector>

namespace {

// ---------------- 位读取器（MSB-first，对应 ffmpeg get_bits.h） ----------------

class MsbBits {
public:
    void Init(const uint8_t *data, size_t bytes) {
        d_ = data;
        nBits_ = (int64_t) bytes * 8;
        pos_ = 0;
    }

    int Get1() {
        if (pos_ >= nBits_) {
            return 0;  // 流耗尽按 0 读（ffmpeg 行为），出错由上层长度校验兜底
        }
        const int64_t byteIdx = pos_ >> 3;
        const int bit = (d_[byteIdx] >> (7 - (pos_ & 7))) & 1;
        pos_++;
        return bit;
    }

    int Get(int n) {
        int v = 0;
        for (int i = 0; i < n; i++) {
            v = (v << 1) | Get1();
        }
        return v;
    }

    int64_t Left() const { return nBits_ - pos_; }

private:
    const uint8_t *d_ = nullptr;
    int64_t nBits_ = 0;
    int64_t pos_ = 0;
};

int Log2Floor(unsigned int v) {
    int r = -1;
    while (v != 0) {
        v >>= 1;
        r++;
    }
    return r;
}

// 7 位值 → 概率：(位反转(c&127) >> 1) + 1（对应 ffmpeg ff_reverse[256] 的低 7 位用法）
uint8_t ProbDstXBit(int c) {
    static uint8_t rev7[128] = {0};
    if (rev7[1] == 0) {
        for (int i = 0; i < 128; i++) {
            int r = 0;
            for (int b = 0; b < 7; b++) {
                if ((i >> b) & 1) {
                    r |= 1 << (6 - b);
                }
            }
            rev7[i] = (uint8_t) r;
        }
    }
    return (uint8_t) ((rev7[c & 127] >> 1) + 1);
}

// ---------------- 算术解码器（对应 dstdec.c 的 ArithCoder） ----------------

struct Arith {
    unsigned int a = 4095;
    unsigned int c = 0;
};

void AcInit(Arith &ac, MsbBits &gb) {
    ac.a = 4095;
    ac.c = (unsigned int) gb.Get(12);
}

void AcGet(Arith &ac, MsbBits &gb, int p, int *e) {
    const unsigned int k = (ac.a >> 8) | ((ac.a >> 7) & 1);
    const unsigned int q = k * (unsigned int) p;
    const unsigned int aq = ac.a - q;
    *e = ac.c < aq ? 1 : 0;
    if (*e != 0) {
        ac.a = aq;
    } else {
        ac.a = q;
        ac.c -= aq;
    }
    if (ac.a < 2048) {
        const int n = 11 - Log2Floor(ac.a);
        ac.a <<= n;
        ac.c = (ac.c << n) | (unsigned int) gb.Get(n);
    }
}

// ---------------- Golomb（对应 golomb.h get_ur_golomb_jpegls + get_sr_golomb_dst） ----------------

int GetSrGolombDst(MsbBits &gb, unsigned int k) {
    // esc_len=0：前导零 i < limit-1 时 value = (i<<k) + k 位；i == limit-1 及以上报错
    const int64_t limit = gb.Left() > 0 ? gb.Left() : 1;
    int64_t i = 0;
    while (i < limit && gb.Get1() == 0) {
        i++;
    }
    // 循环退出时刚消费掉的那位是终止 1（或 i == limit 流耗尽）
    if (i >= limit - 1) {
        return -1;
    }
    int v = (int) ((i << k) | (unsigned int) gb.Get((int) k));
    if (v != 0 && gb.Get1() != 0) {
        v = -v;
    }
    return v;
}

// ---------------- 表结构（对应 dstdec.c 的 Table） ----------------

constexpr int kMaxChannels = 6;
constexpr int kMaxElements = 12;

struct Table {
    unsigned int elements = 1;
    unsigned int length[kMaxElements] = {0};
    int coeff[kMaxElements][128] = {};
};

// read_map：对应 dstdec.c
int ReadMap(MsbBits &gb, Table *t, unsigned int map[kMaxChannels], int channels) {
    t->elements = 1;
    map[0] = 0;
    if (gb.Get1() == 0) {
        for (int ch = 1; ch < channels; ch++) {
            const int bits = Log2Floor(t->elements) + 1;
            map[ch] = (unsigned int) gb.Get(bits);
            if (map[ch] == t->elements) {
                t->elements++;
                if (t->elements >= kMaxElements) {
                    return -1;
                }
            } else if (map[ch] > t->elements) {
                return -2;
            }
        }
    } else {
        for (int ch = 0; ch < kMaxChannels; ch++) {
            map[ch] = 0;
        }
    }
    return 0;
}

int SignExtend(MsbBits &gb, int bits) {
    int v = gb.Get(bits);
    if (bits < 32 && (v & (1 << (bits - 1))) != 0) {
        v -= 1 << bits;
    }
    return v;
}

void ReadUncodedCoeff(MsbBits &gb, int *dst, unsigned int elements, int coeffBits, int isSigned, int offset) {
    for (unsigned int i = 0; i < elements; i++) {
        dst[i] = (isSigned != 0 ? SignExtend(gb, coeffBits) : gb.Get(coeffBits)) + offset;
    }
}

int ReadTable(MsbBits &gb, Table *t, const int8_t codePredCoeff[3][3], int lengthBits, int coeffBits,
              int isSigned, int offset) {
    for (unsigned int i = 0; i < t->elements; i++) {
        t->length[i] = (unsigned int) gb.Get(lengthBits) + 1;
        if (t->length[i] > 128) {
            return -1;
        }
        if (gb.Get1() == 0) {
            ReadUncodedCoeff(gb, t->coeff[i], t->length[i], coeffBits, isSigned, offset);
        } else {
            const int method = gb.Get(2);
            if (method == 3) {
                return -2;
            }
            ReadUncodedCoeff(gb, t->coeff[i], (unsigned int) (method + 1), coeffBits, isSigned, offset);
            const int lsbSize = gb.Get(3);
            for (unsigned int j = (unsigned int) (method + 1); j < t->length[i]; j++) {
                int x = 0;
                for (int k = 0; k < method + 1; k++) {
                    x += codePredCoeff[method][k] * t->coeff[i][j - (unsigned int) k - 1];
                }
                int c = GetSrGolombDst(gb, (unsigned int) lsbSize);
                if (c < 0) {
                    return -3;
                }
                if (x >= 0) {
                    c -= (x + 4) / 8;
                } else {
                    c += (-x + 3) / 8;
                }
                if (isSigned == 0) {
                    if (c < offset || c >= offset + (1 << coeffBits)) {
                        return -4;
                    }
                }
                t->coeff[i][j] = c;
            }
        }
    }
    return 0;
}

const int8_t kFsetsCodePredCoeff[3][3] = {
    {-8},
    {-16, 8},
    {-9, -5, 6},
};

const int8_t kProbsCodePredCoeff[3][3] = {
    {-8},
    {-16, 8},
    {-24, 24, -8},
};

constexpr int kFirGroups = 16;  // filter[elements][16][256]

int BuildFilter(int16_t filter[kMaxElements][kFirGroups][256], const Table &fsets) {
    for (unsigned int i = 0; i < fsets.elements; i++) {
        const unsigned int length = fsets.length[i];
        for (int j = 0; j < kFirGroups; j++) {
            const int total = length - (unsigned int) j * 8;
            int totalClip = total < 0 ? 0 : (total > 8 ? 8 : total);
            for (int k = 0; k < 256; k++) {
                int64_t v = 0;
                for (int l = 0; l < totalClip; l++) {
                    v += (int64_t) (((k >> l) & 1) * 2 - 1) * fsets.coeff[i][j * 8 + l];
                }
                if (v < -32768 || v > 32767) {
                    return -1;
                }
                filter[i][j][k] = (int16_t) v;
            }
        }
    }
    return 0;
}

}  // namespace

// ---------------- DstDecoder ----------------

void DstDecoder::Init(int channels, int64_t bitsPerFramePerCh) {
    channels_ = channels < 1 ? 1 : (channels > kMaxChannels ? kMaxChannels : channels);
    samplesPerFrame_ = bitsPerFramePerCh;
    bytesPerCh_ = (int) (bitsPerFramePerCh / 8);
}

bool DstDecoder::Decode(const uint8_t *data, size_t size, uint8_t *out, std::string *why) {
    auto fail = [&](const char *msg) {
        if (why != nullptr) {
            *why = msg;
        }
        return false;
    };
    if (size <= 1) {
        return fail("DST 帧过短");
    }
    if (samplesPerFrame_ % 8 != 0) {
        return fail("DST 帧长配置异常");
    }
    const unsigned int samplesPerFrame = (unsigned int) samplesPerFrame_;
    const unsigned int nbBytes = samplesPerFrame / 8;  // 每声道字节数

    MsbBits gb;
    gb.Init(data, size);

    if (gb.Get1() == 0) {
        // 未编码帧：bit1..7 必须为 0，其余字节 = 原始交错 DSD，不足补 0x69
        gb.Get1();
        if (gb.Get(6) != 0) {
            return fail("DST 未编码帧的填充位非零");
        }
        const unsigned int total = nbBytes * (unsigned int) channels_;
        const size_t avail = size - 1;
        const unsigned int n = avail < total ? (unsigned int) avail : total;
        std::memcpy(out, data + 1, n);
        std::memset(out + n, 0x69, total - n);
        return true;
    }

    // 分段模式（10.4-10.6）：三段标志都必须为 1
    if (gb.Get1() == 0) {
        return fail("DST 帧使用非同一分段模式（暂不支持）");
    }
    if (gb.Get1() == 0) {
        return fail("DST 帧各声道分段方式不一致（暂不支持）");
    }
    if (gb.Get1() == 0) {
        return fail("DST 帧声道分段未结束标记异常（暂不支持）");
    }

    // 映射（10.7-10.9）
    const unsigned int sameMap = (unsigned int) gb.Get1();
    unsigned int mapChToFelem[kMaxChannels];
    unsigned int mapChToPelem[kMaxChannels];
    Table fsets;
    Table probs;
    if (ReadMap(gb, &fsets, mapChToFelem, channels_) < 0) {
        return fail("DST 帧的滤波器映射非法");
    }
    if (sameMap != 0) {
        probs.elements = fsets.elements;
        std::memcpy(mapChToPelem, mapChToFelem, sizeof(mapChToFelem));
    } else {
        return fail("DST 帧滤波器与概率表映射不同（暂不支持）");
    }

    // 半概率标志（10.10）
    unsigned int halfProb[kMaxChannels];
    for (int ch = 0; ch < channels_; ch++) {
        halfProb[ch] = (unsigned int) gb.Get1();
    }

    // 滤波器系数集（10.12）+ 概率表（10.13）
    if (ReadTable(gb, &fsets, kFsetsCodePredCoeff, 7, 9, 1, 0) < 0) {
        return fail("DST 帧的滤波器系数集解码失败");
    }
    if (ReadTable(gb, &probs, kProbsCodePredCoeff, 6, 7, 0, 1) < 0) {
        return fail("DST 帧的概率表解码失败");
    }

    // 算术编码数据（10.11）
    if (gb.Get1() != 0) {
        return fail("DST 帧的算术数据标志异常");
    }
    Arith ac;
    AcInit(ac, gb);

    static int16_t filter[kMaxElements][kFirGroups][256];
    if (BuildFilter(filter, fsets) < 0) {
        return fail("DST 帧的预测表溢出（系数过大）");
    }

    uint8_t status[kMaxChannels][16];
    std::memset(status, 0xAA, sizeof(status));
    std::memset(out, 0, (size_t) nbBytes * (size_t) channels_);

    int dstXBit = 0;
    AcGet(ac, gb, ProbDstXBit(fsets.coeff[0][0]), &dstXBit);

    for (unsigned int i = 0; i < samplesPerFrame; i++) {
        for (int ch = 0; ch < channels_; ch++) {
            const unsigned int felem = mapChToFelem[ch];
            const int16_t (*flt)[256] = filter[felem];
            uint8_t *st = status[ch];

            auto F = [&](int x) -> int16_t { return flt[x][st[x]]; };
            const int16_t predict = F(0) + F(1) + F(2) + F(3) + F(4) + F(5) + F(6) + F(7)
                + F(8) + F(9) + F(10) + F(11) + F(12) + F(13) + F(14) + F(15);

            int prob;
            int residual;
            if (halfProb[ch] == 0 || (int64_t) i >= (int64_t) fsets.length[felem]) {
                const unsigned int pelem = mapChToPelem[ch];
                const unsigned int index = (unsigned int) (predict < 0 ? -predict : predict) >> 3;
                const unsigned int pIdx = index < probs.length[pelem] ? index : probs.length[pelem] - 1;
                prob = probs.coeff[pelem][pIdx];
            } else {
                prob = 128;
            }
            AcGet(ac, gb, prob, &residual);
            const int v = ((predict >> 15) ^ residual) & 1;

            // status：128-bit 移位寄存器（低 64 + 高 64，小端字节序语义）
            uint64_t lo;
            uint64_t hi;
            std::memcpy(&lo, st, 8);
            std::memcpy(&hi, st + 8, 8);
            hi = (hi << 1) | (lo >> 63);
            lo = (lo << 1) | (uint64_t) v;
            std::memcpy(st, &lo, 8);
            std::memcpy(st + 8, &hi, 8);

            out[(i >> 3) * (unsigned int) channels_ + (unsigned int) ch] |= (uint8_t) (v << (7 - (i & 7)));
        }
    }
    return true;
}
