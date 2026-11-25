#include "fmt_tag.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

void SetErr(char *err, size_t errLen, const char *msg) {
    if (err != nullptr && errLen > 0) {
        std::snprintf(err, errLen, "%s", msg);
    }
}

void AppendUtf8(std::string &out, unsigned int cp) {
    if (cp < 0x80) {
        out.push_back((char) cp);
    } else if (cp < 0x800) {
        out.push_back((char) (0xC0 | (cp >> 6)));
        out.push_back((char) (0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back((char) (0xE0 | (cp >> 12)));
        out.push_back((char) (0x80 | ((cp >> 6) & 0x3F)));
        out.push_back((char) (0x80 | (cp & 0x3F)));
    } else {
        out.push_back((char) (0xF0 | (cp >> 18)));
        out.push_back((char) (0x80 | ((cp >> 12) & 0x3F)));
        out.push_back((char) (0x80 | ((cp >> 6) & 0x3F)));
        out.push_back((char) (0x80 | (cp & 0x3F)));
    }
}

// ---------------- 极简 flat-JSON 解析（只处理顶层字符串/数字值） ----------------

bool ParseJsonString(const std::string &json, size_t &pos, std::string &out) {
    if (pos >= json.size() || json[pos] != '"') {
        return false;
    }
    pos++;
    while (pos < json.size()) {
        const char c = json[pos];
        if (c == '"') {
            pos++;
            return true;
        }
        if (c == '\\') {
            pos++;
            if (pos >= json.size()) {
                return false;
            }
            const char e = json[pos];
            switch (e) {
                case '"':
                    out.push_back('"');
                    break;
                case '\\':
                    out.push_back('\\');
                    break;
                case '/':
                    out.push_back('/');
                    break;
                case 'n':
                    out.push_back('\n');
                    break;
                case 'r':
                    out.push_back('\r');
                    break;
                case 't':
                    out.push_back('\t');
                    break;
                case 'b':
                    out.push_back('\b');
                    break;
                case 'f':
                    out.push_back('\f');
                    break;
                case 'u': {
                    if (pos + 4 >= json.size()) {
                        return false;
                    }
                    unsigned int cp = 0;
                    for (int k = 1; k <= 4; k++) {
                        const char h = json[pos + k];
                        cp <<= 4;
                        if (h >= '0' && h <= '9') {
                            cp |= (unsigned int) (h - '0');
                        } else if (h >= 'a' && h <= 'f') {
                            cp |= (unsigned int) (h - 'a' + 10);
                        } else if (h >= 'A' && h <= 'F') {
                            cp |= (unsigned int) (h - 'A' + 10);
                        } else {
                            return false;
                        }
                    }
                    pos += 4;
                    AppendUtf8(out, cp);
                    break;
                }
                default:
                    return false;
            }
            pos++;
        } else {
            out.push_back(c);
            pos++;
        }
    }
    return false;
}

void SkipJsonWs(const std::string &json, size_t &pos) {
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\n' || json[pos] == '\r')) {
        pos++;
    }
}

/** 顶层对象解析成 map；值一律按字符串收（数字原样拷文本） */
bool ParseFlatJson(const std::string &json, std::map<std::string, std::string> &out) {
    size_t pos = 0;
    SkipJsonWs(json, pos);
    if (pos >= json.size() || json[pos] != '{') {
        return false;
    }
    pos++;
    for (;;) {
        SkipJsonWs(json, pos);
        if (pos < json.size() && json[pos] == '}') {
            return true;
        }
        std::string key;
        if (!ParseJsonString(json, pos, key)) {
            return false;
        }
        SkipJsonWs(json, pos);
        if (pos >= json.size() || json[pos] != ':') {
            return false;
        }
        pos++;
        SkipJsonWs(json, pos);
        std::string value;
        if (pos < json.size() && json[pos] == '"') {
            if (!ParseJsonString(json, pos, value)) {
                return false;
            }
        } else {
            // 数字 / true / false / null：读到 , 或 } 为止
            while (pos < json.size() && json[pos] != ',' && json[pos] != '}') {
                value.push_back(json[pos]);
                pos++;
            }
        }
        out[key] = value;
        SkipJsonWs(json, pos);
        if (pos < json.size() && json[pos] == ',') {
            pos++;
        }
    }
}

// ---------------- 写文件骨架 ----------------

bool ReadAll(const std::string &path, std::vector<uint8_t> &buf, char *err, size_t errLen) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        SetErr(err, errLen, "打不开文件（可能是目录授权未生效）");
        return false;
    }
    std::fseek(f, 0, SEEK_END);
    const long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz <= 0) {
        std::fclose(f);
        SetErr(err, errLen, "文件为空");
        return false;
    }
    buf.resize((size_t) sz);
    const size_t got = std::fread(buf.data(), 1, buf.size(), f);
    std::fclose(f);
    if (got != buf.size()) {
        SetErr(err, errLen, "文件读不完整");
        return false;
    }
    return true;
}

/** 原子落盘：写 path + ".miwentmp" → 删原文件 → rename。 */
bool AtomicReplace(const std::string &path, const std::vector<uint8_t> &data, char *err, size_t errLen) {
    const std::string tmp = path + ".miwentmp";
    FILE *f = std::fopen(tmp.c_str(), "wb");
    if (f == nullptr) {
        SetErr(err, errLen, "临时文件写不进去");
        return false;
    }
    const size_t put = std::fwrite(data.data(), 1, data.size(), f);
    std::fclose(f);
    if (put != data.size()) {
        std::remove(tmp.c_str());
        SetErr(err, errLen, "临时文件写了一半");
        return false;
    }
    std::remove(path.c_str());
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        SetErr(err, errLen, "替换原文件失败（rename）");
        return false;
    }
    return true;
}

// ---------------- FLAC ----------------

/** Vorbis comment 块（小端）：u32 vendorLen + vendor + u32 count + (u32 len + "KEY=value")* */
std::vector<uint8_t> BuildVorbisComment(const std::map<std::string, std::string> &tags) {
    const char *vendor = "miwen";
    std::vector<std::string> comments;
    auto add = [&](const char *key, const std::string &v) {
        if (!v.empty()) {
            comments.push_back(std::string(key) + "=" + v);
        }
    };
    add("TITLE", tags.count("title") ? tags.at("title") : "");
    add("ARTIST", tags.count("artist") ? tags.at("artist") : "");
    add("ALBUM", tags.count("album") ? tags.at("album") : "");
    add("ALBUMARTIST", tags.count("albumartist") ? tags.at("albumartist") : "");
    add("GENRE", tags.count("genre") ? tags.at("genre") : "");
    add("DATE", tags.count("date") ? tags.at("date") : "");
    add("TRACKNUMBER", tags.count("track") ? tags.at("track") : "");

    std::vector<uint8_t> b;
    auto put32le = [&](uint32_t v) {
        b.push_back((uint8_t) (v & 0xFF));
        b.push_back((uint8_t) ((v >> 8) & 0xFF));
        b.push_back((uint8_t) ((v >> 16) & 0xFF));
        b.push_back((uint8_t) ((v >> 24) & 0xFF));
    };
    const uint32_t vlen = (uint32_t) std::strlen(vendor);
    put32le(vlen);
    b.insert(b.end(), vendor, vendor + vlen);
    put32le((uint32_t) comments.size());
    for (const std::string &c : comments) {
        put32le((uint32_t) c.size());
        b.insert(b.end(), c.begin(), c.end());
    }
    return b;
}

bool WriteFlacTags(const std::string &path, const std::map<std::string, std::string> &tags,
                   char *err, size_t errLen) {
    std::vector<uint8_t> data;
    if (!ReadAll(path, data, err, errLen)) {
        return false;
    }
    if (data.size() < 4 || std::memcmp(data.data(), "fLaC", 4) != 0) {
        SetErr(err, errLen, "不是 FLAC 文件（缺 fLaC 头）");
        return false;
    }
    // 遍历 metadata 块，找到 VORBIS_COMMENT（type 4）与音频区起点
    size_t pos = 4;
    std::vector<uint8_t> meta;
    meta.insert(meta.end(), data.begin(), data.begin() + 4);
    size_t audioStart = data.size();
    bool replaced = false;
    while (pos + 4 <= data.size()) {
        const uint8_t h = data[pos];
        const bool last = (h & 0x80) != 0;
        const int type = h & 0x7F;
        const uint32_t bsize = ((uint32_t) data[pos + 1] << 16) | ((uint32_t) data[pos + 2] << 8) | data[pos + 3];
        if (pos + 4 + bsize > data.size()) {
            SetErr(err, errLen, "FLAC 元数据区越界（文件损坏）");
            return false;
        }
        if (type == 4) {
            // 换成新 comment；last 标志按"是否为最终块"在写出时统一设置
            const std::vector<uint8_t> vc = BuildVorbisComment(tags);
            const uint32_t nsize = (uint32_t) vc.size();
            meta.push_back(h & 0x7F);  // 保留 type 4，last 标志清零，写出时统一补
            meta.push_back((uint8_t) ((nsize >> 16) & 0xFF));
            meta.push_back((uint8_t) ((nsize >> 8) & 0xFF));
            meta.push_back((uint8_t) (nsize & 0xFF));
            meta.insert(meta.end(), vc.begin(), vc.end());
            replaced = true;
        } else {
            meta.push_back(h & 0x7F);  // last 标志清零，写出时统一补
            meta.push_back(data[pos + 1]);
            meta.push_back(data[pos + 2]);
            meta.push_back(data[pos + 3]);
            meta.insert(meta.end(), data.begin() + pos + 4, data.begin() + pos + 4 + bsize);
        }
        pos += 4 + bsize;
        if (last) {
            audioStart = pos;
            break;
        }
    }
    if (audioStart > data.size()) {
        SetErr(err, errLen, "FLAC 元数据区解析失败");
        return false;
    }
    if (!replaced) {
        // 原文件没有 VORBIS_COMMENT 块：在最后追加一块
        const std::vector<uint8_t> vc = BuildVorbisComment(tags);
        const uint32_t nsize = (uint32_t) vc.size();
        meta.push_back((uint8_t) ((nsize >> 16) & 0xFF));
        meta.push_back((uint8_t) ((nsize >> 8) & 0xFF));
        meta.push_back((uint8_t) (nsize & 0xFF));
        meta.insert(meta.end(), vc.begin(), vc.end());
    }
    // 最后一个 metadata 块补 last 标志：从 4 开始，每块 (头4 + size)
    {
        size_t p = 4;
        for (;;) {
            const uint32_t bsize = ((uint32_t) meta[p + 1] << 16) | ((uint32_t) meta[p + 2] << 8) | meta[p + 3];
            if (p + 4 + bsize >= meta.size()) {
                meta[p] |= 0x80;
                break;
            }
            p += 4 + bsize;
        }
    }
    std::vector<uint8_t> out = meta;
    out.insert(out.end(), data.begin() + audioStart, data.end());
    return AtomicReplace(path, out, err, errLen);
}

// ---------------- MP3（ID3v2.3） ----------------

uint32_t Syncsafe(const uint8_t *p) {
    return ((uint32_t) (p[0] & 0x7F) << 21) | ((uint32_t) (p[1] & 0x7F) << 14)
        | ((uint32_t) (p[2] & 0x7F) << 7) | (uint32_t) (p[3] & 0x7F);
}

std::vector<uint8_t> BuildId3v23(const std::map<std::string, std::string> &tags) {
    // v2.3 文本帧：encoding 0x01 = UTF-16 带 BOM（中文安全）；帧 size 是普通 BE（v2.3 非 syncsafe）
    auto utf16 = [](const std::string &s) {
        std::vector<uint8_t> b;
        b.push_back(0xFF);
        b.push_back(0xFE);
        size_t i = 0;
        while (i < s.size()) {
            unsigned int cp;
            const uint8_t c = (uint8_t) s[i];
            if (c < 0x80) {
                cp = c;
                i += 1;
            } else if ((c & 0xE0) == 0xC0 && i + 1 < s.size()) {
                cp = ((c & 0x1F) << 6) | (s[i + 1] & 0x3F);
                i += 2;
            } else if ((c & 0xF0) == 0xE0 && i + 2 < s.size()) {
                cp = ((c & 0x0F) << 12) | ((s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
                i += 3;
            } else if ((c & 0xF8) == 0xF0 && i + 3 < s.size()) {
                cp = ((c & 0x07) << 18) | ((s[i + 1] & 0x3F) << 12) | ((s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F);
                i += 4;
            } else {
                cp = '?';
                i += 1;
            }
            if (cp >= 0x10000) {
                cp -= 0x10000;
                const unsigned int hi = 0xD800 | (cp >> 10);
                const unsigned int lo = 0xDC00 | (cp & 0x3FF);
                b.push_back((uint8_t) (hi & 0xFF));
                b.push_back((uint8_t) (hi >> 8));
                b.push_back((uint8_t) (lo & 0xFF));
                b.push_back((uint8_t) (lo >> 8));
            } else {
                b.push_back((uint8_t) (cp & 0xFF));
                b.push_back((uint8_t) (cp >> 8));
            }
        }
        b.push_back(0x00);
        b.push_back(0x00);  // 终止 NUL（UTF-16 双字节）
        return b;
    };

    struct FrameDef {
        const char *id;
        const char *key;
    };
    const FrameDef defs[] = {
        {"TIT2", "title"},
        {"TPE1", "artist"},
        {"TALB", "album"},
        {"TPE2", "albumartist"},
        {"TCON", "genre"},
        {"TYER", "date"},
        {"TRCK", "track"},
    };

    std::vector<uint8_t> body;
    for (const FrameDef &d : defs) {
        auto it = tags.find(d.key);
        if (it == tags.end() || it->second.empty()) {
            continue;
        }
        const std::vector<uint8_t> content = utf16(it->second);
        const uint32_t fsz = (uint32_t) content.size() + 1;  // + encoding byte
        body.insert(body.end(), d.id, d.id + 4);
        body.push_back((uint8_t) ((fsz >> 24) & 0xFF));
        body.push_back((uint8_t) ((fsz >> 16) & 0xFF));
        body.push_back((uint8_t) ((fsz >> 8) & 0xFF));
        body.push_back((uint8_t) (fsz & 0xFF));
        body.push_back(0x00);
        body.push_back(0x00);  // flags
        body.push_back(0x01);  // encoding: UTF-16 w/ BOM
        body.insert(body.end(), content.begin(), content.end());
    }
    if (body.empty()) {
        return {};
    }
    // v2.3 头：ID3 + 03 00 + flags 00 + syncsafe size
    std::vector<uint8_t> out;
    out.push_back('I');
    out.push_back('D');
    out.push_back('3');
    out.push_back(0x03);
    out.push_back(0x00);
    out.push_back(0x00);
    const uint32_t sz = (uint32_t) body.size();
    out.push_back((uint8_t) ((sz >> 21) & 0x7F));
    out.push_back((uint8_t) ((sz >> 14) & 0x7F));
    out.push_back((uint8_t) ((sz >> 7) & 0x7F));
    out.push_back((uint8_t) (sz & 0x7F));
    out.insert(out.end(), body.begin(), body.end());
    return out;
}

bool WriteMp3Tags(const std::string &path, const std::map<std::string, std::string> &tags,
                  char *err, size_t errLen) {
    std::vector<uint8_t> data;
    if (!ReadAll(path, data, err, errLen)) {
        return false;
    }
    // 音频数据起点：有 ID3v2 就跳到 tag 之后；裸 MPEG 帧流从 0 开始
    size_t audioStart = 0;
    if (data.size() >= 10 && std::memcmp(data.data(), "ID3", 3) == 0) {
        const uint8_t ver = data[3];
        const uint32_t sz = Syncsafe(data.data() + 6);
        audioStart = 10 + sz;
        if (ver >= 0x04 && (data[5] & 0x10) != 0) {
            audioStart += 10;  // v2.4 footer
        }
        if (audioStart >= data.size()) {
            SetErr(err, errLen, "MP3 的 ID3v2 头指向音频区之外（文件损坏）");
            return false;
        }
    } else if (data.size() >= 2 && data[0] == 0xFF && (data[1] & 0xE0) == 0xE0) {
        audioStart = 0;  // 裸 MPEG 流
    } else {
        SetErr(err, errLen, "不是 MP3 文件（没有 ID3v2 头也没有 MPEG 帧同步）");
        return false;
    }
    const std::vector<uint8_t> tag = BuildId3v23(tags);
    if (tag.empty()) {
        SetErr(err, errLen, "没有可写入的标签字段");
        return false;
    }
    std::vector<uint8_t> out = tag;
    out.insert(out.end(), data.begin() + audioStart, data.end());
    return AtomicReplace(path, out, err, errLen);
}

}  // namespace

int WriteAudioTags(const std::string &path, const std::string &tagsJson, char *err, size_t errLen) {
    std::map<std::string, std::string> tags;
    if (!ParseFlatJson(tagsJson, tags)) {
        SetErr(err, errLen, "标签数据解析失败");
        return -1;
    }
    bool any = false;
    for (const auto &kv : tags) {
        if (!kv.second.empty()) {
            any = true;
        }
    }
    if (!any) {
        SetErr(err, errLen, "没有要写入的标签字段");
        return -2;
    }

    std::vector<uint8_t> head(12, 0);
    {
        FILE *f = std::fopen(path.c_str(), "rb");
        if (f == nullptr) {
            SetErr(err, errLen, "打不开文件（可能是目录授权未生效）");
            return -3;
        }
        const size_t got = std::fread(head.data(), 1, head.size(), f);
        std::fclose(f);
        if (got < 4) {
            SetErr(err, errLen, "文件太短，不是音频文件");
            return -4;
        }
    }

    if (std::memcmp(head.data(), "fLaC", 4) == 0) {
        return WriteFlacTags(path, tags, err, errLen) ? 0 : -10;
    }
    if (std::memcmp(head.data(), "ID3", 3) == 0 || (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0)) {
        return WriteMp3Tags(path, tags, err, errLen) ? 0 : -10;
    }
    SetErr(err, errLen, "该格式暂不支持标签回写（当前支持 FLAC / MP3）");
    return -20;
}
