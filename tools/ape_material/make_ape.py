# -*- coding: utf-8 -*-
"""用 SDK 自带的 MACDll64.dll 把 wav 压成 APE（ffmpeg 没有 APE 编码器）。

流程对齐官方示例 Compress/Sample 1（LockBuffer → 填数据 → UnlockBuffer → Finish）。
"""
import ctypes
import sys
import wave
import os

DLL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "MACDll64.dll")


class WAVEFORMATEX(ctypes.Structure):
    _fields_ = [
        ("wFormatTag", ctypes.c_uint16),
        ("nChannels", ctypes.c_uint16),
        ("nSamplesPerSec", ctypes.c_uint32),
        ("nAvgBytesPerSec", ctypes.c_uint32),
        ("nBlockAlign", ctypes.c_uint16),
        ("wBitsPerSample", ctypes.c_uint16),
        ("cbSize", ctypes.c_uint16),
    ]


def compress(wav_path, ape_path, level=4000):  # 4000 = APE_COMPRESSION_LEVEL_HIGH
    dll = ctypes.WinDLL(DLL)
    # 64 位必须显式声明返回/参数类型，否则句柄按 32 位截断
    dll.c_APECompress_Create.restype = ctypes.c_void_p
    dll.c_APECompress_Create.argtypes = [ctypes.POINTER(ctypes.c_int)]
    dll.c_APECompress_Start.restype = ctypes.c_int
    dll.c_APECompress_Start.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p,
        ctypes.c_int64, ctypes.c_int, ctypes.c_void_p, ctypes.c_int64]
    dll.c_APECompress_GetBufferBytesAvailable.restype = ctypes.c_int
    dll.c_APECompress_GetBufferBytesAvailable.argtypes = [ctypes.c_void_p]
    dll.c_APECompress_LockBuffer.restype = ctypes.c_void_p
    dll.c_APECompress_LockBuffer.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int64)]
    dll.c_APECompress_UnlockBuffer.restype = ctypes.c_int
    dll.c_APECompress_UnlockBuffer.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    dll.c_APECompress_Finish.restype = ctypes.c_int
    dll.c_APECompress_Finish.argtypes = [
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64]
    dll.c_APECompress_Destroy.argtypes = [ctypes.c_void_p]

    w = wave.open(wav_path, "rb")
    ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(n)
    w.close()

    fmt = WAVEFORMATEX()
    fmt.wFormatTag = 1
    fmt.nChannels = ch
    fmt.nSamplesPerSec = sr
    fmt.nAvgBytesPerSec = sr * ch * sw
    fmt.nBlockAlign = ch * sw
    fmt.wBitsPerSample = sw * 8
    fmt.cbSize = 0

    err = ctypes.c_int(0)
    h = dll.c_APECompress_Create(ctypes.byref(err))
    if not h:
        print("create failed:", err.value)
        sys.exit(1)

    st = dll.c_APECompress_Start(h, ape_path.encode("utf-8"), ctypes.byref(fmt),
                                 len(raw), level, None, 0)
    if st != 0:
        print("start failed:", st)
        sys.exit(1)

    pos = 0
    while pos < len(raw):
        avail = ctypes.c_int64(0)
        buf = dll.c_APECompress_LockBuffer(h, ctypes.byref(avail))
        if not buf:
            print("lock failed at", pos)
            sys.exit(1)
        take = min(len(raw) - pos, avail.value)
        ctypes.memmove(buf, raw[pos:pos + take], take)
        st = dll.c_APECompress_UnlockBuffer(h, take, 1)
        if st != 0:
            print("unlock failed:", st)
            sys.exit(1)
        pos += take

    st = dll.c_APECompress_Finish(h, None, 0, 0)
    if st != 0:
        print("finish failed:", st)
        sys.exit(1)
    dll.c_APECompress_Destroy(h)
    print("ok:", ape_path, os.path.getsize(ape_path), "bytes",
          f"({ch}ch {sr}Hz {sw*8}bit)", flush=True)


if __name__ == "__main__":
    compress(sys.argv[1], sys.argv[2])
