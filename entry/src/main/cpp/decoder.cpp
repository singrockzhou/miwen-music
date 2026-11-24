#include "decoder.h"
#include "fmt_aiff.h"

#include <cstdio>
#include <cstring>
#include <string>

namespace {

bool ReadHead(const std::string &path, uint8_t *buf, size_t len) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        return false;
    }
    const size_t got = std::fread(buf, 1, len, f);
    std::fclose(f);
    return got == len;
}

std::string LowerSuffix(const std::string &path) {
    const size_t dot = path.find_last_of('.');
    if (dot == std::string::npos) {
        return std::string();
    }
    std::string s = path.substr(dot);
    for (size_t i = 0; i < s.size(); i++) {
        s[i] = (char) std::tolower((unsigned char) s[i]);
    }
    return s;
}

}  // namespace

bool NativeHandlesSuffix(const std::string &suffix) {
    // 只有已经能真解码的扩展名才进这里。接一个新格式就加一行，
    // ArkTS 侧的门禁与话术都读同一个判定，避免"能播却被拦"或"播不了却放行"。
    return suffix == ".aiff" || suffix == ".aif" || suffix == ".aifc";
}

AudioSource *CreateSource(const std::string &path) {
    uint8_t head[12];
    if (!ReadHead(path, head, sizeof(head))) {
        return nullptr;
    }

    // 先看 magic，再看扩展名：发烧友的收藏里改错扩展名的文件不少，
    // 真实格式优先于文件名后缀。
    if (std::memcmp(head, "FORM", 4) == 0 &&
        (std::memcmp(head + 8, "AIFF", 4) == 0 || std::memcmp(head + 8, "AIFC", 4) == 0)) {
        return CreateAiffSource(path);
    }

    const std::string sfx = LowerSuffix(path);
    if (sfx == ".aiff" || sfx == ".aif" || sfx == ".aifc") {
        // 扩展名对但 magic 不对：交给 AIFF 解析器给出具体原因（比统一报"格式不支持"有用）
        return CreateAiffSource(path);
    }

    // 以下三种已规划但解码器尚未接入，返回 nullptr 由上层给明确话术
    //   wvpk → WavPack
    //   MAC  → APE
    //   ftyp → ALAC（在 m4a 容器里，需读 stsd 判断）
    return nullptr;
}
