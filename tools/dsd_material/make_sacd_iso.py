# -*- coding: utf-8 -*-
"""合成 SACD ISO 测试素材：sacd-test.iso（立体声区、未压缩 DSD_3_IN_16 帧、单曲目 6 秒）。

布局（偏移依据 refs/scarletbook.h 与 scarletbook_read.c 逐字段核实，与 fmt_iso.cpp 一致）：
- LSN 16      最小 ISO9660 PVD 占位（fmt_iso 不读，仅为真实观感）
- LSN 510-519 Master TOC（10 扇区）：510=SACDMTOC，511=SACDText
- LSN 600-603 2ch 区 TOC：600=TWOCHTOC，601=SACDTTxt，602=SACDTRL1，603=SACDTRL2
- LSN 700 起  音频数据：450 帧 × 5 扇区 = 2250 扇区

音频扇区结构（scarletbook.h audio_sector 位域 + scarletbook_read.c 手工解析分支）：
- 扇区头 1 字节：bit0=dst_encoded，bit1=保留，bit2..4=frame_info_count，bit5..7=packet_info_count
- packet info 2 字节/个：bit7=frame_start，bit3..5=data_type(2=audio,7=padding)，
  长度 = ((b0&7)<<8)|b1
- frame info（非 DST）3 字节/个 = timecode {min,sec,frames}（75fps，逐帧递增）
- 每帧 9408 字节 = 每声道 4704 字节，按声道字节交错（ch0,ch1,ch0,...），MSB-first
- 帧分扇区：s0 头0x24(1包+帧信息+2042B) + s1..s3 头0x20(1包+2045B) + s4 头0x40(音频1231B+填充812B)
"""
import math
import struct

LSN = 2048
SR_DSD = 2822400
BITS_PER_FRAME = 37632
BYTES_PER_CH = 4704
FPS = 75
TOTAL_SEC = 6
SEGS_CH0 = [(0.25, 440.0), (0.5, 1000.0), (0.75, 2000.0)]
SEGS_CH1 = [(0.75, 300.0), (0.5, 700.0), (0.25, 1500.0)]  # 两声道内容不同，防交错/声道接反

MASTER_TOC_LSN = 510
AREA_TOC_LSN = 600
AUDIO_LSN = 700


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


def sector(fill=0):
    return bytearray(LSN) if fill == 0 else bytearray([fill]) * LSN


def build_master_toc():
    s = sector()
    s[0:8] = b'SACDMTOC'
    s[8] = 1            # version.major
    s[9] = 2            # version.minor
    s[64:68] = u32be(AREA_TOC_LSN)   # area_1_toc_1_start
    s[68:72] = u32be(0)              # area_1_toc_2_start
    s[72:76] = u32be(0)              # area_2_toc_1_start
    s[76:80] = u32be(0)              # area_2_toc_2_start
    s[84:86] = u16be(4)              # area_1_toc_size（区 TOC 共 4 扇区）
    s[86:88] = u16be(0)              # area_2_toc_size
    s[120:122] = u16be(2026)         # disc_date_year
    s[122] = 11
    s[123] = 25
    s[128] = 1                       # text_area_count
    s[136:140] = b'en' + bytes([2, 0])  # locales[0]: ISO 8859-1
    return s


def build_sacd_text():
    s = sector()
    s[0:8] = b'SACDText'
    title = b'Miwen SACD Test'
    artist = b'Miwen Audio'
    s[100:100 + len(title)] = title
    s[200:200 + len(artist)] = artist
    s[16:18] = u16be(100)   # album_title_position
    s[18:20] = u16be(200)   # album_artist_position
    return s


def build_area_toc(track_start, track_end, play_sec):
    s = sector()
    s[0:8] = b'TWOCHTOC'
    s[8] = 1
    s[9] = 2
    s[10:12] = u16be(4)          # size（区 TOC 总扇区数）
    s[16:20] = u32be(0)          # max_byte_rate
    s[20] = 4                    # sample_frequency = 64fs
    s[21] = 3                    # 低 4 位 frame_format = 3 (DSD_3_IN_16)
    s[32] = 2                    # channel_count
    s[33] = 0                    # 高 5 位 loudspeaker_config = 0（立体声）
    s[34] = 2                    # max_available_channels
    s[35] = 0                    # area_mute_flags
    s[64] = 0                    # total_playtime.min
    s[65] = play_sec             # .sec
    s[66] = 0                    # .frames
    s[68] = 0                    # track_offset
    s[69] = 1                    # track_count
    s[72:76] = u32be(track_start)
    s[76:80] = u32be(track_end)
    s[80] = 1                    # text_area_count
    s[88:92] = b'en' + bytes([2, 0])   # languages[0]
    s[128:130] = u16be(2048)     # track_text_offset → SACDTTxt 扇区（相对区起点）
    return s


def build_track_text():
    s = sector()
    s[0:8] = b'SACDTTxt'
    s[8:10] = u16be(64)          # track_text_position[0]
    title = b'Miwen Track A'
    # 条目：amount(1) + 3 填充 + [type 0x01 + 填充 + 文本 NUL 结尾]
    s[64] = 1
    s[68] = 0x01                 # TRACK_TYPE_TITLE
    s[70:70 + len(title)] = title
    s[70 + len(title)] = 0
    return s


def build_trl1(start_lsn, length_lsn):
    s = sector()
    s[0:8] = b'SACDTRL1'
    s[8:12] = u32be(start_lsn)          # track_start_lsn[0]
    s[8 + 255 * 4:8 + 255 * 4 + 4] = u32be(length_lsn)  # track_length_lsn[0]
    return s


def build_trl2(length_sec):
    s = sector()
    s[0:8] = b'SACDTRL2'
    # start[0] = {min,sec,frames,flags}
    s[8:12] = bytes([0, 0, 0, 0])
    # duration[0] = {min,sec,frames,flags}
    s[8 + 255 * 4:8 + 255 * 4 + 4] = bytes([0, length_sec, 0, 0])
    return s


def pkt_info(frame_start, data_type, length):
    b0 = ((1 if frame_start else 0) << 7) | ((data_type & 7) << 3) | ((length >> 8) & 7)
    b1 = length & 0xFF
    return bytes([b0, b1])


def build_audio_sectors(ch0_bytes, ch1_bytes):
    """450 帧 → 5 扇区/帧。帧数据 = ch0/ch1 按字节交错。"""
    n_frames = len(ch0_bytes) // BYTES_PER_CH
    out = []
    for f in range(n_frames):
        c0 = ch0_bytes[f * BYTES_PER_CH:(f + 1) * BYTES_PER_CH]
        c1 = ch1_bytes[f * BYTES_PER_CH:(f + 1) * BYTES_PER_CH]
        inter = bytearray(2 * BYTES_PER_CH)
        inter[0::2] = c0
        inter[1::2] = c1
        tc = (f // (60 * FPS), (f // FPS) % 60, f % FPS)
        # s0：帧起始
        s = sector()
        s[0] = (1 << 5) | (1 << 2) | 0          # piCount=1, fiCount=1, 非 DST
        s[1:3] = pkt_info(True, 2, 2042)
        s[3:6] = bytes(tc)
        s[6:6 + 2042] = inter[0:2042]
        out.append(bytes(s))
        # s1..s3：整段续
        for k in range(3):
            s = sector()
            s[0] = (1 << 5) | (0 << 2) | 0      # piCount=1, fiCount=0
            s[1:3] = pkt_info(False, 2, 2045)
            off = 2042 + k * 2045
            s[3:3 + 2045] = inter[off:off + 2045]
            out.append(bytes(s))
        # s4：音频尾段 + 填充包（packet info 连续排在扇区头之后，载荷依次跟随）
        s = sector()
        s[0] = (2 << 5) | (0 << 2) | 0          # piCount=2, fiCount=0
        s[1:3] = pkt_info(False, 2, 1231)
        s[3:5] = pkt_info(False, 7, 812)
        s[5:5 + 1231] = inter[2042 + 3 * 2045:9408]  # 填充载荷 812 字节保持 0
        out.append(bytes(s))
    return out


# ---------------- 验证：镜像 fmt_iso.cpp 的解析路径 ----------------

def rd32(b, o):
    return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]


def rd16(b, o):
    return (b[o] << 8) | b[o + 1]


def verify_iso(path, ch0_src, ch1_src):
    data = open(path, 'rb').read()
    assert len(data) % LSN == 0
    n_sectors = len(data) // LSN
    sec = lambda i: data[i * LSN:(i + 1) * LSN]

    mt = sec(MASTER_TOC_LSN)
    assert mt[0:8] == b'SACDMTOC'
    area_start = rd32(mt, 64)
    area_size = rd16(mt, 84)
    assert area_start == AREA_TOC_LSN and area_size == 4
    txt = sec(MASTER_TOC_LSN + 1)
    assert txt[0:8] == b'SACDText'
    album = txt[rd16(txt, 16):].split(b'\x00')[0].decode()
    artist = txt[rd16(txt, 18):].split(b'\x00')[0].decode()
    assert album == 'Miwen SACD Test' and artist == 'Miwen Audio'

    at = sec(area_start)
    assert at[0:8] == b'TWOCHTOC'
    assert rd16(at, 10) == 4
    assert (at[21] & 0x0F) == 3
    assert at[32] == 2
    assert ((at[33] >> 3) & 31) == 0
    assert at[69] == 1
    track_start = rd32(at, 72)
    track_end = rd32(at, 76)

    # 区 TOC 后续扇区扫描（fmt_iso 同款顺序）
    trl1 = trl2 = None
    pos = 1
    while pos < area_size:
        p = sec(area_start + pos)
        tag = bytes(p[0:8])
        if tag == b'SACDTTxt':
            pos += 1
        elif tag == b'SACD_IGL':
            pos += 2
        elif tag == b'SACD_ACC':
            pos += 32
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
    dur_ms = (d[0] * 60 + d[1]) * 1000 + d[2] * 1000 // FPS
    d_frames = d[0] * 60 * FPS + d[1] * FPS + d[2]
    assert d_frames == TOTAL_SEC * FPS

    # 曲目文本
    tt = sec(area_start + 1)
    p = rd16(tt, 8)
    assert tt[p] == 1 and tt[p + 4] == 0x01
    title = tt[p + 6:].split(b'\x00')[0].decode()
    assert title == 'Miwen Track A'

    # 音频解复用（镜像 fmt_iso SacdFeeder）
    ch_bytes = [bytearray(), bytearray()]
    cur = None
    for lsn in range(t_start, t_start + t_len):
        s = sec(lsn)
        b0 = s[0]
        dst_enc = b0 & 1
        fi_count = (b0 >> 2) & 7
        pi_count = (b0 >> 5) & 7
        off = 1
        pkts = []
        for _ in range(pi_count):
            pkts.append(((s[off] >> 7) & 1, (s[off] >> 3) & 7,
                         ((s[off] & 7) << 8) | s[off + 1]))
            off += 2
        off += 3 * fi_count  # 非 DST 帧信息 3 字节/个
        for fs, dt, ln in pkts:
            if dt == 2:
                if fs:
                    assert cur is None
                    cur = bytearray()
                cur.extend(s[off:off + ln])
                if len(cur) >= 2 * BYTES_PER_CH:
                    ch_bytes[0].extend(cur[0::2])
                    ch_bytes[1].extend(cur[1::2])
                    cur = None
            off += ln
    assert cur is None, '最后一帧未完成'
    assert bytes(ch_bytes[0]) == ch0_src, 'ch0 位流不一致'
    assert bytes(ch_bytes[1]) == ch1_src, 'ch1 位流不一致'

    # 平衡性抽查：正弦调制的 1-bit 流长期均值≈0（位内容本身已做 bit-exact 比对）
    for ch_idx, ch_bits in enumerate([ch0_src, ch1_src]):
        n_bytes = len(ch_bits)
        for seg in range(3):
            seg_b = ch_bits[seg * n_bytes // 3:(seg + 1) * n_bytes // 3]
            ones = sum(bin(b).count('1') for b in seg_b) / (8.0 * len(seg_b))
            assert 0.45 < ones < 0.55, (ch_idx, seg, ones)
    print('verify ok: %d sectors, track %d+%d, dur=%dms, album=%r artist=%r track=%r'
          % (n_sectors, t_start, t_len, dur_ms, album, artist, title))


def main():
    ch0 = gen_channel_bits(TOTAL_SEC, SEGS_CH0)
    ch1 = gen_channel_bits(TOTAL_SEC, SEGS_CH1)
    n_frames = TOTAL_SEC * FPS
    audio = build_audio_sectors(ch0, ch1)
    assert len(audio) == n_frames * 5
    audio_lsn = AUDIO_LSN
    end_lsn = audio_lsn + len(audio)

    out = {}
    out[16] = None  # PVD 占位
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
    # 最小 PVD
    pvd = sector()
    pvd[0] = 1
    pvd[1:6] = b'CD001'
    pvd[6] = 1
    img[16 * LSN:17 * LSN] = pvd
    for i, s in out.items():
        if s is None:
            continue
        img[i * LSN:(i + 1) * LSN] = s
    with open('sacd-test.iso', 'wb') as f:
        f.write(img)
    print('sacd-test.iso ok: %.1f MB, %d sectors, %d audio frames'
          % (len(img) / 1048576.0, total_sectors, n_frames))

    verify_iso('sacd-test.iso', ch0, ch1)


if __name__ == '__main__':
    main()
