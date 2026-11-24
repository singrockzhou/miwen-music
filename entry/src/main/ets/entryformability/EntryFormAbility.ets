import { formBindingData, FormExtensionAbility, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Logger } from '../common/Logger';
import { Const } from '../common/Constants';

const TAG: string = 'FormAbility';

/**
 * 服务卡片供给端。
 *
 * 卡片不能直接控制播放器 —— 它跑在独立进程里，也没有权限碰 AVPlayer。
 * 所以所有动作都走 postCardAction 拉起 App，把 method 交给 PlayerCore；
 * 状态则是反向的：App 把当前曲目写进 preferences，卡片从这里读。
 *
 * onAddForm 必须同步返回，所以先给一版占位数据，再异步读 preferences 后 updateForm。
 */
export default class EntryFormAbility extends FormExtensionAbility {

  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = want.parameters?.['ohos.extra.param.key.form_identity'] as string ?? '';
    Logger.info(TAG, `onAddForm ${formId}`);
    if (formId.length > 0) {
      this.refresh(formId);
    }
    return EntryFormAbility.placeholder();
  }

  onUpdateForm(formId: string): void {
    this.refresh(formId);
  }

  onFormEvent(formId: string, message: string): void {
    Logger.info(TAG, `onFormEvent ${message}`);
  }

  onRemoveForm(formId: string): void {
    Logger.info(TAG, `onRemoveForm ${formId}`);
  }

  /** 读 App 写下的当前曲目，回写卡片 */
  private refresh(formId: string): void {
    preferences.getPreferences(this.context, Const.PREF_NAME)
      .then((pref: preferences.Preferences) => {
        pref.putSync('card_form_id', formId);
        pref.flush();
        const data: Record<string, string> = {
          'title': pref.getSync('card_title', '密纹音乐') as string,
          'artist': pref.getSync('card_artist', '桌面即控制台') as string,
          'playing': pref.getSync('card_playing', 'false') as string,
          'hint': '打开唱片库'
        };
        formProvider.updateForm(formId, formBindingData.createFormBindingData(data))
          .catch((e: Object) => Logger.warn(TAG, `updateForm ${e}`));
      })
      .catch((e: Object) => Logger.warn(TAG, `read pref failed ${e}`));
  }

  private static placeholder(): formBindingData.FormBindingData {
    const data: Record<string, string> = {
      'title': '密纹音乐',
      'artist': '桌面即控制台',
      'playing': 'false',
      'hint': '打开唱片库'
    };
    return formBindingData.createFormBindingData(data);
  }
}
