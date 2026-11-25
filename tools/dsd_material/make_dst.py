# -*- coding: utf-8 -*-
"""生成 DST 压缩的 DFF 测试素材：dsd-dst-1.dff（450 帧全算术编码）与 dsd-dst-fir.dff（FIR 预测帧）。

DST 算术编码器（区间法）推导依据（refs/dst_ac.c 解码器 + fmt_dst.cpp 逐行镜像）：
- 解码器寄存器 c ∈ [0, A) 表示"码流窗口值 - 累积下界"；决策 e=1 ⟺ c < h（h=A-ap）。
- 编码器维护 [L, L+A)（当前尺度 s=12+已产出 renorm 位数的整数区间）：
    e=1 → A←h；e=0 → L+=h, A←ap；renorm n=11-log2floor(A)：A<<=n, L<<=n。
  归纳可证：最终码 N ∈ [L, L+A) 时解码器逐步决策与编码选择一致（每步区间嵌套，
  N 的前缀落在每一步的区间内）。取 N=L+A-1，输出其前 S=12+Σn 位（MSB-first）。
- 帧头（本素材固定形态，39 位）：1(DST),1,1,1(分段),1(same_map),0(map逐声道),0(half_prob),
  fsets: 7位长度-1, 0(直接系数), 9位带符号系数0; probs: 6位长度-1, 0(直接), 7位值(=系数-1);
  0(算术标志)。之后是 12 位 c_init + renorm 位。
- 无预测帧：fsets 系数全 0 → predict=0 → v=residual&1，即每个算术决策 e=数据位，p=128。
- FIR 帧（fsets coeff=8, probs=[128,96]）：predict=±8（1 抽头，取决于上一输出位），
  prob=probs[|predict|>>3]，residual=数据位^((predict>>15)&1)——完整走预测/状态路径。
"""
import math
import struct

SR_DSD = 2822400
BITS_PER_FRAME = 37632          # 每帧每声道 DSD 位（= 4704 字节）
BYTES_PER_FRAME = 4704
FPS = 75
TOTAL_SEC = 6
SEGS = [(0.25, 440.0), (0.5, 1000.0), (0.75, 2000.0)]  # 每段 2s


def gen_dsd_bits(total_sec=TOTAL_SEC, segs=SEGS):
    """一阶 sigma-delta，返回 MSB-first 打包的字节流（每声道）。"""
    n_bits = SR_DSD * total_sec
    buf = bytearray(n_bits // 8)
    accum = 0.0
    byte = 0
    n_in_byte = 0
    out_idx = 0
    seg_len = SR_DSD * total_sec // len(segs)
    for i in range(n_bits):
        seg = min(i // seg_len, len(segs) - 1)
        amp, freq = segs[seg]
        t = i / SR_DSD
        x = amp * math.sin(2 * math.pi * freq * t)
        y = 1.0 if accum > 0 else -1.0
        accum += x - y
        bit = 1 if y > 0 else 0
        byte |= bit << (7 - n_in_byte)  # MSB first（DFF 帧排布）
        n_in_byte += 1
        if n_in_byte == 8:
            buf[out_idx] = byte
            out_idx += 1
            byte = 0
            n_in_byte = 0
    return bytes(buf)


def bits_to_list(data):
    """字节流 → 位列表（MSB first）。"""
    out = []
    for b in data:
        for j in range(7, -1, -1):
            out.append((b >> j) & 1)
    return out


def log2floor(v):
    r = -1
    while v:
        v >>= 1
        r += 1
    return r


_REV7 = [int(f'{i:07b}'[::-1], 2) for i in range(128)]


def prob_dst_x_bit(c):
    return (_REV7[c & 127] >> 1) + 1


class BitWriter:
    def __init__(self):
        self.bits = []

    def w1(self, v):
        self.bits.append(v & 1)

    def w(self, v, n):
        for j in range(n - 1, -1, -1):
            self.bits.append((v >> j) & 1)

    def wb(self, bit_list):
        self.bits.extend(bit_list)

    def tobytes(self):
        out = bytearray((len(self.bits) + 7) // 8)
        for i, v in enumerate(self.bits):
            if v:
                out[i >> 3] |= 1 << (7 - (i & 7))
        return bytes(out)


class MsbBits:
    """镜像 fmt_dst.cpp 的 MsbBits。"""

    def __init__(self, data):
        self.d = data
        self.n_bits = len(data) * 8
        self.pos = 0

    def get1(self):
        if self.pos >= self.n_bits:
            return 0
        b = (self.d[self.pos >> 3] >> (7 - (self.pos & 7))) & 1
        self.pos += 1
        return b

    def get(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | self.get1()
        return v


class Arith:
    """镜像 fmt_dst.cpp 的 Arith（AcInit/AcGet）。"""

    def __init__(self, gb):
        self.a = 4095
        self.c = gb.get(12)
        self.gb = gb

    def get(self, p):
        k = (self.a >> 8) | ((self.a >> 7) & 1)
        q = k * p
        aq = self.a - q
        e = 1 if self.c < aq else 0
        if e:
            self.a = aq
        else:
            self.a = q
            self.c -= aq
        if self.a < 2048:
            n = 11 - log2floor(self.a)
            self.a <<= n
            self.c = (self.c << n) | self.gb.get(n)
        return e


# ---------------- DST 编码器 ----------------

class DstFrameEncoder:
    """单帧 DST 编码（本素材限定：单声道、单元素、same_map、无 half_prob）。

    filter_coeff: fsets 直接系数列表（长度即 fsets.length，≤128）。
    probs_coeff:  probs 直接系数列表（每项 1..128）。
    """

    def __init__(self, filter_coeff, probs_coeff):
        assert 1 <= len(filter_coeff) <= 128
        assert 1 <= len(probs_coeff) <= 64
        for c in filter_coeff:
            assert -256 <= c <= 255  # 9 位带符号范围
        for c in probs_coeff:
            assert 1 <= c <= 128
        self.fcoeff = filter_coeff
        self.pcoeff = probs_coeff
        # 构建 16 组 × 256 项预测表（镜像 BuildFilter）
        self.filter = []
        for j in range(16):
            total = max(0, min(len(filter_coeff) - j * 8, 8))
            tab = []
            for k in range(256):
                v = 0
                for l in range(total):
                    v += (((k >> l) & 1) * 2 - 1) * filter_coeff[j * 8 + l]
                assert -32768 <= v <= 32767
                tab.append(v)
            self.filter.append(tab)

    def _header_bits(self, bw):
        bw.w1(1)              # DST 编码帧
        bw.w1(1)              # same_segmentation
        bw.w1(1)              # same_seg_all_channels
        bw.w1(1)              # end_of_channel_segmentation
        bw.w1(1)              # same_map
        bw.w1(0)              # read_map：逐声道分支（单声道后面无位）
        bw.w1(0)              # half_prob[0] = 0
        # fsets：elements=1
        bw.w(len(self.fcoeff) - 1, 7)
        bw.w1(0)              # 直接系数
        for c in self.fcoeff:
            bw.w(c & 0x1FF, 9)  # 9 位补码
        # probs：elements=1
        bw.w(len(self.pcoeff) - 1, 6)
        bw.w1(0)              # 直接系数
        for c in self.pcoeff:
            bw.w(c - 1, 7)
        bw.w1(0)              # 算术数据标志

    def encode(self, frame_bits):
        """frame_bits: 每声道 37632 位的列表（单声道）。返回帧字节。"""
        assert len(frame_bits) == BITS_PER_FRAME
        bw = BitWriter()
        self._header_bits(bw)

        # 算术编码：区间法
        A = 4095
        L = 0
        renorm_total = 0

        def enc_decision(p, e):
            nonlocal A, L, renorm_total
            k = (A >> 8) | ((A >> 7) & 1)
            ap = k * p
            h = A - ap
            assert h > 0 and ap > 0
            if e:
                A = h
            else:
                L += h
                A = ap
            if A < 2048:
                n = 11 - log2floor(A)
                A <<= n
                L <<= n
                renorm_total += n

        # 决策 0：dst_x_bit（解码端丢弃其值，但消耗区间——取 e=1）
        enc_decision(prob_dst_x_bit(self.fcoeff[0]), 1)

        # 主决策序列（单声道：按样本顺序）
        if all(c == 0 for c in self.fcoeff):
            # 无预测：predict=0 → residual = 数据位，prob = probs[0]
            p0 = self.pcoeff[0]
            for v in frame_bits:
                enc_decision(p0, v)
        else:
            # FIR：predict 由状态寄存器查表（镜像解码器语义）
            reg = 0xAA * 1  # 初始 status 全 0xAA（128 位）
            reg = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            mask = (1 << 128) - 1
            plen = len(self.pcoeff)
            for v in frame_bits:
                predict = 0
                for j in range(16):
                    predict += self.filter[j][(reg >> (8 * j)) & 0xFF]
                idx = (abs(predict) >> 3)
                if idx >= plen:
                    idx = plen - 1
                p = self.pcoeff[idx]
                residual = v ^ ((predict >> 15) & 1)
                enc_decision(p, residual)
                reg = ((reg << 1) | v) & mask

        # 最终码：N ∈ [L, L+A)，取 L+A-1；输出 S = 12 + renorm_total 位
        S = 12 + renorm_total
        N = L + A - 1
        assert 0 <= N < (1 << S), (N, S)
        bw.w(N, S)
        return bw.tobytes()


# ---------------- 镜像解码器（忠实 fmt_dst.cpp，验证用） ----------------

def decode_frame(data, channels=1, filter_coeff=None, probs_coeff=None):
    """镜像 DstDecoder::Decode，返回每声道位列表。"""
    gb = MsbBits(data)
    assert gb.get1() == 1, "应为 DST 编码帧"
    assert gb.get1() == 1
    assert gb.get1() == 1
    assert gb.get1() == 1
    same_map = gb.get1()
    assert same_map == 1
    # read_map
    assert gb.get1() == 0
    # half_prob
    for _ in range(channels):
        assert gb.get1() == 0
    # fsets
    flen = gb.get(7) + 1
    assert gb.get1() == 0
    fcoeff = []
    for _ in range(flen):
        v = gb.get(9)
        if v >= 256:
            v -= 512
        fcoeff.append(v)
    # probs
    plen = gb.get(6) + 1
    assert gb.get1() == 0
    pcoeff = []
    for _ in range(plen):
        pcoeff.append(gb.get(7) + 1)
    assert gb.get1() == 0
    if filter_coeff is not None:
        assert fcoeff == filter_coeff, (fcoeff, filter_coeff)
    if probs_coeff is not None:
        assert pcoeff == probs_coeff, (pcoeff, probs_coeff)

    ac = Arith(gb)
    # BuildFilter（镜像）
    filt = []
    for j in range(16):
        total = max(0, min(flen - j * 8, 8))
        filt.append([sum((((k >> l) & 1) * 2 - 1) * fcoeff[j * 8 + l]
                         for l in range(total)) for k in range(256)])
    all_zero = all(v == 0 for row in filt for v in row)

    nbits = BITS_PER_FRAME
    nbbytes = nbits // 8
    out = [0] * (nbbytes * channels)
    # status：128 位移位寄存器（低 8 字节 = reg 低 64 位，LE 语义）
    regs = [0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA] * channels
    ac.get(prob_dst_x_bit(fcoeff[0]))  # dst_x_bit，值丢弃

    zero_mask = None
    for i in range(nbits):
        for ch in range(channels):
            st = regs[ch]
            if all_zero:
                predict = 0
            else:
                predict = 0
                for j in range(16):
                    predict += filt[j][(st >> (8 * j)) & 0xFF]
            idx = (abs(predict) >> 3)
            if idx >= plen:
                idx = plen - 1
            residual = ac.get(pcoeff[idx])
            v = ((predict >> 15) ^ residual) & 1
            regs[ch] = ((st << 1) | v) & ((1 << 128) - 1)
            out[(i >> 3) * channels + ch] |= v << (7 - (i & 7))
    # 还原每声道位列表
    chans = []
    for ch in range(channels):
        bits = []
        for i in range(nbits):
            bits.append((out[(i >> 3) * channels + ch] >> (7 - (i & 7))) & 1)
        chans.append(bits)
    return chans


# ---------------- DFF-DST 容器 ----------------

def _chunk(cid, payload):
    return cid + struct.pack('>Q', len(payload)) + payload + (b'\x00' if len(payload) % 2 else b'')


def write_dff_dst(path, frame_bytes_list, ch=1):
    prop_snd = _chunk(b'FS  ', struct.pack('>I', SR_DSD))
    prop_snd += _chunk(b'CHNL', struct.pack('>H', ch) + (b'MONO' if ch == 1 else b'FL  FR  '))
    prop_snd += _chunk(b'CMPR', b'DST ' + struct.pack('>H', 0))
    prop = b'SND ' + prop_snd

    body = _chunk(b'FVER', struct.pack('>I', 0x01050000))
    body += _chunk(b'PROP', prop)
    dst_payload = _chunk(b'FRTE', struct.pack('>IH', len(frame_bytes_list), FPS))
    for fb in frame_bytes_list:
        dst_payload += _chunk(b'DSTF', fb)
    body += _chunk(b'DST ', dst_payload)
    with open(path, 'wb') as f:
        f.write(b'FRM8' + struct.pack('>Q', len(body)) + b'DSD ' + body)
    total = sum(len(x) for x in frame_bytes_list)
    print(path, 'ok frames=%d bytes=%d (%.1f%% of raw)' % (
        len(frame_bytes_list), total, 100.0 * total / (len(frame_bytes_list) * BYTES_PER_FRAME * ch)))


# ---------------- 主流程 ----------------

def main():
    bits = bits_to_list(gen_dsd_bits())

    # 1) 全算术编码、无预测：450 帧
    enc = DstFrameEncoder([0], [128])
    frames = []
    for fi in range(TOTAL_SEC * FPS):
        fb = bits[fi * BITS_PER_FRAME:(fi + 1) * BITS_PER_FRAME]
        frames.append(enc.encode(fb))
    # roundtrip 验证（抽 3 帧 + 首尾帧全验，其余帧快速验证）
    check_idx = sorted(set([0, 1, 224, 448, 449] + [i for i in range(0, 450, 50)]))
    for fi in check_idx:
        fb = bits[fi * BITS_PER_FRAME:(fi + 1) * BITS_PER_FRAME]
        dec = decode_frame(frames[fi])[0]
        assert dec == fb, 'frame %d roundtrip mismatch' % fi
    print('zero-filter roundtrip ok on', len(check_idx), 'frames')

    # 全部帧解码验证（predict=0 快速路径，重点验算术码流）
    for fi in range(TOTAL_SEC * FPS):
        fb = bits[fi * BITS_PER_FRAME:(fi + 1) * BITS_PER_FRAME]
        dec = decode_frame(frames[fi])[0]
        assert dec == fb, 'frame %d roundtrip mismatch (full)' % fi
    print('zero-filter roundtrip ok on ALL %d frames' % (TOTAL_SEC * FPS))
    write_dff_dst('dsd-dst-1.dff', frames, ch=1)

    # 2) FIR 预测帧：coeff=[8]，probs=[128,96]，10 帧
    enc2 = DstFrameEncoder([8], [128, 96])
    frames2 = []
    for fi in range(10):
        fb = bits[fi * BITS_PER_FRAME:(fi + 1) * BITS_PER_FRAME]
        frames2.append(enc2.encode(fb))
    for fi in range(10):
        fb = bits[fi * BITS_PER_FRAME:(fi + 1) * BITS_PER_FRAME]
        dec = decode_frame(frames2[fi], filter_coeff=[8], probs_coeff=[128, 96])[0]
        assert dec == fb, 'fir frame %d roundtrip mismatch' % fi
    print('fir roundtrip ok on 10 frames')
    write_dff_dst('dsd-dst-fir.dff', frames2, ch=1)

    print('done')


if __name__ == '__main__':
    main()
