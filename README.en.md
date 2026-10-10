# QQ-share-shell (空壳QQ)

A tiny Android app that makes third-party apps believe **QQ is still installed**, so their
*"Share to QQ"* entry comes back — and then relays whatever you shared to **TIM**.

* Repository: <https://github.com/Elo-Mary/QQ-share-shell>
* 中文文档 / Chinese docs: [README.md](README.md)
* License: MIT (see [LICENSE](LICENSE))

> **Not affiliated with Tencent.** This project contains no Tencent code, resources or data.
> It makes no network requests and asks for no sensitive permissions. It is meant for personal
> use on your own device — do not publish it to app stores.

**Naming note:** the repository is named `QQ-share-shell`, deliberately not `qq-shell` — that name is
already taken on GitHub and usually means *a QQ client or terminal* there, so `share` is included to say
what this project actually does. GitHub treats repository names case-insensitively, so
`qq-share-shell` resolves to the same place. Inside the app, three different names are used on purpose —
the launcher name (`空壳QQ` / `string/app_name`), the entry shown in share sheets
(`QQ` / `string/qq_entry_label`, which must stay `QQ`), and the package name
(`com.tencent.mobileqq`, which is what host apps probe for). See the Chinese README for the full table.

---

## Why the "Share to QQ" entry disappears

The entry is not a system feature: the host app draws it itself, usually after calling the QQ
SDK's `Tencent.isQQInstalled()`, or simply
`getPackageManager().getPackageInfo("com.tencent.mobileqq", 0)`.

TIM's package is `com.tencent.tim` — a **different** constant (`Constants.PACKAGE_TIM`) that most
apps never check. So once you uninstall QQ, step 2 fails and the entry vanishes, even though TIM
can receive the share perfectly well.

## How it works

1. **The package name does the work.** The app is installed as `com.tencent.mobileqq` with
   `versionName 8.9.90`, so package-existence probes (and minimum-version checks) succeed.
2. **Component aliases** mirror the QQ-side component names a QQ SDK might address — including
   `com.tencent.mobileqq.activity.JumpActivity` with the `mqqapi` / `mqqopensdkapi` schemes, and
   `com.tencent.open.agent.AgentActivity` — plus a `.ShareTarget` alias carrying `ACTION_SEND`
   filters so that "QQ" appears in share sheets (toggleable at runtime from the app).
3. **Everything is relayed to TIM.** `mqqapi://share/to_fri?...` payloads are parsed (both
   base64 alphabets and plain text are handled) and forwarded to TIM's share targets. The shell
   excludes itself from the chooser, so it can never loop back into itself.

The app contains no QQ code at all: it is a package-name shell plus an Intent relay.

## What it can and cannot do

| How the host app detects QQ | Works? |
|---|---|
| `getPackageInfo("com.tencent.mobileqq")` exists | ✅ |
| …and requires a minimum `versionName` | ✅ (`8.9.90`) |
| …and looks for QQ component names | ✅ |
| …and enumerates `ACTION_SEND` targets | ✅ |
| **…and verifies QQ's signing certificate** | ❌ impossible without Tencent's key |
| QQ login / QQ Pay / other QQ features | ❌ not implemented (the app says so politely) |

Quick pre-check before building for a specific app: `inspect-target-app.ps1` greps the target
APK's dex files for signature-validation symbols (`checkQQAppSignature`, `isSignatureValid`, …).

## Build

**Option A — standalone script.** Needs only a JDK (`javac`, `jar`, `keytool`) and the Android
SDK (a `platforms/android-XX/android.jar` and `build-tools`). No Gradle, no network:

```powershell
cd qq-shell
powershell -ExecutionPolicy Bypass -File .\build-apk.ps1
# or just double-click build-apk.cmd
# if the SDK lives elsewhere:
powershell -ExecutionPolicy Bypass -File .\build-apk.ps1 -SdkRoot 'D:\Android\Sdk'
```

The script runs `aapt2 compile` → `aapt2 link` → `javac` → `d8` → repack (keeping
`resources.arsc` uncompressed, as Android 11+ requires) → `zipalign` → `apksigner`
(generating a keystore on first run). Output: `dist\qq-shell.apk`.

**Option B — Android Studio.** Open the folder, then *Build → Build APK(s)*. The project ships no
Gradle wrapper at all — `gradlew`, `gradlew.bat`, `gradle-wrapper.jar` and the wrapper properties
are all absent, since a half-present wrapper only produces
`Could not find or load main class org.gradle.wrapper.GradleWrapperMain`. Point Android Studio at a
local Gradle distribution (Settings → Build Tools → Gradle), or install Gradle and run
`gradle wrapper` once to generate a complete wrapper. Option A needs no Gradle whatsoever.

**Offline logic test** (no device needed):

```powershell
javac -encoding UTF-8 -d build\logictest tools\DecodeTest.java
java -Dstdout.encoding=UTF-8 -cp build\logictest DecodeTest    # expect: 12/12 通过
```

## Install

```bash
# real QQ (or an older build of this shell) must be gone first: same package name, different signature
adb uninstall com.tencent.mobileqq
adb install -r dist\qq-shell.apk

# 5 read-only checks on the device
powershell -ExecutionPolicy Bypass -File .\check-on-device.ps1
```

Manual install: copy `dist\qq-shell.apk` to the phone, allow installs from unknown sources, and
(on Chinese ROMs) temporarily turn off "Pure Mode".

Expected result: *"Share to QQ"* reappears. Tapping it either lands in TIM directly or shows a
**QQ / TIM** chooser — pick TIM.

## Troubleshooting highlights

| Symptom | Cause / fix |
|---|---|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | real QQ or an older shell is still installed — uninstall `com.tencent.mobileqq` first |
| `d8` fails with `NullPointerException: Cannot invoke "String.length()" because "<parameter1>" is null` | R8 8.2.2 (build-tools 34) crashes on the synthetic `this$0` field that javac 21+ emits for anonymous/non-static inner classes. This project deliberately uses **static nested classes** for its listeners (see the comment in `ShellActivity`); do the same in your own code, or use newer build-tools |
| Entry still missing on a particular app | that app verifies QQ's signature — use the "keep real QQ but disable it" route instead |
| Share panel has no "QQ" item | the toggle in the app is off, or `adb shell pm enable com.tencent.mobileqq/com.tencent.mobileqq.ShareTarget` |

## Case study: Bilibili 8.22.0 (`tv.danmaku.bili`)

From static analysis of the real APK (full disassembly evidence in the Chinese README):

* `Tencent.isQQInstalled()` → `com.tencent.open.utils.i.b(Context)` is literally
  `getPackageInfo("com.tencent.mobileqq", 0)` — **no signature check, no version check**. The
  shell therefore passes.
* Every signature-validation symbol in that APK belongs to the **WeChat** SDK
  (`WXApiImplComm.validateAppSignatureForPackage`) or the X5 kernel — **not** the QQ path.
  One consequence worth repeating: this trick does **not** work for sharing to WeChat.
* The QQ SDK never hardcodes `…activity.JumpActivity`; it ships `mqqapi://share/to_fri?…`
  URI templates plus the component `com.tencent.open.agent.AgentActivity`. Both are covered by
  this project's aliases.

## Alternatives

| Route | Root required | Bypasses signature checks |
|---|---|---|
| This shell APK | no | no |
| Keep real QQ installed but disable it:<br>`adb shell pm disable-user --user 0 com.tencent.mobileqq` | no (adb only) | yes — it *is* real QQ |
| LSPosed / Xposed module | yes | yes |

## Uninstall / rollback

```bash
adb uninstall com.tencent.mobileqq
```

Uninstall the shell **before** installing real QQ again, otherwise the install fails on the
signature mismatch.

## License and disclaimer

MIT — see [LICENSE](LICENSE).

This is an unofficial, independent project for personal use. It is not affiliated with or
endorsed by Tencent; "QQ" and "TIM" are trademarks of their respective owners and are used here
only to describe interoperability. Do not ship it to app stores, and do not use it against
other people's devices.
