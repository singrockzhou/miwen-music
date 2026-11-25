#ifndef MIWEN_FMT_ISO_H
#define MIWEN_FMT_ISO_H

#include "decoder.h"

#include <cstdint>
#include <string>
#include <vector>

/**
 * SACD ISO 直读（Scarlet Book 格式）。
 *
 * 结构依据 sacd-ripper scarletbook.h / scarletbook_read.c 逐行核实（refs/ 下有副本）：
 * ISO 不经文件系统解析，按 LSN（2048 字节扇区）直读：
 *   Master TOC @ LSN 510（10 扇区）→ 区 TOC（TWOCHTOC 2ch / MULCHTOC 多声道）
 *   → SACDTRL1（track 起 LSN/长 LSN）+ SACDTRL2（时长）+ SACDTTxt（曲目文本）
 * 音频扇区解复用 → 帧（未压缩 = 按声道字节交错 4704 字节/声道；DST 帧 → fmt_dst 解压）
 * → 帧式位流 → 共享抽取器。
 *
 * v1.5.0 范围：立体声区（2ch）全部曲目；多声道区给出明确话术。
 */
struct SacdIsoTrack {
    std::string title;
    int64_t startLsn = 0;
    int64_t lengthLsn = 0;
    int64_t durationMs = 0;
    bool dst = false;
};

struct SacdIsoInfo {
    bool ok = false;
    std::string error;
    std::string album;
    std::string artist;
    int channels = 2;
    bool dst = false;
    std::vector<SacdIsoTrack> tracks;
};

/** 解析 ISO 元数据（供扫描入库展开曲目）。 */
SacdIsoInfo ParseSacdIso(const std::string &path);

AudioSource *CreateSacdIsoSource(const std::string &path, int trackIndex, std::string *why);

#endif // MIWEN_FMT_ISO_H
