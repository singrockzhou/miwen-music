#include "fmt_dsd.h"

#include "dsd_feed.h"
#include "fmt_dst.h"

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

/**
 * 1-bit 流的按声道读取器（实现共享位流接口）。
 *
 * DSF：块内按声道分段——block i = [ch0 的 blockSize 字节][ch1 的 blockSize 字节]…；
 *       比特 LSB 在前。数据随机访问容易，seek 直接换算字节偏移。
 * DFF：帧交织——每帧 ch 个字节（每声道 1 字节），比特 MSB 在前。顺序读天然适配。
 */
class BitReader : public BitSource {
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
    int NextBit(int c) override {
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

// ---------------- DFF（元数据解析，未压缩与 DST 共用） ----------------

struct DffFrameRef {
    int64_t off;
    int64_t len;
};

struct DffMeta {
    int channels = 0;
    int64_t freq = 0;         // 每声道 DSD 比特率（DSD64 = 2822400）
    int64_t dsdOff = -1;      // 'DSD ' 块载荷偏移（未压缩流）
    int64_t dsdSize = 0;
    int64_t dstOff = -1;      // 'DST ' 块载荷偏移（DST 压缩流）
    int64_t dstSize = 0;
    int64_t dstFrames = 0;    // FRTE 帧数
    int dstFrameRate = 75;    // FRTE 帧率（帧/秒）
    std::vector<DffFrameRef> frames;  // DSTF 帧列表（off = 帧数据绝对偏移）
};

bool ParseDffMeta(const std::string &path, DffMeta &m, std::string *why) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        SetWhy(why, "打不开文件（可能是目录授权未生效）");
        return false;
    }
    uint8_t head[16];
    if (std::fread(head, 1, 16, f) < 16 || std::memcmp(head, "FRM8", 4) != 0) {
        std::fclose(f);
        SetWhy(why, "不是 DFF（缺 FRM8 头）");
        return false;
    }
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
                std::fseek(f, (long) (size - 4), SEEK_CUR);
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
                    m.freq = (int64_t) Rd32BE(fr);
                    std::fseek(f, (long) (ssz - 4), SEEK_CUR);
                } else if (std::memcmp(sub, "CHNL", 4) == 0 && ssz >= 2) {
                    uint8_t nc[2];
                    if (std::fread(nc, 1, 2, f) < 2) {
                        left = -1;
                        break;
                    }
                    m.channels = (nc[0] << 8) | nc[1];
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
            m.dsdOff = std::ftell(f);
            m.dsdSize = size;
            std::fseek(f, (long) size, SEEK_CUR);
        } else if (std::memcmp(ch8, "DST ", 4) == 0) {
            isDst = true;
            m.dstOff = std::ftell(f);
            m.dstSize = size;
            // 'DST ' 载荷：FRTE（u32 帧数 + u16 帧率）+ 逐帧 'DSTF' 子块（4CC + u64 size + 数据 + 奇数补齐）
            const int64_t dstEnd = m.dstOff + size;
            int64_t pos = m.dstOff;
            while (pos + 12 <= dstEnd) {
                uint8_t sub[12];
                std::fseek(f, (long) pos, SEEK_SET);
                if (std::fread(sub, 1, 12, f) < 12) {
                    break;
                }
                const int64_t ssz = (int64_t) Rd64BE(sub + 4);
                if (std::memcmp(sub, "FRTE", 4) == 0 && ssz >= 6) {
                    uint8_t frte[6];
                    if (std::fread(frte, 1, 6, f) == 6) {
                        m.dstFrames = (int64_t) Rd32BE(frte);
                        m.dstFrameRate = (frte[4] << 8) | frte[5];
                    }
                } else if (std::memcmp(sub, "DSTF", 4) == 0) {
                    DffFrameRef r;
                    r.off = pos + 12;
                    r.len = ssz;
                    if (r.len > 0 && r.len <= 1024 * 64 && r.off + r.len <= dstEnd + 8) {
                        m.frames.push_back(r);
                    }
                }
                pos += 12 + ssz;
                if ((pos - m.dstOff) & 1) {
                    pos++;  // 奇数补齐
                }
            }
            std::fseek(f, (long) dstEnd, SEEK_SET);
        } else {
            std::fseek(f, (long) size, SEEK_CUR);
        }
    }
    std::fclose(f);
    if (m.frames.empty() && isDst) {
        // 没扫到 DSTF：尝试文件尾的 'DSTI' 索引（{u64 绝对偏移, u32 长度} × 帧数，大端）
        FILE *f2 = std::fopen(path.c_str(), "rb");
        if (f2 != nullptr) {
            std::fseek(f2, 0, SEEK_END);
            const int64_t fileSz = std::ftell(f2);
            // 粗扫全文件找 'DSTI'（DSTI 通常在文件尾，倒着找更快）
            const int64_t tail = fileSz > 1 << 20 ? fileSz - (1 << 20) : 0;
            const size_t scan = (size_t) (fileSz - tail);
            std::vector<uint8_t> buf(scan);
            std::fseek(f2, (long) tail, SEEK_SET);
            if (std::fread(buf.data(), 1, scan, f2) == scan) {
                for (size_t i = 0; i + 12 <= scan; i++) {
                    if (std::memcmp(buf.data() + i, "DSTI", 4) == 0) {
                        const int64_t isz = (int64_t) Rd64BE(buf.data() + i + 4);
                        const int64_t entries = isz / 12;
                        for (int64_t k = 0; k < entries && k < m.dstFrames; k++) {
                            const uint8_t *e = buf.data() + i + 12 + (size_t) k * 12;
                            const int64_t eo = tail + (int64_t) i + 12 + k * 12;
                            if (eo + 12 <= fileSz) {
                                DffFrameRef r;
                                r.off = (int64_t) Rd64BE(e);
                                r.len = (int64_t) Rd32BE(e + 8);
                                m.frames.push_back(r);
                            }
                        }
                        break;
                    }
                }
            }
            std::fclose(f2);
        }
    }
    return true;
}

// ---------------- DFF（未压缩 DSD 流） ----------------

class DffSource : public AudioSource {
public:
    ~DffSource() override {
        close();
    }

    AudioInfo open(const std::string &path) override {
        path_ = path;
        DffMeta m;
        std::string why;
        if (!ParseDffMeta(path, m, &why)) {
            info_.error = why;
            return info_;
        }
        if (m.dstOff >= 0) {
            info_.error = "DST";  // 工厂函数据此改走 DffDstSource
            return info_;
        }
        if (m.dsdOff < 0 || m.dsdSize <= 0) {
            info_.error = "DFF 里没有音频数据块";
            return info_;
        }
        if (m.channels < 1 || m.channels > 2) {
            info_.error = "暂不支持 " + std::to_string(m.channels) + " 声道的 DFF";
            return info_;
        }
        if (m.freq <= 0) {
            info_.error = "DFF 采样率字段异常";
            return info_;
        }
        int64_t decim = m.freq / 88200;
        if (decim < 32) {
            decim = 32;
        }
        decim = decim / 4 * 4;
        if (decim < 4) {
            decim = 4;
        }
        decim_ = decim;
        outRate_ = (int) (m.freq / decim);
        // DSDIFF 的 FS 字段是每声道比特率（DSD64 = 2822400 bit/s），
        // 每声道比特数 = dataSize * 8 / ch——漏乘 8 会把 30s 算成 3.75s，进度条提前到头钉死
        const int64_t dsdFrames = m.dsdSize * 8 / m.channels;
        durationMs_ = (int64_t) ((double) dsdFrames / (double) m.freq * 1000.0);
        totalFrames_ = (int64_t) ((double) durationMs_ * (double) outRate_ / 1000.0);

        if (!br_.Init(path, m.channels, false, false, 0, m.dsdOff, m.dsdSize)) {
            info_.error = "DFF 数据区打不开";
            return info_;
        }
        dec_.Init(m.channels, decim_);
        info_.ok = true;
        info_.sampleRate = outRate_;
        info_.channels = m.channels;
        info_.bitsPerSample = 1;
        info_.totalFrames = totalFrames_;
        info_.durationMs = durationMs_;
        info_.format = DffTag(m.freq);
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

// ---------------- DFF（DST 压缩流：FRTE + DSTF 帧 → DST 解码 → 帧式位流 → 抽取） ----------------

class DffDstFeeder : public FrameBitSource {
public:
    DffDstFeeder(DffMeta &&m) : m_(std::move(m)) {}

    ~DffDstFeeder() override {
        if (f_ != nullptr) {
            std::fclose(f_);
        }
    }

    bool Open(const std::string &path, std::string *why) {
        f_ = std::fopen(path.c_str(), "rb");
        if (f_ == nullptr) {
            SetWhy(why, "DFF 数据区打不开");
            return false;
        }
        // 每帧每声道字节数 = 588 * (fs/44100) / 8；fs 为每声道比特率，DSD64 → 4704
        if (m_.freq <= 0 || (m_.freq % 600) != 0) {
            SetWhy(why, "DFF 采样率字段异常");
            return false;
        }
        bpc_ = (int) (m_.freq / 600);
        if (bpc_ < 1024 || bpc_ > 16384) {
            SetWhy(why, "DFF 的 DST 帧长超出支持范围");
            return false;
        }
        if (m_.frames.empty()) {
            SetWhy(why, "DFF 的 DST 帧索引缺失（无 DSTF 也无 DSTI）");
            return false;
        }
        if (m_.channels < 1 || m_.channels > 6) {
            SetWhy(why, "暂不支持 " + std::to_string(m_.channels) + " 声道的 DFF-DST");
            return false;
        }
        dst_.Init(m_.channels, (int64_t) bpc_ * 8);
        InitFrame(m_.channels, bpc_);
        raw_.resize(1024 * 64);
        dec_.resize((size_t) bpc_ * (size_t) m_.channels);
        path_ = path;
        return true;
    }

    void SeekFrame(int64_t idx, int skipBytes) {
        idx_ = idx;
        pendingSkip_ = skipBytes;
        for (int c = 0; c < ch_; c++) {
            buf_[c].clear();
            byteAt_[c] = 0;
            bitIn_[c] = 0;
        }
    }

    int frameRate() const { return m_.dstFrameRate > 0 ? m_.dstFrameRate : 75; }
    int64_t frameCount() const { return (int64_t) m_.frames.size(); }

protected:
    bool PullFrame() override {
        if (f_ == nullptr || idx_ < 0 || idx_ >= (int64_t) m_.frames.size()) {
            return false;
        }
        const DffFrameRef &r = m_.frames[(size_t) idx_];
        idx_++;
        if (r.len > (int64_t) raw_.size() || std::fseek(f_, (long) r.off, SEEK_SET) != 0
            || std::fread(raw_.data(), 1, (size_t) r.len, f_) != (size_t) r.len) {
            return false;
        }
        std::string why;
        if (!dst_.Decode(raw_.data(), (size_t) r.len, dec_.data(), &why)) {
            return false;
        }
        if (!DeliverFrame(dec_.data(), dec_.size())) {
            return false;
        }
        if (pendingSkip_ > 0) {
            SkipBytesPerCh(pendingSkip_);
            pendingSkip_ = 0;
        }
        return true;
    }

private:
    std::string path_;
    DffMeta m_;
    FILE *f_ = nullptr;
    DstDecoder dst_;
    std::vector<uint8_t> raw_;
    std::vector<uint8_t> dec_;
    int64_t idx_ = 0;
    int pendingSkip_ = 0;
};

class DffDstSource : public AudioSource {
public:
    ~DffDstSource() override {
        close();
    }

    AudioInfo open(const std::string &path) override {
        path_ = path;
        DffMeta m;
        std::string why;
        if (!ParseDffMeta(path, m, &why)) {
            info_.error = why;
            return info_;
        }
        if (m.dsdOff >= 0 && m.dstOff < 0) {
            info_.error = "该 DFF 是未压缩流";
            return info_;
        }
        if (m.freq <= 0) {
            info_.error = "DFF 采样率字段异常";
            return info_;
        }
        int64_t decim = m.freq / 88200;
        if (decim < 32) {
            decim = 32;
        }
        decim = decim / 4 * 4;
        if (decim < 4) {
            decim = 4;
        }
        decim_ = decim;
        outRate_ = (int) (m.freq / decim);

        feeder_ = new DffDstFeeder(std::move(m));
        if (!feeder_->Open(path, &why)) {
            delete feeder_;
            feeder_ = nullptr;
            info_.error = why;
            return info_;
        }
        // 时长 = 帧数 / 帧率（FRTE，通常 75fps）；FRTE 缺失时按帧索引长度推
        const int64_t frames = feeder_->frameCount();
        const int fps = feeder_->frameRate();
        durationMs_ = fps > 0 ? frames * 1000 / fps : 0;
        if (durationMs_ <= 0) {
            info_.error = "DFF-DST 帧数为零";
            return info_;
        }
        totalFrames_ = (int64_t) ((double) durationMs_ * (double) outRate_ / 1000.0);
        dec_.Init(feeder_->channels(), decim_);
        info_.ok = true;
        info_.sampleRate = outRate_;
        info_.channels = feeder_->channels();
        info_.bitsPerSample = 1;
        info_.totalFrames = totalFrames_;
        info_.durationMs = durationMs_;
        info_.format = DffTag(m.freq) + "·DST";
        return info_;
    }

    int64_t read(float *out, int64_t frames) override {
        if (!info_.ok || feeder_ == nullptr) {
            return 0;
        }
        return dec_.Read(*feeder_, out, frames);
    }

    int64_t seek(int64_t frame) override {
        if (!info_.ok || feeder_ == nullptr || frame < 0) {
            return -1;
        }
        const int64_t maxFrame = totalFrames_ > 0 ? totalFrames_ : frame;
        const int64_t target = frame > maxFrame ? maxFrame : frame;
        const int64_t bitsPerFrame = (int64_t) feeder_->bytesPerCh() * 8;
        const int64_t bits = target * decim_;
        const int64_t fi = bits / bitsPerFrame;
        const int64_t intraBits = bits % bitsPerFrame;
        feeder_->SeekFrame(fi, (int) (intraBits / 8));  // decim 是 4 的倍数 → 字节对齐
        dec_.Reset();
        return target;
    }

    void close() override {
        if (feeder_ != nullptr) {
            delete feeder_;
            feeder_ = nullptr;
        }
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
    DffDstFeeder *feeder_ = nullptr;
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
    // 先探一下是不是 DST 压缩流，是则走 DST 解码链
    {
        DffMeta probe;
        if (ParseDffMeta(path, probe, nullptr) && probe.dstOff >= 0) {
            DffDstSource *src = new DffDstSource();
            const AudioInfo info = src->open(path);
            if (info.ok) {
                return src;
            }
            SetWhy(why, info.error);
            delete src;
            return nullptr;
        }
    }
    DffSource *src = new DffSource();
    const AudioInfo info = src->open(path);
    if (info.ok) {
        return src;
    }
    SetWhy(why, info.error);
    delete src;
    return nullptr;
}
