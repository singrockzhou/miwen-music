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

add_library(miwen SHARED
    napi_init.cpp
    decoder.cpp
    fmt_aiff.cpp
    fmt_wavpack.cpp
    fmt_alac.cpp
    ${WAVPACK_SRC}
    ${ALAC_SRC}
)

# ENABLE_LEGACY：解开 WavPack 3.x 及更早的旧文件
# HAVE___BUILTIN_CLZ：用编译器内建的前导零指令，热路径上少一层分支
target_compile_definitions(miwen PRIVATE ENABLE_LEGACY HAVE___BUILTIN_CLZ)

target_link_libraries(miwen PUBLIC libace_napi.z.so libhilog_ndk.z.so)
