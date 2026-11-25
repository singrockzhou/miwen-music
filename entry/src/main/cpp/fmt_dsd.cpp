#include "fmt_dsd.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

// ---------------- 工具 ----------------

uint32_t Rd32LE(const uint8_t *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

uint64_t Rd64LE(const uint8_t *p) {
    return (uint64_t) Rd32LE(p) | ((uint64_t) Rd32LE(p + 4) << 32);
}

uint32_t Rd32BE(const uint8_t *p) {
    return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | (uint32_t) p[3];
}

uint64_t Rd64BE(const uint8_t *p) {
    return ((uint64_t) Rd32BE(p) << 32) | (uint64_t) Rd32BE(p + 4);
}

void SetWhy(std::string *why, const std::string &msg) {
    if (why != nullptr) {
        *why = msg;
    }
}

constexpr int kFirTaps = 65;

/** Blackman 窗 sinc 低通：fc 相对中间率 Nyquist 的归一化截止 */
void DesignTaps(std::vector<float> &taps, double fcNorm) {
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
 * 1-bit 流的按声道读取器。
 *
 * DSF：块内按声道分段——block i = [ch0 的 blockSize 字节][ch1 的 blockSize 字节]…；
 *       比特 LSB 在前。数据随机访问容易，seek 直接换算字节偏移。
 * DFF：帧交织——每帧 ch 个字节（每声道 1 字节），比特 MSB 在前。顺序读天然适配。
 */
class BitReader {
public:
    FILE *f = nullptr;
    int ch = 1;
    bool lsbFirst = true;
    bool blockMode = false;
    int blockSize = 4096;
    int64_t dataStart = 0;
    int64_t dataSize = 0;      // 字节（全部声道合计）
    int64_t dsdFrames = 0;     // 每声道比特数

    // 每声道比特游标（绝对比特号）
    std::vector<int64_t> bitPos;
    // 每声道待用字节缓冲
    std::vector<std::vector<uint8_t>> buf;
    std::vector<size_t> bufAt;

    bool Init(const std::string &path, int channels, bool isLsb, bool isBlock, int blk,
              int64_t start, int64_t bytes) {
        ch = channels;
        lsbFirst = isLsb;
        blockMode = isBlock;
        blockSize = blk > 0 ? blk : 4096;
        dataStart = start;
        dataSize = bytes;
        dsdFrames = bytes * 8 / (size_t) ch;
        bitPos.assign(ch, 0);
        buf.assign(ch, {});
        bufAt.assign(ch, 0);
        f = std::fopen(path.c_str(), "rb");
        return f != nullptr;
    }

    ~BitReader() {
        if (f != nullptr) {
            std::fclose(f);
        }
    }

    /** 取声道 c 的下一个比特：1 / 0；流耗尽返回 -1 */
    int NextBit(int c) {
        if (bufAt[c] >= buf[c].size()) {
            if (!Fill(c)) {
                return -1;
            }
        }
        const uint8_t byte = buf[c][bufAt[c]];
        const int64_t b = bitPos[c] & 7;
        bitPos[c]++;
        bufAt[c]++;
        // 比特序只在"字节内的位"上生效；DSF 的块结构和 DFF 的帧交织都在字节层之上，
        // 每声道逐字节取，序由 Fill() 负责
        if (lsbFirst) {
            return (byte >> b) & 1;
        }
        return (byte >> (7 - b)) & 1;
    }

private:
    /** 按当前 bitPos 给声道 c 填一块字节 */
    bool Fill(int c) {
        const int64_t byteIdx = bitPos[c] >> 3;  // 该声道内的绝对字节号
        if (byteIdx * ch >= dataSize) {
            return false;
        }
        if (blockMode) {
            // DSF：block i = sum(ch 的 blockSize 段)；声道 c 的字节在第 i 块的 c*blockSize 偏移
            const int64_t blk = byteIdx / blockSize;
            const int64_t off = byteIdx % blockSize;
            const int64_t fileOff = dataStart + blk * (int64_t) blockSize * ch + c * (int64_t) blockSize + off;
            int64_t want = blockSize - off;
            if (fileOff >= dataStart + dataSize) {
                return false;
            }
            if (want > dataSize - (fileOff - dataStart)) {
                want = dataSize - (fileOff - dataStart);
            }
            buf[c].assign((size_t) want, 0);
            std::fseek(f, fileOff, SEEK_SET);
            const size_t got = std::fread(buf[c].data(), 1, (size_t) want, f);
            if (got <= 0) {
                return false;
            }
            buf[c].resize(got);
            bufAt[c] = 0;
            return true;
        }
        // DFF：帧交织。所有声道同步消耗，把所有声道的缓冲一起填：
        // 顺序大块读 G 帧（G*ch 字节），按声道拆分——绝不能逐字节 fseek，
        // DSD64 每声道 352,800 字节/秒，逐字节读等于每秒上百万次 fseek，真机必卡死
        bool allEmpty = true;
        for (int k = 0; k < ch; k++) {
            if (bufAt[k] < buf[k].size()) {
                allEmpty = false;
                break;
            }
        }
        if (!allEmpty) {
            // 个别声道没同步（正常播放不该发生）：单字节读兜底
            const int64_t fileOff = dataStart + byteIdx * ch + c;
            if (fileOff >= dataStart + dataSize) {
                return false;
            }
            uint8_t one = 0;
            std::fseek(f, fileOff, SEEK_SET);
            if (std::fread(&one, 1, 1, f) != 1) {
                return false;
            }
            buf[c].assign(1, one);
            bufAt[c] = 0;
            return true;
        }
        const int64_t frames = std::min<int64_t>(8192, (dataSize - byteIdx * ch) / ch);
        if (frames <= 0) {
            return false;
        }
        std::vector<uint8_t> raw((size_t) frames * ch);
        std::fseek(f, dataStart + byteIdx * ch, SEEK_SET);
        if (std::fread(raw.data(), 1, raw.size(), f) != raw.size()) {
            // 读不满也接受（文件尾部截断）
        }
        for (int k = 0; k < ch; k++) {
            buf[k].resize((size_t) frames);
            for (int64_t g = 0; g < frames; g++) {
                buf[k][(size_t) g] = raw[(size_t) (g * ch + k)];
            }
            bufAt[k] = 0;
        }
        return true;
    }
};

/**
 * DSD → PCM 两级抽取。
 * read(out, frames)：输出 frames 帧（交错 float32）。每输出帧消耗 D 比特/声道。
 */
class Decimator {
public:
    int ch = 1;
    int64_t D = 32;        // 总抽取比（32 → 88.2k，64 → 176.4k）
    int64_t D1 = 8;        // 一级盒式平均长度 = D/4
    int outRate = 88200;

    std::vector<float> boxSum;   // 每声道滑动和（±1 之和）
    int64_t boxN = 0;            // 已累计比特数（< D1）
    // 每声道 FIR 历史环（kFirTaps 个中间样本）
    std::vector<float> ring;
    int ringAt = 0;
    int64_t midCount = 0;        // 已产生的中间样本数（取模 4 定相位）
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

    std::vector<float> taps;

    /** 读 frames 输出帧；耗尽返回剩余（<frames = EOF） */
    int64_t Read(BitReader &br, float *out, int64_t frames) {
        int64_t produced = 0;
        while (produced < frames) {
            const int64_t got = ProduceFrame(br, out + produced * ch);
            if (got < 0) {
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
    /** 产出一个输出帧；输入耗尽返回 -1 */
    int64_t ProduceFrame(BitReader &br, float *out) {
        for (int sub = 0; sub < 4; sub++) {
            // 一个中间样本 = D1 比特的盒式平均
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
                // 每第 4 个中间样本跑一次 FIR → 一个输出帧
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

// ---------------- DSF ----------------

class DsfSource : public AudioSource {
public:
    ~DsfSource() override {
        close();
    }

    AudioInfo open(const std::string &path) override {
        path_ = path;
        uint8_t head[96];
        FILE *f = std::fopen(path.c_str(), "rb");
        if (f == nullptr) {
            info_.error = "打不开文件（可能是目录授权未生效）";
            return info_;
        }
        const size_t got = std::fread(head, 1, sizeof(head), f);
        std::fclose(f);
        if (got < sizeof(head)) {
            info_.error = "文件头不完整，不是有效的 DSF";
            return info_;
        }
        if (std::memcmp(head, "DSD ", 4) != 0) {
            info_.error = "不是 DSF（缺 DSD 头）";
            return info_;
        }
        const int channelNum = (int) Rd32LE(head + 52);
        const int64_t freq = (int64_t) Rd32LE(head + 56);
        const int bitsPerSample = (int) Rd32LE(head + 60);
        const int64_t sampleCount = (int64_t) Rd64LE(head + 64);
        const int blockSize = (int) Rd32LE(head + 72);
        if (channelNum < 1 || channelNum > 2) {
            info_.error = "暂不支持 " + std::to_string(channelNum) + " 声道的 DSF";
            return info_;
        }
        if (freq <= 0) {
            info_.error = "DSF 采样率字段异常";
            return info_;
        }
        if (bitsPerSample != 1 && bitsPerSample != 8) {
            info_.error = "DSF 的 bitsPerSample 字段异常（应为 1）";
            return info_;
        }
        // 输出率：DSD64 → 88.2k；DSD128 → 176.4k；更高档位继续对半到 ≤176.4k
        int64_t decim = freq / 88200;
        if (decim < 32) {
            decim = 32;
        }
        // 抽取比取 4 的倍数（两级结构要求）
        decim = decim / 4 * 4;
        if (decim < 4) {
            decim = 4;
        }
        decim_ = decim;
        outRate_ = (int) (freq / decim);
        durationMs_ = (int64_t) ((double) sampleCount / (double) freq * 1000.0);
        totalFrames_ = (int64_t) ((double) durationMs_ * (double) outRate_ / 1000.0);

        // DSF 布局：DSD chunk 28 字节 + fmt chunk 52 字节 → data 块头在 80
        // （'data' 4CC @80，size 字段 @84..92），载荷从 92 开始。
        // 之前写成 88/96 是偏移错位：size 读到垃圾、载荷整体偏 4 字节。
        // size 字段不同实现口径不一（含/不含 12 字节块头），一律钳到文件尾保平安。
        int64_t fileSz = 0;
        {
            FILE *fsz = std::fopen(path.c_str(), "rb");
            if (fsz != nullptr) {
                std::fseek(fsz, 0, SEEK_END);
                fileSz = std::ftell(fsz);
                std::fclose(fsz);
            }
        }
        const int64_t dataStart = 92;
        int64_t dataSize = (int64_t) Rd64LE(head + 84);
        if (dataStart + dataSize > fileSz) {
            dataSize = fileSz - dataStart;
        }
        if (dataSize <= 0) {
            info_.error = "DSF 数据区为空";
            return info_;
        }
        if (!br_.Init(path, channelNum, true, true, blockSize, dataStart, dataSize)) {
            info_.error = "DSF 数据区打不开";
            return info_;
        }
        dec_.Init(channelNum, decim_);
        info_.ok = true;
        info_.sampleRate = outRate_;
        info_.channels = channelNum;
        info_.bitsPerSample = 1;
        info_.totalFrames = totalFrames_;
        info_.durationMs = durationMs_;
        info_.format = FormatTag(freq);
        return info_;
    }

    int64_t read(float *out, int64_t frames) override {
        if (!info_.ok) {
            return 0;
        }
        return dec_.Read(br_, out, frames);
    }

    int64_t seek(int64_t frame) override {
        if (!info_.ok || frame < 0) {
            return -1;
        }
        const int64_t maxFrame = totalFrames_ > 0 ? totalFrames_ : frame;
        const int64_t target = frame > maxFrame ? maxFrame : frame;
        // 目标帧对应的源比特号：frame * decim
        const int64_t bit = target * decim_;
        for (int c = 0; c < br_.ch; c++) {
            br_.bitPos[c] = bit;
            br_.buf[c].clear();
            br_.bufAt[c] = 0;
        }
        dec_.Reset();
        return target;
    }

    void close() override {
        // BitReader 自己释放 FILE*（析构）
    }

    std::string debugStats() const override {
        char buf[80];
        std::snprintf(buf, sizeof(buf), " dsd=%s out=%d", info_.format.c_str(), outRate_);
        return std::string(buf);
    }

private:
    static std::string FormatTag(int64_t freq) {
        const int64_t mult = freq / 44100;
        if (mult >= 512) {
            return "DSD512→PCM(软解)";
        }
        if (mult >= 256) {
            return "DSD256→PCM(软解)";
        }
        if (mult >= 128) {
            return "DSD128→PCM(软解)";
        }
        return "DSD64→PCM(软解)";
    }

    std::string path_;
    AudioInfo info_;
    BitReader br_;
    Decimator dec_;
    int64_t decim_ = 32;
    int outRate_ = 88200;
    int64_t totalFrames_ = 0;
    int64_t durationMs_ = 0;
};

// ---------------- DFF ----------------

class DffSource : public AudioSource {
public:
    ~DffSource() override {
        close();
    }

    AudioInfo open(const std::string &path) override {
        path_ = path;
        FILE *f = std::fopen(path.c_str(), "rb");
        if (f == nullptr) {
            info_.error = "打不开文件（可能是目录授权未生效）";
            return info_;
        }
        uint8_t head[16];
        if (std::fread(head, 1, 16, f) < 16 || std::memcmp(head, "FRM8", 4) != 0) {
            std::fclose(f);
            info_.error = "不是 DFF（缺 FRM8 头）";
            return info_;
        }
        int channels = 0;
        int64_t freq = 0;
        int64_t dataOff = -1;
        int64_t dataSize = 0;
        bool isDst = false;
        // 顶层块遍历：PROP（解析 SND 子块）与 DSD/DST 数据块
        for (;;) {
            uint8_t ch8[12];
            if (std::fread(ch8, 1, 12, f) < 12) {
                break;
            }
            const int64_t size = (int64_t) Rd64BE(ch8 + 4);
            if (std::memcmp(ch8, "PROP", 4) == 0 && size >= 4) {
                uint8_t propType[4];
                if (std::fread(propType, 1, 4, f) < 4 || std::memcmp(propType, "SND ", 4) != 0) {
                    std::fseek(f, size - 4, SEEK_CUR);
                    continue;
                }
                int64_t left = size - 4;
                // PROP 载荷终点：防止子块越界读（异常文件会把顶层块头当子块吞掉）
                const int64_t propEnd = std::ftell(f) + left;
                while (left >= 12 && std::ftell(f) + 12 <= propEnd) {
                    uint8_t sub[12];
                    if (std::fread(sub, 1, 12, f) < 12) {
                        left = -1;
                        break;
                    }
                    const int64_t ssz = (int64_t) Rd64BE(sub + 4);
                    // 采样率块 ID 是 "FS  "（FS + 两个空格）；按前两字节比，别写 "FSnn" 字面量
                    if (std::memcmp(sub, "FS", 2) == 0 && ssz >= 4) {
                        uint8_t fr[4];
                        if (std::fread(fr, 1, 4, f) < 4) {
                            left = -1;
                            break;
                        }
                        freq = (int64_t) Rd32BE(fr);
                        std::fseek(f, (long) (ssz - 4), SEEK_CUR);
                    } else if (std::memcmp(sub, "CHNL", 4) == 0 && ssz >= 2) {
                        uint8_t nc[2];
                        if (std::fread(nc, 1, 2, f) < 2) {
                            left = -1;
                            break;
                        }
                        channels = (nc[0] << 8) | nc[1];
                        std::fseek(f, (long) (ssz - 2), SEEK_CUR);
                    } else if (std::memcmp(sub, "CMPR", 4) == 0 && ssz >= 4) {
                        uint8_t ct[4];
                        if (std::fread(ct, 1, 4, f) < 4) {
                            left = -1;
                            break;
                        }
                        isDst = std::memcmp(ct, "DST ", 4) == 0;
                        std::fseek(f, (long) (ssz - 4), SEEK_CUR);
                    } else {
                        std::fseek(f, (long) ssz, SEEK_CUR);
                    }
                    left -= 12 + ssz;
                }
            } else if (std::memcmp(ch8, "DSD ", 4) == 0) {
                dataOff = std::ftell(f);
                dataSize = size;
                std::fseek(f, (long) size, SEEK_CUR);
            } else if (std::memcmp(ch8, "DST ", 4) == 0) {
                isDst = true;
                std::fseek(f, (long) size, SEEK_CUR);
            } else {
                std::fseek(f, (long) size, SEEK_CUR);
            }
        }
        std::fclose(f);
        if (isDst) {
            info_.error = "DST 压缩的 DFF 暂不支持（无损解压链未接入）";
            return info_;
        }
        if (dataOff < 0 || dataSize <= 0) {
            info_.error = "DFF 里没有音频数据块";
            return info_;
        }
        if (channels < 1 || channels > 2) {
            info_.error = "暂不支持 " + std::to_string(channels) + " 声道的 DFF";
            return info_;
        }
        if (freq <= 0) {
            info_.error = "DFF 采样率字段异常";
            return info_;
        }
        int64_t decim = freq / 88200;
        if (decim < 32) {
            decim = 32;
        }
        decim = decim / 4 * 4;
        if (decim < 4) {
            decim = 4;
        }
        decim_ = decim;
        outRate_ = (int) (freq / decim);
        // DSDIFF 的 FS 字段是每声道比特率（DSD64 = 2822400 bit/s），
        // 每声道比特数 = dataSize * 8 / ch——漏乘 8 会把 30s 算成 3.75s，进度条提前到头钉死
        const int64_t dsdFrames = dataSize * 8 / channels;
        durationMs_ = (int64_t) ((double) dsdFrames / (double) freq * 1000.0);
        totalFrames_ = (int64_t) ((double) durationMs_ * (double) outRate_ / 1000.0);

        if (!br_.Init(path, channels, false, false, 0, dataOff, dataSize)) {
            info_.error = "DFF 数据区打不开";
            return info_;
        }
        dec_.Init(channels, decim_);
        info_.ok = true;
        info_.sampleRate = outRate_;
        info_.channels = channels;
        info_.bitsPerSample = 1;
        info_.totalFrames = totalFrames_;
        info_.durationMs = durationMs_;
        info_.format = DffTag(freq);
        return info_;
    }

    int64_t read(float *out, int64_t frames) override {
        if (!info_.ok) {
            return 0;
        }
        return dec_.Read(br_, out, frames);
    }

    int64_t seek(int64_t frame) override {
        if (!info_.ok || frame < 0) {
            return -1;
        }
        const int64_t maxFrame = totalFrames_ > 0 ? totalFrames_ : frame;
        const int64_t target = frame > maxFrame ? maxFrame : frame;
        // 目标比特号 → 各声道游标复位，抽取器状态清零
        const int64_t bit = target * decim_;
        for (int c = 0; c < br_.ch; c++) {
            br_.bitPos[c] = bit;
            br_.buf[c].clear();
            br_.bufAt[c] = 0;
        }
        dec_.Reset();
        return target;
    }

    void close() override {
    }

    std::string debugStats() const override {
        char buf[80];
        std::snprintf(buf, sizeof(buf), " dsd=%s out=%d", info_.format.c_str(), outRate_);
        return std::string(buf);
    }

private:
    static std::string DffTag(int64_t freq) {
        const int64_t mult = freq / 44100;
        if (mult >= 512) {
            return "DSD512→PCM(软解)";
        }
        if (mult >= 256) {
            return "DSD256→PCM(软解)";
        }
        if (mult >= 128) {
            return "DSD128→PCM(软解)";
        }
        return "DSD64→PCM(软解)";
    }

    std::string path_;
    AudioInfo info_;
    BitReader br_;
    Decimator dec_;
    int64_t decim_ = 32;
    int outRate_ = 88200;
    int64_t totalFrames_ = 0;
    int64_t durationMs_ = 0;
};

}  // namespace

AudioSource *CreateDsfSource(const std::string &path, std::string *why) {
    DsfSource *src = new DsfSource();
    const AudioInfo info = src->open(path);
    if (info.ok) {
        return src;
    }
    SetWhy(why, info.error);
    delete src;
    return nullptr;
}

AudioSource *CreateDffSource(const std::string &path, std::string *why) {
    DffSource *src = new DffSource();
    const AudioInfo info = src->open(path);
    if (info.ok) {
        return src;
    }
    SetWhy(why, info.error);
    delete src;
    return nullptr;
}
