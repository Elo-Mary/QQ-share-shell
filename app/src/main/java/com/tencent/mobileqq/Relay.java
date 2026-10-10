package com.tencent.mobileqq;

import android.content.ClipData;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Parcelable;
import android.text.TextUtils;
import android.util.Base64;
import android.widget.Toast;

import java.net.URLDecoder;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 空壳 QQ 的全部逻辑：把收到的分享内容转交给 TIM（或系统里其它分享目标，但排除自己）。
 *
 * 这个类不做任何联网、不读写其它应用的数据，只是 Intent 的中转站。
 */
final class Relay {

    static final String SELF_PACKAGE = "com.tencent.mobileqq";
    static final String TIM_PACKAGE = "com.tencent.tim";
    static final String SELF_SHARE_ALIAS = "com.tencent.mobileqq.ShareTarget";

    private Relay() {
    }

    static void toast(Context context, String message) {
        try {
            Toast.makeText(context.getApplicationContext(), message, Toast.LENGTH_LONG).show();
        } catch (Throwable ignored) {
            // 某些定制 ROM 在后台不允许弹 Toast，忽略即可
        }
    }

    static boolean isInstalled(Context context, String packageName) {
        try {
            context.getPackageManager().getPackageInfo(packageName, 0);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * 把 source 里的分享内容转出去。
     *
     * @param announce 是否弹一句提示（显式分享跳进来时提示一下，避免用户以为没反应）
     */
    static void forward(Context context, Intent source, boolean announce) {
        Intent send = buildSendIntent(source);
        if (send == null) {
            toast(context, "空壳QQ：这次分享没有可转发的内容（既没有文字也没有图片）");
            return;
        }

        PackageManager pm = context.getPackageManager();
        List<ResolveInfo> all = pm.queryIntentActivities(send, PackageManager.MATCH_DEFAULT_ONLY);
        List<ResolveInfo> timTargets = new ArrayList<ResolveInfo>();
        List<ResolveInfo> others = new ArrayList<ResolveInfo>();
        for (int i = 0; i < all.size(); i++) {
            ResolveInfo ri = all.get(i);
            if (ri == null || ri.activityInfo == null) {
                continue;
            }
            String pkg = ri.activityInfo.packageName;
            if (SELF_PACKAGE.equals(pkg)) {
                // 排除自己，否则会“分享给自己”来回打转
                continue;
            }
            if (TIM_PACKAGE.equals(pkg)) {
                timTargets.add(ri);
            } else {
                others.add(ri);
            }
        }

        List<ResolveInfo> targets = timTargets.isEmpty() ? others : timTargets;

        if (targets.isEmpty()) {
            toast(context, "空壳QQ：手机里没找到 TIM，请先安装 TIM");
            return;
        }

        if (announce) {
            toast(context, "空壳QQ：已把内容转给 TIM");
        }

        // 只有一个目标时直接打开，省掉一次无意义的“选择”弹窗
        if (targets.size() == 1) {
            ResolveInfo ri = targets.get(0);
            Intent direct = new Intent(send);
            direct.setComponent(new ComponentName(ri.activityInfo.packageName, ri.activityInfo.name));
            if (startSafely(context, direct)) {
                return;
            }
        }

        Intent chooser = Intent.createChooser(send, "分享到");
        excludeSelf(chooser);
        if (!startSafely(context, chooser)) {
            toast(context, "空壳QQ：转发失败，没有应用能接收这个内容");
        }
    }

    private static boolean startSafely(Context context, Intent intent) {
        try {
            if (!(context instanceof android.app.Activity)) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            }
            context.startActivity(intent);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /** 让系统分享面板不要把“QQ（空壳）”自己列进去（API 24+ 才支持） */
    private static void excludeSelf(Intent chooser) {
        if (Build.VERSION.SDK_INT < 24) {
            return;
        }
        try {
            chooser.putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, new Parcelable[]{
                    new ComponentName(SELF_PACKAGE, SELF_SHARE_ALIAS),
                    new ComponentName(SELF_PACKAGE, SELF_PACKAGE + ".RelayActivity")
            });
        } catch (Throwable ignored) {
        }
    }

    /** 从收到的 Intent 里抽出一份干净的 ACTION_SEND / ACTION_SEND_MULTIPLE */
    private static Intent buildSendIntent(Intent src) {
        String action = src.getAction();
        Intent out = new Intent();

        if (Intent.ACTION_SEND_MULTIPLE.equals(action)) {
            ArrayList<Parcelable> raw = src.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            ArrayList<Uri> uris = new ArrayList<Uri>();
            if (raw != null) {
                for (int i = 0; i < raw.size(); i++) {
                    if (raw.get(i) instanceof Uri) {
                        uris.add((Uri) raw.get(i));
                    }
                }
            }
            if (uris.isEmpty()) {
                return null;
            }
            out.setAction(Intent.ACTION_SEND_MULTIPLE);
            out.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        } else {
            Uri stream = (Uri) src.getParcelableExtra(Intent.EXTRA_STREAM);
            CharSequence text = src.getCharSequenceExtra(Intent.EXTRA_TEXT);
            CharSequence html = src.getCharSequenceExtra(Intent.EXTRA_HTML_TEXT);
            String subject = src.getStringExtra(Intent.EXTRA_SUBJECT);
            CharSequence title = src.getCharSequenceExtra(Intent.EXTRA_TITLE);

            boolean hasText = text != null && text.length() > 0;
            if (stream == null && !hasText) {
                return null;
            }
            out.setAction(Intent.ACTION_SEND);
            if (stream != null) {
                out.putExtra(Intent.EXTRA_STREAM, stream);
            }
            if (hasText) {
                out.putExtra(Intent.EXTRA_TEXT, text);
            }
            if (html != null) {
                out.putExtra(Intent.EXTRA_HTML_TEXT, html);
            }
            if (subject != null) {
                out.putExtra(Intent.EXTRA_SUBJECT, subject);
            }
            if (title != null) {
                out.putExtra(Intent.EXTRA_TITLE, title);
            }
        }

        String type = src.getType();
        if (TextUtils.isEmpty(type)) {
            type = Intent.ACTION_SEND_MULTIPLE.equals(action) ? "image/*" : "text/plain";
        }
        out.setType(type);
        out.addCategory(Intent.CATEGORY_DEFAULT);
        out.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        ClipData clip = src.getClipData();
        if (clip != null) {
            out.setClipData(clip);
        }
        return out;
    }

    /**
     * 解析 QQ SDK 的分享 URI：
     * mqqapi://share/to_fri?src_type=app&version=1&file_type=news&title=<base64>&description=...
     * 参数多为 base64（URL-safe）编码，也有部分是明文，两种都试。
     *
     * @return 可以转发给 TIM 的 ACTION_SEND；解析不出内容则返回 null
     */
    static Intent buildFromMqqUri(Uri data) {
        Map<String, String> params = new HashMap<String, String>();
        try {
            for (String name : data.getQueryParameterNames()) {
                params.put(name, data.getQueryParameter(name));
            }
        } catch (Throwable ignored) {
        }

        String fileType = params.get("file_type");
        String title = decodeParam(params.get("title"));
        String desc = decodeParam(firstNonNull(params.get("summary"), params.get("description")));
        String url = decodeParam(firstNonNull(params.get("url"), params.get("targetUrl"), params.get("target_url")));
        String image = decodeParam(firstNonNull(params.get("image_url"), params.get("imageUrl")));
        String appName = decodeParam(firstNonNull(params.get("app_name"), params.get("thirdAppDisplayName")));

        StringBuilder sb = new StringBuilder();
        if (!TextUtils.isEmpty(title)) {
            sb.append(title);
        }
        if (!TextUtils.isEmpty(desc)) {
            appendLine(sb, desc);
        }
        if (!TextUtils.isEmpty(url)) {
            appendLine(sb, url);
        }
        if (!TextUtils.isEmpty(image)) {
            // 图片多半是 http 图片地址：作为文字附加，避免把它当成本地文件传给 TIM
            appendLine(sb, image);
        }
        if (!TextUtils.isEmpty(appName)) {
            appendLine(sb, "—— 来自 " + appName);
        }
        if (sb.length() == 0 && TextUtils.isEmpty(fileType)) {
            return null;
        }
        if (sb.length() == 0) {
            return null;
        }

        Intent out = new Intent(Intent.ACTION_SEND);
        out.setType("text/plain");
        out.putExtra(Intent.EXTRA_TEXT, sb.toString());
        if (!TextUtils.isEmpty(title)) {
            out.putExtra(Intent.EXTRA_SUBJECT, title);
        }
        return out;
    }

    private static void appendLine(StringBuilder sb, String value) {
        if (sb.length() > 0) {
            sb.append('\n');
        }
        sb.append(value);
    }

    private static String firstNonNull(String... candidates) {
        for (int i = 0; i < candidates.length; i++) {
            if (!TextUtils.isEmpty(candidates[i])) {
                return candidates[i];
            }
        }
        return null;
    }

    /**
     * 先按 base64 试（URL-safe 字母表和标准字母表都试一遍，加号斜杠与减号下划线
     * QQ 两种写法都用过），解出来像正常文本就用它；否则只在输入确实含百分号
     * 转义时才做 URL 解码。
     *
     * 注意：不要在含 base64 特征时先做 URL 解码 —— URLDecoder 会把加号变成空格，
     * 而加号在标准 base64 里很常见（实测会把“测试”解成“5rWL6K V”）。
     */
    static String decodeParam(String raw) {
        if (raw == null) {
            return null;
        }
        String value = raw.trim();
        if (value.length() == 0) {
            return null;
        }
        if (value.length() >= 4 && value.matches("^[A-Za-z0-9_\\-+/]+=*$")) {
            int rest = value.length() % 4;
            String padded = value;
            if (rest == 2) {
                padded = value + "==";
            } else if (rest == 3) {
                padded = value + "=";
            } else if (rest == 1) {
                padded = null;
            }
            if (padded != null) {
                int[] alphabets = new int[]{Base64.URL_SAFE | Base64.NO_WRAP, Base64.DEFAULT | Base64.NO_WRAP};
                for (int i = 0; i < alphabets.length; i++) {
                    try {
                        byte[] bytes = Base64.decode(padded, alphabets[i]);
                        String text = new String(bytes, "UTF-8");
                        if (printable(text)) {
                            return text;
                        }
                    } catch (Throwable ignored) {
                        // 换另一种字母表再试
                    }
                }
            }
        }
        if (value.indexOf('%') >= 0) {
            try {
                return URLDecoder.decode(value, "UTF-8");
            } catch (Throwable ignored) {
            }
        }
        return value;
    }

    private static boolean printable(String text) {
        if (text == null || text.length() == 0) {
            return false;
        }
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '\uFFFD') {
                return false;
            }
            if (c < 0x20 && c != '\n' && c != '\r' && c != '\t') {
                return false;
            }
        }
        return true;
    }
}
