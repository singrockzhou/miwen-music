#include "fmt_aiff.h"

#include <cmath>
#include <cstring>
#include <fstream>
#include <vector>

namespace {

uint16_t Be16(const uint8_t *p) {
    return (uint16_t) (((uint16_t) p[0] << 8) | (uint16_t) p[1]);
}

uint32_t Be32(const uint8_t *p) {
    return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | (uint32_t) p[3];
}

uint64_t Be64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        v = (v << 8) | (uint64_t) p[i];
    }
    return v;
}

uint32_t Le32(const uint8_t *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

/**
 * AIFF 的采样率不是整数，是 80 位 IEEE 754 扩展精度（1 符号 + 15 阶码 + 64 位显式尾数）。
 * 常见实现只用到 44100 / 48000 这类整数，但它可能不是精确整数（如 44.056kHz 的旧采样），
 * 所以按标准展开而不是抄"读高 4 字节"的简化写法。
 */
double Extended80(const uint8_t *p) {
    const int sign = (p[0] & 0x80) ? -1 : 1;
    const int exp = ((p[0] & 0x7F) << 8) | p[1];
    const uint64_t mant = Be64(p + 2);
    if (exp == 0 && mant == 0) {
        return 0.0;
    }
    if (exp == 0x7FFF) {
        return 0.0;  // inf / nan：采样率不可能是这个，按 0 处理让上层报错
    }
    return (double) sign * (double) mant * std::pow(2.0, (double) exp - 16383.0 - 63.0);
}

enum class SampleCode {
    S8,      // 有符号 8 位（AIFF 整型一律有符号，这点与 WAV 的 8 位无符号相反）
    S16BE,
    S24BE,
    S32BE,
    S16LE,   // AIFC 'sowt'
    S24LE,
    S32LE,
    F32BE,   // AIFC 'fl32' / 'FL32'
    F64BE,   // AIFC 'fl64' / 'FL64'
    UNSUPPORTED
};

class AiffSource : public AudioSource {
public:
    explicit AiffSource(std::string path) : path_(std::move(path)) {}

    ~AiffSource() override {
        close();
    }

    AudioInfo open(const std::string &path) override {
        AudioInfo info;
        info.format = "AIFF";

        f_.open(path, std::ios::in | std::ios::binary);
        if (!f_.is_open()) {
            info.error = "打不开文件";
            return info;
        }

        uint8_t head[12];
        if (!ReadAt(0, head, sizeof(head))) {
            info.error = "文件头不完整";
            return info;
        }
        if (std::memcmp(head, "FORM", 4) != 0) {
            info.error = "不是 AIFF（缺少 FORM 标识）";
            return info;
        }
        const bool isAifc = std::memcmp(head + 8, "AIFC", 4) == 0;
        if (!isAifc && std::memcmp(head + 8, "AIFF", 4) != 0) {
            info.error = "不是 AIFF（FORM 类型不是 AIFF/AIFC）";
            return info;
        }

        uint64_t fileSize = 0;
        f_.seekg(0, std::ios::end);
        fileSize = (uint64_t) f_.tellg();

        // 逐个 chunk 走：COMM 给格式，SSND 给数据起点。两者顺序不固定，所以先全走一遍。
        uint64_t pos = 12;
        bool hasComm = false;
        bool hasSsnd = false;
        uint32_t ssndDataPos = 0;
        uint32_t ssndOffset = 0;
        uint32_t numFrames = 0;
        uint16_t numChannels = 0;
        uint16_t sampleSize = 0;
        double rate = 0.0;
        char codec[5] = {0, 0, 0, 0, 0};

        while (pos + 8 <= fileSize) {
            uint8_t ch[8];
            if (!ReadAt(pos, ch, sizeof(ch))) {
                break;
            }
            const uint32_t size = Be32(ch + 4);
            const uint64_t body = pos + 8;

            if (std::memcmp(ch, "COMM", 4) == 0 && size >= 18) {
                uint8_t c[18];
                if (!ReadAt(body, c, sizeof(c))) {
                    break;
                }
                numChannels = Be16(c);
                numFrames = Be32(c + 2);
                sampleSize = Be16(c + 6);
                rate = Extended80(c + 8);
                hasComm = true;
                if (isAifc && size >= 22) {
                    uint8_t t[4];
                    if (ReadAt(body + 18, t, sizeof(t))) {
                        std::memcpy(codec, t, 4);
                    }
                }
            } else if (std::memcmp(ch, "SSND", 4) == 0 && size >= 8) {
                uint8_t s[8];
                if (!ReadAt(body, s, sizeof(s))) {
                    break;
                }
                ssndDataPos = (uint32_t) body + 8u;
                ssndOffset = Be32(s);
                hasSsnd = true;
            }

            // chunk 长度是奇数时后面补 1 字节，别漏掉，否则后面全部错位
            pos = body + size + (size & 1u);
        }

        if (!hasComm) {
            info.error = "缺少 COMM 块，无法得知格式";
            return info;
        }
        if (!hasSsnd) {
            info.error = "缺少 SSND 块，文件里没有音频数据";
            return info;
        }
        if (numChannels <= 0) {
            info.error = "声道数为 0";
            return info;
        }
        if (rate < 1000.0 || rate > 1536000.0) {
            info.error = "采样率异常";
            return info;
        }

        // AIFC 的压缩类型决定字节序与整/浮点；AIFF 固定大端整型
        code_ = SampleCode::UNSUPPORTED;
        if (!isAifc) {
            switch (sampleSize) {
                case 8: code_ = SampleCode::S8; break;
                case 16: code_ = SampleCode::S16BE; break;
                case 24: code_ = SampleCode::S24BE; break;
                case 32: code_ = SampleCode::S32BE; break;
                default: break;
            }
            info.format = "AIFF";
        } else if (std::memcmp(codec, "NONE", 4) == 0) {
            switch (sampleSize) {
                case 8: code_ = SampleCode::S8; break;
                case 16: code_ = SampleCode::S16BE; break;
                case 24: code_ = SampleCode::S24BE; break;
                case 32: code_ = SampleCode::S32BE; break;
                default: break;
            }
            info.format = "AIFC/PCM";
        } else if (std::memcmp(codec, "sowt", 4) == 0) {
            switch (sampleSize) {
                case 16: code_ = SampleCode::S16LE; break;
                case 24: code_ = SampleCode::S24LE; break;
                case 32: code_ = SampleCode::S32LE; break;
                default: break;
            }
            info.format = "AIFC/sowt";
        } else if (std::memcmp(codec, "fl32", 4) == 0 || std::memcmp(codec, "FL32", 4) == 0) {
            code_ = SampleCode::F32BE;
            info.format = "AIFC/float32";
        } else if (std::memcmp(codec, "fl64", 4) == 0 || std::memcmp(codec, "FL64", 4) == 0) {
            code_ = SampleCode::F64BE;
            info.format = "AIFC/float64";
        }

        if (code_ == SampleCode::UNSUPPORTED) {
            info.error = isAifc ? std::string("AIFC 压缩类型 ") + codec + " 暂不支持（仅支持 PCM / sowt / fl32 / fl64）"
                                : "AIFF 采样位深不支持（仅支持 8/16/24/32）";
            return info;
        }

        bytesPerSample_ = (code_ == SampleCode::F64BE) ? 8 : (sampleSize / 8);
        if (bytesPerSample_ == 0) {
            bytesPerSample_ = 1;
        }
        blockAlign_ = (uint32_t) numChannels * bytesPerSample_;
        dataStart_ = (uint64_t) ssndDataPos + ssndOffset;
        channels_ = numChannels;
        sampleRate_ = (int) std::lround(rate);
        bits_ = sampleSize;

        // COMM 的帧数是权威值，但文件可能被截断：取两者较小，避免读到文件尾触发无谓错误
        uint64_t dataBytes = (fileSize > dataStart_) ? (fileSize - dataStart_) : 0;
        uint64_t framesByFile = dataBytes / blockAlign_;
        totalFrames_ = framesByFile < numFrames ? framesByFile : numFrames;
        curFrame_ = 0;

        if (totalFrames_ <= 0) {
            info.error = "音频数据长度为 0";
            return info;
        }

        info.ok = true;
        info.sampleRate = sampleRate_;
        info.channels = channels_;
        info.bitsPerSample = bits_;
        info.totalFrames = (int64_t) totalFrames_;
        info.durationMs = (int64_t) (totalFrames_ * 1000ull / (uint64_t) sampleRate_);
        return info;
    }

    int64_t read(float *out, int64_t frames) override {
        if (out == nullptr || frames <= 0) {
            return 0;
        }
        const int64_t remain = (int64_t) totalFrames_ - (int64_t) curFrame_;
        if (remain <= 0) {
            return 0;
        }
        if (frames > remain) {
            frames = remain;
        }
        const size_t need = (size_t) frames * blockAlign_;
        if (tmp_.size() < need) {
            tmp_.resize(need);
        }
        f_.clear();
        f_.seekg((std::streamoff) (dataStart_ + (uint64_t) curFrame_ * blockAlign_), std::ios::beg);
        f_.read(reinterpret_cast<char *>(tmp_.data()), (std::streamsize) need);
        const std::streamsize got = f_.gcount();
        if (got <= 0) {
            return 0;
        }
        const int64_t gotFrames = (int64_t) got / (int64_t) blockAlign_;
        if (gotFrames <= 0) {
            return 0;
        }
        convert(tmp_.data(), out, gotFrames);
        curFrame_ += (uint64_t) gotFrames;
        return gotFrames;
    }

    int64_t seek(int64_t frame) override {
        if (frame < 0) {
            frame = 0;
        }
        if ((uint64_t) frame > totalFrames_) {
            frame = (int64_t) totalFrames_;
        }
        curFrame_ = (uint64_t) frame;
        return frame;
    }

    void close() override {
        if (f_.is_open()) {
            f_.close();
        }
    }

private:
    bool ReadAt(uint64_t off, uint8_t *buf, size_t len) {
        f_.clear();
        f_.seekg((std::streamoff) off, std::ios::beg);
        f_.read(reinterpret_cast<char *>(buf), (std::streamsize) len);
        return (size_t) f_.gcount() == len;
    }

    void convert(const uint8_t *src, float *dst, int64_t frames) {
        const int ch = (int) channels_;
        int64_t n = frames * ch;
        switch (code_) {
            case SampleCode::S8:
                for (int64_t i = 0; i < n; i++) {
                    dst[i] = (float) ((int8_t) src[i]) / 128.0f;
                }
                break;
            case SampleCode::S16BE:
                for (int64_t i = 0; i < n; i++) {
                    const int16_t v = (int16_t) (((uint16_t) src[i * 2] << 8) | (uint16_t) src[i * 2 + 1]);
                    dst[i] = (float) v / 32768.0f;
                }
                break;
            case SampleCode::S24BE:
                for (int64_t i = 0; i < n; i++) {
                    int32_t v = ((int32_t) src[i * 3] << 16) | ((int32_t) src[i * 3 + 1] << 8) | (int32_t) src[i * 3 + 2];
                    if (v & 0x800000) {
                        v |= (int32_t) 0xFF000000;
                    }
                    dst[i] = (float) v / 8388608.0f;
                }
                break;
            case SampleCode::S32BE:
                for (int64_t i = 0; i < n; i++) {
                    const uint32_t u = Be32(src + i * 4);
                    dst[i] = (float) ((double) ((int32_t) u) / 2147483648.0);
                }
                break;
            case SampleCode::S16LE:
                for (int64_t i = 0; i < n; i++) {
                    const int16_t v = (int16_t) ((uint16_t) src[i * 2] | ((uint16_t) src[i * 2 + 1] << 8));
                    dst[i] = (float) v / 32768.0f;
                }
                break;
            case SampleCode::S24LE:
                for (int64_t i = 0; i < n; i++) {
                    int32_t v = (int32_t) src[i * 3] | ((int32_t) src[i * 3 + 1] << 8) | ((int32_t) src[i * 3 + 2] << 16);
                    if (v & 0x800000) {
                        v |= (int32_t) 0xFF000000;
                    }
                    dst[i] = (float) v / 8388608.0f;
                }
                break;
            case SampleCode::S32LE:
                for (int64_t i = 0; i < n; i++) {
                    const uint32_t u = Le32(src + i * 4);
                    dst[i] = (float) ((double) ((int32_t) u) / 2147483648.0);
                }
                break;
            case SampleCode::F32BE:
                for (int64_t i = 0; i < n; i++) {
                    const uint32_t u = Be32(src + i * 4);
                    float f;
                    std::memcpy(&f, &u, 4);
                    dst[i] = f;
                }
                break;
            case SampleCode::F64BE: {
                for (int64_t i = 0; i < n; i++) {
                    const uint64_t u = Be64(src + i * 8);
                    double d;
                    std::memcpy(&d, &u, 8);
                    dst[i] = (float) d;
                }
                break;
            }
            default:
                std::memset(dst, 0, (size_t) n * sizeof(float));
                break;
        }
    }

    std::string path_;
    std::ifstream f_;
    SampleCode code_ = SampleCode::UNSUPPORTED;
    uint32_t channels_ = 0;
    uint32_t sampleRate_ = 0;
    uint32_t bits_ = 0;
    uint32_t bytesPerSample_ = 0;
    uint32_t blockAlign_ = 0;
    uint64_t dataStart_ = 0;
    uint64_t totalFrames_ = 0;
    uint64_t curFrame_ = 0;
    std::vector<uint8_t> tmp_;
};

}  // namespace

AudioSource *CreateAiffSource(const std::string &path) {
    return new AiffSource(path);
}
