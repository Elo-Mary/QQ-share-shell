#Requires -Version 5.1
<#
.SYNOPSIS
    粗略体检一个第三方 App 的 APK：它到底是怎么判断“QQ 装没装”的，会不会校验签名。

.DESCRIPTION
    不反编译、不用额外工具，直接在 APK 里的 classes*.dex 中做字符串搜索：
      · 出现 com.tencent.mobileqq  -> 它会探测 QQ 包名（空壳有机会）
      · 出现 com.tencent.tim       -> 它本来就认识 TIM（你可能根本不需要空壳）
      · 出现 isQQInstalled / PACKAGE_QQ / Tencent  -> 它用了 QQ SDK
      · 出现 checkQQAppSignature / isQQAppSignatureValid / isSignatureValid
        -> 它很可能会校验 QQ 的签名，空壳基本没戏
      · GET_SIGNATURES / signatures / MessageDigest 与 getPackageInfo 同时出现
        -> 有签名比对的味道，同样偏悲观
    这只是启发式判断，不是结论；最终以真机实测为准。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\inspect-target-app.ps1 -ApkPath 'D:\某App.apk'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApkPath
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ApkPath)) { throw "找不到文件：$ApkPath" }

Add-Type -AssemblyName System.IO.Compression.FileSystem

$keywords = [ordered]@{
    'com.tencent.mobileqq'    = '探测 QQ 包名'
    'com.tencent.tim'         = '认识 TIM 包名'
    'com.tencent.minihd.qq'   = '认识 QQ HD 包名'
    'isQQInstalled'           = 'QQ SDK 的“是否安装”接口'
    'PACKAGE_QQ'              = 'QQ SDK 常量'
    'Tencent'                 = 'QQ SDK 类名痕迹'
    'checkQQAppSignature'     = '★ 可能校验 QQ 签名'
    'isQQAppSignatureValid'   = '★ 可能校验 QQ 签名'
    'isSignatureValid'        = '★ 可能校验签名'
    'GET_SIGNATURES'          = '读取签名'
    'getPackageInfo'          = '查询包信息'
}

$found = @{}
foreach ($key in $keywords.Keys) { $found[$key] = 0 }

$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ApkPath).Path)
try {
    $dexEntries = @($zip.Entries | Where-Object { $_.FullName -match '\.dex$' })
    if ($dexEntries.Count -eq 0) { throw "这个 APK 里没有 classes*.dex（是 split APK / AAB 拆分包吗？）" }
    Write-Host "扫描 $($dexEntries.Count) 个 dex 文件…" -ForegroundColor DarkGray

    foreach ($entry in $dexEntries) {
        $stream = $entry.Open()
        $memory = New-Object System.IO.MemoryStream
        try {
            $stream.CopyTo($memory)
        } finally {
            $stream.Dispose()
        }
        $text = [System.Text.Encoding]::ASCII.GetString($memory.ToArray())
        $memory.Dispose()
        foreach ($key in $keywords.Keys) {
            $index = $text.IndexOf($key)
            while ($index -ge 0) {
                $found[$key] = $found[$key] + 1
                $index = $text.IndexOf($key, $index + 1)
            }
        }
    }
} finally {
    $zip.Dispose()
}

Write-Host ""
Write-Host "搜索关键字：" -ForegroundColor Cyan
foreach ($key in $keywords.Keys) {
    $count = $found[$key]
    $mark = if ($count -gt 0) { '[命中]' } else { '[  -  ]' }
    $color = if ($count -gt 0) { 'Green' } else { 'DarkGray' }
    Write-Host ("    {0} {1,-24} {2,-22} x{3}" -f $mark, $key, $keywords[$key], $count) -ForegroundColor $color
}

$signatureRisk = ($found['checkQQAppSignature'] + $found['isQQAppSignatureValid'] + $found['isSignatureValid']) -gt 0
$touchesQq = $found['com.tencent.mobileqq'] -gt 0
$knowsTim = $found['com.tencent.tim'] -gt 0

Write-Host ""
Write-Host "判断：" -ForegroundColor Cyan
if ($signatureRisk) {
    Write-Host "    这个 App 有签名校验的痕迹，空壳包很可能被识破。" -ForegroundColor Yellow
    Write-Host "    建议先走 README 第四节的「保留真 QQ 但禁用」方案（真签名，能过校验）。" -ForegroundColor Yellow
} elseif ($touchesQq) {
    Write-Host "    它探测了 QQ 包名，且没看到明显的签名校验痕迹 —— 空壳包值得一试。" -ForegroundColor Green
} else {
    Write-Host "    没发现它探测 com.tencent.mobileqq，那「分享至 QQ」入口的消失可能是别的原因，" -ForegroundColor Yellow
    Write-Host "    建议先把它的分享逻辑用 jadx 看一眼，再来决定。" -ForegroundColor Yellow
}
if ($knowsTim) {
    Write-Host "    另外：它认识 com.tencent.tim，可能本来就有 TIM 的支持（也许有开关，不需要空壳）。" -ForegroundColor Green
}
if ($found['Tencent'] -gt 0 -and -not $signatureRisk) {
    Write-Host "    它用了 QQ SDK，但没搜到签名校验关键字 —— 注意 SDK 里也存在只在运行时才走到的校验分支。" -ForegroundColor DarkGray
}
