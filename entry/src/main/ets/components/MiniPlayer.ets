import { PlayerSnapshot, emptySnapshot } from '../model/PlayerState';
import { PlayerCore } from '../service/PlayerCore';
import { Theme, Tokens } from '../common/Theme';
import { CoverArt } from './CoverArt';
import { PlayPauseGlyph } from './PlayPauseGlyph';

/**
 * 迷你播放条：常驻底部，上滑进播放页。
 *
 * 自持订阅：不靠父页面传状态，避免"首页在放、曲库页的条还是旧的"。
 * 只留三件东西：一条 1px 进度线、一行标题、一个播放键；
 * 上一首/下一首不放在这里——小尺寸下按钮一多就变成遥控器。
 */
@Component
export struct MiniPlayer {
  @State snap: PlayerSnapshot = emptySnapshot();
  @StorageProp('themeKey') themeKey: string = 'dark';

  onOpen: () => void = () => {
  };

  private core: PlayerCore = PlayerCore.instance();
  private listener: (s: PlayerSnapshot) => void = (s: PlayerSnapshot): void => {
    this.snap = s;
  };

  aboutToAppear(): void {
    this.core.onChange(this.listener);
    // 与播放页同理：先拉一次，否则冷启动恢复队列后要等下一次状态变化才显示
    this.snap = this.core.snapshot();
  }

  aboutToDisappear(): void {
    this.core.offChange(this.listener);
  }

  private c(): Tokens {
    return Theme.of(this.themeKey);
  }

  private ratio(): number {
    if (this.snap.duration <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, this.snap.position / this.snap.duration));
  }

  build() {
    Column() {
      // 进度线：比进度环克制，但能看出播到哪了
      Row() {
        Row()
          .width(`${this.ratio() * 100}%`)
          .height(1)
          .backgroundColor(this.c().accent)
      }
      .width('100%')
      .height(1)
      .backgroundColor(this.c().lineSoft)

      Row({ space: 11 }) {
        CoverArt({
          coverPath: this.snap.track !== null ? this.snap.track.coverPath : '',
          // 与播放页保持同一枚封套：首字取专辑名，取不到才退回曲名
          seed: this.snap.track !== null ? this.snap.track.album : '',
          title: this.snap.track !== null
            ? (this.snap.track.album.length > 0 ? this.snap.track.album : this.snap.track.title)
            : '',
          subtitle: '',
          compact: true
        })
          .width(38)
          .height(38)

        Column() {
          Text(this.snap.track !== null ? this.snap.track.title : '未在播放')
            .fontSize(12)
            .fontColor(this.c().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Text(this.snap.track !== null
              ? (this.snap.track.artist.length > 0 ? this.snap.track.artist : this.snap.track.album)
              : '选一张唱片开始')
              .fontSize(9)
              .fontColor(this.c().dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.snap.isDemo) {
              Text('示例')
                .fontSize(7)
                .fontColor(this.c().accent)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .border({ width: 0.5, color: this.c().accentDeep })
            }
          }
          .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        PlayPauseGlyph({ playing: this.snap.playing, glyph: 17, color: this.c().accent })
          .width(40)
          .height(40)
          .onClick(() => {
            this.core.toggle();
          })
      }
      .width('100%')
      .padding({ left: 14, right: 8, top: 7, bottom: 7 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(this.c().surface)
    .onClick(() => this.onOpen())
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Up, distance: 8 })
        .onActionEnd(() => this.onOpen())
    )
  }
}
