import { router } from '@kit.ArkUI';
import { Const } from '../common/Constants';
import { Theme, Tokens } from '../common/Theme';
import { UiEnv } from '../common/UiEnv';
import { PlayerCore } from '../service/PlayerCore';
import { PlayerSnapshot, emptySnapshot } from '../model/PlayerState';
import { HomeView } from '../view/HomeView';
import { LibraryView } from '../view/LibraryView';
import { CollectionView } from '../view/CollectionView';
import { SettingsView } from '../view/SettingsView';
import { MiniPlayer } from '../components/MiniPlayer';

/**
 * 唯一的主页面：四个 tab + 常驻迷你播放条。
 *
 * 为什么不给每个 tab 各开一个 router 页面：
 * 切 tab 会重建页面，曲库的滚动位置、搜索关键词、列表分页全部丢失；
 * 播放条也会跟着重建，看起来像"每次切 tab 都在重新加载"。
 *
 * 底部 tab 条不用图标：四个词 + 一条 1px 铜线，和整套"纸面"语言一致。
 */
@Entry
@Component
struct Index {
  @State current: number = 0;
  @State hasTrack: boolean = false;
  @StorageProp('themeKey') themeKey: string = 'dark';
  @StorageProp('accentPin') accentPin: string = '';
  @StorageProp('bp') bp: string = Const.BP_SM;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;

  private controller: TabsController = new TabsController();
  private core: PlayerCore = PlayerCore.instance();
  private listener: (s: PlayerSnapshot) => void = (s: PlayerSnapshot): void => {
    this.hasTrack = s.track !== null;
  };

  aboutToAppear(): void {
    UiEnv.init();
    this.core.onChange(this.listener);
    // 冷启动时内核可能已在恢复队列，先对齐一次，否则迷你条要等下一次通知才出现
    this.hasTrack = this.core.snapshot().track !== null;
  }

  aboutToDisappear(): void {
    this.core.offChange(this.listener);
  }

  private c(): Tokens {
    return Theme.of(this.themeKey, this.accentPin);
  }

  private go(i: number): void {
    this.current = i;
    this.controller.changeIndex(i);
  }

  private openPlayer(): void {
    if (!this.hasTrack) {
      return;
    }
    router.pushUrl({ url: 'pages/PlayerPage' }).catch(() => {
    });
  }

  @Builder
  TabBar(index: number, label: string) {
    Column() {
      Row()
        .width(this.current === index ? 16 : 0)
        .height(1)
        .backgroundColor(this.c().accent)
        .margin({ bottom: 9 })
      Text(label)
        .fontSize(10)
        .fontColor(this.current === index ? this.c().text : this.c().faint)
        .letterSpacing(1.2)
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .border({ width: { top: 0.5 }, color: this.c().lineSoft })
    .backgroundColor(this.c().surface)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
        TabContent() {
          HomeView({
            onGoLibrary: () => this.go(1),
            onGoSearch: () => this.go(1)
          })
        }
        .tabBar(this.TabBar(0, '首页'))

        TabContent() {
          LibraryView()
        }
        .tabBar(this.TabBar(1, '曲库'))

        TabContent() {
          CollectionView({
            onGoLibrary: () => this.go(1)
          })
        }
        .tabBar(this.TabBar(2, '我的'))

        TabContent() {
          SettingsView()
        }
        .tabBar(this.TabBar(3, '设置'))
      }
      .barHeight(56)
      .barMode(BarMode.Fixed)
      .scrollable(true)
      .animationDuration(200)
      .divider({ strokeWidth: 0, color: Color.Transparent })
      .backgroundColor(this.c().bg)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .onChange((i: number) => {
        this.current = i;
      })

      if (this.hasTrack) {
        Column() {
          MiniPlayer({ onOpen: () => this.openPlayer() })
        }
        .width('100%')
        .margin({ bottom: 56 + this.bottomInset })
        .shadow({ radius: 0, color: Color.Transparent })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.c().bg)
  }
}
