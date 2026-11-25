import { router, promptAction } from '@kit.ArkUI';
import { Const } from '../common/Constants';
import { Theme, Tokens } from '../common/Theme';
import { Logger } from '../common/Logger';
import { ProService } from '../service/ProService';
import { PlayerCore } from '../service/PlayerCore';
import { ActionPanel, ActionItem } from '../components/ActionPanel';

const TAG: string = 'ProPage';

/** 一条 Pro 功能 */
interface ProFeat {
  name: string;
  desc: string;
  tag: string;
}

/**
 * 密纹 Pro 购买页。
 *
 * 版式照抄这本"纸面"的规矩：没有圆角卡片、没有渐变、没有图标库，
 * 靠字号层级 + 发丝线 + 铜金单色建立秩序。
 *
 * 内容上有一条自我约束：**不做"规划中"的功能吹成"已支持"**。
 * 解锁页写得越实在，退款和差评越少——尤其这行用户是被"离线、诚实"吸引来的。
 */
@Entry
@Component
struct ProPage {
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('bp') bp: string = Const.BP_SM;
  @StorageProp('proOwned') proOwned: boolean = false;
  // 沉浸式全屏下状态栏会盖住返回栏，必须自己让出安全区
  @StorageProp('topInset') topInset: number = 0;

  @State panelOpen: boolean = false;
  @State panelItems: ActionItem[] = [];

  private core: PlayerCore = PlayerCore.instance();

  private readonly featNow: ProFeat[] = [
    { name: '直出模式', desc: '旁路系统音效，PCM 原样送到输出', tag: '已实装' },
    { name: '主题包', desc: '黑胶 · 夜航 · 牛皮纸 · 高对比（无障碍）', tag: '已实装' },
    { name: '歌词增强', desc: '读文件内嵌歌词、双语双行、时间轴 ±0.5s 微调', tag: '已实装' },
    { name: 'M3U 与备份还原', desc: '歌单导入导出，索引与收藏备份成单个 zip', tag: '已实装' },
    { name: 'A-B 循环', desc: '任意两点反复听，学乐器扒谱用', tag: '已实装' },
    { name: '听歌统计', desc: '起播次数、收听时长、趋势图，可存成长图', tag: '已实装' },
    { name: '卡片矩阵', desc: '封面墙三档密度：大卡 / 标准 / 密集', tag: '已实装' },
    { name: 'CUE 整轨分轨', desc: '一张整轨 + 一个 CUE，拆成可点播的轨，播放按时间片定位', tag: '已实装' },
    { name: '无缝播放', desc: '双播放器预加载提前切流，或 3 秒交叉淡入淡出', tag: '已实装' },
    { name: '桌面歌词', desc: '系统桌面歌词 + 锁屏歌词 + 播控中心歌词，一份数据三处显示', tag: '已实装' },
    { name: '自建解码链 · AIFF', desc: '系统解不了的自己解：AIFF / AIFC 直解 PCM 输出', tag: '已实装' },
    { name: '自建解码链 · WavPack', desc: '内嵌 libwavpack：.wv 无损 / hybrid，.wvc 校正文件一并挂上', tag: '已实装' },
    { name: '自建解码链 · ALAC', desc: '内嵌 Apple 官方解码器：m4a 里的 ALAC 直解；AAC 仍走系统', tag: '已实装' },
    { name: '自建解码链 · APE', desc: '内嵌 Monkey\'s Audio 官方 MACLib（3-Clause BSD）：官方快速 Seek，全格式解码完成', tag: '已实装' }
  ];

  private readonly featNext: ProFeat[] = [
    { name: '变速不变调', desc: '0.5–2.0× 变速，音高不动（依赖自建解码链）', tag: '下一梯队' },
    { name: 'DSD 直读', desc: 'dsf / dff / ISO 解码与 DoP 输出提示', tag: 'Pro 2.0' }
  ];

  private readonly featLater: ProFeat[] = [
    { name: 'DSD 直读', desc: 'dsf / dff / ISO 解码与 DoP 输出，依赖解码链扩展', tag: '规划中' },
    { name: '标签编辑', desc: '在密纹里改标题与封面，不装第二个应用', tag: '规划中' }
  ];

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  aboutToAppear(): void {
    this.proOwned = ProService.isPro();
  }

  // ---------------- 动作 ----------------

  private openBuy(): void {
    if (this.proOwned) {
      this.openManage();
      return;
    }
    this.panelItems = [
      { label: '体验授权（开发版）', hint: '不扣费', danger: false },
      { label: '去应用市场购买', hint: '即将开放', danger: false }
    ];
    this.panelOpen = true;
  }

  private openManage(): void {
    if (ProService.isDevGrant()) {
      this.panelItems = [
        { label: '已解锁（开发版授权）', hint: ProService.since(), danger: false },
        { label: '撤销授权，重新验收', hint: '仅开发版', danger: true }
      ];
      this.panelOpen = true;
      return;
    }
    promptAction.showToast({ message: `密纹 Pro 已解锁 · ${ProService.since()}`, duration: 2400 });
  }

  private onPick(i: number): void {
    this.panelOpen = false;
    if (this.proOwned) {
      if (i === 1) {
        ProService.revoke();
        // 撤销后直出模式必须跟着关掉，否则用户拿到的是"没付费却仍生效"的状态
        this.core.setDirectMode(false);
        promptAction.showToast({ message: '已撤销授权，直出模式已关闭' });
        Logger.info(TAG, 'revoke done');
      }
      return;
    }
    if (i === 0) {
      ProService.grantDev();
      promptAction.showToast({ message: '已启用体验授权，Pro 功能全部可用', duration: 2600 });
      Logger.info(TAG, 'dev grant from page');
      return;
    }
    promptAction.showToast({ message: '应用市场商品还没配，先用体验授权验收', duration: 2800 });
  }

  private restore(): void {
    if (this.proOwned) {
      promptAction.showToast({ message: `已解锁 · ${ProService.since()}` });
      return;
    }
    promptAction.showToast({ message: '恢复购买需要接入应用市场支付，当前版本暂无正版凭证', duration: 2800 });
  }

  // ---------------- 组件 ----------------

  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor(this.c().dim)
        .width(40)
        .onClick(() => router.back())
      Blank()
      Text('MIWEN PRO')
        .fontSize(8)
        .fontColor(this.c().faint)
        .letterSpacing(1.8)
      Blank()
      Text('')
        .width(40)
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SectionTitle(cn: string, en: string) {
    Row() {
      Text(cn)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.c().accent)
        .letterSpacing(1.4)
      Blank()
      Text(en)
        .fontSize(7)
        .fontColor(this.c().faint)
        .letterSpacing(1.6)
    }
    .width('100%')
    .padding({ top: 28, bottom: 8 })
  }

  @Builder
  Divider() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor(this.c().lineSoft)
  }

  @Builder
  Pledge(text: string, sub: string) {
    Row() {
      // 方点，不用圆形：整本册子里没有圆角
      Row()
        .width(5)
        .height(5)
        .backgroundColor(this.c().accent)
        .margin({ top: 6 })
      Column() {
        Text(text)
          .fontSize(11)
          .fontColor(this.c().text)
        Text(sub)
          .fontSize(9)
          .fontColor(this.c().dim)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  FeatRow(f: ProFeat, hot: boolean) {
    Row() {
      Column() {
        Text(f.name)
          .fontSize(12)
          .fontColor(this.c().text)
        Text(f.desc)
          .fontSize(9)
          .fontColor(this.c().dim)
          .margin({ top: 3 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(f.tag)
        .fontSize(8)
        .fontColor(hot ? this.c().accent : this.c().faint)
        .letterSpacing(0.6)
        .border({ width: 0.5, color: hot ? this.c().accentDeep : this.c().line })
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
        .margin({ left: 10 })
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.TopBar()

        Scroll() {
          Column() {
            // ---- 标识 ----
            Column() {
              Text('密纹')
                .fontSize(10)
                .fontColor(this.c().dim)
                .letterSpacing(6)
              Text('PRO')
                .fontSize(46)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.c().text)
                .letterSpacing(8)
                .margin({ top: 2 })
              Row()
                .width(28)
                .height(1.5)
                .backgroundColor(this.c().accent)
                .margin({ top: 14, bottom: 16 })
              Text('一次买断，永久可用')
                .fontSize(15)
                .fontColor(this.c().text)
              Text('不加订阅、不联网校验、不收集任何数据。')
                .fontSize(10)
                .fontColor(this.c().dim)
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding({ top: 26, bottom: 10 })

            // 已解锁状态条
            if (this.proOwned) {
              Row() {
                Text(ProService.isDevGrant() ? '已解锁 · 开发版授权' : '已解锁 · 正版')
                  .fontSize(10)
                  .fontColor(this.c().accent)
                Blank()
                Text(ProService.since())
                  .fontSize(9)
                  .fontColor(this.c().faint)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .backgroundColor(this.c().accentWash)
              .border({ width: 0.5, color: this.c().accentDeep })
              .margin({ top: 18 })
            }

            // ---- 承诺 ----
            this.SectionTitle('这本册子的规矩', 'THE DEAL')
            this.Divider()
            this.Pledge('一次买断', '没有月付、没有年度续费、没有"高级会员"再套一层')
            this.Divider()
            this.Pledge('永久可用', '买断包含当前版本与后续两个大版本的功能更新')
            this.Divider()
            this.Pledge('不联网校验', '除购买与恢复购买，应用不发起任何网络请求')
            this.Divider()
            this.Pledge('不缩减免费功能', '1.0 已经能做的事，不会有一天变成 Pro 专享')
            this.Divider()
            this.Pledge('可以先试用', '每个 Pro 功能都能用 3 次，用完再决定买不买')
            this.Divider()

            // ---- 功能 ----
            this.SectionTitle('本期包含', 'INCLUDED NOW')
            this.Divider()
            ForEach(this.featNow, (f: ProFeat) => {
              this.FeatRow(f, true)
              this.Divider()
            }, (f: ProFeat) => f.name)

            this.SectionTitle('下个版本', 'NEXT RELEASE')
            this.Divider()
            ForEach(this.featNext, (f: ProFeat) => {
              this.FeatRow(f, false)
              this.Divider()
            }, (f: ProFeat) => f.name)

            this.SectionTitle('规划中', 'ON THE BENCH')
            this.Divider()
            ForEach(this.featLater, (f: ProFeat) => {
              this.FeatRow(f, false)
              this.Divider()
            }, (f: ProFeat) => f.name)

            // ---- 价格 ----
            this.SectionTitle('价格', 'PRICE')
            this.Divider()
            Row() {
              Column() {
                Row() {
                  Text('¥')
                    .fontSize(16)
                    .fontColor(this.c().accent)
                    .margin({ top: 8 })
                  Text(`${Const.PRO_PRICE_EARLY}`)
                    .fontSize(44)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.c().accent)
                }
                .alignItems(VerticalAlign.Top)

                Text('首发早鸟价')
                  .fontSize(9)
                  .fontColor(this.c().dim)
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Column() {
                Text(`¥${Const.PRO_PRICE}`)
                  .fontSize(14)
                  .fontColor(this.c().faint)
                  .decoration({ type: TextDecorationType.LineThrough, color: this.c().faint })
                Text('常规价')
                  .fontSize(9)
                  .fontColor(this.c().faint)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.End)
            }
            .width('100%')
            .padding({ top: 16, bottom: 6 })
            .alignItems(VerticalAlign.Top)

            Text('早鸟价在 1.1 版本首发期内有效，之后恢复常规价。')
              .fontSize(9)
              .fontColor(this.c().faint)
              .width('100%')
              .margin({ bottom: 22 })

            // ---- 按钮 ----
            Text(this.proOwned ? `已解锁 · ${ProService.since()}` : `解锁密纹 Pro · ¥${Const.PRO_PRICE_EARLY}`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.proOwned ? this.c().text : this.c().onAccent)
              .letterSpacing(0.8)
              .width('100%')
              .height(52)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.proOwned ? this.c().surfaceAlt : this.c().accent)
              .border({ width: 0.5, color: this.proOwned ? this.c().line : this.c().accent })
              .onClick(() => this.openBuy())

            Text('恢复购买')
              .fontSize(11)
              .fontColor(this.c().dim)
              .width('100%')
              .height(46)
              .textAlign(TextAlign.Center)
              .onClick(() => this.restore())

            // ---- 脚注 ----
            Column() {
              Text('文件夹树与多根目录已在 1.1 免费提供，不计入 Pro —— 找不到歌属于基本可用性，不该收费。')
                .fontSize(9)
                .fontColor(this.c().faint)
                .width('100%')
                .margin({ bottom: 8 })
              Text('上面"本期包含"的每一项，都是这一版真机上点得到的；没做完的都还在"下个版本"里，不提前收费。')
                .fontSize(9)
                .fontColor(this.c().faint)
                .width('100%')
                .margin({ bottom: 8 })
              Text('购买与恢复购买是密纹唯一需要联网的两个动作。购买凭证缓存在本地，之后断网、换卡、飞行模式都能正常听。')
                .fontSize(9)
                .fontColor(this.c().faint)
                .width('100%')
              if (!this.proOwned || ProService.isDevGrant()) {
                Text('开发版说明：当前版本未接入应用市场支付，解锁走本地体验授权，不产生任何扣费，也不会联网。正式上架后该入口关闭。')
                  .fontSize(9)
                  .fontColor(this.c().faint)
                  .width('100%')
                  .margin({ top: 8 })
              }
            }
            .width('100%')
            .padding({ top: 14, bottom: 90 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: 720 })
      .alignSelf(ItemAlign.Center)
      .padding({
        left: this.bp === Const.BP_SM ? 20 : 32,
        right: this.bp === Const.BP_SM ? 20 : 32,
        top: this.topInset + 4
      })

      if (this.panelOpen) {
        ActionPanel({
          title: this.proOwned ? '密纹 Pro 已解锁' : '解锁密纹 Pro',
          subtitle: this.proOwned
            ? '开发版授权仅用于验收，可随时撤销'
            : '一次买断 · 永久可用 · 不订阅',
          items: this.panelItems,
          onPick: (i: number) => {
            this.onPick(i);
          },
          onClose: () => {
            this.panelOpen = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.c().bg)
  }
}
