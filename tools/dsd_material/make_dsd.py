# -*- coding: utf-8 -*-
"""生成 DSD 测试素材：DSF 与 DFF 各两条（DSD64），三段阶梯信号与 APE 素材同款。

1-bit 调制用一阶 sigma-delta：y = sign(accum > 0)，误差反馈保证输出均值=输入。
PC 端基准用 ffmpeg 解 DSF（独立实现）取 RMS 交叉核对。
"""
import math
import struct
import sys

SR_DSD = 2822400  # DSD64
SR_PCM = 44100
TOTAL_SEC = 30
# 每段 10s；DSD 位率下的瞬时幅度（sigma-delta 后均值≈amp）
SEGS = [(0.25, 440.0), (0.5, 1000.0), (0.75, 2000.0)]


def gen_dsd_bits():
    """返回 30s 的 ±1 位流（int 列表太占内存，直接写字节）"""
    n_bits = SR_DSD * TOTAL_SEC
    buf = bytearray(n_bits // 8)
    accum = 0.0
    # 逐位太慢（8.4M 位 python 约 20-40 秒），用 numpy 也没有反馈环……接受慢速一次生成
    byte = 0
    n_in_byte = 0
    out_idx = 0
    for i in range(n_bits):
        t = i / SR_DSD
        seg = int(t // 10)
        if seg > 2:
            seg = 2
        amp, freq = SEGS[seg]
        x = amp * math.sin(2 * math.pi * freq * t)
        # 一阶 sigma-delta
        y = 1.0 if accum > 0 else -1.0
        accum += x - y
        bit = 1 if y > 0 else 0
        # DSF: LSB first —— 我们生成通用位流，写文件时再排
        byte |= bit << n_in_byte
        n_in_byte += 1
        if n_in_byte == 8:
            buf[out_idx] = byte
            out_idx += 1
            byte = 0
            n_in_byte = 0
    return bytes(buf)


def write_dsf(path, bits_lsb_first, ch=1):
    """DSF：'DSD ' 头 + 'fmt ' + 'data'，块内按声道分段，比特 LSB 在前"""
    block_size = 4096
    sample_count = len(bits_lsb_first) * 8
    data_bytes = len(bits_lsb_first)  # 单声道
    # 补齐块
    last = data_bytes % block_size
    data = bits_lsb_first + (b'\x00' * (block_size - last) if last != 0 else b'')

    with open(path, 'wb') as f:
        # DSD chunk: id(4) size(8)=28 version(4) formatid(4) id3pos(8)
        # id3pos 指向文件尾的 ID3v2 标签；0 = 没有（ffmpeg 的 dsf 解复用器会读这个字段）
        f.write(b'DSD ')
        f.write(struct.pack('<Q', 28))
        f.write(struct.pack('<I', 1))  # version
        f.write(struct.pack('<I', 0))  # format id: DSD raw
        f.write(struct.pack('<Q', 0))  # id3 offset
        # fmt chunk: id(4) size(8)=52 + fields
        f.write(b'fmt ')
        f.write(struct.pack('<Q', 52))
        f.write(struct.pack('<I', 1))          # version
        f.write(struct.pack('<I', 0))          # format id
        f.write(struct.pack('<I', 0 if ch == 1 else 1))  # channel type: mono / stereo
        f.write(struct.pack('<I', ch))         # channel num
        f.write(struct.pack('<I', SR_DSD))     # sampling frequency
        f.write(struct.pack('<I', 1))          # bits per sample
        f.write(struct.pack('<Q', sample_count))
        f.write(struct.pack('<I', block_size))
        f.write(struct.pack('<I', 0))          # reserved
        # data chunk
        f.write(b'data')
        f.write(struct.pack('<Q', len(data) + 12))
        f.write(data)
    print(path, 'ok', data_bytes, 'bytes')


# 8 位查找表：LSB-first 打包字节 → MSB-first 打包字节（位反转）
_REV = bytes(int(f'{i:08b}'[::-1], 2) for i in range(256))


def write_dff(path, bits_lsb_first, ch=1):
    """DFF：FRM8 容器，帧交织（单声道无交织差异），比特 MSB 在前

    入参与 write_dsf 一致：gen_dsd_bits 输出的 LSB-first 字节流。
    逻辑位序不变，只是打包方向相反——逐字节查表位反转即可。
    千万别把字节流当逻辑位流逐位重排：那是按 1:8 压缩，数据区会变成大片 0xFF/0x00。
    """
    data = bytes(_REV[b] for b in bits_lsb_first)

    def chunk(cid, payload):
        return cid + struct.pack('>Q', len(payload)) + payload + (b'\x00' if len(payload) % 2 else b'')

    prop_snd = chunk(b'FS  ', struct.pack('>I', SR_DSD))
    prop_snd += chunk(b'CHNL', struct.pack('>H', ch) + (b'MONO' if ch == 1 else b'FL  FR  '))
    # CMPR：compressionType(4) + count(2 BE) + comments——'DSD ' 必须在最前，
    # 否则 ffmpeg 按 SVX8 压缩类型读出乱码直接拒绝
    prop_snd += chunk(b'CMPR', b'DSD ' + struct.pack('>H', 0))
    # PROP 的 payload = 'SND ' 4CC 直接跟子块——4CC 后没有 size 字段
    # （写成 chunk 会让 ffmpeg 把 size 当子块 id，采样率读成 0，整个文件被当 8SVX 拒掉）
    prop = b'SND ' + prop_snd

    frv8 = chunk(b'FVER', struct.pack('>I', 0x01050000))
    body = frv8 + chunk(b'PROP', prop) + chunk(b'DSD ', data)
    with open(path, 'wb') as f:
        f.write(b'FRM8' + struct.pack('>Q', len(body)) + b'DSD ' + body)
    print(path, 'ok', len(data), 'bytes')


if __name__ == '__main__':
    bits = gen_dsd_bits()
    write_dsf('dsd-64-1.dsf', bits)
    # DSF/DFF 是同一条逻辑位流的两种打包方向，共用一份生成结果即可
    write_dff('dsd-64-1.dff', bits)
    print('done')
