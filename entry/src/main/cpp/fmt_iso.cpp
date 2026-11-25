#include "fmt_iso.h"

#include "decoder.h"
#include "dsd_feed.h"
#include "fmt_dst.h"

#include <cstdio>
#include <cstring>

namespace {

constexpr int64_t kLsn = 2048;
constexpr int64_t kMasterTocLsn = 510;
constexpr int64_t kMasterTocLen = 10;
constexpr int kFrameBytesPerCh = 4704;   // 每帧每声道 DSD 字节（2.8224Mbit/s ÷ 75fps ÷ 8）
constexpr int kFps = 75;
constexpr int kMaxDstFrame = 1024 * 64;  // 与 sacd-ripper MAX_DST_SIZE 一致

void SetWhyErr(std::string *why, const char *msg);

uint32_t Rd32BE(const uint8_t *p) {
    return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | (uint32_t) p[3];
}

uint16_t Rd16BE(const uint8_t *p) {
    return (uint16_t) ((p[0] << 8) | p[1]);
}

// Master TOC 内的区描述（scarletbook.h master_toc_t，pack(1)，多字节字段大端）
struct MasterToc {
    int64_t area1Start = 0;   // 2ch 区 TOC 起 LSN
    int64_t area2Start = 0;   // Mch 区 TOC 起 LSN
    int64_t area1Size = 0;    // 区 TOC 扇区数
    int64_t area2Size = 0;
    std::string album;
    std::string artist;
};

// 区 TOC（scarletbook.h area_toc_t 固定部分 2048 字节，字段偏移按字段序累加核对过）
struct AreaToc {
    char id[9] = {0};
    int64_t size = 0;          // 区 TOC 总扇区数
    int frameFormat = 0;       // 0=DST，2=DSD_3_IN_14，3=DSD_3_IN_16
    int channelCount = 2;
    int loudspeakerConfig = 0;
    int trackCount = 0;
    int64_t trackStartLsn = 0;
    int64_t trackEndLsn = 0;
};

bool ReadSectors(FILE *f, int64_t lsn, int64_t count, std::vector<uint8_t> &buf) {
    buf.resize((size_t) (count * kLsn));
    if (std::fseek(f, (long) (lsn * kLsn), SEEK_SET) != 0) {
        return false;
    }
    return std::fread(buf.data(), 1, buf.size(), f) == buf.size();
}

std::string CleanText(const uint8_t *p, size_t maxLen) {
    // ISO8859-1/UTF-8 文本按字节收，截到 NUL；控制字节压成空格（sacd-ripper 同款处理）
    std::string out;
    for (size_t i = 0; i < maxLen && p[i] != 0; i++) {
        const uint8_t c = p[i];
        out.push_back(c < 0x20 && c != 0 ? (uint8_t) ' ' : c);
    }
    return out;
}

bool ParseMasterToc(FILE *f, MasterToc &mt, std::string *why) {
    std::vector<uint8_t> buf;
    if (!ReadSectors(f, kMasterTocLsn, kMasterTocLen, buf)) {
        SetWhyErr(why, "ISO 的 Master TOC 读不出来");
        return false;
    }
    if (std::memcmp(buf.data(), "SACDMTOC", 8) != 0) {
        SetWhyErr(why, "不是 SACD ISO（缺 SACDMTOC 标记）");
        return false;
    }
    mt.area1Start = Rd32BE(buf.data() + 64);
    mt.area2Start = Rd32BE(buf.data() + 72);
    mt.area1Size = Rd16BE(buf.data() + 84);
    mt.area2Size = Rd16BE(buf.data() + 86);
    // 第一张 SACDText 扇区（LSN 511）：专辑名/艺术家
    const uint8_t *txt = buf.data() + kLsn;
    if (std::memcmp(txt, "SACDText", 8) == 0) {
        const uint16_t titlePos = Rd16BE(txt + 16);
        const uint16_t artistPos = Rd16BE(txt + 18);
        if (titlePos > 0 && titlePos < kLsn) {
            mt.album = CleanText(txt + titlePos, 200);
        }
        if (artistPos > 0 && artistPos < kLsn) {
            mt.artist = CleanText(txt + artistPos, 200);
        }
    }
    if (mt.area1Start <= 0 && mt.area2Start <= 0) {
        SetWhyErr(why, "SACD ISO 里没有任何音频区");
        return false;
    }
    return true;
}

bool ParseAreaToc(FILE *f, int64_t startLsn, int64_t sizeSectors, AreaToc &at,
                  std::vector<SacdIsoTrack> &tracks, std::string *why) {
    if (startLsn <= 0 || sizeSectors <= 0 || sizeSectors > 96) {
        SetWhyErr(why, "SACD 区 TOC 参数异常");
        return false;
    }
    std::vector<uint8_t> buf;
    if (!ReadSectors(f, startLsn, sizeSectors, buf)) {
        SetWhyErr(why, "SACD 区 TOC 读不出来");
        return false;
    }
    std::memcpy(at.id, buf.data(), 8);
    if (std::memcmp(at.id, "TWOCHTOC", 8) != 0 && std::memcmp(at.id, "MULCHTOC", 8) != 0) {
        SetWhyErr(why, "不是有效的 SACD 区 TOC");
        return false;
    }
    at.size = Rd16BE(buf.data() + 10);
    at.frameFormat = buf[21] & 0x0F;
    at.channelCount = buf[32];
    at.loudspeakerConfig = (buf[33] >> 3) & 0x1F;
    at.trackCount = buf[69];
    at.trackStartLsn = Rd32BE(buf.data() + 72);
    at.trackEndLsn = Rd32BE(buf.data() + 76);
    if (at.trackCount <= 0 || at.trackCount > 255) {
        SetWhyErr(why, "SACD 区没有曲目");
        return false;
    }

    // 遍历区 TOC 后续扇区找 SACDTRL1 / SACDTRL2 / SACDTTxt（sacd-ripper 同款顺序）
    const uint8_t *trl1 = nullptr;
    const uint8_t *trl2 = nullptr;
    const uint8_t *txt = nullptr;
    int64_t pos = kLsn;  // 跳过第一扇区（区 TOC 本体）
    const int64_t end = at.size * kLsn;
    while (pos + kLsn <= end && pos + kLsn <= (int64_t) buf.size()) {
        const uint8_t *p = buf.data() + pos;
        if (std::memcmp(p, "SACDTTxt", 8) == 0) {
            if (txt == nullptr) {
                txt = p;
            }
            pos += kLsn;
        } else if (std::memcmp(p, "SACD_IGL", 8) == 0) {
            pos += kLsn * 2;
        } else if (std::memcmp(p, "SACD_ACC", 8) == 0) {
            pos += kLsn * 32;
        } else if (std::memcmp(p, "SACDTRL1", 8) == 0) {
            trl1 = p;
            pos += kLsn;
        } else if (std::memcmp(p, "SACDTRL2", 8) == 0) {
            trl2 = p;
            pos += kLsn;
        } else {
            break;
        }
    }
    if (trl1 == nullptr) {
        SetWhyErr(why, "SACD 区缺少 SACDTRL1 曲目表");
        return false;
    }

    tracks.resize((size_t) at.trackCount);
    for (int i = 0; i < at.trackCount; i++) {
        SacdIsoTrack &t = tracks[(size_t) i];
        t.startLsn = Rd32BE(trl1 + 8 + (size_t) i * 4);
        t.lengthLsn = Rd32BE(trl1 + 8 + 255 * 4 + (size_t) i * 4);
        t.dst = at.frameFormat == 0;
    }
    if (trl2 != nullptr) {
        // duration[255] 在 start[255] 之后；每项 {min, sec, frames, flags}，75fps
        for (int i = 0; i < at.trackCount; i++) {
            const uint8_t *d = trl2 + 8 + 255 * 4 + (size_t) i * 4;
            const int64_t frames = (int64_t) d[0] * 60 * kFps + (int64_t) d[1] * kFps + d[2];
            tracks[(size_t) i].durationMs = frames * 1000 / kFps;
        }
    }
    if (txt != nullptr) {
        // SACDTTxt：track_text_position[i]（u16 BE）→ 曲目文本条目
        for (int i = 0; i < at.trackCount; i++) {
            const uint16_t p = Rd16BE(txt + 8 + (size_t) i * 2);
            if (p == 0 || p >= kLsn) {
                continue;
            }
            const uint8_t *tp = txt + p;
            const int amount = tp[0];
            tp += 4;
            for (int j = 0; j < amount && j < 14; j++) {
                const uint8_t type = tp[0];
                tp += 2;  // type + 0x20 填充
                if (tp[0] != 0) {
                    if (type == 0x01) {  // TRACK_TYPE_TITLE
                        tracks[(size_t) i].title = CleanText(tp, 256);
                    }
                    while (tp[0] != 0) {
                        tp++;
                    }
                    while (tp[0] == 0) {
                        tp++;
                    }
                }
            }
        }
    }
    // 未压缩帧的时长兜底：LSN 区间 ÷ (ch × 4704) × 1000/75
    for (auto &t : tracks) {
        if (t.durationMs <= 0 && !t.dst) {
            const int64_t bytes = t.lengthLsn * kLsn;
            const int64_t frames = bytes / ((int64_t) at.channelCount * kFrameBytesPerCh);
            t.durationMs = frames * 1000 / kFps;
        }
    }
    return true;
}

void SetWhyErr(std::string *why, const char *msg) {
    if (why != nullptr) {
        *why = msg;
    }
}

// ---------------- ISO 帧喂入器：扇区解复用 → 帧组装 → DST/未压缩 → 交错字节 ----------------

class SacdFeeder : public FrameBitSource {
public:
    SacdFeeder(const std::string &path, int channels, bool dst, int64_t startLsn, int64_t endLsn)
        : dstEnc_(dst), startLsn_(startLsn), endLsn_(endLsn), channels_(channels) {
        f_ = std::fopen(path.c_str(), "rb");
        dst_.Init(channels, (int64_t) kFrameBytesPerCh * 8);
        InitFrame(channels, kFrameBytesPerCh);
    }

    ~SacdFeeder() override {
        if (f_ != nullptr) {
            std::fclose(f_);
        }
    }

    bool Ok() const { return f_ != nullptr; }

    void SeekFrame(int64_t frameIdx, int skipBytes) {
        // DST 帧大小可变、无全局帧索引：v1.5.0 用"回到轨道起点逐帧解码丢弃"实现定位，
        // 长曲目 seek 会花几秒，在验证报告里如实标注
        curLsn_ = startLsn_;
        frameBuf_.clear();
        frameStarted_ = false;
        frameDst_ = false;
        frameSectorLeft_ = 0;
        fiIdx_ = 0;
        skipFrames_ = frameIdx;
        pendingSkip_ = skipBytes;
        for (int c = 0; c < channels_; c++) {
            buf_[c].clear();
            byteAt_[c] = 0;
            bitIn_[c] = 0;
        }
    }

protected:
    bool PullFrame() override {
        if (f_ == nullptr) {
            return false;
        }
        for (;;) {
            // 先交付已组装完成的帧（seek 丢弃模式；可能堆叠，逐个弹出）
            if (!pendingDecoded_.empty()) {
                std::vector<uint8_t> &fr = pendingDecoded_.front();
                const bool ok = DeliverFrame(fr.data(), fr.size());
                pendingDecoded_.erase(pendingDecoded_.begin());
                if (ok && skipFrames_ > 0) {
                    skipFrames_--;
                    continue;
                }
                if (ok) {
                    if (pendingSkip_ > 0) {
                        SkipBytesPerCh(pendingSkip_);
                        pendingSkip_ = 0;
                    }
                    return true;
                }
                return false;
            }
            if (curLsn_ >= endLsn_ && !frameStarted_) {
                return false;  // 轨道读完
            }
            if (curLsn_ < endLsn_ && !ReadMore()) {
                return false;
            }
            if (frameStarted_ && FrameComplete()) {
                AssembleDecoded();
                frameStarted_ = false;
            }
        }
    }

private:
    bool FrameComplete() const {
        if (frameDst_) {
            return frameSectorLeft_ == 0;
        }
        return frameBuf_.size() >= (size_t) (channels_ * kFrameBytesPerCh);
    }

    bool ReadMore() {
        // 批量读扇区（一次 16 个），逐扇区解复用
        const int64_t want = 16;
        const int64_t n = (endLsn_ - curLsn_) < want ? (endLsn_ - curLsn_) : want;
        if (n <= 0) {
            return false;
        }
        sectorBuf_.resize((size_t) (n * kLsn));
        if (std::fseek(f_, (long) (curLsn_ * kLsn), SEEK_SET) != 0
            || std::fread(sectorBuf_.data(), 1, sectorBuf_.size(), f_) != sectorBuf_.size()) {
            return false;
        }
        for (int64_t s = 0; s < n; s++) {
            ProcessSector(sectorBuf_.data() + (size_t) (s * kLsn));
        }
        curLsn_ += n;
        return true;
    }

    void ProcessSector(const uint8_t *p) {
        const uint8_t b0 = p[0];
        const bool dstEnc = (b0 & 1) != 0;
        const int fiCount = (b0 >> 2) & 7;
        const int piCount = (b0 >> 5) & 7;
        size_t off = 1;
        // packet info：2 字节/个
        struct Pkt {
            int frameStart;
            int dataType;
            int len;
        };
        Pkt pkts[7];
        for (int i = 0; i < piCount && i < 7; i++) {
            pkts[i].frameStart = (p[off] >> 7) & 1;
            pkts[i].dataType = (p[off] >> 3) & 7;
            pkts[i].len = ((p[off] & 7) << 8) | p[off + 1];
            off += 2;
        }
        // frame info：DST 4 字节/个，非 DST 3 字节/个
        int sectorCounts[7] = {0};
        int chFlags[7] = {0};
        for (int i = 0; i < fiCount && i < 7; i++) {
            if (dstEnc) {
                chFlags[i] = p[off + 3];
                sectorCounts[i] = (chFlags[i] >> 2) & 0x1F;
                off += 4;
            } else {
                off += 3;
            }
        }
        int fi = 0;
        for (int i = 0; i < piCount && i < 7; i++) {
            const Pkt &pk = pkts[i];
            if (pk.dataType == 2) {  // DATA_TYPE_AUDIO
                if (pk.frameStart != 0) {
                    if (frameStarted_ && FrameComplete()) {
                        AssembleDecoded();
                        // 同扇区连续帧：pendingDecoded_ 可能堆叠，下一轮 PullFrame 逐个交付
                    }
                    frameStarted_ = true;
                    frameDst_ = dstEnc;
                    frameSectorLeft_ = dstEnc ? sectorCounts[fi < fiCount ? fi : 0] : 0;
                    fi++;
                    frameBuf_.clear();
                }
                if (frameStarted_) {
                    frameBuf_.insert(frameBuf_.end(), p + off, p + off + pk.len);
                    if (frameDst_) {
                        frameSectorLeft_--;
                    }
                }
            }
            off += (size_t) pk.len;
        }
    }

    void AssembleDecoded() {
        const size_t want = (size_t) (channels_ * kFrameBytesPerCh);
        if (frameDst_) {
            decBuf_.resize(want);
            if (dst_.Decode(frameBuf_.data(), frameBuf_.size(), decBuf_.data(), nullptr)) {
                pendingDecoded_.push_back(decBuf_);
            }
        } else {
            if (frameBuf_.size() < want) {
                frameBuf_.resize(want, 0x69);  // 短帧补 0x69（与 dstdec 未编码帧口径一致）
            }
            pendingDecoded_.push_back(frameBuf_);
        }
    }

    FILE *f_ = nullptr;
    bool dstEnc_;
    int channels_;
    int64_t startLsn_;
    int64_t endLsn_;
    int64_t curLsn_;
    DstDecoder dst_;
    std::vector<uint8_t> sectorBuf_;
    std::vector<uint8_t> frameBuf_;
    bool frameStarted_ = false;
    bool frameDst_ = false;
    int frameSectorLeft_ = 0;
    int fiIdx_ = 0;
    std::vector<std::vector<uint8_t>> pendingDecoded_;
    std::vector<uint8_t> decBuf_;
    int64_t skipFrames_ = 0;
    int pendingSkip_ = 0;
};

}  // namespace

// ---------------- 对外接口 ----------------

SacdIsoInfo ParseSacdIso(const std::string &path) {
    SacdIsoInfo info;
    FILE *f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        info.error = "打不开 ISO 文件";
        return info;
    }
    MasterToc mt;
    std::string why;
    if (!ParseMasterToc(f, mt, &why)) {
        std::fclose(f);
        info.error = why;
        return info;
    }
    // 优先立体声区；只有多声道区时如实报不支持
    int64_t areaLsn = 0;
    int64_t areaSize = 0;
    if (mt.area1Start > 0) {
        areaLsn = mt.area1Start;
        areaSize = mt.area1Size;
    } else {
        std::fclose(f);
        info.error = "这张 SACD 只有立体声区才支持，当前只有多声道区（暂不支持）";
        return info;
    }
    AreaToc at;
    std::vector<SacdIsoTrack> tracks;
    if (!ParseAreaToc(f, areaLsn, areaSize, at, tracks, &why)) {
        std::fclose(f);
        info.error = why;
        return info;
    }
    std::fclose(f);
    if (at.channelCount != 2 || at.loudspeakerConfig != 0) {
        info.error = "暂不支持 " + std::to_string(at.channelCount) + " 声道的 SACD 区";
        return info;
    }
    info.ok = true;
    info.album = mt.album;
    info.artist = mt.artist;
    info.channels = at.channelCount;
    info.dst = at.frameFormat == 0;
    info.tracks = std::move(tracks);
    return info;
}

AudioSource *CreateSacdIsoSource(const std::string &path, int trackIndex, std::string *why) {
    auto fail = [&](const std::string &msg) {
        if (why != nullptr) {
            *why = msg;
        }
        return (AudioSource *) nullptr;
    };
    SacdIsoInfo info = ParseSacdIso(path);
    if (!info.ok) {
        return fail(info.error);
    }
    if (trackIndex < 0 || trackIndex >= (int) info.tracks.size()) {
        return fail("SACD 曲目序号越界");
    }
    const SacdIsoTrack &t = info.tracks[(size_t) trackIndex];

    class SacdSource : public AudioSource {
    public:
        SacdSource(const std::string &path, const SacdIsoTrack &t, int channels, bool dst,
                   const std::string &album, const std::string &artist)
            : feeder_(path, channels, dst, t.startLsn, t.startLsn + t.lengthLsn) {
            info_.channels = channels;
            info_.bitsPerSample = 1;
            info_.durationMs = t.durationMs;
            info_.format = std::string("SACD-ISO") + (dst ? "(DST)" : "(DSD)") + "→PCM(软解)";
            album_ = album;
            artist_ = artist;
        }

        AudioInfo open(const std::string &path) override {
            if (!feeder_.Ok()) {
                info_.error = "SACD 数据区打不开";
                return info_;
            }
            const int64_t decim = 32;  // DSD64 固定 2.8224MHz → 88.2k
            decim_ = decim;
            outRate_ = 88200;
            durationMs_ = info_.durationMs;
            if (durationMs_ <= 0) {
                info_.error = "SACD 曲目时长字段异常";
                return info_;
            }
            totalFrames_ = (int64_t) ((double) durationMs_ * (double) outRate_ / 1000.0);
            dec_.Init(feeder_.channels(), decim_);
            info_.ok = true;
            info_.sampleRate = outRate_;
            info_.totalFrames = totalFrames_;
            return info_;
        }

        int64_t read(float *out, int64_t frames) override {
            if (!info_.ok) {
                return 0;
            }
            return dec_.Read(feeder_, out, frames);
        }

        int64_t seek(int64_t frame) override {
            if (!info_.ok || frame < 0) {
                return -1;
            }
            const int64_t maxFrame = totalFrames_ > 0 ? totalFrames_ : frame;
            const int64_t target = frame > maxFrame ? maxFrame : frame;
            const int64_t bitsPerFrame = kFrameBytesPerCh * 8;
            const int64_t bits = target * decim_;
            feeder_.SeekFrame(bits / bitsPerFrame, (int) (bits % bitsPerFrame / 8));
            dec_.Reset();
            return target;
        }

        void close() override {
        }

        std::string debugStats() const override {
            return " sacd out=" + std::to_string(outRate_);
        }

    private:
        SacdFeeder feeder_;
        Decimator dec_;
        AudioInfo info_;
        int64_t decim_ = 32;
        int outRate_ = 88200;
        int64_t totalFrames_ = 0;
        int64_t durationMs_ = 0;
        std::string album_;
        std::string artist_;
    };

    SacdSource *src = new SacdSource(path, t, info.channels, info.dst, info.album, info.artist);
    const AudioInfo info2 = src->open(path);
    if (!info2.ok) {
        if (why != nullptr) {
            *why = info2.error;
        }
        delete src;
        return nullptr;
    }
    return src;
}
