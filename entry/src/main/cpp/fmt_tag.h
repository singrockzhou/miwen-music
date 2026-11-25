#ifndef MIWEN_FMT_TAG_H
#define MIWEN_FMT_TAG_H

#include <string>

/**
 * 文件标签回写：把库内编辑的元数据写进音频文件本体（v1.5.0）。
 *
 * 支持：FLAC（Vorbis comment 块整体重建）、MP3（ID3v2.3 整体重建，UTF-16LE 文本帧）。
 * 音频流字节一个不动——FLAC 只重排 metadata 区（STREAMINFO 原样保留），
 * MP3 从旧 ID3v2 结束处开始整段拷贝（文件尾若有 ID3v1 一并保留）。
 * 写临时文件 + rename 原子替换，中途断电不会留半个坏文件。
 *
 * 其余格式（WAV/AIFF/APE/WavPack/DFF/DSF…）明确报暂不支持。
 *
 * tagsJson 约定（flat JSON，值全部按字符串收，数字也行）：
 *   {"title":"..","artist":"..","album":"..","albumartist":"..","genre":"..","date":"..","track":".."}
 * 缺 key = 不写该帧；整包空 = 不产生任何帧（返回错误，上层不会走到这）。
 *
 * coverPath（v1.7.0）：非空时把该图片写进文件本体封面（FLAC=PICTURE 块 type 6 整体替换/追加，
 * MP3=ID3v2.3 APIC 帧整体重建）。支持 JPEG/PNG（按文件头识别 mime）。音频流依旧一个字节不动。
 */
int WriteAudioTags(const std::string &path, const std::string &tagsJson,
                   const std::string &coverPath, char *err, size_t errLen);

#endif // MIWEN_FMT_TAG_H
