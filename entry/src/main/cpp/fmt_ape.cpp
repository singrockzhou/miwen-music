#include "fmt_ape.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

// All.h 必须在 MACLib.h 之前：uint16/uint32/str_utfn 这些类型别名都在里面，
// 官方 SDK 的示例（Decompress - Sample 1.cpp）就是这个顺序，MACLib.h 不自带
#include "All.h"
#include "MACLib.h"
#include "CharacterHelper.h"

// MACLib 全部类型/常量收在 namespace APE 里（官方示例同款用法）
using namespace APE;

// ============================================================================
// Monkey's Audio (APE) 解码，官方 MACLib 13.50 SDK（3-Clause BSD，ape/License.txt）。
//
// 关键事实（都以 SDK 源码核对过）：
// - CreateIAPEDecompress 接受 wchar_t（str_utfn）路径，本机路径是 UTF-8 的 char，
//   用 CAPECharacterHelper::GetUTFNFromUTF8 转换（内部 new[]，调用方 delete[]）。
// - GetData(pBuffer, nBlocks, &retrieved)：nBlocks 按"块"计，一块 = 一帧×所有声道，
//   输出 buffer 大小 = nBlocks * APE_INFO_BLOCK_ALIGN；输出布局与 WAV 相同——
//   小端交错整型（arm64 小端主机直接按 int16 / 3 字节 / int32 摊开）。
// - Seek(nBlockOffset) 是真·快速定位：按 APE_INFO_BLOCKS_PER_FRAME 算出目标帧，
//   直接从那一帧开始解码（APEDecompress.cpp L228 起），不像 ALAC 要顺序跳。
// - MACLib 输出 float 无关；错误时不终止而是按官方逻辑塞静音继续，
//   所以这里按 retrieved==0 判 eof，错误码只累计到诊断通道。
// - 位深只接 8/16/24/32：这是文件头里真实存在的取值集合；其他位深直接给出明确话术
//   （20bit 在 APE 文件里实际以 3 字节存储的假设未经验证，不写进代码）。
// ============================================================================

namespace {

class ApeSource : public AudioSource {
public:
    ~ApeSource() override { CloseInternal(); }

    AudioInfo open(const std::string &path) override {
        AudioInfo info;

        // 先自己 fopen 探一下：MACLib 的报错码不带"权限/不存在"的区分，
        // 而这个区分在真机上是最常见的失败原因（fileShare 授权被洗掉）。
        FILE *probe = std::fopen(path.c_str(), "rb");
        if (probe == nullptr) {
            info.error = "APE: 打不开文件（fopen 失败，可能是目录授权未生效）";
            return info;
        }
        std::fclose(probe);

        // UTF-8 char 路径 → str_utfn(wchar_t)，官方转换函数，内部 new[] 我们负责删
        str_utfn *wpath = CAPECharacterHelper::GetUTFNFromUTF8(
            reinterpret_cast<const str_utf8 *>(path.c_str()));
        if (wpath == nullptr) {
            info.error = "APE: 路径转换失败";
            return info;
        }
        int err = 0;
        dec_ = CreateIAPEDecompress(wpath, &err, true, false, false);
        delete[] wpath;
        if (dec_ == nullptr || err != 0) {
            info.error = "APE: 解码器初始化失败（错误码 " + std::to_string(err) +
                         "，文件损坏或不是 APE？）";
            return info;
        }

        sampleRate_ = static_cast<int>(dec_->GetInfo(IAPEDecompress::APE_INFO_SAMPLE_RATE));
        channels_ = static_cast<int>(dec_->GetInfo(IAPEDecompress::APE_INFO_CHANNELS));
        bits_ = static_cast<int>(dec_->GetInfo(IAPEDecompress::APE_INFO_BITS_PER_SAMPLE));
        blockAlign_ = static_cast<int>(dec_->GetInfo(IAPEDecompress::APE_INFO_BLOCK_ALIGN));
        totalFrames_ = dec_->GetInfo(IAPEDecompress::APE_INFO_TOTAL_BLOCKS);

        if (sampleRate_ <= 0 || channels_ <= 0) {
            info.error = "APE: 音频参数异常 sr=" + std::to_string(sampleRate_) +
                         " ch=" + std::to_string(channels_);
            return info;
        }
        if (channels_ > 2) {
            // 与 AIFF/ALAC 同一口径：AudioRenderer 侧只验证过单/立体声
            info.error = "多声道（" + std::to_string(channels_) +
                         "ch）暂不支持，先转成 FLAC";
            return info;
        }
        if (bits_ != 8 && bits_ != 16 && bits_ != 24 && bits_ != 32) {
            info.error = "APE 位深 " + std::to_string(bits_) +
                         "bit 暂不支持（支持 8/16/24/32）";
            return info;
        }
        // blockAlign 应等于 ch * bytesPerSample，对不上说明文件头有问题
        const int expectAlign = channels_ * ((bits_ + 7) / 8);
        if (blockAlign_ != expectAlign) {
            info.error = "APE: 块对齐异常 align=" + std::to_string(blockAlign_) +
                         "（应为 " + std::to_string(expectAlign) + "）";
            return info;
        }

        raw_.resize(8192 * static_cast<size_t>(blockAlign_));

        info.ok = true;
        info.sampleRate = sampleRate_;
        info.channels = channels_;
        info.bitsPerSample = bits_;
        info.totalFrames = totalFrames_;
        info.durationMs = totalFrames_ * 1000 / sampleRate_;
        // 版本号口径见 MACLib.h L277：APE_INFO_FILE_VERSION = 实际版本 × 1000（3930 = 3.93）
        const int ver = static_cast<int>(dec_->GetInfo(IAPEDecompress::APE_INFO_FILE_VERSION));
        info.format = "APE v" + std::to_string(ver / 1000) + "." +
                      std::to_string((ver % 1000) / 10);
        return info;
    }

    int64_t read(float *out, int64_t frames) override {
        if (dec_ == nullptr) {
            return -1;
        }
        int64_t got = 0;
        while (got < frames) {
            const int64_t want = std::min<int64_t>(
                frames - got, static_cast<int64_t>(raw_.size() / blockAlign_));
            if (want <= 0) {
                break;
            }
            int64_t retrieved = 0;
            const int st = dec_->GetData(raw_.data(), want, &retrieved);
            if (st != 0) {
                errCount_++;  // 官方逻辑：错误时塞静音继续，不因此中断
            }
            if (retrieved <= 0) {
                eof_ = true;
                break;
            }
            Convert(raw_.data(), static_cast<int64_t>(retrieved) * channels_);
            // pending_ 以 float 存（帧×声道），与 ALAC 同一单位约定，立体声下
            // 不再把 size() 当帧数用（fmt_alac 第一版的教训）
            const int ch = channels_;
            const int64_t availFrames =
                static_cast<int64_t>(pending_.size()) / (ch > 0 ? ch : 1);
            const int64_t take = std::min(frames - got, availFrames);
            std::memcpy(out + got * ch, pending_.data(),
                        static_cast<size_t>(take) * ch * sizeof(float));
            pending_.erase(pending_.begin(),
                           pending_.begin() + static_cast<size_t>(take) * ch);
            got += take;
            outTotal_ += retrieved;
        }
        return got;
    }

    int64_t seek(int64_t frame) override {
        if (dec_ == nullptr) {
            return -1;
        }
        if (frame < 0) {
            frame = 0;
        }
        if (frame > totalFrames_) {
            frame = totalFrames_;
        }
        // 官方快速 seek：按帧索引直接跳，无顺序解码开销
        const int st = dec_->Seek(frame);
        if (st != 0) {
            errCount_++;
            return -1;
        }
        pending_.clear();
        eof_ = false;
        return frame;
    }

    void close() override { CloseInternal(); }

    std::string debugStats() const override {
        char buf[120];
        std::snprintf(buf, sizeof(buf),
                      "out=%lld err=%d eof=%d",
                      static_cast<long long>(outTotal_),
                      errCount_, eof_ ? 1 : 0);
        return std::string(buf);
    }

private:
    void CloseInternal() {
        delete dec_;
        dec_ = nullptr;
        pending_.clear();
    }

    /** 小端交错整型 → float（与 WAV/ALAC 同一布局口径） */
    void Convert(const uint8_t *src, int64_t nSamples) {
        const size_t old = pending_.size();
        pending_.resize(old + static_cast<size_t>(nSamples));
        float *out = pending_.data() + old;
        switch (bits_) {
            case 8: {
                // APE/WAV 的 8bit 是无符号（中点 128）
                for (int64_t i = 0; i < nSamples; i++) {
                    out[i] = (static_cast<float>(src[i]) - 128.0f) / 128.0f;
                }
                break;
            }
            case 16: {
                const int16_t *s = reinterpret_cast<const int16_t *>(src);
                for (int64_t i = 0; i < nSamples; i++) {
                    out[i] = static_cast<float>(s[i]) / 32768.0f;
                }
                break;
            }
            case 24: {
                for (int64_t i = 0; i < nSamples; i++) {
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
                for (int64_t i = 0; i < nSamples; i++) {
                    out[i] = static_cast<float>(s[i]) / 2147483648.0f;
                }
                break;
            }
            default: {
                for (int64_t i = 0; i < nSamples; i++) {
                    out[i] = 0.0f;
                }
                break;
            }
        }
    }

    IAPEDecompress *dec_ = nullptr;
    int sampleRate_ = 0;
    int channels_ = 0;
    int bits_ = 0;
    int blockAlign_ = 0;
    int64_t totalFrames_ = 0;
    std::vector<uint8_t> raw_;    // GetData 直出的交错整型
    std::vector<float> pending_;  // 已转 float 未取走
    int64_t outTotal_ = 0;        // 诊断：累计产出帧数
    int32_t errCount_ = 0;        // 诊断：GetData/Seek 错误次数
    bool eof_ = false;
};

}  // namespace

AudioSource *CreateApeSource(const std::string &path, std::string *why) {
    ApeSource *src = new ApeSource();
    AudioInfo info = src->open(path);
    if (info.ok) {
        return src;
    }
    delete src;
    if (why != nullptr) {
        *why = info.error.empty() ? "APE: 打不开（原因未知）" : info.error;
    }
    return nullptr;
}
