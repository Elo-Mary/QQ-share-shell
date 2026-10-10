package com.tencent.mobileqq;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

/**
 * 所有“QQ 侧组件名”最终都落到这里。
 *
 * 三条来路：
 *  1) 分享面板里选了“QQ”  -> ACTION_SEND / ACTION_SEND_MULTIPLE
 *  2) QQ SDK 显式点名 com.tencent.mobileqq.activity.JumpActivity -> ACTION_VIEW + mqqapi://share/...
 *  3) QQ 的登录/支付等其它调用 -> 只提示“需要真正的 QQ”，不做任何事
 */
public class RelayActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            dispatch(getIntent());
        } catch (Throwable t) {
            Relay.toast(this, "空壳QQ：转发出错 " + t);
        }
        finish();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        try {
            dispatch(intent);
        } catch (Throwable t) {
            Relay.toast(this, "空壳QQ：转发出错 " + t);
        }
        finish();
    }

    private void dispatch(Intent intent) {
        if (intent == null) {
            return;
        }

        String action = intent.getAction();
        if (Intent.ACTION_SEND.equals(action) || Intent.ACTION_SEND_MULTIPLE.equals(action)) {
            Relay.forward(this, intent, false);
            return;
        }

        Uri data = intent.getData();
        String scheme = data == null ? null : data.getScheme();
        if (scheme != null && scheme.startsWith("mqq")) {
            Intent send = Relay.buildFromMqqUri(data);
            if (send == null && (intent.hasExtra(Intent.EXTRA_TEXT) || intent.hasExtra(Intent.EXTRA_STREAM))) {
                // 少数 App 会既带 mqqapi URI 又直接把内容放进 extra
                send = intent;
            }
            if (send != null) {
                Relay.forward(this, send, true);
            } else {
                // 登录 / 支付 / 拉起 QQ 主页之类：空壳无法处理，明确告知而不是静默失败
                Relay.toast(this, "空壳QQ：这是 QQ 的其它功能请求，需要真正的 QQ");
            }
            return;
        }

        Relay.toast(this, "空壳QQ：此功能需要真正的 QQ");
    }
}
