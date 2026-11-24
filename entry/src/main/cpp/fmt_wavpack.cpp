#include "fmt_wavpack.h"

#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "wavpack.h"

namespace {

/** 单次解码帧数上限。调用方按 100ms 索要（44100Hz 约 4410 帧），
 *  这里只防误传巨值，不参与常规路径。 */
const int64_t kMaxChunkFrames = 192000;

/** seek 失败后重建上下文、顺序解码追帧的上限（约 5 分钟音频）。
 *  WavPack 解码约 200 倍速，5 分钟音频追赶约 1.5 秒；再长就放弃定位，
 *  免得整轨文件拖一下进度条把界面卡死。 */
const int64_t kMaxResyncFrames = 44100 * 300;

/** seek 兜底时每次解码丢弃的帧数 */
const size_t kSkipChunk = 4096;

/** 一个文件句柄，兼作 libwavpack 的 reader id。 */
struct WvFile {
    FILE *fp = nullptr;
    int64_t length = 0;
};

int64_t LengthOf(FILE *fp) {
    if (fp == nullptr) {
        return 0;
    }
    if (std::fseek(fp, 0, SEEK_END) != 0) {
        return 0;
    }
    const long n = std::ftell(fp);
    std::fseek(fp, 0, SEEK_SET);
    return n < 0 ? 0 : (int64_t) n;
}

/** 把 path 的扩展名换成 .wvc；没有扩展名时直接追加。 */
std::string WvcPath(const std::string &path) {
    const size_t dot = path.find_last_of('.');
    const size_t sep = path.find_last_of("/\\");
    if (dot == std::string::npos || (sep != std::string::npos && dot < sep)) {
        return path + ".wvc";
    }
    return path.substr(0, dot) + ".wvc";
}

FILE *OpenCorrection(const std::string &path) {
    // 大小写两种都试：Windows 拷来的库常常是 .WV/.WVC 混排
    const std::string lower = WvcPath(path);
    std::string upper = lower;
    for (size_t i = upper.size() - 4; i < upper.size(); i++) {
        upper[i] = (char) std::toupper((unsigned char) upper[i]);
    }
    FILE *f = std::fopen(lower.c_str(), "rb");
    if (f == nullptr) {
        f = std::fopen(upper.c_str(), "rb");
    }
    return f;
}

/** libwavpack 的英文错误变成用户能看懂的中文。查不到出处的错误原样带回去，
 *  至少不会让人以为「格式没问题但就是不响」。 */
std::string TranslateError(const char *raw) {
    if (raw == nullptr || raw[0] == '\0') {
        return "解码器打不开该文件";
    }
    const std::string e(raw);
    if (e.find("DSD") != std::string::npos) {
        return "这是 DSD 编码的 WavPack（.wv 里装的是 DSD 位流），当前解码链只输出 PCM，暂不支持";
    }
    if (e.find("not compatible") != std::string::npos || e.find("version") != std::string::npos) {
        return "WavPack 版本不受支持：" + e;
    }
    if (e.find("can't open") != std::string::npos || e.find("open") != std::string::npos) {
        return "打不开文件：" + e;
    }
    return e;
}

}  // namespace

// ---------------------------------------------------------------------------
// libwavpack 的 C 回调。必须 extern "C"：结构体里存的是 C 函数指针类型，
// 混用 C++ 链接在部分编译器上会被判类型不兼容。
// ---------------------------------------------------------------------------
extern "C" {

static int32_t WvReadBytes(void *id, void *data, int32_t bcount) {
    WvFile *h = static_cast<WvFile *>(id);
    if (h == nullptr || h->fp == nullptr || bcount <= 0) {
        return 0;
    }
    return (int32_t) std::fread(data, 1, (size_t) bcount, h->fp);
}

static int32_t WvWriteBytes(void *id, void *data, int32_t bcount) {
    // 只读打开，编辑标签的路径永远不会走到这里
    (void) id;
    (void) data;
    (void) bcount;
    return 0;
}

static int64_t WvGetPos(void *id) {
    WvFile *h = static_cast<WvFile *>(id);
    if (h == nullptr || h->fp == nullptr) {
        return -1;
    }
    const long p = std::ftell(h->fp);
    return p < 0 ? -1 : (int64_t) p;
}

static int WvSetPosAbs(void *id, int64_t pos) {
    WvFile *h = static_cast<WvFile *>(id);
    if (h == nullptr || h->fp == nullptr) {
        return 0;
    }
    return std::fseek(h->fp, (long) pos, SEEK_SET) == 0 ? 1 : 0;
}

static int WvSetPosRel(void *id, int64_t delta, int mode) {
    WvFile *h = static_cast<WvFile *>(id);
    if (h == nullptr || h->fp == nullptr) {
        return 0;
    }
    return std::fseek(h->fp, (long) delta, mode) == 0 ? 1 : 0;
}

static int WvPushBackByte(void *id, int c) {
    WvFile *h = static_cast<WvFile *>(id);
    if (h == nullptr || h->fp == nullptr) {
        return 0;
    }
    return std::ungetc(c, h->fp) != EOF ? 1 : 0;
}

static int64_t WvGetLength(void *id) {
    WvFile *h = static_cast<WvFile *>(id);
    return h == nullptr ? 0 : h->length;
}

static int WvCanSeek(void *id) {
    WvFile *h = static_cast<WvFile *>(id);
    return (h != nullptr && h->fp != nullptr) ? 1 : 0;
}

static int WvTruncateHere(void *id) {
    (void) id;
    return 0;
}

static int WvClose(void *id) {
    // 句柄生命周期由 WavpackSource 管，不让库替我们 fclose
    (void) id;
    return 0;
}

}  // extern "C"

namespace {

class WavpackSource : public AudioSource {
public:
    explicit WavpackSource(std::string path) : path_(std::move(path)) {}

    // 内部持有 wpc → wv_/reader_ 的指针，一旦拷贝就是悬垂引用
    WavpackSource(const WavpackSource &) = delete;
    WavpackSource &operator=(const WavpackSource &) = delete;

    ~WavpackSource() override {
        close();
    }

    AudioInfo open(const std::string &path) override {
        AudioInfo info;
        info.format = "WavPack";

        wv_.fp = std::fopen(path.c_str(), "rb");
        if (wv_.fp == nullptr) {
            info.error = "打不开文件";
            return info;
        }
        wv_.length = LengthOf(wv_.fp);

        // 先自己认 magic。上层按扩展名放行，但改错扩展名的 .wv 在这类收藏里很常见，
        // 认出来就报清楚，而不是甩一句库内部的 "not a WavPack file"。
        uint8_t head[4];
        if (std::fread(head, 1, sizeof(head), wv_.fp) != sizeof(head) ||
            std::memcmp(head, "wvpk", 4) != 0) {
            info.error = "不是 WavPack（缺少 wvpk 标识）";
            return info;
        }
        std::fseek(wv_.fp, 0, SEEK_SET);

        // 校正文件（.wvc）：有就接上，无损文件才能还原到原始位深。
        // 有损 .wv 一般没有 .wvc，打开失败是正常情况，不算错误。
        wvc_.fp = OpenCorrection(path);
        if (wvc_.fp != nullptr) {
            wvc_.length = LengthOf(wvc_.fp);
        }

        // 必须落在成员上：libwavpack 会把 reader 指针存进 wpc，之后每次解 block 都从这个指针调回调。
        // 放栈上的话 open() 一返回它就是悬垂地址，第一次 read 直接崩。
        std::memset(&reader_, 0, sizeof(reader_));
        reader_.read_bytes = WvReadBytes;
        reader_.write_bytes = WvWriteBytes;
        reader_.get_pos = WvGetPos;
        reader_.set_pos_abs = WvSetPosAbs;
        reader_.set_pos_rel = WvSetPosRel;
        reader_.push_back_byte = WvPushBackByte;
        reader_.get_length = WvGetLength;
        reader_.can_seek = WvCanSeek;
        reader_.truncate_here = WvTruncateHere;
        reader_.close = WvClose;

        char err[256];
        std::memset(err, 0, sizeof(err));
        // OPEN_NORMALIZE：老式浮点 WavPack 的数值范围可能超出 ±1，归一化后再交给渲染器；
        // OPEN_TAGS：读 APEv2 标签，后面拿封面/增益就不用再开一次文件。
        if (!OpenContext(err, sizeof(err))) {
            info.error = TranslateError(err);
            return info;
        }

        channels_ = WavpackGetNumChannels(wpc_);
        sampleRate_ = (int) WavpackGetSampleRate(wpc_);
        bits_ = WavpackGetBitsPerSample(wpc_);
        const int mode = WavpackGetMode(wpc_);
        isFloat_ = (mode & MODE_FLOAT) != 0;

        if (channels_ <= 0) {
            info.error = "声道数为 0";
            return info;
        }
        if (sampleRate_ < 1000 || sampleRate_ > 1536000) {
            info.error = "采样率异常";
            return info;
        }
        if (bits_ <= 0 || bits_ > 32) {
            bits_ = 16;
        }

        // 时长：绝大多数文件头部写了总样本数。只有流式编码（未回填最终 block）才拿不到，
        // 这时按无损经验压缩率反推一个上界，够进度条用；seek 会被夹在这个上界内。
        int64_t n = WavpackGetNumSamples64(wpc_);
        if (n < 0) {
            const int bps = isFloat_ ? 4 : ((bits_ + 7) / 8);
            const int64_t raw = wv_.length / 2;   // 无损压缩比经验值约 0.5
            n = raw / (int64_t) (channels_ * (bps > 0 ? bps : 2));
            estimated_ = true;
        }
        if (n <= 0) {
            info.error = "音频数据长度为 0";
            return info;
        }
        totalFrames_ = n;

        if (isFloat_) {
            info.format = "WavPack/float";
        } else if ((mode & MODE_HYBRID) != 0) {
            info.format = wvc_.fp != nullptr ? "WavPack/hybrid+校正" : "WavPack/hybrid(有损)";
        } else if ((mode & MODE_LOSSLESS) != 0) {
            info.format = "WavPack/无损";
        }

        info.ok = true;
        info.sampleRate = sampleRate_;
        info.channels = channels_;
        info.bitsPerSample = bits_;
        info.totalFrames = totalFrames_;
        info.durationMs = (int64_t) ((double) totalFrames_ * 1000.0 / (double) sampleRate_);
        return info;
    }

    int64_t read(float *out, int64_t frames) override {
        if (out == nullptr || frames <= 0 || wpc_ == nullptr) {
            return 0;
        }
        if (frames > kMaxChunkFrames) {
            frames = kMaxChunkFrames;
        }
        const size_t need = (size_t) frames * (size_t) channels_;
        if (ibuf_.size() < need) {
            ibuf_.resize(need);
        }
        const uint32_t got = WavpackUnpackSamples(wpc_, ibuf_.data(), (uint32_t) frames);
        if (got == 0) {
            return 0;   // 到底，或数据损坏（损坏时库返回 0 并在 next 调用继续找下一个 block）
        }
        ToFloat(out, (int64_t) got);
        return (int64_t) got;
    }

    int64_t seek(int64_t frame) override {
        if (wpc_ == nullptr) {
            return -1;
        }
        if (frame < 0) {
            frame = 0;
        }
        if (frame > totalFrames_) {
            frame = totalFrames_;
        }
        if (WavpackSeekSample64(wpc_, frame)) {
            return frame;
        }

        // libwavpack 的约定：seek 返回 FALSE 之后这个上下文就不能再读了 —— 它在失败前
        // 已经 free 掉当前 block，继续 read 会输出错位数据（听感是电平突然掉一半的噪声）。
        // 唯一正确的做法是关掉重建，再顺序解到目标帧。
        if (!OpenContext(nullptr, 0)) {
            return -1;
        }
        if (frame > kMaxResyncFrames) {
            return 0;   // 目标太远，重建后停在开头：位置如实回报，不假装成功
        }
        return SkipFrames(frame);
    }

    void close() override {
        if (wpc_ != nullptr) {
            WavpackCloseFile(wpc_);
            wpc_ = nullptr;
        }
        if (wv_.fp != nullptr) {
            std::fclose(wv_.fp);
            wv_.fp = nullptr;
        }
        if (wvc_.fp != nullptr) {
            std::fclose(wvc_.fp);
            wvc_.fp = nullptr;
        }
        ibuf_.clear();
    }

private:
    /** 建（或重建）解码上下文。重建场景下文件的读写位置一定是从头开始。 */
    bool OpenContext(char *err, size_t errLen) {
        if (wpc_ != nullptr) {
            WavpackCloseFile(wpc_);
            wpc_ = nullptr;
        }
        if (wv_.fp == nullptr) {
            if (err != nullptr && errLen > 0) {
                std::snprintf(err, errLen, "%s", "文件句柄已关闭");
            }
            return false;
        }
        std::fseek(wv_.fp, 0, SEEK_SET);
        if (wvc_.fp != nullptr) {
            std::fseek(wvc_.fp, 0, SEEK_SET);
        }
        if (err != nullptr && errLen > 0) {
            err[0] = '\0';
        }
        // OPEN_NORMALIZE：老式浮点 WavPack 的数值范围可能超出 ±1，归一化后再交给渲染器；
        // OPEN_TAGS：读 APEv2 标签，后面拿封面/增益就不用再开一次文件。
        wpc_ = WavpackOpenFileInputEx64(&reader_, &wv_, wvc_.fp != nullptr ? &wvc_ : nullptr,
                                        err, OPEN_WVC | OPEN_TAGS | OPEN_NORMALIZE, 0);
        return wpc_ != nullptr;
    }

    /** 从当前位置顺序解掉 frame 帧（丢弃）。返回实际追到的帧数。 */
    int64_t SkipFrames(int64_t frame) {
        const size_t need = (size_t) kSkipChunk * (size_t) channels_;
        if (drop_.size() < need) {
            drop_.resize(need);
        }
        int64_t left = frame;
        while (left > 0) {
            const uint32_t want = (uint32_t) (left > (int64_t) kSkipChunk ? (int64_t) kSkipChunk : left);
            const uint32_t got = WavpackUnpackSamples(wpc_, drop_.data(), want);
            if (got == 0) {
                break;
            }
            left -= (int64_t) got;
        }
        return frame - left;
    }

    /** libwavpack 输出交错 int32：整型文件是「按源位深缩放的原值」，浮点文件是 IEEE float 的位模式。 */
    void ToFloat(float *out, int64_t frames) {
        const size_t n = (size_t) frames * (size_t) channels_;
        if (isFloat_) {
            // 同宽同序，直接按位拷贝；别写 (float) ibuf_[i]，那是把位模式当整数转，声音会全废
            std::memcpy(out, ibuf_.data(), n * sizeof(float));
            return;
        }
        const int shift = bits_ >= 32 ? 31 : (bits_ - 1);
        const double scale = 1.0 / (double) ((int64_t) 1 << shift);
        const int32_t *src = ibuf_.data();
        for (size_t i = 0; i < n; i++) {
            out[i] = (float) ((double) src[i] * scale);
        }
    }

    std::string path_;
    WvFile wv_;
    WvFile wvc_;
    WavpackStreamReader64 reader_;
    WavpackContext *wpc_ = nullptr;
    int channels_ = 0;
    int sampleRate_ = 0;
    int bits_ = 16;
    bool isFloat_ = false;
    bool estimated_ = false;
    int64_t totalFrames_ = 0;
    std::vector<int32_t> ibuf_;
    std::vector<int32_t> drop_;
};

}  // namespace

AudioSource *CreateWavpackSource(const std::string &path) {
    return new WavpackSource(path);
}
