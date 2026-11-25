#include "fmt_eq.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

constexpr int64_t kFadeFrames = 256;  // 系数插值窗（约 5.8ms @44.1k）

// 一个系数是否"平直"（全零增益/preamp）：全平直时直接旁路，与直出逐样本等价
bool FlatCoeff(const EqSource::Coeff &c) {
    return std::fabs(c.b0 - 1.0) < 1e-12 && std::fabs(c.b1) < 1e-12
        && std::fabs(c.b2) < 1e-12 && std::fabs(c.a1) < 1e-12
        && std::fabs(c.a2) < 1e-12;
}

double DbToGain(double db) {
    return std::pow(10.0, db / 20.0);
}

}  // namespace

EqSource::EqSource(AudioSource *inner, int channels, int sampleRate)
    : inner_(inner), ch_(channels < 1 ? 1 : (channels > 8 ? 8 : channels)),
      fs_(sampleRate < 8000 ? 44100.0 : (double) sampleRate),
      active_(false), preampGain_(1.0), fadePos_(0), fadeLen_(0), preFrom_(1.0), preTo_(1.0) {
}

EqSource::~EqSource() {
    delete inner_;
}

AudioInfo EqSource::open(const std::string &path) {
    info_ = inner_->open(path);
    return info_;
}

EqSource::Coeff EqSource::DesignBand(const Band &b, double fs) {
    // 全零增益的 band 给平直系数（b0=1 其余 0），级联里等于不存在
    if (std::fabs(b.gainDb) < 1e-6) {
        Coeff c;
        return c;
    }
    const double A = std::pow(10.0, b.gainDb / 40.0);
    const double w0 = 2.0 * M_PI * std::max(10.0, std::min(fs * 0.49, b.freq)) / fs;
    const double cw = std::cos(w0);
    const double sw = std::sin(w0);
    double alpha = sw / (2.0 * std::max(0.05, b.q));
    double b0 = 0, b1 = 0, b2 = 0, a0 = 0, a1 = 0, a2 = 0;
    if (b.type == 0) {
        // peaking
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cw;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cw;
        a2 = 1.0 - alpha / A;
    } else {
        // shelf（S=1 的简化 α， cookbook 的 sqrt((A+1/A)(1/S-1)+2) 在 S=1 时为 sqrt(2)）
        alpha = sw * 0.7071067811865476;
        const double sa = 2.0 * std::sqrt(A) * alpha;
        if (b.type == 1) {
            // lowshelf
            b0 = A * ((A + 1.0) - (A - 1.0) * cw + sa);
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
            b2 = A * ((A + 1.0) - (A - 1.0) * cw - sa);
            a0 = (A + 1.0) + (A - 1.0) * cw + sa;
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
            a2 = (A + 1.0) + (A - 1.0) * cw - sa;
        } else {
            // highshelf
            b0 = A * ((A + 1.0) + (A - 1.0) * cw + sa);
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
            b2 = A * ((A + 1.0) + (A - 1.0) * cw - sa);
            a0 = (A + 1.0) - (A - 1.0) * cw + sa;
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw);
            a2 = (A + 1.0) - (A - 1.0) * cw - sa;
        }
    }
    Coeff c;
    c.b0 = b0 / a0;
    c.b1 = b1 / a0;
    c.b2 = b2 / a0;
    c.a1 = a1 / a0;
    c.a2 = a2 / a0;
    return c;
}

void EqSource::resetStates() {
    st_.assign(std::max((size_t) 1, to_.size()), State{});
    fadePos_ = 0;
    fadeLen_ = 0;
}

void EqSource::setConfig(const Config &cfg) {
    // from_ = 当前生效系数（首次配置时 to_ 为空 → 全平直），to_ = 新配置目标
    from_ = to_;
    if (from_.size() != cfg.bands.size()) {
        from_.assign(cfg.bands.size(), Coeff{});
    }
    to_.assign(cfg.bands.size(), Coeff{});
    bool anyGain = false;
    for (size_t i = 0; i < cfg.bands.size(); i++) {
        const Coeff c = DesignBand(cfg.bands[i], fs_);
        to_[i] = c;
        if (!FlatCoeff(c)) {
            anyGain = true;
        }
    }
    active_ = cfg.enabled && anyGain;
    preFrom_ = preampGain_;          // 当前生效的 preamp 增益
    preTo_ = DbToGain(cfg.preampDb);
    if (st_.size() != to_.size()) {
        st_.assign(to_.size(), State{});
    }
    fadePos_ = 0;
    fadeLen_ = (active_ && (from_ != to_ || (preFrom_ - preTo_) > 1e-9 || (preFrom_ - preTo_) < -1e-9))
        ? kFadeFrames : 0;
    preampGain_ = preTo_;
}

int64_t EqSource::read(float *out, int64_t frames) {
    const int64_t got = inner_->read(out, frames);
    if (got <= 0 || !active_) {
        return got;  // 关闭或全平直：逐样本旁路（与直出等价）
    }
    const size_t total = (size_t) got * (size_t) ch_;
    for (size_t i = 0; i < total; i++) {
        const size_t ci = i % (size_t) ch_;
        const double x = out[i];
        double s = x;
        if (fadeLen_ > 0) {
            // 系数切换窗内：from_→to_ 逐样本线性插值，防 zipper noise
            const double t = (double) fadePos_ / (double) fadeLen_;
            for (size_t b = 0; b < to_.size(); b++) {
                const Coeff &cf = from_[b];
                const Coeff &ct = to_[b];
                State &st = st_[b];
                const double y = (ct.b0 + (cf.b0 - ct.b0) * t) * s
                    + (ct.b1 + (cf.b1 - ct.b1) * t) * st.x1[ci]
                    + (ct.b2 + (cf.b2 - ct.b2) * t) * st.x2[ci]
                    - (ct.a1 + (cf.a1 - ct.a1) * t) * st.y1[ci]
                    - (ct.a2 + (cf.a2 - ct.a2) * t) * st.y2[ci];
                st.x2[ci] = st.x1[ci];
                st.x1[ci] = s;
                st.y2[ci] = st.y1[ci];
                st.y1[ci] = y;
                s = y;
            }
            const double pg = preFrom_ + (preTo_ - preFrom_) * t;
            out[i] = (float) (s * pg);
            fadePos_++;
            if (fadePos_ >= fadeLen_) {
                fadeLen_ = 0;
                from_ = to_;
            }
        } else {
            for (size_t b = 0; b < to_.size(); b++) {
                const Coeff &c = to_[b];
                State &st = st_[b];
                const double y = c.b0 * s + c.b1 * st.x1[ci] + c.b2 * st.x2[ci]
                    - c.a1 * st.y1[ci] - c.a2 * st.y2[ci];
                st.x2[ci] = st.x1[ci];
                st.x1[ci] = s;
                st.y2[ci] = st.y1[ci];
                st.y1[ci] = y;
                s = y;
            }
            out[i] = (float) (s * preampGain_);
        }
    }
    return got;
}

int64_t EqSource::seek(int64_t frame) {
    // 定位后旧滤波状态作废：复位防历史样本串进新位置
    for (auto &st : st_) {
        for (int c = 0; c < 8; c++) {
            st.x1[c] = st.x2[c] = st.y1[c] = st.y2[c] = 0.0;
        }
    }
    fadePos_ = 0;
    fadeLen_ = 0;
    from_ = to_;
    return inner_->seek(frame);
}

void EqSource::close() {
    inner_->close();
    delete inner_;
    inner_ = nullptr;
}

std::string EqSource::debugStats() const {
    return std::string();
}
