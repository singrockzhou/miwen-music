/**
 * 播控卡片（2*2 / 4*2）。
 *
 * 只留三件东西：一行曲名、一行艺人、一个播放键。
 * 卡片里不放进度环 —— 2*2 尺寸下会糊，而且卡片刷新有延迟，进度条会"跳"。
 */
@Entry
@Component
struct PlayerCard {
  @LocalStorageProp('title') title: string = '密纹音乐';
  @LocalStorageProp('artist') artist: string = '桌面即控制台';
  @LocalStorageProp('playing') playing: string = 'false';
  @LocalStorageProp('hint') hint: string = '打开唱片库';

  build() {
    Column() {
      Row() {
        Text('密纹·播控')
          .fontSize(9)
          .fontColor('#C8A96A')
          .letterSpacing(1)
        Blank()
        Text(this.playing === 'true' ? 'II' : '▶')
          .fontSize(15)
          .fontColor('#C8A96A')
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            postCardAction(this, {
              action: 'call',
              abilityName: 'EntryAbility',
              params: { method: 'toggle' }
            });
          })
      }
      .width('100%')

      Blank()

      Text(this.title)
        .fontSize(13)
        .fontColor('#F4EFE6')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.artist)
        .fontSize(8)
        .fontColor('#8E8778')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 3 })

      Blank()

      Row() {
        Text(this.hint)
          .fontSize(8)
          .fontColor('#6E6A61')
        Blank()
        Text('›')
          .fontSize(10)
          .fontColor('#6E6A61')
      }
      .width('100%')
      .onClick(() => {
        postCardAction(this, {
          action: 'router',
          abilityName: 'EntryAbility',
          params: { method: 'open' }
        });
      })
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#0B0B0D')
  }
}
