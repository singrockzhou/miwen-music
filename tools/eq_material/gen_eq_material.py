#!/usr/bin/env python3
"""EQ 验证素材生成 + PC 基准（v1.8.0）。

素材 eq-tones.wav：三段各 6s 的正弦音（100Hz / 1kHz / 8kHz），rms≈0.25，
44.1k 双声道 float32（与内核输出格式一致，AVPlayer/native 都能直读）。

真机断言口径（rms 日志来自 NativePlayer.trackLevel，2 秒一条）：
- EQ off：三段 rms 均为 0.25（bypass 与直出等价）；
- EQ on 且仅 1k 频段 +6dB：1kHz 段 rms ≈ 0.25×|H|（基准算出 ≈0.50，即 ×2.0），
  100Hz/8kHz 段基本不变（Q=1.1 峰型在 8kHz 处的增益接近 0dB）。

基准数字直接用双二阶频响公式算：|H(e^{jw})| 在信号频率处的模。
"""
import math
import struct
import sys
import os

SR = 44100
SEG = 6.0          # 每段秒数
AMP = 0.25 * math.sqrt(2)   # 峰值（正弦 rms = peak/sqrt(2) = 0.25）
FREQS = [100.0, 1000.0, 8000.0]
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   '..', 'eq-tones.wav') if False else os.path.abspath('eq-tones.wav')


def biquad_peak_response(f_signal: float, f0: float, gain_db: float, q: float, fs: float) -> float:
    """RBJ peaking biquad 在信号频率处的幅度响应 |H|。"""
    if abs(gain_db) < 1e-9:
        return 1.0
    A = 10 ** (gain_db / 40.0)
    w0 = 2 * math.pi * f0 / fs
    alpha = math.sin(w0) / (2 * q)
    cw = math.cos(w0)
    b0 = 1 + alpha * A
    b1 = -2 * cw
    b2 = 1 - alpha * A
    a0 = 1 + alpha / A
    a1 = -2 * cw
    a2 = 1 - alpha / A
    b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0
    w = 2 * math.pi * f_signal / fs
    # H(z) 在 z=e^{jw}
    num_re = b0 + b1 * math.cos(w) + b2 * math.cos(2 * w)
    num_im = -(b1 * math.sin(w) + b2 * math.sin(2 * w))
    den_re = 1 + a1 * math.cos(w) + a2 * math.cos(2 * w)
    den_im = -(a1 * math.sin(w) + a2 * math.sin(2 * w))
    num = abs(complex(num_re, num_im))
    den = abs(complex(den_re, den_im))
    return num / den


def main() -> int:
    frames_per_seg = int(SR * SEG)
    samples = []  # 交错 float32
    for seg, f0 in enumerate(FREQS):
        for n in range(frames_per_seg):
            v = AMP * math.sin(2 * math.pi * f0 * n / SR)
            samples.append(v)
            samples.append(v)  # 双声道相同
    # WAV 头（float32 PCM, format tag 3）
    data_bytes = b''.join(struct.pack('<f', s) for s in samples)
    hdr = b'RIFF' + struct.pack('<I', 36 + len(data_bytes)) + b'WAVE'
    hdr += b'fmt ' + struct.pack('<IHHIIHH', 16, 3, 2, SR, SR * 8, 8, 32)
    hdr += b'data' + struct.pack('<I', len(data_bytes))
    with open(OUT, 'wb') as f:
        f.write(hdr + data_bytes)

    # 基准：EQ off / EQ on(1k +6dB, 其余 0)
    print(f"素材: {OUT} ({os.path.getsize(OUT)} bytes, {len(samples)/2/SR:.1f}s)")
    print("== EQ off 基准 ==")
    for f0 in FREQS:
        print(f"  {f0:>8.0f} Hz 段 rms = {AMP * math.sqrt(2) / math.sqrt(2):.3f} (0.250)")
    print("== EQ on: 1k band +6dB (peaking Q=1.1) 其余 0dB ==")
    for f0 in FREQS:
        h = biquad_peak_response(f0, 1000.0, 6.0, 1.1, SR)
        print(f"  {f0:>8.0f} Hz 段 |H|={h:.3f} ({20*math.log10(h):+.2f} dB) -> rms = {0.25*h:.3f}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
