#include "fmt_rate.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

// WSOLA 参数（见 fmt_rate.h 头注释）
constexpr int64_t kWindow = 2048;   // L：窗长（帧）
constexpr int64_t kHalf = 1024;     // H：半窗 = 交叉淡化长度 = 匹配长度
constexpr int64_t kTauMax = 256;    // 搜索半径（帧）
constexpr int64_t kSearchStep = 2;  // 相似度搜索步长
constexpr int64_t kPullFrames = 8192;  // 从内层解码器拉输入的块大小

}  // namespace

RateSource::RateSource(AudioSource *inner, int channels, int sampleRate)
    : inner_(inner), ch_(channels < 1 ? 1 : channels), sampleRate_(sampleRate),
      rate_(1.0), inFrames_(0), inPos_(0), eofIn_(false), hopErr_(0.0),
      outFrames_(0), outPos_(0), flushed_(false), tailValid_(false) {
    tail_.assign((size_t) kHalf * ch_, 0.0f);
}

RateSource::~RateSource() {
    delete inner_;
}

AudioInfo RateSource::open(const std::string &path) {
    info_ = inner_->open(path);
    return info_;
}

void RateSource::setRate(double rate) {
    if (rate < 0.25) {
        rate = 0.25;
    }
    if (rate > 4.0) {
        rate = 4.0;
    }
    if ((rate - rate_) < 1e-6 && (rate_ - rate) < 1e-6) {
        return;
    }
    rate_ = rate;
    // 中途变速：缓冲里的拉伸状态照旧，尾巴保持连续；不复位避免咔哒声
}

bool RateSource::ensureInput(int64_t nFrames) {
    while (!eofIn_ && inFrames_ < nFrames) {
        std::vector<float> tmp((size_t) kPullFrames * ch_);
        const int64_t got = inner_->read(tmp.data(), kPullFrames);
        if (got <= 0) {
            eofIn_ = true;
            break;
        }
        inBuf_.insert(inBuf_.end(), tmp.begin(), tmp.begin() + got * ch_);
        inFrames_ += got;
    }
    return inFrames_ >= nFrames;
}

void RateSource::compact() {
    if (inPos_ > 1 << 17) {  // 128k 帧（44.1k 下约 3 秒）才整理一次
        inBuf_.erase(inBuf_.begin(), inBuf_.begin() + inPos_ * ch_);
        inFrames_ -= inPos_;
        inPos_ = 0;
    }
    if (outPos_ > 1 << 17) {
        outBuf_.erase(outBuf_.begin(), outBuf_.begin() + outPos_ * ch_);
        outFrames_ -= outPos_;
        outPos_ = 0;
    }
}

void RateSource::produceOne() {
    // 步进：输出每窗 H 帧，输入每窗 H*rate 帧（带小数累加）
    const double hs = (double) kHalf * rate_ + hopErr_;
    int64_t inputHop = (int64_t) hs;
    if (inputHop < 1) {
        inputHop = 1;
    }
    hopErr_ = hs - (double) inputHop;

    const int64_t base = inPos_ + inputHop;

    // 搜索区间裁剪：起点不能越过输入缓冲，窗尾必须完整
    int64_t lo = -kTauMax;
    int64_t hi = kTauMax;
    if (base + lo < inPos_ + 1) {
        lo = inPos_ + 1 - base;  // 不重放"理想接续点"之前已消费太远的音频
    }
    if (ensureInput(base + hi + kWindow)) {
        // 输入充足，搜索区间原样
    } else if (eofIn_) {
        // 输入耗尽：放宽到剩余长度；连一个完整窗都拼不出就冲洗
        const int64_t remain = inFrames_ - base;
        if (remain < kWindow) {
            // 冲洗：剩余输入按原速附加（不再拉伸），尾部可能有 <46ms 的拼接痕迹，可接受
            if (remain > 0) {
                outBuf_.insert(outBuf_.end(),
                               inBuf_.begin() + inPos_ * ch_, inBuf_.begin() + inFrames_ * ch_);
                outFrames_ += remain;
                inPos_ = inFrames_;
            }
            flushed_ = true;
            return;
        }
        hi = remain - kWindow;
        if (hi > kTauMax) {
            hi = kTauMax;
        }
        if (hi < lo) {
            // 剩余不够搜索但仍够一窗：不搜，直接拼
            hi = lo = 0;
        }
    }

    // 相似度搜索：找与上一窗尾巴最像的接续点
    int64_t bestTau = (lo + hi) / 2;
    if (tailValid_) {
        double bestScore = -1e300;
        for (int64_t tau = lo; tau <= hi; tau += kSearchStep) {
            const float *cand = &inBuf_[(base + tau) * ch_];
            double score = 0.0;
            for (int64_t k = 0; k < kHalf; k++) {
                const int64_t idx = (size_t) (k * ch_);
                for (int c = 0; c < ch_; c++) {
                    score += (double) cand[idx + c] * tail_[idx + c];
                }
            }
            if (score > bestScore) {
                bestScore = score;
                bestTau = tau;
            }
        }
    }

    const int64_t s = base + bestTau;
    const float *seg = &inBuf_[s * ch_];

    // 组窗输出：前 H 帧与尾巴交叉淡化，后 H 帧直接取本窗
    const size_t winSamples = (size_t) kWindow * ch_;
    const size_t startIdx = outBuf_.size();
    outBuf_.resize(startIdx + winSamples);
    float *out = &outBuf_[startIdx];
    if (tailValid_) {
        for (int64_t k = 0; k < kHalf; k++) {
            const double w = (double) k / (double) kHalf;
            const int64_t idx = k * ch_;
            for (int c = 0; c < ch_; c++) {
                out[idx + c] = (float) (tail_[idx + c] * (1.0 - w) + seg[idx + c] * w);
            }
        }
        std::memcpy(out + (size_t) kHalf * ch_, seg + (size_t) kHalf * ch_,
                    (size_t) kHalf * ch_ * sizeof(float));
        std::memcpy(tail_.data(), seg + (size_t) (kWindow - kHalf) * ch_,
                    (size_t) kHalf * ch_ * sizeof(float));
    } else {
        std::memcpy(out, seg, winSamples * sizeof(float));
        std::memcpy(tail_.data(), seg + (size_t) (kWindow - kHalf) * ch_,
                    (size_t) kHalf * ch_ * sizeof(float));
        tailValid_ = true;
    }
    outFrames_ += kWindow;
    inPos_ += inputHop;
    compact();
}

int64_t RateSource::read(float *out, int64_t frames) {
    if (frames <= 0) {
        return 0;
    }
    // 1.0 直通：绕过全部 WSOLA 状态，零开销
    if ((rate_ - 1.0) < 1e-6 && (1.0 - rate_) < 1e-6) {
        return inner_->read(out, frames);
    }

    // 产到够为止；输入耗尽且冲洗完就返回手头剩下的（<frames 表示 EOF）
    while (outFrames_ - outPos_ < frames && !flushed_) {
        produceOne();
    }
    const int64_t pending = outFrames_ - outPos_;
    if (pending <= 0) {
        return 0;
    }
    const int64_t give = std::min(frames, pending);
    std::memcpy(out, &outBuf_[outPos_ * ch_], (size_t) give * ch_ * sizeof(float));
    outPos_ += give;
    compact();
    return give;
}

int64_t RateSource::seek(int64_t frame) {
    const int64_t landed = inner_->seek(frame);
    if (landed < 0) {
        return landed;
    }
    // 全量复位：变速是流式状态，seek 之后从头积累
    inBuf_.clear();
    inFrames_ = 0;
    inPos_ = 0;
    eofIn_ = false;
    hopErr_ = 0.0;
    outBuf_.clear();
    outFrames_ = 0;
    outPos_ = 0;
    flushed_ = false;
    tailValid_ = false;
    std::fill(tail_.begin(), tail_.end(), 0.0f);
    return landed;
}

void RateSource::close() {
    inner_->close();
    inBuf_.clear();
    inFrames_ = 0;
    inPos_ = 0;
    outBuf_.clear();
    outFrames_ = 0;
    outPos_ = 0;
    flushed_ = false;
    tailValid_ = false;
}

std::string RateSource::debugStats() const {
    const std::string inner = inner_->debugStats();
    if ((rate_ - 1.0) < 1e-6 && (1.0 - rate_) < 1e-6) {
        return inner;
    }
    char buf[96];
    std::snprintf(buf, sizeof(buf), " rate=%.2f in=%lld out=%lld",
                  rate_, (long long) (inFrames_ - inPos_), (long long) (outFrames_ - outPos_));
    return inner + buf;
}
