#include "fmt_alac.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

#include "ALACDecoder.h"
#include "ALACBitUtilities.h"  // BitBuffer 定义在里头，ALACDecoder.h 只前向声明

// ============================================================================
// MP4/M4A 容器解析 + Apple ALAC 解码。
//
// 关键事实（都以 ffmpeg 产物实测核对过）：
// - stsd 入口 'alac' 内嵌一个 36 字节的子原子 'alac'：size(4)+type(4)+ver/flags(4)+ALACSpecificConfig(24)。
//   解码器 Init 吃的就是那 24 字节 ALACSpecificConfig。
// - ALAC 的每个"帧"对应 stsz 里的一个 sample；stco 给 chunk 的文件偏移，
//   stsc 给"每 chunk 几个 sample"，两者联合才能算出每帧的字节位置。
// - ALACDecoder::Decode 输出交错的本机位深样本：16→int16、24→小端 3 字节、32→int32。
//   24 字节的字节序由 matrix_dec.c 里的 LBYTE/MBYTE/HBYTE 决定，
//   TARGET_RT_BIG_ENDIAN 未定义时走小端——arm64 上正好正确（EndianPortable.c
//   原版漏判 aarch64，已在 alac/EndianPortable.c 补上）。
//
// seek 策略：ALAC 帧自带帧数（partial frame 头），但没有全局块索引，
// 所以回退 seek 走「重建解码器 + 从头顺序解码跳到目标帧」，与 WavPack 无索引文件同一策略。
// ============================================================================

namespace {

const char kNonAlac[] = "mp4 容器非 ALAC 编码（AAC 等），交回系统解码";

uint32_t Rd32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
uint64_t Rd64(const uint8_t *p) {
    return (uint64_t(Rd32(p)) << 32) | Rd32(p + 4);
}
uint16_t Rd16(const uint8_t *p) {
    return uint16_t((uint16_t(p[0]) << 8) | uint16_t(p[1]));
}

uint32_t FourCC(const char *s) {
    return Rd32(reinterpret_cast<const uint8_t *>(s));
}

struct Box {
    uint64_t pos = 0;
    uint64_t size = 0;
    uint32_t type = 0;
};

/** 列出 [begin,end) 里的顶层盒。 */
bool ListBoxes(FILE *f, uint64_t begin, uint64_t end, std::vector<Box> &out) {
    uint64_t p = begin;
    while (p + 8 <= end) {
        uint8_t h[8];
        if (fseeko(f, static_cast<off_t>(p), SEEK_SET) != 0 ||
            std::fread(h, 1, 8, f) != 8) {
            return false;
        }
        Box b;
        b.type = Rd32(h + 4);
        uint64_t sz = Rd32(h);
        if (sz == 1) {
            uint8_t e[8];
            if (std::fread(e, 1, 8, f) != 8) {
                return false;
            }
            sz = Rd64(e);
        } else if (sz == 0) {
            sz = end - p;
        }
        if (sz < 8 || p + sz > end) {
            return false;
        }
        b.pos = p;
        b.size = sz;
        out.push_back(b);
        p += sz;
    }
    return true;
}

bool FindBox(FILE *f, uint64_t begin, uint64_t end, const char *type, Box &out) {
    std::vector<Box> boxes;
    if (!ListBoxes(f, begin, end, boxes)) {
        return false;
    }
    const uint32_t t = FourCC(type);
    for (const Box &b : boxes) {
        if (b.type == t) {
            out = b;
            return true;
        }
    }
    return false;
}

bool ReadAt(FILE *f, uint64_t pos, void *buf, size_t len) {
    if (fseeko(f, static_cast<off_t>(pos), SEEK_SET) != 0) {
        return false;
    }
    return std::fread(buf, 1, len, f) == len;
}

struct Mp4Alac {
    uint8_t cookie[24];                    // ALACSpecificConfig
    int32_t frameLength = 0;
    int32_t bits = 0;
    int32_t channels = 0;
    int32_t sampleRate = 0;
    int64_t totalFrames = 0;
    std::vector<int64_t> sampleOff;        // 每个帧的文件偏移
    std::vector<int32_t> sampleLen;        // 每个帧的字节数
};

/** 解析一个 trak：stsd / stsz / stsc / stco(co64) / mdhd。
 *  注意顺序：mdhd 里要把 media 时长换算成帧数需要采样率，而采样率在 stsd 的
 *  cookie 里，所以 stsd 必须先解析。 */
bool ParseTrak(FILE *f, const Box &trak, Mp4Alac &d, uint32_t &codec) {
    Box mdia;
    if (!FindBox(f, trak.pos + 8, trak.pos + trak.size, "mdia", mdia)) {
        return false;
    }

    Box minf;
    if (!FindBox(f, mdia.pos + 8, mdia.pos + mdia.size, "minf", minf)) {
        return false;
    }
    Box stbl;
    if (!FindBox(f, minf.pos + 8, minf.pos + minf.size, "stbl", stbl)) {
        return false;
    }
    const uint64_t s0 = stbl.pos + 8;
    const uint64_t s1 = stbl.pos + stbl.size;

    // ---- stsd：编码四字码 + ALAC magic cookie ----
    Box stsd;
    if (!FindBox(f, s0, s1, "stsd", stsd)) {
        return false;
    }
    std::vector<uint8_t> sd(stsd.size);
    if (!ReadAt(f, stsd.pos, sd.data(), sd.size())) {
        return false;
    }
    // stsd: size(4) type(4) ver/flags(4) entryCount(4) entry...
    if (stsd.size < 24) {
        return false;
    }
    const uint32_t entryCount = Rd32(sd.data() + 12);
    uint64_t ep = 16;
    for (uint32_t i = 0; i < entryCount && ep + 8 <= stsd.size; i++) {
        const uint32_t esize = Rd32(sd.data() + ep);
        codec = Rd32(sd.data() + ep + 4);
        if (esize < 8 || ep + esize > stsd.size) {
            break;
        }
        if (codec == FourCC("alac")) {
            // 扫描入口里的子原子：36 字节的 'alac'（ver/flags 4 + config 24）
            for (uint64_t j = ep + 8; j + 8 <= ep + esize; j++) {
                if (Rd32(sd.data() + j) == 36 && Rd32(sd.data() + j + 4) == FourCC("alac")) {
                    std::memcpy(d.cookie, sd.data() + j + 12, 24);
                    d.frameLength = static_cast<int32_t>(Rd32(d.cookie));
                    d.bits = d.cookie[5];
                    d.channels = d.cookie[9];
                    d.sampleRate = static_cast<int32_t>(Rd32(d.cookie + 20));
                    break;
                }
            }
        }
        ep += esize;
    }
    if (codec != FourCC("alac") || d.frameLength == 0) {
        return false;  // 不是 ALAC 轨（或 cookie 没拿到）
    }

    // mdhd（在 cookie 拿到采样率之后解析）：v0 timescale@12 duration@16；v1 timescale@20 duration@24（8 字节）
    Box mdhd;
    if (FindBox(f, mdia.pos + 8, mdia.pos + mdia.size, "mdhd", mdhd)) {
        std::vector<uint8_t> b(mdhd.size);
        if (ReadAt(f, mdhd.pos, b.data(), b.size())) {
            const int ver = b[8];
            uint32_t timescale;
            uint64_t duration;
            if (ver == 1) {
                timescale = Rd32(b.data() + 28);
                duration = Rd64(b.data() + 32);
            } else {
                timescale = Rd32(b.data() + 20);
                duration = Rd32(b.data() + 24);
            }
            if (timescale != 0) {
                if (timescale == static_cast<uint32_t>(d.sampleRate)) {
                    d.totalFrames = static_cast<int64_t>(duration);
                } else {
                    d.totalFrames = static_cast<int64_t>(
                        static_cast<double>(duration) * d.sampleRate / timescale);
                }
            }
        }
    }

    // ---- stsz：每帧字节数 ----
    Box stsz;
    if (!FindBox(f, s0, s1, "stsz", stsz)) {
        return false;
    }
    std::vector<uint8_t> z(stsz.size);
    if (!ReadAt(f, stsz.pos, z.data(), z.size())) {
        return false;
    }
    const uint32_t uniform = Rd32(z.data() + 12);
    const uint32_t count = Rd32(z.data() + 16);
    if (count == 0) {
        return false;
    }
    d.sampleLen.resize(count);
    if (uniform != 0) {
        std::fill(d.sampleLen.begin(), d.sampleLen.end(), static_cast<int32_t>(uniform));
    } else {
        if (stsz.size < 20 + static_cast<uint64_t>(count) * 4) {
            return false;
        }
        for (uint32_t i = 0; i < count; i++) {
            d.sampleLen[i] = static_cast<int32_t>(Rd32(z.data() + 20 + i * 4));
        }
    }

    // ---- stco / co64：chunk 的文件偏移 ----
    Box co;
    const bool isCo64 = FindBox(f, s0, s1, "co64", co);
    if (!isCo64 && !FindBox(f, s0, s1, "stco", co)) {
        return false;
    }
    std::vector<uint8_t> cb(co.size);
    if (!ReadAt(f, co.pos, cb.data(), cb.size())) {
        return false;
    }
    const uint32_t chunkCount = Rd32(cb.data() + 12);
    std::vector<int64_t> chunkOff(chunkCount);
    for (uint32_t i = 0; i < chunkCount; i++) {
        chunkOff[i] = isCo64
            ? static_cast<int64_t>(Rd64(cb.data() + 16 + static_cast<uint64_t>(i) * 8))
            : static_cast<int64_t>(Rd32(cb.data() + 16 + static_cast<uint64_t>(i) * 4));
    }

    // ---- stsc：每 chunk 几个 sample ----
    Box stsc;
    if (!FindBox(f, s0, s1, "stsc", stsc)) {
        return false;
    }
    std::vector<uint8_t> sc(stsc.size);
    if (!ReadAt(f, stsc.pos, sc.data(), sc.size())) {
        return false;
    }
    const uint32_t runCount = Rd32(sc.data() + 12);
    // (firstChunk, samplesPerChunk) —— 1 起始的 chunk 号
    std::vector<std::pair<uint32_t, uint32_t>> runs;
    for (uint32_t i = 0; i < runCount; i++) {
        const uint32_t first = Rd32(sc.data() + 16 + static_cast<uint64_t>(i) * 12);
        const uint32_t spc = Rd32(sc.data() + 16 + static_cast<uint64_t>(i) * 12 + 4);
        if (spc != 0) {
            runs.emplace_back(first, spc);
        }
    }
    if (runs.empty()) {
        return false;
    }

    // sample → chunk → 文件偏移
    d.sampleOff.resize(count);
    int64_t si = 0;
    for (size_t r = 0; r < runs.size() && si < count; r++) {
        const uint32_t first = runs[r].first;
        const uint32_t spc = runs[r].second;
        const uint32_t last = (r + 1 < runs.size()) ? runs[r + 1].first
                                                    : chunkCount + 1;
        for (uint32_t ck = first; ck < last && si < count; ck++) {
            if (ck - 1 >= chunkCount) {
                return false;
            }
            const int64_t base = chunkOff[ck - 1];
            int64_t cursor = base;
            for (uint32_t k = 0; k < spc && si < count; k++, si++) {
                d.sampleOff[si] = cursor;
                cursor += d.sampleLen[si];
            }
        }
    }
    if (si < count) {
        return false;  // stsc/stco 覆盖不全
    }
    return true;
}

class AlacSource : public AudioSource {
public:
    explicit AlacSource(std::string path) : path_(std::move(path)) {}
    ~AlacSource() override { CloseInternal(); }

    AudioInfo open(const std::string &path) override {
        AudioInfo info;
        FILE *f = std::fopen(path.c_str(), "rb");
        if (f == nullptr) {
            info.error = "ALAC: 打不开文件（fopen 失败，可能是目录授权未生效）";
            return info;
        }
        fseeko(f, 0, SEEK_END);
        const int64_t fsize = static_cast<int64_t>(ftello(f));
        fseeko(f, 0, SEEK_SET);

        Mp4Alac d;
        std::memset(d.cookie, 0, sizeof(d.cookie));
        uint32_t codec = 0;
        Box trak;
        bool gotTrack = false;
        uint64_t p = 0;
        Box moov;
        if (!FindBox(f, 0, static_cast<uint64_t>(fsize), "moov", moov)) {
            info.error = "m4a/mp4 里没有 moov 盒，不是标准容器";
            std::fclose(f);
            return info;
        }
        std::vector<Box> tops;
        ListBoxes(f, moov.pos + 8, moov.pos + moov.size, tops);
        for (const Box &b : tops) {
            if (b.type != FourCC("trak")) {
                continue;
            }
            Mp4Alac tmp;
            uint32_t c = 0;
            if (ParseTrak(f, b, tmp, c)) {
                d = tmp;
                codec = c;
                trak = b;
                gotTrack = true;
                break;
            }
            if (c != 0 && c != FourCC("alac")) {
                codec = c;  // 记下非 ALAC 的编码，给上层回退用
            }
        }
        if (!gotTrack) {
            std::fclose(f);
            if (codec != 0) {
                // codec 是按大端四字码读的，原样按字节展开才是 "mp4a" 这种可读形式
                char cc[5] = {
                    static_cast<char>((codec >> 24) & 0xff),
                    static_cast<char>((codec >> 16) & 0xff),
                    static_cast<char>((codec >> 8) & 0xff),
                    static_cast<char>(codec & 0xff), 0
                };
                info.error = std::string(kNonAlac) + "（" + cc + "）";
            } else {
                info.error = "m4a/mp4 里没有可识别的 ALAC 音轨";
            }
            return info;
        }

        // 解码器初始化：Init 吃 24 字节 ALACSpecificConfig
        dec_ = new ALACDecoder();
        if (dec_->Init(d.cookie, sizeof(d.cookie)) != 0) {
            std::fclose(f);
            info.error = "ALAC 解码器初始化失败（magic cookie 不合规范？）";
            return info;
        }
        cfg_ = dec_->mConfig;
        std::memcpy(cookie_, d.cookie, sizeof(cookie_));

        if (cfg_.sampleRate == 0 || cfg_.numChannels == 0 ||
            cfg_.frameLength == 0) {
            std::fclose(f);
            info.error = "ALAC 配置异常：sr=" + std::to_string(cfg_.sampleRate) +
                         " ch=" + std::to_string(cfg_.numChannels);
            return info;
        }
        if (cfg_.numChannels > 2) {
            // 与 AIFF 通道同一口径：AudioRenderer 侧只验证过单/立体声
            std::fclose(f);
            info.error = "多声道（" + std::to_string(cfg_.numChannels) +
                         "ch）暂不支持，先转成 FLAC";
            return info;
        }

        f_ = f;
        fsize_ = fsize;
        sampleOff_ = std::move(d.sampleOff);
        sampleLen_ = std::move(d.sampleLen);
        cur_ = 0;
        eof_ = false;
        raw_.resize(static_cast<size_t>(cfg_.frameLength) * cfg_.numChannels * 4);
        pkt_.resize(64 * 1024);

        info.ok = true;
        info.sampleRate = cfg_.sampleRate;
        info.channels = cfg_.numChannels;
        info.bitsPerSample = cfg_.bitDepth;
        if (d.totalFrames <= 0) {
            // mdhd 没给出来（异常文件）：按帧数×帧长估一个，宁可粗也不要 0
            d.totalFrames = static_cast<int64_t>(sampleLen_.size()) * cfg_.frameLength;
        }
        totalFrames_ = d.totalFrames;
        info.totalFrames = totalFrames_;
        info.durationMs = totalFrames_ * 1000 / cfg_.sampleRate;
        info.format = "ALAC";
        return info;
    }

    int64_t read(float *out, int64_t frames) override {
        if (f_ == nullptr) {
            return -1;
        }
        // 单位约定：pending_ 以 float 存（帧×声道），frames/got/take 以帧计。
        // 立体声下两者差 2 倍——第一版把 size() 直接当帧数用，
        // memcpy 越界读了 vector 容量里的陈旧数据（真机上表现为位置 2× 于实际
        // 产出、内容滞后约一半，rms 恰好还是旧段的值），教训记进验证报告。
        const int ch = cfg_.numChannels;
        int64_t got = 0;
        while (got < frames) {
            if (pending_.empty()) {
                if (eof_ || !DecodeNext()) {
                    break;
                }
            }
            const int64_t availFrames =
                static_cast<int64_t>(pending_.size()) / (ch > 0 ? ch : 1);
            const int64_t take = std::min(frames - got, availFrames);
            if (take <= 0) {
                break;
            }
            std::memcpy(out + got * ch, pending_.data(),
                        static_cast<size_t>(take) * ch * sizeof(float));
            pending_.erase(pending_.begin(),
                           pending_.begin() + static_cast<size_t>(take) * ch);
            got += take;
        }
        return got;
    }

    int64_t seek(int64_t frame) override {
        if (f_ == nullptr) {
            return -1;
        }
        if (frame < 0) {
            frame = 0;
        }
        if (frame > totalFrames_) {
            frame = totalFrames_;
        }
        // ALAC 没有全局块索引：重建解码器，从头顺序解码跳到目标帧。
        // 解码速度远高于实时，几首歌长度的回退 seek 在真机上无感。
        ResetDecoder();
        cur_ = 0;
        eof_ = false;
        pending_.clear();
        const int ch = cfg_.numChannels;
        int64_t skip = frame;
        while (skip > 0 && !eof_) {
            const size_t before = pending_.size();
            if (!DecodeNext()) {
                break;
            }
            const int64_t produced =
                static_cast<int64_t>(pending_.size() - before) / (ch > 0 ? ch : 1);
            if (produced <= skip) {
                skip -= produced;
                pending_.clear();
            } else {
                // 目标帧落在这个包内：留下 [skip, produced) 那段
                pending_.erase(pending_.begin(),
                               pending_.begin() + static_cast<size_t>(skip) * ch);
                skip = 0;
            }
        }
        return frame;
    }

    void close() override { CloseInternal(); }

    std::string debugStats() const override {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "pkt=%lld/%d out=%lld pend=%d err=%d eof=%d",
                      static_cast<long long>(cur_),
                      static_cast<int>(sampleOff_.size()),
                      static_cast<long long>(outTotal_),
                      static_cast<int>(pending_.size() / (cfg_.numChannels > 0 ? cfg_.numChannels : 1)),
                      errCount_, eof_ ? 1 : 0);
        return std::string(buf);
    }

private:
    void CloseInternal() {
        if (f_ != nullptr) {
            std::fclose(f_);
            f_ = nullptr;
        }
        delete dec_;
        dec_ = nullptr;
        pending_.clear();
        sampleOff_.clear();
        sampleLen_.clear();
    }

    void ResetDecoder() {
        delete dec_;
        dec_ = new ALACDecoder();
        dec_->Init(cookie_, sizeof(cookie_));
        cfg_ = dec_->mConfig;
    }

    /** 解下一帧到 pending_。返回 false = 到底或读盘失败。 */
    bool DecodeNext() {
        if (cur_ >= static_cast<int64_t>(sampleOff_.size())) {
            eof_ = true;
            return false;
        }
        const int32_t len = sampleLen_[cur_];
        if (len <= 0 || static_cast<int64_t>(sampleOff_[cur_]) + len > fsize_) {
            eof_ = true;
            return false;
        }
        if (static_cast<size_t>(len) > pkt_.size()) {
            pkt_.resize(static_cast<size_t>(len));
        }
        if (!ReadAt(f_, sampleOff_[cur_], pkt_.data(), static_cast<size_t>(len))) {
            eof_ = true;
            return false;
        }
        cur_++;

        BitBuffer bb;
        BitBufferInit(&bb, pkt_.data(), static_cast<uint32_t>(len));
        uint32_t outFrames = 0;
        const int32_t st = dec_->Decode(&bb, raw_.data(),
                                        static_cast<uint32_t>(cfg_.frameLength),
                                        cfg_.numChannels, &outFrames);
        outTotal_ += outFrames;
        if (st != 0) {
            errCount_++;
        }
        if (st != 0 && outFrames == 0) {
            // 坏帧：跳过继续。全坏了 read() 自然返回 0，上层按 eof 处理。
            return true;
        }
        AppendFloat(raw_.data(), outFrames);
        return true;
    }

    void AppendFloat(const uint8_t *src, uint32_t n) {
        const size_t total = static_cast<size_t>(n) * cfg_.numChannels;
        const size_t old = pending_.size();
        pending_.resize(old + total);
        float *out = pending_.data() + old;
        switch (cfg_.bitDepth) {
            case 16: {
                const int16_t *s = reinterpret_cast<const int16_t *>(src);
                for (size_t i = 0; i < total; i++) {
                    out[i] = static_cast<float>(s[i]) / 32768.0f;
                }
                break;
            }
            case 20:
            case 24: {
                // Apple 解码器在小端主机上输出小端 3 字节（matrix_dec.c：LBYTE=0），
                // 必须按低字节在前拼——按大端拼会把正弦变噪声（真机 rms 恒 0.555 的教训）
                for (size_t i = 0; i < total; i++) {
                    const uint8_t *b = src + i * 3;
                    int32_t v = b[0] | (int32_t(b[1]) << 8) | (int32_t(b[2]) << 16);
                    if (v & 0x800000) {
                        v -= 0x1000000;
                    }
                    out[i] = static_cast<float>(v) / 8388608.0f;
                }
                break;
            }
            case 32: {
                const int32_t *s = reinterpret_cast<const int32_t *>(src);
                for (size_t i = 0; i < total; i++) {
                    out[i] = static_cast<float>(s[i]) / 2147483648.0f;
                }
                break;
            }
            default: {
                for (size_t i = 0; i < total; i++) {
                    out[i] = 0.0f;
                }
                break;
            }
        }
    }

    std::string path_;
    FILE *f_ = nullptr;
    int64_t fsize_ = 0;
    ALACDecoder *dec_ = nullptr;
    ALACSpecificConfig cfg_{};
    uint8_t cookie_[24] = {};
    std::vector<int64_t> sampleOff_;
    std::vector<int32_t> sampleLen_;
    int64_t cur_ = 0;
    int64_t totalFrames_ = 0;
    bool eof_ = false;
    std::vector<uint8_t> raw_;    // 单帧解码输出（交错，本机位深）
    std::vector<uint8_t> pkt_;    // 单帧原始字节
    std::vector<float> pending_;  // 已解码未取走的 float 样本
    int64_t outTotal_ = 0;        // 诊断：累计产出帧数
    int32_t errCount_ = 0;        // 诊断：Decode 返回非零的包数
};

}  // namespace

AudioSource *CreateAlacSource(const std::string &path, std::string *why) {
    AlacSource *src = new AlacSource(path);
    AudioInfo info = src->open(path);
    if (info.ok) {
        return src;
    }
    delete src;
    if (why != nullptr) {
        *why = info.error.empty() ? "ALAC: 打不开（原因未知）" : info.error;
    }
    return nullptr;
}
