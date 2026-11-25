# 密纹音乐 · HarmonyOS 工程

一个**只读本地、不联网、不要账号**的私人唱片库。首页是一面封套墙，播放页是一圈沟槽进度环。
本目录是可直接用 DevEco Studio 打开、编译、真机运行的完整工程（ArkTS / Stage 模型）。

- 包名：`com.miwen.music`
- 兼容 / 目标：HarmonyOS 5.0.0 (API 12)
- 设备：phone / tablet / 2in1（手机、折叠、平板、鸿蒙 PC）
- 编译验证：`hvigorw assembleHap --mode module -p product=default -p buildMode=debug` → **BUILD SUCCESSFUL**，产物 `entry/build/default/outputs/default/entry-default-signed.hap`（3.82 MB，已签名可直接 `hdc install`）
- 代码规模：54 个 `.ets` 约 16,000 行 + `cpp/` 自研 22 文件约 5,500 行（另内嵌 libwavpack 5.8.1、Apple ALAC 与 Monkey's Audio MACLib 官方源码）
- 当前版本：v1.6.0（第三梯队收官：**年度听歌报告 + 自定义强调色**——统计页加年份切换 / 12 月柱状图 / 年度 TOP5，随长图导出；设置页可从封套八色钉住全局强调色，派生 accent 系四色，切主题与重启均保持。v1.5.0 已含 DST 解压、SACD ISO 直读、文件标签回写；v1.4.0 已含变速不变调(WSOLA)、DSF/DFF 软解、曲库维护页、睡眠定时渐弱）
- 文档：全部收在 [`docs/`](docs/)，见下方文档索引

### 文档索引

| 文档 | 内容 |
|---|---|
| [真机验证报告](docs/密纹音乐-真机验证报告.md) | 每轮真机验证的断言项、结论、暴露的问题与修复，含未覆盖项 |
| [交付说明](docs/密纹音乐-交付说明.md) | 交付物清单、能力清单、已知边界与诚实说明 |
| [收费版本功能规划](docs/密纹音乐-付费版功能规划.md) | 免费 / Pro 怎么切、四个梯队、定价与验收口径 |
| [Pro 版技术验证](docs/密纹音乐-Pro版技术验证.md) | EQ 不可行的证据、直出模式与实装验证 |
| [界面验收稿](docs/密纹音乐-界面验收稿.html) | 6 屏可视稿（5 手机 + 1 平板），浏览器直接打开，可切主题 |

---

## 1. 跑起来（3 步）

1. DevEco Studio → Open → 选本目录（`miwen-app`），等待 Sync 完成。
2. File → Project Structure → Signing Configs → 勾 **Automatically generate signature**（需登录华为账号）。这一步只影响装机，不改代码。
   > 仓库里的 `build-profile.json5` 已把 `signingConfigs` 置空——证书路径与本机绑定、口令不应公开，请按上一步自行生成。
3. 选真机或模拟器 → Run。首屏即是一面示例唱片墙（22 首内置示例，无真实音频，用计时器引擎演示播放）。

> 想换成自己的音乐：首页示例条上的「换成我的」→ 选一个音乐文件夹 → 自动扫描入库。
> 鸿蒙第三方应用拿不到全盘目录，**必须**由系统选择器授权，这是平台规则不是缺陷。

---

## 2. 目录与职责

```
entry/src/main/
├─ module.json5                 权限（KEEP_BACKGROUND_RUNNING / FILE_ACCESS_PERSIST）、后台模式、卡片扩展
├─ cpp/                         原生解码器（CMake，产物 libmiwen.so）
│  ├─ CMakeLists.txt            add_library(miwen SHARED ...) → libmiwen.so
│  ├─ napi_init.cpp             NAPI 绑定：open/read/seek/close/handles/version
│  ├─ decoder.h / decoder.cpp   统一接口 + 按 magic（再看扩展名）分派
│  ├─ fmt_aiff.cpp              AIFF / AIFC（PCM / sowt / fl32 / fl64）
│  ├─ fmt_wavpack.cpp           WavPack（内嵌官方 libwavpack 5.8.1，BSD-3；seek 失败走重建+顺序解码）
│  ├─ fmt_alac.cpp              ALAC（m4a/mp4 容器解析 + Apple 官方解码器，Apache-2.0；AAC 自动回退系统）
│  ├─ fmt_ape.cpp               APE（Monkey's Audio 官方 MACLib 13.50，3-Clause BSD；官方快速 Seek）
│  ├─ wavpack/                  libwavpack 源码 30 文件（去 DSD、去手写汇编，附原 COPYING）
│  ├─ alac/                     Apple ALAC 解码源码 14 文件（EndianPortable 补 aarch64 小端判定，附原 LICENSE）
│  ├─ ape/                      MACLib 源码（官方 CMake 库清单 + License.txt，arm64 走 NNFilterNeon）
│  └─ types/libmiwen/           给 ArkTS 的 .d.ts 与 oh-package.json5
├─ ets/
│  ├─ common/
│  │  ├─ Constants.ets          全部常量：格式、分页、主题键、播放模式、断点
│  │  ├─ Theme.ets              三套主题令牌 + 封套散列取色（唯一色源）
│  │  ├─ UiEnv.ets              断点 sm/md/lg（mediaquery → AppStorage）
│  │  ├─ Fmt.ets                时间 / 采样率 / 体积 / 相对时间
│  │  ├─ Lrc.ets                LRC 解析 + 二分定位当前行
│  │  └─ Logger.ets             hilog 封装
│  ├─ model/                    Track / Album / Playlist / PlayerSnapshot / RootDir（根目录与文件夹树）
│  ├─ db/
│  │  ├─ TrackStore.ets         曲库索引：upsert、分页、搜索、按专辑聚合、按文件夹聚合、孤儿归属修复
│  │  └─ PlaylistStore.ets      收藏 / 歌单 / 最近播放（只存 uri）
│  ├─ service/
│  │  ├─ PlayerCore.ets         播放内核（单例）：AVPlayer + AVSession + 长时任务 + 焦点 + 三引擎
│  │  ├─ NativePlayer.ets       原生解码通道：libmiwen.so 解 PCM → AudioRenderer（v1.3.0）
│  │  ├─ NativeSelfTest.ets     原生解码自检：现场生成 AIFF 并播放，验证字节序/声道/位深
│  │  ├─ LibraryService.ets     选目录 → 持久授权 → 递归扫描 → 标签解析 → 入库（按根逐个扫）
│  │  ├─ RootService.ets        多根目录真源：增删、判重、嵌套检测、按 path 配回新授权
│  │  ├─ ImportFlow.ets         "选目录+扫描+切来源+通知刷新" 的完整流程（三处复用）
│  │  ├─ TagCodec.ets           ID3v2 / FLAC 解析实现
│  │  ├─ TagParser.ets          taskpool 并发入口（只做转调）
│  │  ├─ DemoLibrary.ets        22 首示例曲目 + 示例歌词
│  │  ├─ SelfTest.ets           播放自检：rawfile 测试音走真实解码链路
│  │  ├─ AudioProbe.ets         音频能力探测：查系统给第三方开放了哪些音效通道
│  │  ├─ ProService.ets         密纹 Pro 授权（本地凭证，区分正版/开发版）
│  │  └─ SettingsService.ets    preferences 读写、主题/来源广播、卡片状态
│  ├─ state/ListSources.ets     LazyForEach 的 IDataSource（曲目 / 专辑）
│  ├─ components/               CoverArt / GrooveRing / TrackRow / MiniPlayer / EmptyState /
│  │                            ActionPanel / PlayPauseGlyph / SettingRow
│  ├─ view/                     HomeView / LibraryView / CollectionView / SettingsView（四个 tab）
│  ├─ pages/
│  │  ├─ Index.ets              唯一主页面：Tabs + 迷你播放条
│  │  ├─ PlayerPage.ets         播放页（上滑进入、下滑退出）
│  │  ├─ ProPage.ets            密纹 Pro 购买页（承诺 / 功能清单 / 价格 / 解锁）
│  │  ├─ RootsPage.ets          音乐文件夹管理（多根增删、重新授权、单根/全量重扫）
│  │  └─ ListPage.ets           专辑 / 歌单 / 收藏 / 最近 / 队列 共用列表页
│  ├─ widget/PlayerCard.ets     桌面播控卡片（2*2 / 4*4）
│  ├─ entryability/             启动初始化顺序 + 沉浸式与安全区
│  └─ entryformability/         卡片数据供给（读 preferences 回写卡片）
└─ resources/base/profile/      main_pages / form_config
```

---

## 3. 五个核心模块

| 模块 | 入口 | 关键行为 |
|---|---|---|
| 首页 | `view/HomeView.ets` | 品牌头 + 示例提示条 + 最近在听（横向 104vp 封套）+ 唱片墙（按专辑聚合，2/4/5 列）+ 零联网页脚 |
| 浏览 / 搜索 | `view/LibraryView.ets` | 关键词防抖搜索、四种排序、格式筛选、列表/封面/文件夹三种看法、滚动分页、长按面板 |
| 音乐文件夹 | `pages/RootsPage.ets` | 多根目录：增删、状态探测、单根/全量重扫、重新授权（重装后救回索引） |
| 播放器 | `pages/PlayerPage.ets` | 沟槽进度环、两行歌词、拖动进度、播放/暂停、上下曲、模式切换、收藏、队列入口 |
| 歌单 / 收藏 | `view/CollectionView.ets` + `pages/ListPage.ets` | 收藏 / 歌单（新建、重命名、删除、加曲）/ 最近播放（50 条上限），全部本地 |
| 设置 | `view/SettingsView.ets` | 三主题、曲库来源与目录、重扫、清空索引、默认模式、睡眠定时、播放自检、零联网说明、异常演练 |

路由：`Index` 承载四个 tab；`PlayerPage`、`ListPage` 由 `router.pushUrl` 打开。
`PlayerPage` 用 `pageTransition` 做上滑进入 / 下滑退出（"一镜到底"的可用近似）。

**播放自检**（`service/SelfTest.ets`）：示例曲走计时器引擎、不产生真实音频，所以「示例能播」证明不了
AVPlayer 这条链。设置 → 诊断 → 播放自检会把内置 4 秒扫频 WAV 从 rawfile 落到沙箱，再走一遍真实
`openReal`（fs.open → fdSrc → prepared → playing），用来在任意设备上确认解码、音频焦点、长时任务都是活的。
自检曲追加到队尾，不会冲掉你正在听的队列。

### 3.1 密纹 Pro（v1.1 新增）

一次买断制的付费解锁，不加订阅、不做联网校验。当前实装三个文件：`pages/ProPage.ets`（购买页）、
`service/ProService.ets`（授权）、`service/AudioProbe.ets`（能力探测）。

**Pro 的第一个功能是「直出模式」而不是均衡器**，原因必须写在代码边上：

> 鸿蒙 SDK 对第三方只开放 `audio.AudioEffectMode` 两态（`EFFECT_NONE` / `EFFECT_DEFAULT`），
> 全 SDK 没有 `AudioEffectManager`、没有频段增益 API；`AudioLoopbackEqualizerPreset` 只作用于耳返。
> 所以做不了 10 段 EQ，能做到的是「旁路系统音效、让 PCM 原样输出」。

真机日志（设置 → 诊断 → 播放自检，开直出）：

```
state -> prepared
audioEffectMode=NONE      ← 必须在 play() 之前落，否则首曲仍走系统音效
state -> playing
```

**授权模型**（`ProService`）：

- `pro_owned` / `pro_since` / `pro_dev_grant` 三个 key 存在 preferences，状态同步到 AppStorage 的 `proOwned`；
- 正版走华为应用市场 IAP 的非消耗型商品（未接），**开发版授权**用于真机上把"锁 → 面板 → 解锁 → 功能可用"跑通；
- 两者都让功能可用，但设置页会如实显示"开发版授权"，避免拿没付钱的机器做验收把结论骗了；
- **上架前必须**：接 `@kit.IAPKit`、把 `grantDev()` 的入口用 `isDebug` 关掉、补 `queryOwnedPurchases` 的恢复购买。

音频能力探测的存在意义：把"能不能做 EQ"这个结论变成用户和自己设备都能验一遍的东西，
而不是停留在某份文档里的一句话。

### 3.2 文件夹树与多根目录（v1.1 新增）

**为什么必须有，而不是"锦上添花"**：这款 App 的用户大多从别处搬来一个现成的曲库，
标签经常是空的、乱码的、或者整张专辑都写成同一个歌手。这种库里，只有磁盘上的目录结构是可信的。
按标签浏览会把 3000 首挤进"未知专辑"，按文件夹浏览才能找回《Kind of Blue》。

实装四个文件：`model/RootDir.ets`、`service/RootService.ets`、`pages/RootsPage.ets`，
以及 `view/LibraryView.ets` 里新增的第三态视图与 `db/TrackStore.ets` 里的两个聚合查询。

**索引层只加了两个字段**（`Track`）：

| 字段 | 含义 | 为什么这样存 |
|---|---|---|
| `folder` | 相对所属根的目录路径，不含文件名，根下直接放的是空串 | 建树时只靠这一个字符串就能拼出层级；改目录名不会误伤标签 |
| `root_path` | 所属根目录的绝对路径 | 多根并存时按根过滤、按根清索引，不用再回到 URI 里解析 |

聚合在 SQL、建树在 ArkTS：

```
SELECT folder, COUNT(*), SUM(size) FROM track
WHERE source = ? AND root_path = ? GROUP BY folder     ← 一次查完
        ↓
buildTree(stats, curPath)                              ← 拍平成"当前这一层"
```

没有用递归 CTE：一个曲库的目录数通常几十到几百，一次取全再拼层级更好调试，
而且能顺手把「含子孙的总数」和「本层直接数」分别算对 —— 用户点进某个目录之前，
想知道的就是"里面一共有多少首"。

**多根目录的三条边界**（`RootService.add` 的返回值就是这三种）：

| 情况 | 处理 | 不这样做的后果 |
|---|---|---|
| path 已存在（重装后重新授权同一个目录，uri 变了） | 只更新 uri，不新增条目 | 同一个目录出现两行，各扫各的 |
| 新目录是某个已有根的子目录 | 拒绝，并在界面上说清楚 | 同一首歌被算两个根，统计和移除都会出错 |
| 新目录是某个已有根的父目录 | 允许，并把被包含的子根收编 | 重扫时父子两边各写一遍 `root_path`，归属打架 |

启动时 `RootService.list()` 还会顺手清掉历史遗留的嵌套根（只摘显示，不动索引）。

**重新授权是本轮最有价值的一条路径**。鸿蒙的 `fileShare.persistPermission` 在应用重装后会失效，
表现是每首歌 `fs.open` 都返回 `13900001`，而数据库里几千首索引完好无损。
`RootsPage` 的"重新授权"就是让用户重选一次同一个目录：`uri` 变了、`path` 不变，
`RootService` 按 path 把新授权配回旧记录 —— **不重扫、不丢歌单、不需要联网**。

真机日志（重装后先看到失效，重新授权后恢复）：

```
probe /storage/Users/currentUser/Download failed code=13900001    ← 重装后授权丢失
picked file://docs/storage/Users/currentUser/Download
found 3 audio files under /storage/Users/currentUser/Download     ← 授权恢复，不重扫也能播
```

**老索引的一次性修复**：1.0 建的索引没有 `root_path` / `folder`，
升级后会出现"设置页显示 3 首、文件夹页显示 0 首"的矛盾。
`TrackStore.adoptOrphans` 在启动时把无主记录认给唯一的根（只在恰好一个根时执行 ——
多根时无从判断归属，猜错比空着更糟）。真机日志：

```
adopted 3 orphan rows
adopted 3/3 orphan tracks
```

**文件夹视图的两条交互约定**：

- 搜索框和格式筛选在这个视图下**收起**。搜索走标签、文件夹走目录，是两条不同的路，
  并排放在一屏会让用户以为"搜了但树没变是坏了"。
- 面包屑每一段都可点回退；`播放全部 N` 播的是**整棵子树**（`pageUnder`，上限 500 首），
  当前层直接放的曲目单独列在「本层曲目」小标下面。

---

## 4. 播放内核

```
UI（Home/Library/Collection/Player/MiniPlayer）
        │  onChange(snapshot)  ← 每 160ms 最多一次；状态变更立即推
        ▼
   PlayerCore（单例）
   ├─ local 引擎：media.AVPlayer，一首一个实例，切歌先摘引用再 release
   ├─ native 引擎：libmiwen.so 解 PCM → AudioRenderer.on('writeData')（v1.3.3，AIFF/AIFC/WavPack/ALAC/APE）
   └─ demo 引擎：200ms 计时器推进度（示例曲库没有真实文件）
   ├─ AVSession：metadata + playbackState（起播前先置 BUFFERING）
   ├─ backgroundTaskManager：AUDIO_PLAYBACK 长时任务，与播放态成对申请/释放
   ├─ 音频焦点：DUCK 降到 30%，PAUSE 暂停，RESUME 续播
   └─ preferences：队列 uri / 下标 / 位置 → 下次启动断点续播
```

要点（都是踩过的坑）：

- **AVPlayer 状态机**必须按 `idle → initialized → prepared → playing` 走，所有迁移集中在 `onState`；旧实例的迟到回调用 `p !== this.player` 拦掉。
- **起播前先置 BUFFERING**，否则播控中心的进度条会先走一段再回退。
- **DUCK 不是暂停**：导航播报时降到 30%，播报结束恢复 1.0；来电才暂停，挂断后从原位置继续。
- **长时任务**只申请 `audioPlayback`；暂停即释放，避免后台权限空占。
- **异常策略**：解码/文件失效 → 状态置 `error` + 页面顶部错误条 + 1.8s 后自动跳下一首；连续 3 首失败才停下，不会无限跳过。
- **示例引擎**是刻意的设计：没有真实音频也能验收播放/暂停/进度/上下曲/模式，换成真实曲库后自动走 AVPlayer。
- **示例曲不申请长时任务**（`startBgTask` 里 `isDemo` 直接返回）：它没有 AVPlayer，占了后台权限也不会出声。实机日志可区分——真实播放是 `hasBackgroundTask:1, isFreeze:0`，示例是 `0 / 1`。

### 4.1 自建解码链（v1.3.3）

系统解码器（AVCodec）解不了 APE / ALAC / WavPack / AIFF，所以这条链是"自己解、自己喂"：

```
Track → NativePlayer.open(path)
          └─ libmiwen.so: CreateSource() 按 magic 分派 → 解析格式头 → 返回
             { sampleRate, channels, bits, totalFrames, durationMs }
       → audio.createAudioRenderer(素材原采样率, F32LE)
       → renderer.on('writeData', buf) → decRead(id, frames) → 交错 float32 → memcpy 进 buf
       → PlayerCore 250ms 读 getPositionMs() 推进度（系统不会替我们发 timeUpdate）
```

几个刻意的取舍：

- **统一输出交错 float32**：四种格式内部表示不同（AIFF 大端整型、WavPack 整型/浮点、ALAC/APE 整型），统一到 float 之后 ArkTS 只认一种 `SAMPLE_FORMAT_F32LE`，不必每格式一条通道。
- **不做重采样**：素材采样率原样交给 AudioRenderer，不支持就报错。静默换成 48k 会变调——对发烧友来说变调比"播不了"更伤信任。
- **`write()` 已废弃**（API 11 起），必须用 `on('writeData')` 回调，由系统按需索要数据；回调里直接 `stop()` 会和音频线程互等，收尾放到 `setTimeout(0)`。
- **进度口径是"已写入帧数"**，比真实出声早约一个缓冲区（100~200ms），与 AVPlayer 侧观感一致。
- **直出照样生效**：AudioRenderer 也有 `setAudioEffectMode`，原生通道同样能旁路 Histen（真机日志 `audioEffectMode=NONE`）。
- **音频焦点要自己听**：没有 AVPlayer 就没有替我们申请焦点的对象，必须 `renderer.on('audioInterrupt')`，DUCK→音量 25%，PAUSE/STOP→暂停，RESUME→续播。
- **NAPI 导出的是句柄（number）而不是指针**：JS 侧不能长期持有 native 指针，句柄表在 .so 内，`close` 时删表并 `delete`。
- **`open` 同步、`read` 同步**：一次 100ms 数据，AIFF 只是 memcpy + 整型转 float，微秒级；WavPack 真机实测单次解码远低于 5ms，暂不需要 async work。

自检入口：设置 → 诊断 → **原生解码自检**。现场生成 8 秒 AIFF（四段 440/660/880/1100 Hz），听到四个依次升高的音说明字节序、声道、位深全对。

**WavPack 专有的两个取舍**（v1.3.1，详见验证报告第十三节）：

- **内嵌官方 libwavpack 5.8.1**（BSD-3，附原 `COPYING`）：WavPack 的熵解码不可能自写，裁掉 DSD 与手写汇编（arm64 走纯 C）后 24 个 `.c` 直接编译进 `libmiwen.so`（strip 后 466,992 字节）。
- **seek 失败后走「关掉重建 + 顺序解码」**：libwavpack 官方注释写明 `WavpackSeekSample64` 返回 FALSE 是 fatal——失败前已 `free_streams`，继续读会输出错位数据（实测 rms 从 0.212 掉到 0.143）。所以无 block index 的文件 seek 先重建上下文再解到目标帧，上限 5 分钟音频，超过则回开头而不假报位置。

**ALAC 专有的两个取舍**（v1.3.2，详见验证报告第十四节）：

- **内嵌 Apple 官方解码器**（Apache-2.0，随源附原 LICENSE）+ 自写 MP4 容器解析（stsd 的 magic cookie 直接喂 `ALACDecoder::Init`；stsz/stsc/stco 联合算出每帧字节位置）。`EndianPortable.c` 原版漏判 aarch64 已补。
- **m4a 是容器不是格式**：AAC/MP3 也走 .m4a。native 打开发现不是 ALAC 就报「mp4 容器非 ALAC」，PlayerCore 据此自动回退 AVPlayer——AAC m4a 用户无感，ALAC m4a 走真解码。

**APE 专有的两个取舍**（v1.3.3，详见验证报告第十五节）：

- **内嵌 Monkey's Audio 官方 MACLib 13.50**（3-Clause BSD，随源附原 License.txt，© 2000-2027 Matthew T. Ashland）：解码入口 `CreateIAPEDecompress`（`GetUTFNFromUTF8` 转 wchar 路径），按官方 CMake 库清单收源码——**Prepare / WAVInputSource / APECompressCreate 三个"看着像编码侧"的文件被解码路径引用符号，裁掉就链接失败**，实测必须保留；`All.h` 必须先于 `MACLib.h` 包含（`uint16/uint32/str_utfn` 别名都在里面）。arm64 自动走官方 `NNFilterNeon.cpp`。
- **官方 `CAPEDecompress::Seek` 是真·快速定位**（按 `BLOCKS_PER_FRAME` 算目标帧直接跳），不像 ALAC 要重建顺序解码；APL/Link 文件（magic `MACF`）也接了，音频主体在外部时由 MACLib 报错误码。位深只接 8/16/24/32（文件头真实取值集合），其他位深明确报暂不支持。

已知边界（v1.3.3）：已接 AIFF/AIFC/WavPack/ALAC/**APE**（Pro 2.0「全格式真解码」清单完成）；ALAC 多声道 >2 明确报暂不支持、CAF 容器未接、加密 m4a 未处理；曲库列表的 m4a 时长列暂显示 00:00（扫描侧不解析 mp4 标签，点播后以解码器为准）；WavPack 的 `.wvc`/hybrid 接线正确但未实测；DSD 编码的 `.wv` 明确报「暂不支持」；CUE 分轨暂不支持原生格式（时间片要裁 PCM）；采样率 8k–192k 之外不支持。

### 4.2 ArkUI 真机坑（2026-11-24 实机踩到）
这些在编译期全绿、只有在设备上才暴露：

- **`width('100%')` 会撑坏自动宽度的容器**：`Column(){ Text; Row().width('100%') }` 里的 Row 会按父容器 100% 展开，导致整列占满一行、后面的页签被挤出屏幕（表现为"四个排序只剩一个"）。下划线一类的装饰改用 `Text.border({width:{bottom:1}})`，宽度随内容走。
- **`▶`(U+25B6) 会走 emoji 字体**：鸿蒙上渲染成系统蓝色圆角方块，直接违反"禁用 Material 蓝 / 禁用圆角"。播控图标必须用形状自绘（见 `components/PlayPauseGlyph.ets`）。
- **`Path().commands()` 的坐标不随 width/height 缩放**：同样的尺寸参数在真机上画出来只有一半大小，还会偏位。画三角形用 `Polygon().points()`。
- **`@Builder` 的参数按值传递会被冻结**：把 `${this.count} 首` 传进 builder，之后 count 变了也不刷新。会变的值要么写成无参 builder 直读状态，要么抽成 `@Component`（`@Prop` 会同步）。
- **`@Watch` 挂 async 方法不触发**：`@Watch('reload')` 配 `async reload()` 静默失效，必须挂一个同步方法再在里面调异步。
- **系统栏图标色必须在窗口层改**：页面配色靠 AppStorage 换，但状态栏图标归 `setWindowSystemBarProperties` 管；不跟着换，浅色主题下就是白字压白底。
- **`@Prop size` 与 CustomComponent 内置属性冲突**（`offset`、`key` 同理），改名即可，报错信息是 `is not assignable to the same property in base type 'CustomComponent'`。
- **页面进来必须主动拉一次快照**：只 `onChange` 订阅是不够的。内核只在"状态变化"时通知，而"解码失败""暂停"这类静置状态不会再发；不拉 `snapshot()` 的话页面停在空快照上，错误横幅永远不出现（`PlayerPage` / `MiniPlayer` / `Index` 三处都补了首拉）。
- **`mediaImage` 不要传应用沙箱路径**：不传只打一行 `img uri empty`（语义就是"这首没图"）；传 `file:///data/storage/...` 反而更糟——媒体层会拿 curl 去下载，报 `URL using bad/illegal format` + `DoDownload failed` + `not repeat setmetadata again`。想让播控中心真出图得给媒体库 uri，要 `READ_IMAGEVIDEO` 权限，与"零权限"定位冲突，所以这版直接不传。
- **`ForEach` 的 key 必须包含"会变的那部分"**：根目录卡片的 key 原先只用 `path`，而重新授权后 `path` 不变、只有 `uri` / 可读状态变了，`ForEach` 判定"这一项没变"就复用旧子组件，`@Prop` 永远收不到新值 —— 真机上表现为状态标签一直停在"需重新授权"，但日志里 `probe` 明明已经成功。key 改成 `path_alive_count` 才修好。同理，文件夹行的 key 要带上 `total`，否则重扫后曲目数不更新。
- **`padding` 是覆盖语义，连写两次只有最后一次生效**：`padding({top,bottom}).border(...).padding({left})` 会让上下留白凭空消失。一次给全。

---

## 5. 数据层

`miwen.db`（RDB，单库多表）：

| 表 | 主键 | 说明 |
|---|---|---|
| `track` | `uri` UNIQUE | 曲目索引；`source` 区分 `local` / `demo`；`mtime` 用于"最近添加" |
| `favorite` | `uri` | 收藏，`added_at` 排序 |
| `playlist` | `id` | 歌单名与更新时间 |
| `playlist_track` | `(playlist_id, uri)` | 歌单内容，`ord` 保序 |
| `recent` | `uri` | 最近播放，最多保留 50 条 |

约束：

- 任何列表都走 `LIMIT/OFFSET`，**禁止全量 SELECT**。
- 写入用 `INSERT OR REPLACE`（不依赖 upsert 语法；`id` 不参与任何关联，换 id 无副作用）。
- 收藏 / 歌单只存 uri，曲目元数据变化时不会出现"歌单里还是旧标题"。
- 示例数据与真实数据同一张表、靠 `source` 隔离：切来源只换查询条件，不复制一套代码。

---

## 6. 视觉规范（代码即规范）

`common/Theme.ets` 是唯一色源，页面不写死色值。

| 令牌 | 暗夜（默认） | 白纸 | 磁带 |
|---|---|---|---|
| `bg` | `#0B0B0D` | `#FBF9F6` | `#1A1512` |
| `surface` | `#141416` | `#FFFFFF` | `#221B16` |
| `text` | `#F4EFE6` | `#17171A` | `#F0E3CE` |
| `accent` | `#C8A96A` | `#A8792E` | `#C8A96A` |
| `groove` | `#26262B` | `#E7DFD2` | `#3A2E24` |

- 铜金只用于**落针点、进度、当前项、主按钮**，不铺面积、不做渐变。
- 圆角只用 0 / 0.5 / 1vp；卡片不做圆角堆叠与投影（杂志感，不要安卓味）。
- 没有封面时不摆灰块：按专辑名散列取一个旧纸色，叠 3 圈铜色沟槽 + 首字烫印，纯本地绘制。
- 封套分两档：`>= 56vp` 画刊头（线 + 专辑名 + 艺人），`< 56vp`（列表行 42、迷你条 38）传 `compact: true` 整块省掉，只留一枚 17vp 首字——那个尺寸下刊头只会糊成墨点。
- 播放页：环 300vp、封面 236vp、歌词两行、进度条 1.2vp，一屏只有一个亮的东西。

---

## 7. 布局适配

`UiEnv` 用两条 mediaquery（600 / 840vp）把断点写进 `AppStorage('bp')`，页面用 `@StorageProp` 订阅。

| 断点 | 宽度 | 封面墙 | 页面留白 | 播放页 |
|---|---|---|---|---|
| `sm` | < 600vp | 2 列 | 20vp | 单列（环 + 信息 + 控制） |
| `md` | 600–840vp | 4 列 | 32vp | 左右分栏 |
| `lg` | ≥ 840vp | 5 列 | 32vp | 左右分栏，封面 340vp |

- 沉浸式：`EntryAbility` 开全屏后用 `getWindowAvoidArea(TYPE_SYSTEM)` 取状态栏/手势条高度，换算 vp 写进 `AppStorage('topInset' / 'bottomInset')`，页面按它留白。
- 列表与 Grid 都用 `LazyForEach` + `cachedCount`，旋转/折叠展开后列数变化不会重建数据。

---

## 8. 性能预算

| 场景 | 做法 | 预期 |
|---|---|---|
| 5000 首首屏 | 首屏只查 60 条（`PAGE_SIZE`），列表先出、标签后台补 | 列表可交互 < 1s，不随曲库线性变慢 |
| 标签解析 | `taskpool.execute(parseTags, head, suffix)`，主线程只做 IO；每 20 个文件让一次主线程 | 扫描时 UI 不掉帧 |
| 封面 | 解析出的图落盘 `cacheDir/covers/<hash>_<mtime>.jpg`，二次进入不再解码 | 列表滚动无重复 IO |
| 进度刷新 | `timeUpdate` → 160ms 节流通知 UI；播控状态 500ms 同步一次 | 每秒 ≤ 6 次状态替换 |
| 列表 | `LazyForEach` + `cachedCount(4~6)`；搜索 260ms 防抖 + 请求序号丢弃过期结果 | 快速输入不闪烁 |
| 内存 | 封面缩略图按需加载，原图只在播放页使用；`Bitmap` 不常驻 | 长列表滚动稳定 |

---

## 9. 验收清单

> 2026-11-24 已在 HUAWEI MLN-AL00（HarmonyOS 7.0.0.111 / API 26）实机跑过一遍，
> 逐条结论、发现的问题与修复见 [`docs/密纹音乐-真机验证报告.md`](docs/密纹音乐-真机验证报告.md)。
> 下表 `[x]` 为实机已确认，`[ ]` 为需要你用自己的音乐目录复核的项。

### 9.1 首页
- [x] 首次启动有 22 首示例唱片，封面墙按专辑铺开，不出现空白灰块
- [ ] 点「换成我的」→ 选目录 → 顶部出现"正在整理 x/y" → 完成后墙刷新
- [x] 点一张封套 → 进入专辑列表；点封面墙外的「全部曲目」→ 切到曲库 tab
- [x] 无曲库时显示空态（一句话 + 两个动作），不是空白页

### 9.2 浏览 / 搜索
- [x] 搜索"夜"能命中标题/艺人/专辑；清空后恢复全量
- [x] 排序切换（最近添加 / 标题 / 艺人 / 采样率）立即重排
- [x] 格式筛选（FLAC / MP3 / …）只显示对应格式；命中 0 条时空态文案正确
- [x] 列表行右侧常显「FLAC · 96 kHz + 时长」，正在播放行标题转铜色并带竖线
- [ ] 滚动到底自动加载下一页，底部提示"共 n 首，已全部显示"
- [ ] 长按任一行弹出面板：播放 / 下一首播放 / 加入队列 / 收藏 / 查看专辑 / 文件信息

### 9.3 文件夹视图 / 多根目录（v1.1）
- [x] 曲库右上「列表 / 封面 / 文件夹」三态切换，选择会被记住
- [x] 文件夹视图下搜索框与格式筛选收起，面包屑每段可点回退
- [x] 子目录行显示「N 首 · M 个子目录」，其中 N 含所有子孙
- [x] 进入子目录后「本层曲目」只列直接放在这一层的文件
- [x] 「播放全部 N」播整棵子树，上限 500 首
- [x] 设置 → 音乐文件夹：多根列表、状态标签（可读 / 需重新授权）、单根重扫、全部重扫、移除
- [x] 移除目录二次确认，只清该根索引，磁盘文件不动；移除最后一个根时整库归零并回到空态
- [x] 重装后目录授权失效 → 卡片标"需重新授权" → 重新授权同一个目录即恢复，不用重扫
- [x] 添加一个已被父目录覆盖的子目录 → 拒绝并提示，不会让同一首歌属于两个根
- [x] 1.0 索引升级：启动时自动补齐 `root_path` / `folder`，管理页不再显示 0 首
- [x] 白纸主题下文件夹视图无白字压白底

### 9.4 播放器
- [ ] 起播前显示"正在读取…"，进度条不先走再回退
- [x] 播放/暂停图标正确切换；上一首在 3 秒内回到上一曲，3 秒后回到本曲开头
- [x] 拖动进度条：拖动时进度不被播放位置覆盖，松手后 seek 生效
- [x] 沟槽环随进度增长，落针点落在环末端；切歌后归零
- [x] 有 `.lrc` 时逐行高亮（当前行 + 下一行）；没有时提示"本地没有同名 .lrc"
- [x] 模式按钮循环切换 列表 / 单曲 / 随机，杀进程后仍保留
- [x] 收藏键切换后，「我的 → 收藏」立即出现该曲
- [x] 顶部「队列 3/22」可进入队列页，队列里可删除单曲

### 9.5 歌单 / 收藏 / 最近
- [x] 收藏页「播放全部」「随机」都能起播；空态引导去曲库
- [ ] 新建歌单 → 输入名字 → 建立；长按歌单行以外的「⋯」可重命名 / 删除
- [ ] 曲库长按「加入歌单…」能把歌加进指定歌单，数量即时更新
- [ ] 最近播放最多 50 条，「清空记录」只清记录不删文件

### 9.6 设置
- [x] 三套主题切换立即生效，重启后保留；白纸主题下文字对比度正常（状态栏图标随主题反色）
- [x] 「全部重新扫描」有进度提示；「清空曲库索引」二次确认，且不动磁盘文件（重启后仍为 0 首）
- [ ] 「载入示例曲库」可反复切回示例（已验）；「音乐文件夹 → 添加」后自动切回本机来源（待你用真实目录验）
- [x] 睡眠定时到点只暂停；「模拟播放异常」能触发错误条并自动跳下一首（提示停留 2.5s）

### 9.7 状态同步 / 异常 / 空态
- [x] 首页迷你条、播放页、播控中心三处状态一致（曲名、播放态、进度）
- [ ] 删除正在播放的文件再播放 → 错误条 + 自动跳下一首；连续失败会停下
- [x] 下拉/切 tab 后迷你条仍显示当前曲目，进度不断
- [x] 杀进程重进：队列与进度恢复，状态为暂停（不自动出声）

### 9.8 适配与性能
- [x] 手机竖屏：封面墙 2 列，播放页单列
- [ ] 折叠展开 / 平板：封面墙 4 列；播放页左右分栏，控制区不被拉宽
- [ ] 鸿蒙 PC 窗口放大：内容宽度受限，不出现一行 2000px 的文字
- [ ] 5000 首曲库：首屏 < 3s 出列表，滚动不掉帧，搜索不卡输入
- [x] 权限列表里**没有** `ohos.permission.INTERNET`

### 9.9 v1.5.0 三项收官（DST / SACD ISO / 标签回写）
- [x] DST 解压：DFF（CMPR=DST）真机播放，`dsd-dst-1.dff`（450 帧全算术）整首播完自动接续；`dsd-dst-fir.dff`（10 帧 FIR 帧）时长 133ms 精确
- [x] SACD ISO 直读：`sacd-test.iso` 扫描后曲库出现虚拟曲目「Miwen Track A」（艺人行 = ISO 内 SACDText 的 "Miwen Audio · Miwen SACD Test"、格式 ISO · 88.2 kHz、时长 00:06），点播全链路播放正常
- [x] 文件标签回写：维护页批量改标签 + 「同时回写到文件」→ FLAC 写 Vorbis comment、MP3 写 ID3v2.3，拉回文件独立解析验证标签正确、音频流逐字节不动；非 FLAC/MP3 自动跳过并计数
- [x] 回写失败路径如实：目录授权失效时 Toast 报「失败 N（打不开文件…）」，不假成功
- [x] 目录授权失效（杀进程/重装）→ 重新授权即恢复，无需重扫

### 9.10 v1.6.0 第三梯队收官（年度报告 / 强调色）✅ 2026-11-25 真机验证
- [x] 年度听歌报告：统计页出现「年度报告」区（YEARLY REPORT），年份 chip「2026」，四格（808 次 / 1 小时 42 分 / 36 首 / 2 天）与 12 月柱状图（仅 11 月非零，与记录自 2026.11.24 一致）、年度 TOP5（第二轨 145 次起）完整渲染；「存成长图」走系统保存对话框存入 Download，photoAccessHelper 媒体库写入日志确认（shell 域无权读用户 Download、图库有应用锁，文件内容未直接回读——保留此边界记录）
- [x] 自定义强调色：设置→外观→强调色出现八色板 + 跟随主题；钉住封套蓝紫后全 App 即时变色（设置 tab 下划线、分区标题、播放条箭头、主题选中圆点、年度 chip 与柱状图均换色，色板选中块加粗白边框）；切到白纸浅色主题后钉住色保持且无文字不可读；force-stop 重启后仍「已钉住」；Pro 已解锁用户钉住直接放行不扣试用次数

---

## 10. 已知边界（P0 刻意不做）

| 项 | 现状 | 原因 / 下一步 |
|---|---|---|
| APE / DSD / WavPack / AIFF | 能扫到、能入库，点播时给明确话术（`UNDECODED_SUFFIX`），不落到笼统格式错误 | 真解码（NAPI）与 DSD/DoP 顺延 Pro 2.0；PRO 2.0 落地后把这批挪回可播名单 |
| M4A / MP4 的 ilst 标签 | 未解析，标题落回文件名 | 与 ID3/FLAC 同一入口，P1 补 `moov/udta/meta/ilst` |
| GBK 标签 | 先试 GB18030，失败退 UTF-8，个别老文件会乱码 | P1 内置 GBK 映射表 |
| ~~CUE 分轨~~ | **已做（Pro 1.5）**：整轨按 CUE 拆虚拟轨，`cueStart/cueEnd` 存库，时间片定位 + 到点自动切 | CUE 与音频不同目录时靠三级配对兜底（按文件名全根找）；分轨歌词按片头裁窗平移（1.2.2），窗口内无词时提示「这一轨没有歌词」 |
| 桌面歌词 | **已做（Pro 1.5）**：API 23+ 原生 AVSession 桌面歌词，`isDesktopLyricSupported` 为假时隐藏入口；逐行高亮真机复核通过（换行时重推整份 LRC + 全量元数据） | 淡入淡出期间界面停在旧曲（新增对外显示暂存），旧曲静音后才结算；淡出期内 `pause/seek/next` 均已补结算 |
| 封面缓旋 | 未做（P0 封面静止，只做透明度呼吸） | 与进度环共用 Canvas 时逐帧动画会抢主线程，留给 P1 |
| 卡片实时刷新 | 切歌后调用 `formProvider.updateForm`，依赖已记录的 formId | 用户没加卡片时静默跳过；P1 用 `requestFormUpdate` + 定时刷新 |
| HiCar / 鸿蒙 PC 专属布局 | 未做 | P2，同一套曲库 |

---

## 11. 内容与合规模板

- 隐私政策只需三句：不收集任何用户数据、不上传任何文件、无账号。
- 应用内不出现「扫描全网」「在线音源」「免费听 VIP」等表述。
- 首次提交前在 AGC 查重应用名（同名不可上架，一年最多改 2 次），并核对商标 9 / 41 类。
- 受限权限 `FILE_ACCESS_PERSIST` 需在 AGC 申请，理由写「读取用户授权的本地音乐目录」。

---

## 12. 界面验收稿

[`docs/密纹音乐-界面验收稿.html`](docs/密纹音乐-界面验收稿.html)（浏览器直接打开）：5 个手机屏 + 1 个平板屏，可切暗夜/白纸/磁带。
色值、字号、间距与 `common/Theme.ets`、各页面 vp 数值对齐，改样式时两边一起改。
