#include "decoder.h"
#include "fmt_aiff.h"
#include "fmt_wavpack.h"
#include "fmt_alac.h"
#include "fmt_ape.h"
#include "fmt_dsd.h"
#include "fmt_iso.h"

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

void SetWhy(std::string *why, const std::string &msg) {
    if (why != nullptr) {
        *why = msg;
    }
}

std::string Hex4(const uint8_t *p) {
    static const char kHex[] = "0123456789abcdef";
    std::string s;
    for (int i = 0; i < 4; i++) {
        s.push_back(kHex[p[i] >> 4]);
        s.push_back(kHex[p[i] & 0x0F]);
    }
    return s;
}

}  // namespace

bool NativeHandlesSuffix(const std::string &suffix) {
    // 只有已经能真解码的扩展名才进这里。接一个新格式就加一行，
    // ArkTS 侧的门禁与话术都读同一个判定，避免"能播却被拦"或"播不了却放行"。
    // .m4a 例外：容器里可能是 AAC（AVPlayer 能解）。路由走 native，
    // open 失败且原因带「mp4 容器非 ALAC」时由 PlayerCore 回退 AVPlayer。
    return suffix == ".aiff" || suffix == ".aif" || suffix == ".aifc" ||
           suffix == ".wv" || suffix == ".m4a" || suffix == ".ape" ||
           suffix == ".dsf" || suffix == ".dff";
    // .iso 不在这里：ISO 是一张碟，要经扫描展开成"每曲一条记录"，
    // 播放走 NativePlayer 的 #mwi: 虚拟路径（openSacdTrack），不走通用 open。
}

AudioSource *CreateSource(const std::string &path, std::string *why) {
    uint8_t head[12];
    if (!ReadHead(path, head, sizeof(head))) {
        // 区分"根本没权限打开"与"文件短于 12 字节"——这两种在真机上表现一样，原因完全不同
        FILE *probe = std::fopen(path.c_str(), "rb");
        if (probe == nullptr) {
            SetWhy(why, "原生解码打不开该文件（fopen 失败，可能是目录授权未生效）");
        } else {
            std::fclose(probe);
            SetWhy(why, "文件头不足 12 字节，无法识别格式");
        }
        return nullptr;
    }

    // 先看 magic，再看扩展名：发烧友的收藏里改错扩展名的文件不少，
    // 真实格式优先于文件名后缀。
    if (std::memcmp(head, "FORM", 4) == 0 &&
        (std::memcmp(head + 8, "AIFF", 4) == 0 || std::memcmp(head + 8, "AIFC", 4) == 0)) {
        return CreateAiffSource(path);
    }

    if (std::memcmp(head, "wvpk", 4) == 0) {
        return CreateWavpackSource(path);
    }

    // APE 文件头 magic：'MAC '（正常文件）或 'MACF'（APL/Link 文件，
    // 音频主体在外部——MACLib 会尝试解析，失败时给出错误码话术）
    if (std::memcmp(head, "MAC ", 4) == 0 || std::memcmp(head, "MACF", 4) == 0) {
        return CreateApeSource(path, why);
    }

    // DSF：'DSD ' 头块；DFF：FRM8 容器。DST 压缩在解析器里给明确话术
    if (std::memcmp(head, "DSD ", 4) == 0) {
        return CreateDsfSource(path, why);
    }
    if (std::memcmp(head, "FRM8", 4) == 0) {
        return CreateDffSource(path, why);
    }

    if (std::memcmp(head, "ftyp", 4) == 0) {
        // m4a/mp4 容器：里面的编码不一定是 ALAC（AAC 也走这个容器）。
        // CreateAlacSource 对非 ALAC 会给出「mp4 容器非 ALAC」话术，上层据此回退 AVPlayer。
        return CreateAlacSource(path, why);
    }

    const std::string sfx = LowerSuffix(path);
    if (sfx == ".aiff" || sfx == ".aif" || sfx == ".aifc") {
        // 扩展名对但 magic 不对：交给 AIFF 解析器给出具体原因（比统一报"格式不支持"有用）
        return CreateAiffSource(path);
    }
    if (sfx == ".wv") {
        // 同上：改错扩展名的文件由 WavPack 解析器给出具体原因
        return CreateWavpackSource(path);
    }
    if (sfx == ".m4a" || sfx == ".mp4") {
        // 同上：magic 不是 ftyp（有些文件开头是 skip/free 盒）也交给容器解析器
        return CreateAlacSource(path, why);
    }
    if (sfx == ".ape" || sfx == ".apl") {
        // 同上：改错扩展名的文件由 APE 解析器给出具体原因
        return CreateApeSource(path, why);
    }
    if (sfx == ".dsf") {
        return CreateDsfSource(path, why);
    }
    if (sfx == ".dff") {
        return CreateDffSource(path, why);
    }

    // ISO（SACD 镜像）：整碟不能直接"播放"，扫描入库时会展开成曲目并走 openSacdTrack；
    // 若有调用拿裸 ISO 路径来播，给出引导话术
    if (sfx == ".iso") {
        SetWhy(why, "SACD ISO 请先重新扫描曲库：扫描会把它展开成一张碟的曲目列表");
        return nullptr;
    }
    SetWhy(why, "没有匹配的解码器：magic=" + Hex4(head) + " 后缀=" + sfx);
    return nullptr;
}
