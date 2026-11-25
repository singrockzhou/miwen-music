#include "napi/native_api.h"

#include "decoder.h"
#include "fmt_rate.h"

#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

/** 句柄表条目：除了解码器本身，记下声道数 —— read 要按"帧×声道×4 字节"精确开 ArrayBuffer，
 *  不能拿缓冲区容量顶替，否则 JS 侧会读到尾部垃圾。 */
struct Entry {
    AudioSource *src;
    int channels;
};

// 所有调用都在 UI 线程同步执行（一次读 100ms 数据，量很小），不另开线程；
// ArkTS 侧只持有一个 number 句柄，不在 JS 里长期存 native 指针。
std::map<int32_t, Entry> g_sources;
int32_t g_nextId = 1;

Entry *Find(int32_t id) {
    auto it = g_sources.find(id);
    return it == g_sources.end() ? nullptr : &it->second;
}

std::string GetString(napi_env env, napi_value v) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok || len == 0) {
        return std::string();
    }
    std::vector<char> buf(len + 1, 0);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, v, buf.data(), buf.size(), &copied) != napi_ok) {
        return std::string();
    }
    return std::string(buf.data(), copied);
}

int32_t GetInt(napi_env env, napi_value v, int32_t def) {
    int32_t out = def;
    if (napi_get_value_int32(env, v, &out) != napi_ok) {
        return def;
    }
    return out;
}

void SetInt(napi_env env, napi_value obj, const char *name, int32_t value) {
    napi_value v = nullptr;
    napi_create_int32(env, value, &v);
    napi_set_named_property(env, obj, name, v);
}

void SetStr(napi_env env, napi_value obj, const char *name, const std::string &value) {
    napi_value v = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &v);
    napi_set_named_property(env, obj, name, v);
}

napi_value Null(napi_env env) {
    napi_value nul = nullptr;
    napi_get_null(env, &nul);
    return nul;
}

napi_value MakeInfo(napi_env env, bool ok, const AudioInfo &info, int32_t id, const char *fallbackError) {
    napi_value obj = nullptr;
    napi_create_object(env, &obj);

    napi_value v = nullptr;
    napi_get_boolean(env, ok, &v);
    napi_set_named_property(env, obj, "ok", v);

    SetInt(env, obj, "id", id);
    SetInt(env, obj, "sampleRate", info.sampleRate);
    SetInt(env, obj, "channels", info.channels);
    SetInt(env, obj, "bitsPerSample", info.bitsPerSample);

    napi_create_int64(env, info.totalFrames, &v);
    napi_set_named_property(env, obj, "totalFrames", v);
    napi_create_int64(env, info.durationMs, &v);
    napi_set_named_property(env, obj, "durationMs", v);

    SetStr(env, obj, "format", info.format.empty() ? std::string("未知") : info.format);

    std::string err = info.error;
    if (err.empty() && !ok && fallbackError != nullptr) {
        err = fallbackError;
    }
    SetStr(env, obj, "error", err);
    return obj;
}

/** open(path) → { ok, id, sampleRate, channels, bitsPerSample, totalFrames, durationMs, format, error } */
napi_value Open(napi_env env, napi_callback_info cb) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, cb, &argc, args, nullptr, nullptr);

    const std::string path = GetString(env, args[0]);
    if (path.empty()) {
        return MakeInfo(env, false, AudioInfo(), 0, "路径为空");
    }

    std::string why;
    AudioSource *src = CreateSource(path, &why);
    if (src == nullptr) {
        return MakeInfo(env, false, AudioInfo(), 0, why.empty() ? "该格式的解码器尚未接入" : why.c_str());
    }

    const AudioInfo info = src->open(path);
    if (!info.ok) {
        src->close();
        delete src;
        return MakeInfo(env, false, info, 0, "解码器打不开该文件");
    }

    const int32_t id = g_nextId++;
    Entry e;
    // 统一包一层 WSOLA 变速链：rate=1 时直通零开销，变速随时切换不需要重建解码器
    RateSource *rs = new RateSource(src, info.channels, info.sampleRate);
    e.src = rs;
    e.channels = info.channels;
    g_sources[id] = e;
    return MakeInfo(env, true, info, id, nullptr);
}

/** read(id, frames) → ArrayBuffer（交错 float32，长度 = 实际帧数×声道×4）| null（到底或出错） */
napi_value Read(napi_env env, napi_callback_info cb) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, cb, &argc, args, nullptr, nullptr);

    Entry *e = Find(GetInt(env, args[0], -1));
    if (e == nullptr) {
        return Null(env);
    }

    int32_t frames = GetInt(env, args[1], 4096);
    if (frames <= 0) {
        frames = 4096;
    }
    // 单次上限 4 秒（按 192k 算），防止调用方误传巨大帧数把内存撑爆
    if (frames > 192000 * 4) {
        frames = 192000 * 4;
    }

    std::vector<float> tmp((size_t) frames * (size_t) e->channels);
    const int64_t got = e->src->read(tmp.data(), frames);
    if (got <= 0) {
        return Null(env);
    }

    const size_t bytes = (size_t) got * (size_t) e->channels * sizeof(float);
    void *data = nullptr;
    napi_value ab = nullptr;
    if (napi_create_arraybuffer(env, bytes, &data, &ab) != napi_ok || data == nullptr) {
        return Null(env);
    }
    std::memcpy(data, tmp.data(), bytes);
    return ab;
}

/** seek(id, frame) → 实际帧号；-1 表示失败 */
napi_value Seek(napi_env env, napi_callback_info cb) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, cb, &argc, args, nullptr, nullptr);

    Entry *e = Find(GetInt(env, args[0], -1));
    int64_t frame = 0;
    if (argc >= 2) {
        napi_get_value_int64(env, args[1], &frame);
        if (frame < 0) {
            frame = 0;
        }
    }

    napi_value out = nullptr;
    napi_create_int64(env, e == nullptr ? -1 : e->src->seek(frame), &out);
    return out;
}

/** close(id) */
napi_value Close(napi_env env, napi_callback_info cb) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, cb, &argc, args, nullptr, nullptr);

    auto it = g_sources.find(GetInt(env, args[0], -1));
    if (it != g_sources.end()) {
        it->second.src->close();
        delete it->second.src;
        g_sources.erase(it);
    }
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

/** handles(suffix) → boolean，与 ArkTS 侧门禁共用同一份白名单 */
napi_value Handles(napi_env env, napi_callback_info cb) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, cb, &argc, args, nullptr, nullptr);
    const std::string sfx = GetString(env, args[0]);
    napi_value out = nullptr;
    napi_get_boolean(env, NativeHandlesSuffix(sfx), &out);
    return out;
}

/** version() → 解码器版本串，用来确认装到设备上的确实是新 .so */
napi_value Version(napi_env env, napi_callback_info) {
    napi_value out = nullptr;
    napi_create_string_utf8(env, "miwen-decoder/0.4 (aiff, wavpack, alac, ape, dsd)", NAPI_AUTO_LENGTH, &out);
    return out;
}

/** stats(id) → 解码器诊断串（生产环境为空串），排障期从 ArkTS 电平日志带出 */
napi_value Stats(napi_env env, napi_callback_info cb) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, cb, &argc, args, nullptr, nullptr);
    Entry *e = Find(GetInt(env, args[0], 0));
    const std::string s = e == nullptr ? std::string() : e->src->debugStats();
    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &out);
    return out;
}

/** setRate(id, rate)：0.5~2.0 变速不变调（WSOLA）；1.0 直通。随时切换，不需重建解码器 */
napi_value SetRate(napi_env env, napi_callback_info cb) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, cb, &argc, args, nullptr, nullptr);
    Entry *e = Find(GetInt(env, args[0], -1));
    if (e != nullptr) {
        double rate = 1.0;
        if (napi_get_value_double(env, args[1], &rate) != napi_ok) {
            rate = 1.0;
        }
        if (auto *rs = dynamic_cast<RateSource *>(e->src)) {
            rs->setRate(rate);
        }
    }
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"open", nullptr, Open, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"read", nullptr, Read, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"seek", nullptr, Seek, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"handles", nullptr, Handles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stats", nullptr, Stats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setRate", nullptr, SetRate, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_module = {
    1,
    0,
    nullptr,
    Init,
    "miwen",
    nullptr,
    {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterMiwenModule(void) {
    napi_module_register(&g_module);
}
