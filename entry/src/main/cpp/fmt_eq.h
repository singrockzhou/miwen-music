#ifndef MIWEN_FMT_EQ_H
#define MIWEN_FMT_EQ_H

#include "decoder.h"

#include <vector>

/**
 * EQ 均衡链（v1.8.0，Pro 付费功能）。
 *
 * 包住任意 AudioSource，对交错 float32 做 PCM 域均衡滤波——这是全应用唯一的
 * 调音插入点（可行口径见 docs/密纹音乐-EQ参数化均衡器可行性说明.md）：
 * 鸿蒙系统不向第三方开放频段增益接口（API 12 与 26 双口径核实），AVPlayer
 * 通道是黑盒拿不到 PCM；本类建立在自建解码链之上，EQ off 时逐样本旁路
 * （与直出模式等价），EQ on 时在写入 AudioRenderer 前完成调音。
 *
 * 滤波器：RBJ Audio EQ Cookbook 双二阶（biquad），每 band 每声道一级，
 * N band 级联。三种类型：
 *   0 = peaking（峰型：中心频点 f，增益 g，带宽 Q）
 *   1 = lowshelf（低架：g 作用于 f 以下整体）
 *   2 = highshelf（高架：g 作用于 f 以上整体）
 * PreAmp 在全部级联之后统一乘（负增益预扣防削波，正增益靠用户自己控制）。
 *
 * 防 zipper noise：setConfig 换系数时不在当前缓冲上瞬切，而是从旧系数到
 * 新系数做 256 帧线性插值（约 5.8ms @44.1k），期间新旧系数逐样本 lerp。
 * DF1 实现，seek 时滤波状态复位（避免旧状态串进新位置）。
 *
 * 采样率：本类构造时确定（换曲重建链路，系数按新 fs 重算，天然满足）。
 */
class EqSource : public AudioSource {
public:
    /** 接管 inner 的生命周期（close 时一并 delete） */
    EqSource(AudioSource *inner, int channels, int sampleRate);
    ~EqSource() override;

    AudioInfo open(const std::string &path) override;
    int64_t read(float *out, int64_t frames) override;
    int64_t seek(int64_t frame) override;
    void close() override;
    std::string debugStats() const override;

    struct Band {
        int type = 0;        // 0 peaking / 1 lowshelf / 2 highshelf
        double freq = 1000.0;
        double gainDb = 0.0;
        double q = 1.1;
    };
    struct Config {
        bool enabled = false;
        double preampDb = 0.0;
        std::vector<Band> bands;
    };
    /** 归一化后的双二阶系数（a0=1）。public：fmt_eq.cpp 的工具函数与 vector 比较都要用 */
    struct Coeff {
        double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
        bool operator==(const Coeff &o) const {
            return b0 == o.b0 && b1 == o.b1 && b2 == o.b2 && a1 == o.a1 && a2 == o.a2;
        }
        bool operator!=(const Coeff &o) const {
            return !(*this == o);
        }
    };

    /** 换配置（可在播放中随时调用）：重算目标系数并启动系数插值 */
    void setConfig(const Config &cfg);

private:
    /** 按 RBJ 公式算单 band 系数（已按 a0 归一化） */
    static Coeff DesignBand(const Band &b, double fs);

    void resetStates();

    AudioSource *inner_;
    int ch_;
    double fs_;
    AudioInfo info_;

    Config cfg_;
    bool active_;            // enabled 且至少一个 band 有实际增益
    double preampGain_;      // 10^(preampDb/20)
    // 系数插值：from_ -> to_，fadePos_ 计数
    std::vector<Coeff> from_;
    std::vector<Coeff> to_;
    int64_t fadePos_;
    int64_t fadeLen_;
    double preFrom_;
    double preTo_;
    // 每 band 每声道的 DF1 状态
    struct State {
        double x1[8] = {0}, x2[8] = {0}, y1[8] = {0}, y2[8] = {0};
    };
    std::vector<State> st_;  // 每 band 一项
};

#endif // MIWEN_FMT_EQ_H
