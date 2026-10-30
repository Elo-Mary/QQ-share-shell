# 空壳QQ：让「分享至 QQ」重新出现，内容实际进 TIM

一个**不含任何腾讯代码**的占位应用：包名占用 `com.tencent.mobileqq`，注册了几个与 QQ 同名的组件，
让第三方 App 以为 QQ 还装着；收到分享内容后原样转交给 TIM。

* 仓库：<https://github.com/Elo-Mary/QQ-share-shell>（GitHub 仓库名大小写不敏感，`qq-share-shell` 同样能访问）
* 英文文档 / English docs: [README.en.md](README.en.md)
* 许可证：MIT（见 [LICENSE](LICENSE)，署名 Elo-Mary）
* 状态：已在本机编译出可安装的 APK，并在真机上实测通过（见文末「交付状态」与附录的实测案例）

> 本工程与腾讯公司无关，不含任何腾讯代码、资源或数据；仅建议在自己设备上自用，不要分发到应用商店。

---

## 一、为什么只装 TIM，「分享至 QQ」就消失了

「分享至 QQ」这个入口**不是系统给的**，而是第三方 App 自己判断后画出来的：

1. App 调 QQ SDK 的 `Tencent.isQQInstalled()`，或者干脆自己 `getPackageManager().getPackageInfo("com.tencent.mobileqq", 0)`；
2. 查到 → 显示「分享至 QQ」按钮；
3. 点击后才轮到系统选择器：因为 QQ 和 TIM 都注册了 `ACTION_SEND`，你会看到「QQ / TIM」二选一。

TIM 的包名是 `com.tencent.tim`（QQ SDK 里对应 `Constants.PACKAGE_TIM`，和 `PACKAGE_QQ` 是两个不同的常量）。
绝大多数 App 只判 QQ、不判 TIM，于是你卸掉 QQ 之后，第 2 步就失败了，按钮直接消失 —— 这不是系统分享面板的问题，
所以在系统设置里怎么找都找不到开关。

腾讯自己的文档也承认这个「QQ / TIM 平台混淆」问题：<https://developer.umeng.com/docs/128606/detail/3014083>

---

## 二、先看清楚本方案的边界（决定你要不要折腾）

| 第三方 App 的判定方式 | 空壳包能否骗过 |
|---|---|
| 只查 `getPackageInfo("com.tencent.mobileqq")` 是否存在 | ✅ 能 |
| 还比较 `versionName` 是否够新（SDK 内部有最低版本门槛） | ✅ 能（本工程是 `8.9.90`） |
| 枚举 QQ 的组件（如 `com.tencent.mobileqq.activity.JumpActivity`） | ✅ 能（manifest 里注册了同名组件） |
| 用 `queryIntentActivities(ACTION_SEND)` 收集分享目标 | ✅ 能（`.ShareTarget` 会让「QQ」出现在分享面板里） |
| **校验 QQ 的签名/证书指纹**是否等于腾讯官方证书 | ❌ **不能**，除非拿到腾讯私钥 |
| 校验安装来源、加固完整性、服务端二次校验 | ❌ 不能 |
| 用 QQ 登录 / QQ 支付 | ❌ 本工程不实现（会提示「需要真正的 QQ」） |

**最省事的判断办法**：按第六节把包构建出来装上，看那个 App 的「分享至 QQ」是否回来。回来了就是前四类之一，能用；
不回来就是签名校验那一类，只能走第三节的路线 2 或 3。

**不想白折腾的话，先体检那个 App 的 APK**（不用反编译，直接在 dex 里搜关键字）：

```powershell
powershell -ExecutionPolicy Bypass -File .\inspect-target-app.ps1 -ApkPath 'D:\某个App.apk'
```

命中 `checkQQAppSignature` / `isSignatureValid` 之类 → 空壳基本没戏，直接走「禁用真 QQ」；
只命中 `com.tencent.mobileqq` 而没有签名校验痕迹 → 空壳值得一试。

---

## 三、三条路线对比

| 路线 | 要 root 吗 | 原理 | 能过签名校验吗 | 代价 |
|---|---|---|---|---|
| **空壳 APK**（本工程） | 不要 | 占住 `com.tencent.mobileqq` 这个包名和组件名 | ❌ 不能 | 要侧载；包名被占用，装不回真 QQ（除非先卸载空壳） |
| **保留 QQ 但禁用它**（见第四节） | 不要（要 adb） | 真 QQ 还在，包名/签名/版本全是真的；只是它的组件不参与分享选择器 | ✅ 能（因为它本来就是真 QQ） | 手机上仍留着 QQ 的安装体积 |
| LSPosed / Xposed 模块 | 要 | hook `PackageManager` 的包查询，伪造「已安装」 | ✅ 能（连签名都能一起伪造） | 需要 root + 模块环境，风险最高 |

---

## 四、强烈建议先试：留着 QQ，但把它禁用（2 分钟，零风险）

```bash
# 禁用 QQ（应用还在，但它的组件不再参与任何选择器/响应）
adb shell pm disable-user --user 0 com.tencent.mobileqq

# 想恢复
adb shell pm enable com.tencent.mobileqq
```

原理：`pm disable` 只是把包内组件设为 disabled，`getPackageInfo` 依然能查到这个包 —— 于是第三方 App 的
「分享至 QQ」入口会回来；而 QQ 被禁用的 Activity 不会出现在选择器里，所以点下去只会落到 TIM。
代价是手机里还留着 QQ 的体积（不想留就把 QQ 的数据/缓存清掉，但包必须在）。

两个注意点：

* 有些 ROM（部分 HarmonyOS / MIUI 版本）禁用后连包查询都会失败，那就没效果 —— 换空壳包。
* 如果那个 App 是用 **QQ SDK 的显式分享**（`setClassName("com.tencent.mobileqq", "...activity.JumpActivity")`），
  QQ 被禁用后会 `ActivityNotFoundException`（提示分享失败）。这种情况下**空壳包反而更合适**：
  空壳的 `JumpActivity` 会接住这次调用并把内容转给 TIM。

---

## 五、工程结构

```
QQ-share-shell/
├─ README.md                                  中文文档（本文，含哔哩哔哩实测附录）
├─ README.en.md                               英文文档
├─ LICENSE                                    MIT（署名 Elo-Mary）
├─ .gitignore / .gitattributes                忽略规则、换行符规则
├─ build-apk.ps1                              免 Gradle / 免联网的一键构建脚本
├─ build-apk.cmd                              双击版（内部就是调上面那个 ps1）
├─ check-on-device.ps1                        装完之后在电脑上跑的真机自检
├─ inspect-target-app.ps1                     体检第三方 App 的 APK，判断它查不查签名
├─ tools/DecodeTest.java                      mqqapi:// 参数解码的离线单测（不需要手机）
├─ settings.gradle / build.gradle             Android Studio 工程（可选路线，不带 wrapper）
├─ gradle.properties
└─ app/
   ├─ build.gradle                             applicationId = com.tencent.mobileqq
   └─ src/main/
      ├─ AndroidManifest.xml                   ★ 关键：包名 + 组件别名 + 分享过滤器
      ├─ java/com/tencent/mobileqq/
      │  ├─ ShellActivity.java                 唯一可见界面：状态、开关、自测
      │  ├─ RelayActivity.java                 所有 QQ 组件名的落点，分发 Intent
      │  └─ Relay.java                         转发逻辑 + mqqapi:// 分享参数解析
      └─ res/
         ├─ drawable/ic_launcher.xml           自己画的占位图标（非腾讯素材）
         └─ values/strings.xml
```

（`build/`、`dist/`、`qqshell.keystore` 属于本地产物与签名密钥，已被 `.gitignore` 排除，不在仓库里。）

Manifest 里注册了什么、为什么：

| 组件名 | 作用 |
|---|---|
| `.ShareTarget`（activity-alias） | 带 `ACTION_SEND` / `ACTION_SEND_MULTIPLE` 过滤器，让「QQ」出现在分享面板；**可在 App 里一键关闭** |
| `.activity.JumpActivity` | QQ SDK 分享/登录的显式入口，带 `mqqapi` / `mqqopensdkapi` 等 scheme |
| `.activity.LoginActivity`、`.activity.AssistActivity`、`.activity.QQBrowserActivity`、`.activity.qfileJumpActivity`、`com.tencent.open.agent.AgentActivity` | 只是「存在」，供被显式点名时接住，不带过滤器 |

**三个名字的分工**（都在 `app/src/main/res/values/strings.xml`，改名只改这一处）：

| 名字 | 值 | 出现位置 | 为什么要这样 |
|---|---|---|---|
| 仓库名 | `QQ-share-shell` | GitHub | 描述"做什么"：`share` 表明它不是 QQ 客户端（光叫 `qq-shell` 在 GitHub 上已被占用且多指 QQ 客户端），`shell` 对应中文名"空壳" |
| `string/app_name` | `空壳QQ` | 桌面图标下方、系统「应用信息」、最近任务 | 自己的名字，让人一眼看出不是真 QQ |
| `string/qq_entry_label` | `空壳QQ` | 分享面板 / 分享选择器里的那一项 | 入口能否出现只取决于**包名**，与名字无关；这里刻意**不写 `QQ`**——不冒充，也免得用户以为这一项会打开真 QQ |
| `string/project_version` | `1.0.2` | App 状态页 | 项目自己的版本号；APK 内部的 `versionName` 是故意伪装成 QQ 版本的另一个东西 |
| `string/shell_title` 等 | 界面文案 | App 内 | 说明与免责声明，集中放 strings.xml 便于以后做多语言 |

转发逻辑（`Relay.java`）要点：

* 收到 `ACTION_SEND` → 原样复制文本/图片/`ClipData` → 优先交给 `com.tencent.tim` 的分享目标；只有一个目标就直接打开，多个才弹选择器。
* 收到 `mqqapi://share/to_fri?...` → 解析 query 里的 `title/description/url/image_url`（base64 与明文都试）→ 拼成文字后转给 TIM。
* 用 `Intent.EXTRA_EXCLUDE_COMPONENTS`（API 24+）把空壳自己排除掉，避免「分享给自己」来回打转。
* 登录/支付等其它 `mqq*` 请求：只弹一句「需要真正的 QQ」，不做任何事。

---

## 六、构建

### 路线 A：免 Gradle 脚本（推荐，只要 JDK + Android SDK）

```powershell
cd <项目目录>            # 例如 clone 下来的 QQ-share-shell
powershell -ExecutionPolicy Bypass -File .\build-apk.ps1
# 或者直接双击 build-apk.cmd
# SDK 不在默认位置时（脚本会自动在 ANDROID_HOME、%LOCALAPPDATA%\Android\Sdk 等处找）：
powershell -ExecutionPolicy Bypass -File .\build-apk.ps1 -SdkRoot 'D:\Android\Sdk'
```

脚本做的是：`aapt2 compile` → `aapt2 link` → `javac` → `d8` → 重新打包（`resources.arsc` 保持未压缩）
→ `zipalign` → `apksigner` 签名（首次会自动用 `keytool` 生成 `qqshell.keystore`）。
产物在 `dist\qq-shell.apk`，最后会打印 `adb install` 命令，并做一次签名和对齐校验。

需要：JDK（`javac`/`jar`/`keytool`，8~21 均可；Android Studio 自带的 `jbr` 也行）、
Android SDK 里的 `platforms/android-XX/android.jar` 与 `build-tools`（`aapt2`/`d8`/`zipalign`/`apksigner`）。

### 路线 B：Android Studio

用 Studio 打开项目目录 → Sync → `Build > Build APK(s)`。

本工程**不带 Gradle wrapper**：`gradlew`、`gradlew.bat`、`gradle-wrapper.jar` 和
`gradle/wrapper/gradle-wrapper.properties` 都没有（二进制文件不便随源码分发，留着半套 wrapper
反而会报 `Could not find or load main class org.gradle.wrapper.GradleWrapperMain`）。
用 Studio 打开时，在 Settings → Build Tools → Gradle 里选「本机 Gradle」或指定一个 Gradle 安装位置；
想用 `./gradlew` 就自己装个 Gradle 跑一次 `gradle wrapper` 生成完整 wrapper。
若 Studio 报 AGP 版本不兼容，把根 `build.gradle` 里的 `8.2.2` 换成你 Studio 支持的版本（AGP ≥ 7.3 即可）。

最省事的依然是路线 A：那个脚本连 Gradle 都不需要。

### 离线逻辑测试（可选，不需要手机）

`mqqapi://` 分享参数的解码逻辑可以在电脑上单独验证：

```powershell
javac -encoding UTF-8 -d build\logictest tools\DecodeTest.java
java -Dstdout.encoding=UTF-8 -cp build\logictest DecodeTest
```

预期输出最后一行是 `12/12 通过`。

---

## 七、安装与验证

```bash
# 1) 装之前：确保真 QQ 已卸载（包名相同、签名不同，会 INSTALL_FAILED_UPDATE_INCOMPATIBLE）
adb uninstall com.tencent.mobileqq

# 2) 安装
adb install -r dist\qq-shell.apk
#    手机直接安装的话：需要允许「安装未知来源应用」，国产 ROM 还要关掉「纯净模式」

# 3) 一键自检（推荐，只读不改手机）
powershell -ExecutionPolicy Bypass -File .\check-on-device.ps1
```

手动等价命令（PowerShell 里 `&` 是特殊字符，所以整条远端命令用一个字符串包起来、里面用单引号保护 URL）：

```powershell
adb shell pm list packages | Select-String tencent
adb shell dumpsys package com.tencent.mobileqq | Select-String JumpActivity,ShareTarget
adb shell "cmd package query-activities -a android.intent.action.SEND -t text/plain --brief"

# 端到端：模拟 QQ SDK 的显式分享（title 是 base64 的“测试”）
adb shell "am start -a android.intent.action.VIEW -d 'mqqapi://share/to_fri?src_type=app&file_type=news&title=5rWL6K+V&url=aHR0cHM6Ly9leGFtcGxlLmNvbQ==' -n com.tencent.mobileqq/com.tencent.mobileqq.activity.JumpActivity"
# 预期：弹出「空壳 QQ：已把内容转给 TIM」并打开 TIM 的分享界面
```

也可以不动电脑：打开壳的桌面图标（「空壳QQ」）→「自测：把一段文字转发给 TIM」。

### 不走 adb 的手动安装 + 4 步自测

1. **把 APK 传到手机**——只需要 `dist\qq-shell.apk`（`.idsig` 那个文件不用管）：
   * 数据线连上，选「传输文件」，把 APK 拷到手机存储根目录或 Download 目录；
   * 或者用局域网传输工具（LocalSend、KDE Connect 之类）直接发到手机；
   * 用微信/QQ 传要注意：它们可能把文件名改成 `xxx.apk.1`，装上之前得改回 `.apk`。
2. **安装**：需要打开「允许安装未知来源应用」；国产 ROM 还要临时关掉「纯净模式 / 安全守护」。
   若提示 **签名冲突 / 应用未安装**，说明手机上还有真 QQ 或旧空壳，先卸载 `com.tencent.mobileqq`。
3. **装完先看壳自己的状态页**（打开桌面图标「空壳QQ」），确认三件事：
   * 包名是 `com.tencent.mobileqq`；
   * TIM：已安装；
   * 「在分享面板里显示“QQ”这一项」是勾选状态。
   然后点「自测：把一段文字转发给 TIM」——能打开 TIM 就说明转发链路是通的。
4. **去目标 App 实测**（例如哔哩哔哩 → 某个视频 → 分享），对着下表看结果：

| 看到的现象 | 含义 | 下一步 |
|---|---|---|
| 「分享至 QQ」回来了，点它直接进 TIM | 完全成功 | 收工 |
| 「分享至 QQ」回来了，点它先弹「QQ / TIM」选择器 | 也成功（跟你装 QQ 时的现象一致），选 TIM 即可 | 收工 |
| 「分享至 QQ」回来了，点它报「分享失败/取消」，但 TIM 已经打开并带上了内容 | 走的是 QQ SDK 显式分享，内容已转交 TIM，只是拿不到成功回执 | 可用，忽略那个提示 |
| 「分享至 QQ」依然不显示 | 该 App 还有别的判定层（或它在校验签名） | 用第四节的「保留真 QQ 但禁用」方案 |

回报时最有用的信息：**App 名称+版本**、属于上表哪一种、以及（如果方便）壳状态页的截图。

真机实测第三方 App 时，用 logcat 看空壳这边到底走了哪条路：

```bash
adb logcat -c
adb logcat -s QQShell
# 然后在那个 App 里点一次「分享至 QQ」，回来看看这几行：
#   dispatch: action=… scheme=…
#   forward: 候选分享目标 N 个（TIM x，其它 y）
#   forward: 直接投给 com.tencent.tim/…（或 “弹出发送选择器”）
```

日志有意**不记录分享内容**（正文、链接、图片地址都不打），只记录类型、数量与是否为空 —— 贴给别人看也不会泄露你分享了什么。

---

## 八、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 手机上还有真 QQ 或旧签名的空壳，先 `adb uninstall com.tencent.mobileqq` |
| 分享面板里没有「QQ」 | 开关被关了：App 内勾选，或 `adb shell pm enable com.tencent.mobileqq/com.tencent.mobileqq.ShareTarget` |
| 分享面板有「QQ」，点了没反应 | 内容既没文字也没图片（`Relay` 会提示）；或把 TIM 的分享目标禁用了 |
| 点了「分享至 QQ」，原 App 提示「分享取消/失败」 | 它走的是 QQ SDK 显式分享，内容其实已经进 TIM 了（ActivityResult 拿不到 QQ 的成功回执，属预期）；空壳无法伪造 SDK 的成功响应 |
| 那个 App 仍然不显示「分享至 QQ」 | 它在校验 QQ 签名 —— 空壳过不去。改用第四节的「禁用真 QQ」，或者接受它没有这个入口 |
| 空壳装好后 QQ 登录/QQ 支付不能用了 | 预期行为：空壳不实现这些 |
| 脚本报找不到 SDK / build-tools | 用 `-SdkRoot` 指定；或在 SDK Manager 里装 Android SDK Platform 与 Build-Tools |
| `d8` 报内部错误：`NullPointerException: Cannot invoke "String.length()" because "<parameter1>" is null` | 新版 javac（21+）给匿名内部类/非静态内部类生成的合成字段 `this$0`，会让 build-tools 34 里的 R8 8.2.2 内部崩溃。本工程已经把监听器都写成「静态嵌套类 + 显式持有引用」来规避（见 `ShellActivity` 末尾注释）。你自己加代码时不要用匿名内部类捕获外部实例；或换更新的 build-tools |
| 桌面图标和分享面板里都叫「空壳QQ」 | 刻意如此：入口能否出现只取决于包名，名字不写 `QQ`，不冒充。见上文「三个名字的分工」 |
| 想知道某次分享为什么没成功 | 另开窗口跑 `adb logcat -s QQShell`，日志会打印收到的 action/scheme、候选目标数量、最终投给了谁；**日志不记录分享内容** |

---

## 九、卸载与回滚

```bash
adb uninstall com.tencent.mobileqq
# 或在 设置 → 应用 里找到「空壳QQ」卸载
```

**装回真正的 QQ 之前必须先卸载空壳**，否则签名冲突装不上。
如果之前用过第四节的禁用方案：`adb shell pm enable com.tencent.mobileqq`。

---

## 十、风险与合规

App 首屏的「免责声明与使用限制」全文如下（同样内置于 `res/values/strings.xml`）：

* **非官方**：本工程是独立的第三方个人项目，与腾讯公司及其关联公司没有任何关系，未获其授权、认可或赞助。
  「QQ」「TIM」等名称与商标归各自权利人所有，此处仅用于说明兼容对象与用途。工程内不含任何腾讯代码、资源或数据。
* **本应用做什么**：只在你自己的设备上使用与 QQ 相同的包名与若干同名组件名，并把收到的分享内容原样转交给你指定的应用；
  它不修改其它任何应用、不读取其它应用的数据，也不破解或绕过任何签名校验与保护措施。
* **隐私**：不联网，不收集、不上传任何数据；**不申请任何权限**（连包可见性都用 `<queries>` 声明解决，没有 `QUERY_ALL_PACKAGES`）。
* **使用限制**：仅限在你自己拥有或有权管理的设备上、为个人使用与学习研究而安装使用。不得用于他人的或未经同意的设备；
  不得用于欺骗、冒充或误导任何人；不得用于绕过任何安全机制、风控或授权校验；不得以任何形式分发、转售、上架应用商店或用于商业用途。
* **风险与责任**：按「现状」提供，不附带任何明示或默示担保。使用它可能与你设备上某些应用的服务条款不一致，也可能导致
  这些应用功能异常（例如 QQ 登录、QQ 支付不可用）。是否使用、以及使用所产生的一切后果（包括账号、数据、设备与法律后果）
  均由使用者自行承担，作者不承担任何责任。请在使用前自行确认所在地法律以及所使用应用的服务条款。
* **权利人**：若权利人认为本工程或其仓库内容不妥，请通过仓库 Issue 联系，作者将在收到通知后立即停止分发并删除相关内容。
* **不同意即卸载**：本声明自安装之日起生效；不同意其中任何一条请不要使用并立即卸载。本应用仅建议作为**临时性方案**：
  问题解决后请在 24 小时内自行卸载，以恢复设备原状。
* 部分系统（Play 保护、国产 ROM 的纯净模式）可能对侧载的这种包给出安全提示；若某个 App 因为签名/完整性校验而出现异常行为，与本工程无关。

> **一句实话**：免责声明**不能**免除侵权责任、也不能替代授权，它只能明确项目定位、使用边界与责任归属。
> 真正降低风险的做法是：只在自有设备上使用、不分发、不上架、不用它去影响别人的设备。
> 也因此，本工程刻意不含腾讯代码、不用腾讯图标素材，并在 App 内与仓库里都写明非官方。

### 本项目如何避免「碰瓷」

包名兼容是**功能必需**（宿主应用就是按包名判断的），除此之外一律不沾：

| 可能被看成"碰瓷"的做法 | 本项目的做法 |
|---|---|
| 用 QQ 的名字出现在分享面板 | ❌ 不做：分享面板里显示的是「空壳QQ」（`string/qq_entry_label`），功能并不依赖这个名字 |
| 应用名 / 桌面名冒充 QQ | ❌ 不做：应用名是「空壳QQ」 |
| 使用 QQ 的图标素材 | ❌ 不做：图标是自己画的矢量图 |
| 把版本的品牌露出做得像官方 | ❌ 不做：APK 内部 `versionName` 虽为 `8.9.90`（SDK 版本判断需要），但状态页明确标注它不是项目版本、且这是伪装值 |
| 宣称兼容 QQ 官方能力 | ❌ 不做：README 与 App 内都写明不提供 QQ 登录/支付，且会在校验签名的 App 上失效 |

---

## 兼容性记录（欢迎共建）

这是最有用的一份清单：**哪些 App 能用、为什么不能用**。请按同样格式提 Issue 补充。

| App | 版本 | 判定方式 | 结果 |
|---|---|---|---|
| 哔哩哔哩 (`tv.danmaku.bili`) | 8.22.0 | 只 `getPackageInfo("com.tencent.mobileqq", 0)`，不校验签名 | ✅ 可用（详见文末附录的反汇编证据） |
| 微信 (`com.tencent.mm`) 分享 | — | 微信 SDK 会校验微信自己的签名 | ❌ 不适用本方案（同思路做微信空壳也不行） |

自测某个 App 前，先跑一遍：`powershell -ExecutionPolicy Bypass -File .\inspect-target-app.ps1 -ApkPath '某个.apk'`，
它会告诉你这个 App 有没有签名校验痕迹。

---

## 附录：静态分析实测案例——哔哩哔哩 8.22.0（`tv.danmaku.bili`）

拿真实 APK（29 个 dex，未加固，targetSdk 34，已声明 `QUERY_ALL_PACKAGES`）逐层挖了一遍判定链，结论是
**这个 App 上空壳应当有效**。证据如下。

**1. 入口判定只看包名，不看签名（决定性）**

`Tencent.isQQInstalled(Context)` 只是转发，真正实现在 `com.tencent.open.utils.i.b(Context)`，
反汇编出来就是一句：

```
const-string v2, "com.tencent.mobileqq"
invoke-static {pm, "com.tencent.mobileqq", 0}  getPackageInfo   ← flags = 0，没有 GET_SIGNATURES
  ├─ 成功 → "isQQInstalled true" → return true
  └─ NameNotFoundException → return false
```

常量池里**没有** `GET_SIGNATURES`/签名比对逻辑，方法也不做版本比较 → 只要有个叫
`com.tencent.mobileqq` 的包在，它就认为 QQ 装着。

**2. 签名校验代码不属于 QQ 路径**

全部签名相关方法都归属于别的 SDK：

| 方法 | 归属 |
|---|---|
| `validateAppSignatureForPackage` / `validateAppSignature` | `com/tencent/mm/opensdk/openapi/WXApiImplComm`（微信 SDK） |
| `checkSignature` | `com/tencent/mm/opensdk/openapi/BaseWXApiImplV10`（微信 SDK） |
| `verifySignature` | `com/tencent/smtt/sdk/stat/MttLoader`（X5 内核） |

QQ SDK 那侧（`Lcom/tencent/tauth/Tencent;`）只有 `isQQInstalled` / `isQQinstalled` / `shareToQQ` /
`isSupportShareToQQ` / `startIMAio` 这些正常 API。**没有任何签名校验。**（注意：微信那条路是校验签名的，
所以"分享到微信"用同样的空壳思路是不行的。）

**3. 分享的投递方式，本工程的组件别名正好都覆盖**

QQ SDK 的 dex 里**根本没有** `com.tencent.mobileqq.activity.JumpActivity` 这个字符串
（搜到的 `JumpActivity` 全是华为 HMS 和哔哩哔哩自己的 `GameRedirectJumpActivity`），
它只有这些 URI 模板：

```
mqqapi://share/to_fri?src_type=app&version=1&file_type=news
mqqapi://share/to_qzone?...
mqqapi://im/chat?...
mqqapi://opensdk/...
```

以及一个硬编码组件名 `com.tencent.open.agent.AgentActivity`。
也就是说它靠 **mqqapi 这个 scheme** 去解析由谁来处理（真 QQ 的 manifest 里注册了该 scheme）。
本工程的 `.activity.JumpActivity` 别名注册了同一批 scheme，`com.tencent.open.agent.AgentActivity`
也注册了同名别名，所以这两条路都能被接住并转给 TIM。

**待真机确认的**：哔哩哔哩自己的分享面板是否还有别的判定（例如服务端开关、隐私合规层
`__Ghost$Insertion$com_bilibili_privacy_PrivacyGhost_getPackageInfo` 在未同意隐私政策前是否拦截包查询）。

---

## 准备发布到 GitHub（尚未发布）

代码与文档已经是可以直接放上去的状态，剩下的都是可选项：

| 项目 | 状态 |
|---|---|
| 仓库名 | ✅ <https://github.com/Elo-Mary/QQ-share-shell> |
| 发版流程 | 改 `app/src/main/res/values/strings.xml` 里的 `string/project_version`（与 tag 一致）→ 构建 → 打 tag → 在网页上建 Release 并上传 `dist\qq-shell.apk` |
| 仓库 Description | 可直接粘贴：`Unofficial shell that makes apps show "Share to QQ" again, then relays the shared content to TIM. 空壳QQ` |
| 仓库 Topics | 建议：`android`、`tim`、`share-sheet`、`compatibility-shim`、`java`、`apk` |
| LICENSE | ✅ 已加 [LICENSE](LICENSE)（MIT），署名 Elo-Mary |
| 英文文档 | ✅ 已加 [README.en.md](README.en.md)（英文摘要 + 原理 + 限制 + 免责声明） |
| `.gitignore` | ✅ 已忽略 `build/`、`dist/`、`*.keystore`、`*.jks` 以及本地分析用的第三方 APK |
| 界面文案 | ✅ 全部集中在 `res/values/strings.xml`，改名/多语言只动这一处 |
| 配套脚本 | ✅ 真机自检 `check-on-device.ps1`、APK 体检 `inspect-target-app.ps1`、离线单测 `tools/DecodeTest.java` |
| Release 签名 | 现在用的 `qqshell.keystore` 由首次构建自动生成（不会提交）。要让别人能覆盖安装你的 Release 包，请自己备份好它；丢了就只能换签名，老版本无法覆盖升级 |
| 免责声明 | App 内「说明与免责声明」与本文第十节都已写好；发布时建议在 Release 说明里再贴一遍 |

发布动作（仓库已建好并克隆到本地，项目文件已就位）：`git add -A` → `git commit -m "Initial commit"` →
`git push -u origin main` → 打 `v1.0.0` 标签并在 Release 里附上 `dist\qq-shell.apk`。
`git push` 需要你的 GitHub 凭据，建议你自己执行。

---

## 交付状态

**已编译出可安装的 APK、做过静态验证，并在真机上实测通过**（2026-10-10）：

* 工具链：JDK 23.0.2 + Android SDK（build-tools 34.0.0 + platform android-36）。
  用这套组合时注意上文的 R8 陷阱：build-tools 34 的 R8 8.2.2 配 JDK 21+ 会崩，本工程已用静态嵌套类规避。
* 产物：`dist\qq-shell.apk`（v1.0.2 为 32.5 KB），签名密钥 `qqshell.keystore`（首次构建自动生成，SHA-1 `AC:5D:F4:51:09:34:2B:0F:1F:81:0D:8F:36:8D:08:32:99:93:21:46`，
  与 App 状态页里显示的一致）。该密钥已被 `.gitignore` 排除，请自行备份。
* v1.0.2 的改动：**权限归零**（移除 `QUERY_ALL_PACKAGES`）、分享面板里显示「空壳QQ」不再冒充 QQ、
  加 `QQShell` logcat 日志（不含分享内容）、状态页显示项目版本。

已经验证过的项：

| 验证项 | 结果 |
|---|---|
| 包名 / 版本 / 名称 | `com.tencent.mobileqq`，versionName `8.9.90`（伪装值，为过 QQ SDK 的版本判断）；项目版本见状态页；应用名、桌面名与分享面板那一项都是 `空壳QQ` |
| `uses-sdk` | minSdk 21，targetSdk 34 |
| 权限 | **零权限**（不声明任何 `uses-permission`；包可见性靠 `<queries>` 声明解决） |
| `resources.arsc` | 未压缩（Android 11+ 的硬要求） |
| 对齐 | `zipalign -c 4` 通过 |
| 签名 | v1 + v2 + v3 三套方案均通过 `apksigner verify` |
| 组件与过滤器 | `.ShareTarget`（含两个不带 data 的探测用过滤器）、`.activity.JumpActivity`（mqqapi 等 scheme）、其余 8 个占位别名，均已进入二进制清单 |
| `mqqapi://` 参数解码 | 离线单测 `tools/DecodeTest.java` **12/12 通过**（含加号/减号两种 base64、无 padding、URL 编码、明文、空值） |
| 真机实测 | ✅ **已确认可行**：装上后目标 App 的「分享至 QQ」入口恢复，分享内容成功进入 TIM |

**结论**：方案成立且已在真机跑通。剩下唯一会失效的情形是宿主 App 校验 QQ 的签名（见第二节与附录的实测案例）。

第一次在别处构建若报错，把完整报错贴回来即可，多半是 SDK 路径 / JDK 版本 / build-tools 版本这类环境问题。
