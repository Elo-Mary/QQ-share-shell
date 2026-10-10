package com.tencent.mobileqq;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.security.MessageDigest;

/**
 * 空壳QQ 的唯一可见界面：运行状态、分享面板开关、自测入口，以及使用说明与免责声明。
 *
 * 注意：下面的事件监听器一律写成「静态嵌套类 + 显式持有 Activity 引用」，不要改成匿名内部类。
 * 非静态内部类和匿名类会被 javac 生成合成字段 this$0，而 build-tools 34 里的 R8 8.2.2
 * 遇到新版 javac（21+）生成的 this$0 会内部崩溃（NullPointerException），
 * 详见 README「常见问题」里那一行。
 */
public class ShellActivity extends Activity {

    private static final String TIM_PACKAGE = "com.tencent.tim";
    private static final String SELF_SHARE_ALIAS = "com.tencent.mobileqq.ShareTarget";

    private TextView statusView;
    private int pad;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setTitle(R.string.shell_title);

        pad = (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 16,
                getResources().getDisplayMetrics());

        ScrollView scroll = new ScrollView(this);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad, pad, pad);
        scroll.addView(box);

        addBody(box, getString(R.string.shell_subtitle));

        addHeading(box, getString(R.string.shell_section_status));
        statusView = new TextView(this);
        statusView.setTextSize(13);
        box.addView(statusView);

        CheckBox showInShare = new CheckBox(this);
        showInShare.setText(R.string.shell_checkbox);
        showInShare.setChecked(isAliasEnabled());
        showInShare.setOnCheckedChangeListener(new AliasToggleListener(this));
        box.addView(showInShare);

        Button test = new Button(this);
        test.setText(R.string.shell_button_self_test);
        test.setOnClickListener(new SelfTestListener(this));
        box.addView(test);

        final Intent timIntent = getPackageManager().getLaunchIntentForPackage(TIM_PACKAGE);
        Button openTim = new Button(this);
        openTim.setText(timIntent == null
                ? getString(R.string.shell_button_open_tim_missing)
                : getString(R.string.shell_button_open_tim));
        openTim.setEnabled(timIntent != null);
        openTim.setOnClickListener(new OpenTimListener(this, timIntent));
        box.addView(openTim);

        addHeading(box, getString(R.string.shell_section_usage));
        addBody(box, getString(R.string.shell_usage));

        // 免责声明：逐条渲染，条与条之间留一点空隙
        addHeading(box, getString(R.string.shell_section_disclaimer));
        int[] disclaimerIds = new int[]{
                R.string.shell_disclaimer_unofficial,
                R.string.shell_disclaimer_scope,
                R.string.shell_disclaimer_privacy,
                R.string.shell_disclaimer_limits,
                R.string.shell_disclaimer_risk,
                R.string.shell_disclaimer_rights,
                R.string.shell_disclaimer_consent,
                R.string.shell_disclaimer_uninstall
        };
        for (int i = 0; i < disclaimerIds.length; i++) {
            addBody(box, getString(disclaimerIds[i]));
            if (i < disclaimerIds.length - 1) {
                addSpacer(box);
            }
        }

        setContentView(scroll);
        refresh();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    private void addHeading(LinearLayout box, CharSequence text) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(15);
        view.setPadding(0, pad, 0, pad / 4);
        box.addView(view);
    }

    private void addBody(LinearLayout box, CharSequence text) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(13);
        view.setLineSpacing(0, 1.15f);
        box.addView(view);
    }

    /** 段落之间留白，纯代码实现，避免为此再引入 layout 资源 */
    private void addSpacer(LinearLayout box) {
        View spacer = new View(this);
        spacer.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, pad / 3));
        box.addView(spacer);
    }

    /** 运行状态：包名、版本、Android 版本、TIM、分享面板条目、本应用签名指纹 */
    private void refresh() {
        StringBuilder sb = new StringBuilder();
        sb.append("包名：").append(getPackageName()).append('\n');
        try {
            PackageInfo self = getPackageManager().getPackageInfo(getPackageName(), 0);
            sb.append("版本：").append(self.versionName).append("（").append(self.versionCode).append("）\n");
        } catch (Throwable t) {
            sb.append("版本：读取失败\n");
        }
        sb.append("Android：").append(Build.VERSION.RELEASE)
                .append("（API ").append(Build.VERSION.SDK_INT).append("）\n");

        String timVersion = packageVersion(TIM_PACKAGE);
        if (timVersion == null) {
            sb.append("TIM：未安装（收到分享时会提示找不到 TIM）\n");
        } else {
            sb.append("TIM：已安装，版本 ").append(timVersion).append('\n');
        }

        sb.append("分享面板条目：").append(isAliasEnabled() ? "已开启（显示为 QQ）" : "已关闭").append('\n');
        sb.append("本应用签名 SHA-1：").append(ownSignatureSha1()).append('\n');
        sb.append("（少数应用会用腾讯官方证书指纹比对 QQ 是否为正版；与上面这串不一致时，")
                .append("它们不会显示分享入口。）");

        statusView.setText(sb.toString());
    }

    private String packageVersion(String packageName) {
        try {
            return getPackageManager().getPackageInfo(packageName, 0).versionName;
        } catch (Throwable t) {
            return null;
        }
    }

    private boolean isAliasEnabled() {
        try {
            int state = getPackageManager().getComponentEnabledSetting(
                    new ComponentName(this, SELF_SHARE_ALIAS));
            return state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
                    || state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED;
        } catch (Throwable t) {
            return true;
        }
    }

    private void setAliasEnabled(boolean enabled) {
        try {
            getPackageManager().setComponentEnabledSetting(
                    new ComponentName(this, SELF_SHARE_ALIAS),
                    enabled ? PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                            : PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP);
        } catch (Throwable t) {
            Relay.toast(this, "切换失败：" + t);
        }
    }

    private String ownSignatureSha1() {
        try {
            PackageInfo pi = getPackageManager().getPackageInfo(getPackageName(),
                    PackageManager.GET_SIGNATURES);
            if (pi.signatures == null || pi.signatures.length == 0) {
                return "未知";
            }
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            byte[] digest = md.digest(pi.signatures[0].toByteArray());
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < digest.length; i++) {
                if (i > 0) {
                    sb.append(':');
                }
                sb.append(String.format("%02X", digest[i] & 0xFF));
            }
            return sb.toString();
        } catch (Throwable t) {
            return "读取失败：" + t;
        }
    }

    /*
     * 静态嵌套类形式的监听器（见类注释：不要改成匿名内部类）
     */

    private static final class AliasToggleListener implements CompoundButton.OnCheckedChangeListener {
        private final ShellActivity host;

        AliasToggleListener(ShellActivity host) {
            this.host = host;
        }

        @Override
        public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
            host.setAliasEnabled(isChecked);
            host.refresh();
        }
    }

    private static final class SelfTestListener implements View.OnClickListener {
        private final ShellActivity host;

        SelfTestListener(ShellActivity host) {
            this.host = host;
        }

        @Override
        public void onClick(View v) {
            Intent sample = new Intent(Intent.ACTION_SEND);
            sample.setType("text/plain");
            sample.putExtra(Intent.EXTRA_SUBJECT, "空壳QQ 自测");
            sample.putExtra(Intent.EXTRA_TEXT, "这是一条来自空壳QQ 的测试内容。");
            Relay.forward(host, sample, true);
        }
    }

    private static final class OpenTimListener implements View.OnClickListener {
        private final ShellActivity host;
        private final Intent target;

        OpenTimListener(ShellActivity host, Intent target) {
            this.host = host;
            this.target = target;
        }

        @Override
        public void onClick(View v) {
            try {
                host.startActivity(target);
            } catch (Throwable t) {
                Relay.toast(host, "打开 TIM 失败：" + t);
            }
        }
    }
}
