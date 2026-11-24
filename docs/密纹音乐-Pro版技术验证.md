# 密纹音乐 · 密纹 Pro 技术验证与实装报告

- 验证日期：2026-11-24
- 版本：`1.1.0`（在 1.0.0 基础上新增 Pro 付费墙与直出模式）
- 设备：MLN-AL00 / HarmonyOS 7.0.0.111 / API 26 / 1256×2760
- 产物：`entry/build/default/outputs/default/entry-default-signed.hap`（1.35 MB），真机安装运行通过

---

## 一、结论先说

| 问题 | 结论 |
|---|---|
| 能不能做 10 段 EQ？ | **不能。** 鸿蒙对第三方只开放两种音效模式（开/关），没有频段增益接口 |
| 那 Pro 卖什么音质相关？ | **直出模式**：旁路系统音效链，PCM 原样输出。已实装、已真机验证 |
| 直出真的生效了吗？ | **生效。** 真机日志 `prepared → audioEffectMode=NONE → playing`，且必须先于 `play()` 落 |
| 付费墙跑通了吗？ | **跑通。** 设置页卡 → Pro 页 → 购买面板 → 体验授权 → 状态同步 → 功能解锁，全链路真机走通 |

**一句话**：Pro 不卖"调音"，卖"还原"。这不是退而求其次——只是把一句大话换成一句能兑现的话。

---

## 二、验证方法

两条独立的证据链，任何一条单独成立都不够：

1. **SDK 静态证据**：直接读鸿蒙 SDK 的 `.d.ts` 声明，确认有没有参数化音效接口；
2. **运行时证据**：在真机上调用 `getAudioEffectInfoArray()` 读系统实际开放的模式，再把 `audioEffectMode` 设成 `EFFECT_NONE`，从 hilog 确认落在 `prepared` 与 `playing` 之间。

第 2 条尤其重要——文档说"支持"，和这台机器上真的能设，是两件事。

---

## 三、SDK 层证据

| 检查项 | 结果 |
|---|---|
| 全 SDK 搜 `AudioEffectManager` / `createAudioEffectManager` | **0 条结果**（`sdk/default/openharmony/ets/api/` 全量 grep） |
| `audio.AudioEffectMode` 枚举 | 只有 `EFFECT_NONE = 0`、`EFFECT_DEFAULT = 1` 两个值（`@ohos.multimedia.audio.d.ts:7852`） |
| `getAudioEffectInfoArray(usage)` | 存在，但返回类型是 `Array<Readonly<AudioEffectMode>>`，即"支持哪几种模式"，不返回任何频段/增益数据；且它在 `AudioStreamManager` 上，不在 `AudioManager` 上（`audio.d.ts:2981`）——第一次写错就在这里吃了编译错误 |
| `AudioLoopbackEqualizerPreset` / `setEqualizerPreset` | 存在，但属于 **AudioLoopback（耳返）**，只影响返听通路，不影响播放输出（`audio.d.ts:8459`） |
| `AVPlayer.audioEffectMode` | 存在，可写，但只能取上面那两个值（`@ohos.multimedia.media.d.ts:2997`） |

也就是说：第三方能做的只有"用系统音效 / 不用系统音效"，中间那 10 根推子，系统没给。

---

## 四、运行时证据

### 4.1 系统实际开放的模式

设置 → 诊断 → 音频能力探测，真机返回：

```
NONE / DEFAULT · 仅开放「关/默认」两态，无频段增益通道
```

（截图：`.verify/pro-11-probe.jpeg`）

`getAudioEffectInfoArray(STREAM_USAGE_MUSIC)` 返回长度 2，与 SDK 声明完全一致。这条同时证明了另一件事：**探测代码本身是有效的**，将来系统若开放多档模式，这个探测会立刻读出来，`eq` 标志会自动变 true。

### 4.2 直出是否真的落在播放链上

播放自检（内置 4 秒扫频走真实 `openReal`）时的 hilog：

```
11-24 12:54:19.313  I  PlayerCore: state -> initialized
11-24 12:54:19.464  I  PlayerCore: state -> prepared
11-24 12:54:19.464  I  PlayerCore: audioEffectMode=NONE     ← 直出在这里落下
11-24 12:54:19.480  I  PlayerCore: state -> playing
11-24 12:54:19.501  I  PlayerCore: background audio task started
11-24 12:54:23.441  I  PlayerCore: state -> completed
```

关键点有两个：

- **顺序正确**：`audioEffectMode` 在 `prepared` 之后、`playing` 之前设置。系统文档要求首次生效必须在 `play()` 前，晚了就只对下一首有效。
- **可重复**：12:55:52 与 12:57:17 两次自检都稳定输出 `audioEffectMode=NONE`。

### 4.3 没有播放器时的行为

```
12:50:29.330  I  PlayerCore: direct -> ON applied=false
```

没在播时切直出，偏好已经存下，但当前没有 AVPlayer 实例可设。**这里发现了第一个 UI 缺陷**：原本文案写"当前播放状态不允许切换，稍后再试"——这是错的，跟事实相反（偏好已存，下一首就生效）。已改成：

> 直出已开启，下一首起生效

一个说反话的提示，比没有提示更伤人。

---

## 五、已实装内容

| 文件 | 作用 |
|---|---|
| `service/ProService.ets`（新） | Pro 授权状态：`isPro / since / grantDev / revoke / restoreToStorage`。区分"正版"与"开发版授权"，避免拿一台没付钱的机器做验收把结论骗了 |
| `service/AudioProbe.ets`（新） | 音频能力探测，把第 4.1 节的结论做成用户可点的诊断项 |
| `pages/ProPage.ets`（新） | Pro 购买页：标识区、四条承诺、三组功能清单（已解锁/下个版本/规划中）、价格、解锁按钮、恢复购买、脚注 |
| `service/PlayerCore.ets` | `setDirectMode / directMode / applyEffect`；在 `onState('prepared')` 里落音效模式 |
| `view/SettingsView.ets` | 顶部 Pro 卡（未解锁/已解锁两态）、播放区「直出模式」行（Pro 锁）、诊断区「音频能力探测」行 |
| `service/SettingsService.ets` | 新增 `getStr / setStr` 通用访问器与 `direct / setDirect` |
| `entryability/EntryAbility.ets` | 启动时 `ProService.restoreToStorage()`，避免设置页首帧闪"未解锁" |
| `common/Constants.ets` | Pro 相关 key 与价格常量；`VERSION` 提到 `1.1.0` |

### 交互流程（全部真机点过）

| 步骤 | 结果 | 截图 |
|---|---|---|
| 设置页出现 Pro 卡（未解锁） | 左侧铜金竖线、`密纹 PRO` + `未解锁` | `.verify/pro-02-settings.jpeg` |
| 点卡进 Pro 页 | 标识区、承诺、功能清单正常 | `.verify/pro-03-propage.jpeg` |
| 滚到价格区 | ¥18 大号铜金 + ¥28 删除线 + 铜金主按钮（无圆角） | `.verify/pro-04-price.jpeg` |
| 点解锁 | 底部面板：体验授权（不扣费）/ 去应用市场购买（即将开放）/ 取消 | `.verify/pro-05-panel.jpeg` |
| 选体验授权 | 出现「已解锁 · 开发版授权 2026-11-24」横条 | `.verify/pro-08-top.jpeg` |
| 返回设置页 | Pro 卡变「已解锁 / 直出模式已可用」 | `.verify/pro-09-settings-on.jpeg` |
| 直出模式从 PRO 变可点 | 值显示 `开/关`，说明文字换成实际行为 | `.verify/pro-16-direct.jpeg` |
| 撤销授权 | 面板第二项可撤销，撤销后直出自动关闭 | 逻辑已验，未截图 |

### 顺手修掉的两个问题

1. **Pro 页顶部被状态栏压住**：「MIWEN PRO」和状态栏图标叠在一起。原因是独立页面没有让出 `topInset`。已加 `padding({ top: this.topInset + 4 })`，复验通过（`.verify/v2-09-propage-top.jpeg`）。
2. **直出开关的提示文案说反话**：见第 4.3 节，已修。

---

## 六、遗留问题

| 问题 | 说明 | 建议 |
|---|---|---|
| **IAP 未接** | 购买面板走"体验授权"，不产生扣费。正版链路要等应用市场配好非消耗型商品 | 上架前接 `@kit.IAPKit`，并把"体验授权"入口用 `isDebug` 关掉 |
| **恢复购买是空实现** | 只弹提示。接了 IAP 才有 `queryOwnedPurchases` 可调 | 与上一条同批做 |
| **重装丢目录授权** | 重装后曲库索引还在，但每首歌 `fs.open` 都返回 `13900001`，表现为"点不动" | 错误条文案里给出"重新选择音乐文件夹"的直达入口（**待做**，这是本次验证中新发现的） |
| **试用次数** | 规划里写了"Pro 功能可用 3 次"，本次未实现，直出是硬锁 | 等有"可量化"的功能（导入、导出）再做试用，开关型功能做试用体验很割裂 |
| 对照组未截 | 关闭直出后的 `audioEffectMode=DEFAULT` 没单独抓日志 | 走的是同一个三元表达式另一分支，风险低；下次回归顺手补 |

---

## 七、对产品规划的影响

1. **EQ 从 Pro 清单撤下**，第一梯队门面换成直出模式。已在《密纹音乐-付费版功能规划.md》第〇节、第一梯队、不做清单、验收口径、风险四处同步修订。
2. **Pro 的话术基准变了**：从"你能调出自己喜欢的声音"改成"你听到的是文件里原本的声音"。后者更窄，但对这行用户更硬。
3. **付费墙的形态已验证可行**：本地授权 + 状态广播 + 就地锁，不依赖任何服务端，符合零联网定位。接 IAP 时只需替换 `grantDev()` 的实现，页面一行不用改。
