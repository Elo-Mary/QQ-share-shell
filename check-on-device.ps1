#Requires -Version 5.1
<#
.SYNOPSIS
    装完空壳 QQ 之后，在电脑上跑一遍真机自检（需要 platform-tools 里的 adb）。

.DESCRIPTION
    依次检查：
      1) 设备是否连上（adb devices）
      2) com.tencent.mobileqq 是否在包列表里、TIM 是否在
      3) 壳里的关键组件（JumpActivity / ShareTarget / RelayActivity）是否被系统识别
      4) 系统能否把“分享文字”解析到空的 QQ 包
      5) 端到端测试 QQ SDK 的显式分享路径（mqqapi://share/to_fri）
    只读不写，不会改动手机上的任何东西（第 5 步会拉起一次分享界面）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\check-on-device.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\check-on-device.ps1 -SkipShareTest
#>
[CmdletBinding()]
param(
    [string]$SdkRoot,
    [string]$PackageName = 'com.tencent.mobileqq',
    [string]$TimPackage = 'com.tencent.tim',
    [switch]$SkipShareTest
)

$ErrorActionPreference = 'Stop'

function Write-Section([string]$message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

function Write-Pass([string]$message) {
    Write-Host "    [OK] $message" -ForegroundColor Green
}

function Write-Fail([string]$message) {
    Write-Host "    [!!] $message" -ForegroundColor Yellow
}

function Find-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @()
    if ($SdkRoot) { $candidates += (Join-Path $SdkRoot 'platform-tools\adb.exe') }
    if ($env:ANDROID_HOME) { $candidates += (Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe') }
    if ($env:ANDROID_SDK_ROOT) { $candidates += (Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe') }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk\platform-tools\adb.exe'),
        'C:\Android\Sdk\platform-tools\adb.exe'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

$adb = Find-Adb
if (-not $adb) {
    throw "没找到 adb。请安装 Android SDK Platform-Tools，或用 -SdkRoot 'D:\Android\Sdk' 指定 SDK 位置。"
}
Write-Host "使用 adb：$adb" -ForegroundColor DarkGray

# ---------------------------------------------------------------- 1 设备
Write-Section "1/6 检查设备连接"
$devices = & $adb devices
$devices | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
$online = @($devices | Where-Object { $_ -match '\sdevice$' })
if ($online.Count -eq 0) {
    Write-Fail "没有处于 device 状态的设备。请在手机上打开「USB 调试」并允许本机调试授权。"
    exit 1
}
Write-Pass "已连接 $($online.Count) 台设备"

# ---------------------------------------------------------------- 2 包
Write-Section "2/6 检查包是否安装"
$packages = & $adb shell pm list packages
$hasShell = @($packages | Where-Object { $_.Trim() -eq "package:$PackageName" }).Count -gt 0
$hasTim = @($packages | Where-Object { $_.Trim() -eq "package:$TimPackage" }).Count -gt 0
if ($hasShell) {
    Write-Pass "$PackageName 已安装（空壳在）"
} else {
    Write-Fail "$PackageName 没装上 —— 先 adb install -r dist\qq-shell.apk"
}
if ($hasTim) {
    Write-Pass "$TimPackage 已安装（转发目标在）"
} else {
    Write-Fail "$TimPackage 没装 —— 空壳收到分享后会提示找不到 TIM"
}
if (-not $hasShell) { exit 1 }

# ---------------------------------------------------------------- 3 组件
Write-Section "3/6 检查关键组件"
$dump = & $adb shell dumpsys package $PackageName
$wanted = @(
    @{ Name = 'activity.JumpActivity'; Hint = 'QQ SDK 显式分享入口' },
    @{ Name = 'ShareTarget';            Hint = '分享面板里的“QQ”条目' },
    @{ Name = 'RelayActivity';          Hint = '实际转发者' }
)
foreach ($item in $wanted) {
    if (@($dump | Select-String -SimpleMatch $item.Name).Count -gt 0) {
        Write-Pass "$($item.Name)（$($item.Hint)）"
    } else {
        Write-Fail "$($item.Name) 没找到（$($item.Hint)）"
    }
}
$aliasState = @($dump | Select-String -Pattern 'ShareTarget' -SimpleMatch)
if ($aliasState.Count -gt 0 -and @($dump | Select-String -Pattern 'disabledComponents' -SimpleMatch).Count -gt 0) {
    Write-Host "    提示：若 ShareTarget 出现在 disabledComponents 段里，说明分享面板条目被关了（App 内开关，或 adb shell pm enable $PackageName/$PackageName.ShareTarget）。" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 4 分享目标解析
Write-Section "4/6 系统能否把分享解析到这个包（Android 11+）"
$query = & $adb shell "cmd package query-activities -a android.intent.action.SEND -t text/plain --brief" 2>&1
if ($query -match 'Unknown command' -or $query -match 'Error') {
    Write-Fail "这台设备不支持 cmd package query-activities（需要 Android 11+），跳过。"
} else {
    $hits = @($query | Select-String -SimpleMatch $PackageName)
    if ($hits.Count -gt 0) {
        Write-Pass "系统把 text/plain 分享解析到了 $PackageName"
        $hits | ForEach-Object { Write-Host "         $($_.Line.Trim())" -ForegroundColor DarkGray }
    } else {
        Write-Fail "系统没有把分享解析到 $PackageName —— 检查 ShareTarget 是否被禁用"
    }
}

# ---------------------------------------------------------------- 5 端到端（多条投递路径）
Write-Section "5/6 端到端测试投递路径"
if ($SkipShareTest) {
    Write-Host "    已按 -SkipShareTest 跳过" -ForegroundColor DarkGray
} else {
    $cases = @(
        @{ Name = 'QQ SDK 显式分享（JumpActivity + mqqapi）'
           Cmd  = "am start -a android.intent.action.VIEW -d 'mqqapi://share/to_fri?src_type=app&file_type=news&title=5rWL6K+V&url=aHR0cHM6Ly9leGFtcGxlLmNvbQ==' -n $PackageName/$PackageName.activity.JumpActivity" },
        @{ Name = '包限定 scheme（mqqopensdkapi，模拟只凭包名+scheme 的投递）'
           Cmd  = "am start -a android.intent.action.VIEW -d 'mqqopensdkapi://bizAgent/test?src_type=app' -p $PackageName" },
        @{ Name = '隐式 ACTION_SEND（应弹选择器，列表里是「空壳QQ」和 TIM）'
           Cmd  = "am start -a android.intent.action.SEND -t 'text/plain' --es android.intent.extra.TEXT 'shell self test'" }
    )
    foreach ($case in $cases) {
        Write-Host "    · $($case.Name)" -ForegroundColor DarkGray
        $result = & $adb shell $case.Cmd 2>&1
        $result | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        if ($result -match 'Error|Exception|does not exist|Unable') {
            Write-Fail "失败：$($case.Name)"
        } else {
            Write-Pass "已拉起：$($case.Name)"
        }
        Start-Sleep -Milliseconds 900
    }
}

# ---------------------------------------------------------------- 6 权限面
Write-Section "6/6 检查权限面（应为零权限）"
$permBlock = @(& $adb shell dumpsys package $PackageName 2>&1 |
    Select-String -Pattern 'requested permissions:' -Context 0,8 |
    ForEach-Object { $_.Context.PostContext })
$permText = ($permBlock -join "`n")
if ($permText -match 'QUERY_ALL_PACKAGES') {
    Write-Fail "仍声明了 QUERY_ALL_PACKAGES —— 应已移除"
} elseif ($permText.Trim().Length -eq 0) {
    Write-Pass "没有任何 requested permissions（零权限）"
} else {
    Write-Pass "权限列表里没有 QUERY_ALL_PACKAGES"
    $permBlock | Where-Object { $_.Trim() } | Select-Object -First 5 | ForEach-Object { Write-Host "        $($_.Trim())" -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "自检结束。接下来：在真正的第三方 App 里点一次「分享至 QQ」。" -ForegroundColor Cyan
Write-Host "若那个 App 仍然不显示入口，说明它校验了 QQ 的签名 —— 请改用 README 第四节的「禁用真 QQ」。" -ForegroundColor Cyan
Write-Host "排查分享失败时另开窗口跑：adb logcat -s QQShell（日志不含分享内容，只记录类型与数量）" -ForegroundColor Cyan
