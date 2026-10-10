import java.net.URLDecoder;

/**
 * 与 Relay.decodeParam 逻辑一致的离线测试（不需要手机、不需要 Android SDK 的 dex 工具）。
 *
 * 只依赖 javac/java 就能跑，用于验证 mqqapi:// 分享参数里的 base64 / URL 编码解码：
 *
 *   javac -encoding UTF-8 -d build\logictest tools\DecodeTest.java
 *   java -Dstdout.encoding=UTF-8 -cp build\logictest DecodeTest
 *
 * 其中 Android 的 Base64.URL_SAFE 对应 java.util.Base64.getUrlDecoder()，
 * Android 的 Base64.DEFAULT 对应 java.util.Base64.getDecoder()。
 */
public class DecodeTest {

    static boolean printable(String text) {
        if (text == null || text.length() == 0) return false;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '\uFFFD') return false;
            if (c < 0x20 && c != '\n' && c != '\r' && c != '\t') return false;
        }
        return true;
    }

    static String decodeParam(String raw) {
        if (raw == null) return null;
        String value = raw.trim();
        if (value.length() == 0) return null;
        if (value.length() >= 4 && value.matches("^[A-Za-z0-9_\\-+/]+=*$")) {
            int rest = value.length() % 4;
            String padded = value;
            if (rest == 2) padded = value + "==";
            else if (rest == 3) padded = value + "=";
            else if (rest == 1) padded = null;
            if (padded != null) {
                java.util.Base64.Decoder[] alphabets = {
                    java.util.Base64.getUrlDecoder(), java.util.Base64.getDecoder()
                };
                for (java.util.Base64.Decoder decoder : alphabets) {
                    try {
                        byte[] bytes = decoder.decode(padded);
                        String text = new String(bytes, "UTF-8");
                        if (printable(text)) return text;
                    } catch (Throwable ignored) { }
                }
            }
        }
        // 关键：只有在输入确实含百分号转义时才做 URL 解码。
        // 否则 URLDecoder 会把 base64 里的加号变成空格（会把“测试”解成“5rWL6K V”）。
        if (value.indexOf('%') >= 0) {
            try { return URLDecoder.decode(value, "UTF-8"); } catch (Throwable ignored) { }
        }
        return value;
    }

    public static void main(String[] args) {
        String[][] cases = {
            {"5rWL6K+V", "测试"},                                  // 标准字母表（含加号）
            {"6K-06K-0", "说说"},                                  // URL-safe 字母表（含减号）
            {"aHR0cHM6Ly9leGFtcGxlLmNvbQ==", "https://example.com"},
            {"5L2g5aW977yM5LiA5Liq5rWL6K+V", "你好，一个测试"},
            {"dGVzdA", "test"},                                    // 无 padding
            {"aGVsbG8gd29ybGQ", "hello world"},
            {"Hello", "Hello"},
            {"abc", "abc"},
            {"%E4%B8%AD%E6%96%87", "中文"},
            {"%E5%88%86%E4%BA%AB", "分享"},
            {"", null},
            {null, null}
        };
        int pass = 0;
        for (String[] c : cases) {
            String got = decodeParam(c[0]);
            boolean ok = c[1] == null ? got == null : c[1].equals(got);
            if (ok) pass++;
            System.out.printf("  %-6s raw=%-34s -> %-22s 期望=%s%n",
                    ok ? "PASS" : "FAIL",
                    c[0] == null ? "null" : "'" + c[0] + "'",
                    got == null ? "null" : "'" + got + "'",
                    c[1] == null ? "null" : "'" + c[1] + "'");
        }
        System.out.println("  " + pass + "/" + cases.length + " 通过");
        if (pass != cases.length) {
            System.exit(1);
        }
    }
}
