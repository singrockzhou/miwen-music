cmake_minimum_required(VERSION 3.5.0)
project(miwen)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVE_ROOT})
# libwavpack 的头文件（wavpack.h 与 wavpack_local.h 同目录，内部相对包含才能成立）
include_directories(${NATIVE_ROOT}/wavpack)
# Apple ALAC 的头文件同理
include_directories(${NATIVE_ROOT}/alac)
# Monkey's Audio MACLib（官方 CMake 口径：Source/Shared 与 Source/MACLib 两个 include 目录）
include_directories(${NATIVE_ROOT}/ape/Shared)
include_directories(${NATIVE_ROOT}/ape/MACLib)

# WavPack 5.8.1 官方解码库（BSD-3，见 wavpack/COPYING）。
# 只收解码 / 打开 / 标签相关文件：
#   - 不含 pack_dsd.c / unpack_dsd.c（DSD 不在解码链范围内，开文件时就会明确报出来）
#   - 不含 *.S / *.asm（x86 与 armv7 手写汇编，arm64 走纯 C 路径）
#   - 含 unpack3*.c（ENABLE_LEGACY）：很老的 WavPack 3.x 文件仍能播
set(WAVPACK_SRC
    wavpack/common_utils.c
    wavpack/decorr_utils.c
    wavpack/entropy_utils.c
    wavpack/extra1.c
    wavpack/extra2.c
    wavpack/open_filename.c
    wavpack/open_legacy.c
    wavpack/open_raw.c
    wavpack/open_utils.c
    wavpack/pack.c
    wavpack/pack_dns.c
    wavpack/pack_floats.c
    wavpack/pack_utils.c
    wavpack/read_words.c
    wavpack/tag_utils.c
    wavpack/tags.c
    wavpack/unpack.c
    wavpack/unpack3.c
    wavpack/unpack3_open.c
    wavpack/unpack3_seek.c
    wavpack/unpack_floats.c
    wavpack/unpack_seek.c
    wavpack/unpack_utils.c
    wavpack/write_words.c
)

# Apple ALAC 官方解码器（Apache-2.0，见 alac/LICENSE，© 2011 Apple Inc.）。
# 只收解码侧文件（编码器 / LibALAC 包装 / Windows dllmain 不编译）：
#   - ALACDecoder.cpp（C++）+ ag_dec / dp_dec / matrix_dec（C）
#   - EndianPortable.c 原版漏判 aarch64，已在本仓补上小端判定
set(ALAC_SRC
    alac/ALACDecoder.cpp
    alac/ALACBitUtilities.c
    alac/EndianPortable.c
    alac/ag_dec.c
    alac/dp_dec.c
    alac/matrix_dec.c
)

# Monkey's Audio 官方 MACLib 13.50（3-Clause BSD，见 ape/License.txt，
# © 2000-2027 Matthew T. Ashland）。按官方 CMakeLists 的库清单收文件：
#   - 不含 Windows 专属（WinFileIO / MACDll / DirectShow / Winamp / GUI）
#   - Prepare / WAVInputSource / APECompress 是官方清单内文件——解码路径引用
#     其符号（CPrepare::Unprepare / CreateInputSource / CAPECompress 构造），
#     裁掉会链接失败，实测必须保留
#   - 含 Old/ 全套：3.97 以前的旧版本 APE 文件仍能播
#   - NNFilterNeon.cpp：官方自带的 NEON 加速路径（arm64 自动启用）
#   - 非 Windows 平台编译需 PLATFORM_LINUX（官方 All.h 探测 __linux__ 亦可，
#     这里显式定义，与官方 CMakeLists 的 else 分支一致）
set(APE_SRC
    ape/Shared/BufferIO.cpp
    ape/Shared/CharacterHelper.cpp
    ape/Shared/CircleBuffer.cpp
    ape/Shared/CPUFeatures.cpp
    ape/Shared/CRC.cpp
    ape/Shared/GlobalFunctions.cpp
    ape/Shared/MemoryIO.cpp
    ape/Shared/Semaphore.cpp
    ape/Shared/StdLibFileIO.cpp
    ape/Shared/Thread.cpp
    ape/Shared/WholeFileIO.cpp
    ape/MACLib/APECompress.cpp
    ape/MACLib/APECompressCore.cpp
    ape/MACLib/APECompressCreate.cpp
    ape/MACLib/APEDecompress.cpp
    ape/MACLib/APEDecompressCore.cpp
    ape/MACLib/APEHeader.cpp
    ape/MACLib/APEInfo.cpp
    ape/MACLib/APELink.cpp
    ape/MACLib/APETag.cpp
    ape/MACLib/BitArray.cpp
    ape/MACLib/FloatTransform.cpp
    ape/MACLib/Interim.cpp
    ape/MACLib/MACLib.cpp
    ape/MACLib/MACProgressHelper.cpp
    ape/MACLib/MD5.cpp
    ape/MACLib/NewPredictor.cpp
    ape/MACLib/NNFilter.cpp
    ape/MACLib/NNFilterGeneric.cpp
    ape/MACLib/NNFilterNeon.cpp
    ape/MACLib/Prepare.cpp
    ape/MACLib/UnBitArray.cpp
    ape/MACLib/UnBitArrayBase.cpp
    ape/MACLib/WAVInputSource.cpp
    ape/MACLib/Old/AntiPredictorExtraHighOld.cpp
    ape/MACLib/Old/AntiPredictorFastOld.cpp
    ape/MACLib/Old/AntiPredictorHighOld.cpp
    ape/MACLib/Old/AntiPredictorNormalOld.cpp
    ape/MACLib/Old/AntiPredictorOld.cpp
    ape/MACLib/Old/APEDecompressCoreOld.cpp
    ape/MACLib/Old/APEDecompressOld.cpp
    ape/MACLib/Old/NewPredictorOld.cpp
    ape/MACLib/Old/UnBitArrayOld.cpp
    ape/MACLib/Old/UnMACOld.cpp
)

add_library(miwen SHARED
    napi_init.cpp
    decoder.cpp
    fmt_aiff.cpp
    fmt_wavpack.cpp
    fmt_alac.cpp
    fmt_ape.cpp
    fmt_rate.cpp
    fmt_dsd.cpp
    ${WAVPACK_SRC}
    ${ALAC_SRC}
    ${APE_SRC}
)

# ENABLE_LEGACY：解开 WavPack 3.x 及更早的旧文件
# HAVE___BUILTIN_CLZ：用编译器内建的前导零指令，热路径上少一层分支
target_compile_definitions(miwen PRIVATE ENABLE_LEGACY HAVE___BUILTIN_CLZ)
# APE 官方 CMake 在非 Windows/Apple 平台的定义（All.h 里按这个走 musl/Linux 分支）
target_compile_definitions(miwen PRIVATE PLATFORM_LINUX)

target_link_libraries(miwen PUBLIC libace_napi.z.so libhilog_ndk.z.so)
