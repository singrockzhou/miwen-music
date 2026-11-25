# -*- coding: utf-8 -*-
"""合成多声道 SACD ISO 素材：sacd-mch-test.iso（只有多声道区、未压缩 DSD_3_IN_16、单曲目 6 秒）。

与 make_sacd_iso.py（立体声基准素材）配套，覆盖 v1.7.0 两项验证：
- 任务 36 多声道 SACD 区：5 声道（MULCHTOC），fmt_iso 走 area2 分支，输出层 downmix；
- 任务 35 ISO 标题编码：SACDText 专辑名用 Shift-JIS、曲目标题用 GB2312，
  验证 fmt_iso DecodeIsoText 的探测解码（Latin-1 路径下这两条会乱码）。

布局（偏移依据 refs/scarletbook.h，与 fmt_iso.cpp 一致）：
- LSN 510-519 Master TOC：area_2_toc_1_start=600（area1 全 0 = 无立体声区）
- LSN 600-603 多声道区 TOC：600=MULCHTOC，601=SACDTTxt，602=SACDTRL1，603=SACDTRL2
- LSN 700 起 音频：450 帧 × 5 声道 × 4704 B，按扇区容量切块摊开
"""
import math
import struct

LSN = 2048
SR_DSD = 2822400
BYTES_PER_CH = 4704
FPS = 75
TOTAL_SEC = 6
NCH = 5

MASTER_TOC_LSN = 510
AREA_TOC_LSN = 600
AUDIO_LSN = 700

# 5 声道各放不同频率正弦调制（幅度一致保证 1-bit 平衡），内容互不相同防接反
SEGS = [
    [(0.5, 440.0), (0.5, 1000.0), (0.5, 2000.0)],
    [(0.5, 300.0), (0.5, 700.0), (0.5, 1500.0)],
    [(0.5, 550.0), (0.5, 1100.0), (0.5, 2200.0)],
    [(0.5, 350.0), (0.5, 800.0), (0.5, 1600.0)],
    [(0.5, 600.0), (0.5, 1200.0), (0.5, 2400.0)],
]


def gen_channel_bits(total_sec, segs):
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
        byte |= bit << (7 - n_in_byte)
        n_in_byte += 1
        if n_in_byte == 8:
            buf[out_idx] = byte
            out_idx += 1
            byte = 0
            n_in_byte = 0
    return bytes(buf)


def u32be(v):
    return struct.pack('>I', v)


def u16be(v):
    return struct.pack('>H', v)


def sector():
    return bytearray(LSN)


def pkt_info(frame_start, data_type, length):
    b0 = ((1 if frame_start else 0) << 7) | ((data_type & 7) << 3) | ((length >> 8) & 7)
    return bytes([b0, length & 0xFF])


def build_master_toc():
    s = sector()
    s[0:8] = b'SACDMTOC'
    s[8] = 1
    s[9] = 2
    # area1（立体声）全 0；area2 = 多声道区
    s[72:76] = u32be(AREA_TOC_LSN)   # area_2_toc_1_start
    s[86:88] = u16be(4)              # area_2_toc_size
    s[120:122] = u16be(2026)
    s[122] = 11
    s[123] = 25
    s[128] = 1
    s[136:140] = b'ja' + bytes([2, 0])  # 日文盘：Shift-JIS 场景
    return s


def build_sacd_text():
    s = sector()
    s[0:8] = b'SACDText'
    album = 'サウンドテスト'.encode('shift_jis')   # Shift-JIS 双字节（Latin-1 路径下必乱码）
    artist = b'Miwen Audio'
    s[100:100 + len(album)] = album
    s[200:200 + len(artist)] = artist
    s[16:18] = u16be(100)
    s[18:20] = u16be(200)
    return s


def build_area_toc(track_start, track_end, play_sec):
    s = sector()
    s[0:8] = b'MULCHTOC'
    s[8] = 1
    s[9] = 2
    s[10:12] = u16be(4)
    s[16:20] = u32be(0)
    s[20] = 4                    # 64fs
    s[21] = 3                    # DSD_3_IN_16（未压缩）
    s[32] = NCH                  # channel_count = 5
    s[33] = 0                    # loudspeaker_config（fmt_iso v1.7.0 不再强制 0）
    s[34] = NCH                  # max_available_channels
    s[35] = 0
    s[64] = 0
    s[65] = play_sec
    s[66] = 0
    s[68] = 0
    s[69] = 1
    s[72:76] = u32be(track_start)
    s[76:80] = u32be(track_end)
    s[80] = 1
    s[88:92] = b'zh' + bytes([2, 0])   # 中文文本场景
    s[128:130] = u16be(2048)
    return s


def build_track_text():
    s = sector()
    s[0:8] = b'SACDTTxt'
    s[8:10] = u16be(64)
    title = '多声道测试曲'.encode('gb2312')   # GB2312 双字节
    s[64] = 1
    s[68] = 0x01
    s[70:70 + len(title)] = title
    s[70 + len(title)] = 0
    return s


def build_trl1(start_lsn, length_lsn):
    s = sector()
    s[0:8] = b'SACDTRL1'
    s[8:12] = u32be(start_lsn)
    s[8 + 255 * 4:8 + 255 * 4 + 4] = u32be(length_lsn)
    return s


def build_trl2(length_sec):
    s = sector()
    s[0:8] = b'SACDTRL2'
    s[8:12] = bytes([0, 0, 0, 0])
    s[8 + 255 * 4:8 + 255 * 4 + 4] = bytes([0, length_sec, 0, 0])
    return s


def build_audio_sectors(ch_list):
    """N 声道逐字节交错，整帧按扇区容量切块摊开：首段 2042（带帧信息），后续 2045。"""
    nch = len(ch_list)
    frame_bytes = nch * BYTES_PER_CH
    n_frames = len(ch_list[0]) // BYTES_PER_CH
    out = []
    for f in range(n_frames):
        inter = bytearray(frame_bytes)
        # 声道按字节交错（DSD 帧标准排布，与立体声素材 inter[0::2] 同族）
        for c, cb in enumerate(ch_list):
            inter[c::nch] = cb[f * BYTES_PER_CH:(f + 1) * BYTES_PER_CH]
        tc = (f // (60 * FPS), (f // FPS) % 60, f % FPS)
        pos = 0
        first = True
        while pos < frame_bytes:
            cap = 2042 if first else 2045
            seg = inter[pos:pos + cap]
            s = sector()
            if first:
                s[0] = (1 << 5) | (1 << 2) | 0   # piCount=1, fiCount=1, 非 DST
                s[1:3] = pkt_info(True, 2, len(seg))
                s[3:6] = bytes(tc)
                s[6:6 + len(seg)] = seg
                first = False
            else:
                s[0] = (1 << 5) | (0 << 2) | 0
                s[1:3] = pkt_info(False, 2, len(seg))
                s[3:3 + len(seg)] = seg
            pos += len(seg)
            out.append(bytes(s))
    return out


# ---------------- 验证：镜像 fmt_iso.cpp v1.7.0 的解析路径 ----------------

def rd32(b, o):
    return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]


def rd16(b, o):
    return (b[o] << 8) | b[o + 1]


def verify_iso(path, ch_src_list, title_src_bytes, album_src_bytes):
    nch = len(ch_src_list)
    data = open(path, 'rb').read()
    assert len(data) % LSN == 0
    n_sectors = len(data) // LSN
    sec = lambda i: data[i * LSN:(i + 1) * LSN]

    mt = sec(MASTER_TOC_LSN)
    assert mt[0:8] == b'SACDMTOC'
    assert rd32(mt, 64) == 0, 'area1 应为空'
    area_start = rd32(mt, 72)
    area_size = rd16(mt, 86)
    assert area_start == AREA_TOC_LSN and area_size == 4

    txt = sec(MASTER_TOC_LSN + 1)
    album = txt[rd16(txt, 16):].split(b'\x00')[0]
    artist = txt[rd16(txt, 18):].split(b'\x00')[0]
    assert album == album_src_bytes and artist == b'Miwen Audio'
    assert album.decode('shift_jis') == 'サウンドテスト'

    at = sec(area_start)
    assert at[0:8] == b'MULCHTOC'
    assert (at[21] & 0x0F) == 3
    assert at[32] == nch
    assert at[69] == 1
    track_start = rd32(at, 72)
    track_end = rd32(at, 76)

    trl1 = trl2 = None
    pos = 1
    while pos < area_size:
        p = sec(area_start + pos)
        tag = bytes(p[0:8])
        if tag == b'SACDTTxt':
            pos += 1
        elif tag == b'SACDTRL1':
            trl1 = p
            pos += 1
        elif tag == b'SACDTRL2':
            trl2 = p
            pos += 1
        else:
            break
    assert trl1 is not None and trl2 is not None
    t_start = rd32(trl1, 8)
    t_len = rd32(trl1, 8 + 255 * 4)
    assert t_start == track_start
    d = trl2[8 + 255 * 4:8 + 255 * 4 + 4]
    d_frames = d[0] * 60 * FPS + d[1] * FPS + d[2]
    assert d_frames == TOTAL_SEC * FPS

    tt = sec(area_start + 1)
    p = rd16(tt, 8)
    assert tt[p] == 1 and tt[p + 4] == 0x01
    title = tt[p + 6:].split(b'\x00')[0]
    assert title == title_src_bytes
    assert title.decode('gb2312') == '多声道测试曲'

    # 音频解复用（镜像 fmt_iso SacdFeeder v1.7.0 通用切块）
    frame_bytes = nch * BYTES_PER_CH
    ch_bytes = [bytearray() for _ in range(nch)]
    cur = None
    for lsn in range(t_start, t_start + t_len):
        s = sec(lsn)
        b0 = s[0]
        assert (b0 & 1) == 0, '本素材不含 DST'
        fi_count = (b0 >> 2) & 7
        pi_count = (b0 >> 5) & 7
        off = 1
        pkts = []
        for _ in range(pi_count):
            pkts.append(((s[off] >> 7) & 1, (s[off] >> 3) & 7,
                         ((s[off] & 7) << 8) | s[off + 1]))
            off += 2
        off += 3 * fi_count  # 非 DST 帧信息 3 字节/个（timecode）
        for fs, dt, ln in pkts:
            if dt == 2:
                if fs:
                    assert cur is None
                    cur = bytearray()
                cur.extend(s[off:off + ln])
                if len(cur) >= frame_bytes:
                    for c in range(nch):
                        ch_bytes[c].extend(cur[c::nch])
                    cur = None
            off += ln
    assert cur is None, '最后一帧未完成'
    for c in range(nch):
        assert bytes(ch_bytes[c]) == ch_src_list[c], 'ch%d 位流不一致' % c

    # 平衡性抽查
    for ch_idx, ch_bits in enumerate(ch_src_list):
        n_bytes = len(ch_bits)
        for seg in range(3):
            seg_b = ch_bits[seg * n_bytes // 3:(seg + 1) * n_bytes // 3]
            ones = sum(bin(b).count('1') for b in seg_b) / (8.0 * len(seg_b))
            assert 0.45 < ones < 0.55, (ch_idx, seg, ones)
    print('verify ok: %d sectors, %dch, track %d+%d, album(shift_jis)=%r title(gb2312)=%r'
          % (n_sectors, nch, t_start, t_len,
             album.decode('shift_jis'), title.decode('gb2312')))


def main():
    ch_list = [gen_channel_bits(TOTAL_SEC, segs) for segs in SEGS]
    audio = build_audio_sectors(ch_list)
    audio_lsn = AUDIO_LSN
    end_lsn = audio_lsn + len(audio)

    out = {}
    for i in range(MASTER_TOC_LSN, MASTER_TOC_LSN + 10):
        out[i] = None
    out[MASTER_TOC_LSN] = build_master_toc()
    out[MASTER_TOC_LSN + 1] = build_sacd_text()
    out[AREA_TOC_LSN] = build_area_toc(audio_lsn, end_lsn, TOTAL_SEC)
    out[AREA_TOC_LSN + 1] = build_track_text()
    out[AREA_TOC_LSN + 2] = build_trl1(audio_lsn, len(audio))
    out[AREA_TOC_LSN + 3] = build_trl2(TOTAL_SEC)
    for i, s in enumerate(audio):
        out[audio_lsn + i] = s

    total_sectors = end_lsn
    img = bytearray(total_sectors * LSN)
    pvd = sector()
    pvd[0] = 1
    pvd[1:6] = b'CD001'
    pvd[6] = 1
    img[16 * LSN:17 * LSN] = pvd
    for i, s in out.items():
        if s is None:
            continue
        img[i * LSN:(i + 1) * LSN] = s
    with open('sacd-mch-test.iso', 'wb') as f:
        f.write(img)
    print('sacd-mch-test.iso ok: %.1f MB, %d sectors, %d frames x %dch'
          % (len(img) / 1048576.0, total_sectors, TOTAL_SEC * FPS, NCH))

    verify_iso('sacd-mch-test.iso', ch_list,
               '多声道测试曲'.encode('gb2312'), 'サウンドテスト'.encode('shift_jis'))


if __name__ == '__main__':
    main()
