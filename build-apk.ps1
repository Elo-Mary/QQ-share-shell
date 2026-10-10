#Requires -Version 5.1
<#
.SYNOPSIS
    不依赖 Gradle、不联网，直接用 Android SDK 的 build-tools + JDK 编译空壳 QQ 的 APK。

.DESCRIPTION
    需要的环境只有两样：
      1) JDK（javac / jar / keytool，JDK 8 ~ 21 都行；Android Studio 自带的 jbr 也可以）
      2) Android SDK 的 platforms（android.jar）和 build-tools（aapt2 / d8 / zipalign / apksigner）
    流程：aapt2 编译资源 -> aapt2 链接出无 dex 的 APK -> javac 编译 Java -> d8 生成 classes.dex
          -> 把 dex 塞进 APK -> zipalign 对齐 -> apksigner 签名。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-apk.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-apk.ps1 -SdkRoot 'D:\Android\Sdk'
#>
[CmdletBinding()]
param(
    [string]$SdkRoot,
    [string]$OutDir,
    [string]$KeystorePath,
    [string]$KeystoreAlias = 'qqshell',
    [string]$KeystorePass = 'android',
    [string]$PackageName = 'com.tencent.mobileqq',
    [int]$VersionCode = 89090,
    [string]$VersionName = '8.9.90',
    [int]$MinSdk = 21,
    [int]$TargetSdk = 34
)

$ErrorActionPreference = 'Stop'
# 把控制台切到 UTF-8，否则 javac / keytool / d8 的中文提示会显示成乱码（失败也不影响构建）
try {
    & chcp.com 65001 | Out-Null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
}
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
if (-not $KeystorePath) { $KeystorePath = Join-Path $root 'qqshell.keystore' }
$work = Join-Path $root 'build'

function Write-Step([string]$message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

function Write-Ok([string]$message) {
    Write-Host "    $message" -ForegroundColor Green
}

function ConvertTo-Version([string]$text) {
    # .NET 的 Version 至少要有两段："36" 解析会失败，所以补成 "36.0"；
    # 同时去掉 "-rc1" 这类后缀，兼容 35.0.0-rc2 这种目录名。
    if (-not $text) { return $null }
    $clean = ($text -split '-')[0].Trim()
    if ($clean -notmatch '\.') { $clean = "$clean.0" }
    $version = $null
    if ([version]::TryParse($clean, [ref]$version)) { return $version }
    return $null
}

function Get-LatestVersionDir([string]$parent) {
    if (-not (Test-Path -LiteralPath $parent)) { return $null }
    $best = $null
    foreach ($dir in (Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue)) {
        $version = ConvertTo-Version $dir.Name
        if ($null -ne $version) {
            if ($null -eq $best -or $version -gt $best.Version) {
                $best = [pscustomobject]@{ Dir = $dir.FullName; Version = $version }
            }
        }
    }
    if ($best) { return $best.Dir }
    return $null
}

function Get-LatestPlatformDir([string]$parent) {
    if (-not (Test-Path -LiteralPath $parent)) { return $null }
    $best = $null
    foreach ($dir in (Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue)) {
        # 平台目录名形如 android-36、android-34
        if ($dir.Name -notmatch '^android-(.+)$') { continue }
        $version = ConvertTo-Version $Matches[1]
        if ($null -ne $version) {
            if ($null -eq $best -or $version -gt $best.Version) {
                $best = [pscustomobject]@{ Dir = $dir.FullName; Version = $version }
            }
        }
    }
    if ($best) { return $best.Dir }
    return $null
}

function Get-JdkHome {
    # Oracle 的 javapath 这类 shim 目录里只有 java/javac/javaw/jshell，没有 jar/keytool，
    # 所以优先从 `java -XshowSettings` 里读真实的 java.home，再去那里找工具。
    if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
        return $env:JAVA_HOME
    }
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) {
        try {
            $settings = & $java.Source -XshowSettings:properties -version 2>&1
            foreach ($line in $settings) {
                if ($line -match '^\s*java\.home\s*=\s*(.+?)\s*$') {
                    $candidate = $Matches[1].Trim()
                    if (Test-Path -LiteralPath (Join-Path $candidate 'bin\javac.exe')) { return $candidate }
                }
            }
        } catch {
            # 读不到就当没找到，继续走后面的候选路径
        }
    }
    return $null
}

$script:JdkHome = Get-JdkHome

function Find-JdkTool([string]$name) {
    if ($script:JdkHome) {
        $tool = Join-Path $script:JdkHome "bin\$name.exe"
        if (Test-Path -LiteralPath $tool) { return $tool }
    }
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $bins = @()
    if ($env:JAVA_HOME) { $bins += (Join-Path $env:JAVA_HOME 'bin') }

    # Android Studio 自带的 jbr：不写死盘符，从 Program Files 与各磁盘根目录下找
    $studioRoots = @()
    foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($programFiles) { $studioRoots += (Join-Path $programFiles 'Android\Android Studio') }
    }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drive.Root) { $studioRoots += (Join-Path $drive.Root 'Android Studio') }
    }
    foreach ($root in $studioRoots) {
        $jbrBin = Join-Path $root 'jbr\bin'
        if (Test-Path -LiteralPath $jbrBin) { $bins += $jbrBin }
    }

    # 常见的 JDK 安装位置（各厂商目录下的每个版本）
    foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programFiles) { continue }
        foreach ($vendor in @('Java', 'Eclipse Adoptium', 'Microsoft', 'Amazon Corretto', 'Zulu', 'BellSoft')) {
            $vendorDir = Join-Path $programFiles $vendor
            if (-not (Test-Path -LiteralPath $vendorDir)) { continue }
            $bins += @(Get-ChildItem -LiteralPath $vendorDir -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'bin' })
        }
    }

    foreach ($bin in $bins) {
        $tool = Join-Path $bin "$name.exe"
        if (Test-Path -LiteralPath $tool) { return $tool }
    }
    return $null
}

Write-Step "定位 Android SDK"
if (-not $SdkRoot) {
    $candidates = @()
    if ($env:ANDROID_HOME) { $candidates += $env:ANDROID_HOME }
    if ($env:ANDROID_SDK_ROOT) { $candidates += $env:ANDROID_SDK_ROOT }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk'),
        (Join-Path ${env:ProgramFiles(x86)} 'Android\android-sdk'),
        'C:\Android\Sdk'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'platforms'))) {
            $SdkRoot = $candidate
            break
        }
    }
}
if (-not $SdkRoot) {
    throw "没找到 Android SDK。请用 -SdkRoot 'D:\Android\Sdk' 指定，或设置环境变量 ANDROID_HOME。"
}
$platformsDir = Join-Path $SdkRoot 'platforms'
$buildToolsDir = Join-Path $SdkRoot 'build-tools'
$platform = Get-LatestPlatformDir $platformsDir
$buildTools = Get-LatestVersionDir $buildToolsDir
if (-not $platform) { throw "在 $platformsDir 里没有找到任何 platform（需要 android.jar）。请在 Android Studio 的 SDK Manager 里装一个 Android SDK Platform。" }
if (-not $buildTools) { throw "在 $buildToolsDir 里没有找到任何 build-tools。请在 SDK Manager 里装 Android SDK Build-Tools。" }
$androidJar = Join-Path $platform 'android.jar'
Write-Ok "SDK        : $SdkRoot"
Write-Ok "platform   : $platform"
Write-Ok "build-tools: $buildTools"

$aapt2 = Join-Path $buildTools 'aapt2.exe'
$zipalign = Join-Path $buildTools 'zipalign.exe'
$apksigner = Join-Path $buildTools 'apksigner.bat'
$d8 = $null
foreach ($name in @('d8.bat', 'd8.cmd', 'd8')) {
    $candidate = Join-Path $buildTools $name
    if (Test-Path -LiteralPath $candidate) { $d8 = $candidate; break }
}
foreach ($tool in @($aapt2, $d8, $zipalign, $apksigner, $androidJar)) {
    if (-not $tool -or -not (Test-Path -LiteralPath $tool)) { throw "缺少必要文件：$tool" }
}

Write-Step "定位 JDK 工具"
$javac = Find-JdkTool 'javac'
$jar = Find-JdkTool 'jar'
$keytool = Find-JdkTool 'keytool'
if (-not $javac) { throw "没找到 javac。请安装 JDK，或用 Android Studio 自带的 jbr（设置 JAVA_HOME）。" }
if (-not $jar) { throw "没找到 jar（JDK 自带）。请设置 JAVA_HOME 指向真正的 JDK 目录。" }
Write-Ok "JDK home: $(if ($script:JdkHome) { $script:JdkHome } else { '(未识别，用 PATH 里的工具)' })"
Write-Ok "javac  : $javac"
Write-Ok "jar    : $jar"
Write-Ok "keytool: $(if ($keytool) { $keytool } else { '（缺失，将无法自动生成签名密钥）' })"

Write-Step "准备构建目录"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
foreach ($dir in @($work, (Join-Path $work 'res'), (Join-Path $work 'gen'),
        (Join-Path $work 'classes'), (Join-Path $work 'dex'), $OutDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
Write-Ok "work: $work"

# ---------------------------------------------------------------- 清单注入
Write-Step "生成临时 AndroidManifest.xml（注入包名/版本/uses-sdk）"
$manifestSource = Join-Path $root 'app\src\main\AndroidManifest.xml'
$manifestTemp = Join-Path $work 'AndroidManifest.xml'
$manifest = [System.IO.File]::ReadAllText($manifestSource, [System.Text.Encoding]::UTF8)
if ($manifest -notmatch '<manifest[^>]*\spackage\s*=') {
    $manifest = $manifest -replace '<manifest', ('<manifest package="' + $PackageName + '"')
}
if ($manifest -notmatch 'android:versionCode') {
    $manifest = $manifest -replace '<manifest', ('<manifest android:versionCode="' + $VersionCode + '" android:versionName="' + $VersionName + '"')
}
if ($manifest -notmatch '<uses-sdk') {
    $usesSdk = '<uses-sdk android:minSdkVersion="' + $MinSdk + '" android:targetSdkVersion="' + $TargetSdk + '" />'
    $manifest = $manifest -replace '(<application)', ($usesSdk + "`r`n`r`n    " + '$1')
}
[System.IO.File]::WriteAllText($manifestTemp, $manifest, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "package=$PackageName versionName=$VersionName minSdk=$MinSdk targetSdk=$TargetSdk"

# ---------------------------------------------------------------- 资源
Write-Step "aapt2 compile：编译资源"
$resDir = Join-Path $root 'app\src\main\res'
$compiledZip = Join-Path $work 'res\resources.zip'
& $aapt2 compile --dir $resDir -o $compiledZip
if ($LASTEXITCODE -ne 0) { throw "aapt2 compile 失败（退出码 $LASTEXITCODE）" }
Write-Ok "资源已编译 -> $compiledZip"

Write-Step "aapt2 link：链接资源（生成不含 dex 的 APK 和 R.java）"
$baseApk = Join-Path $work 'base.apk'
$genDir = Join-Path $work 'gen'
& $aapt2 link -o $baseApk -I $androidJar --manifest $manifestTemp --java $genDir $compiledZip
if ($LASTEXITCODE -ne 0) { throw "aapt2 link 失败（退出码 $LASTEXITCODE）" }
Write-Ok "APK 骨架 -> $baseApk"

# ---------------------------------------------------------------- Java
Write-Step "javac：编译 Java 源码"
$sourceDir = Join-Path $root 'app\src\main\java'
$sources = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -Filter '*.java' | ForEach-Object { $_.FullName })
$sources += @(Get-ChildItem -LiteralPath $genDir -Recurse -Filter 'R.java' | ForEach-Object { $_.FullName })
if ($sources.Count -eq 0) { throw "没有找到任何 .java 源文件" }
$classesDir = Join-Path $work 'classes'
$javacArgs = @('-encoding', 'UTF-8', '-source', '8', '-target', '8', '-nowarn',
    '-classpath', $androidJar, '-d', $classesDir) + $sources
& $javac @javacArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "    源码级别 8 编译失败，改用 --release 11 重试" -ForegroundColor Yellow
    $javacArgs = @('-encoding', 'UTF-8', '--release', '11', '-nowarn',
        '-classpath', $androidJar, '-d', $classesDir) + $sources
    & $javac @javacArgs
    if ($LASTEXITCODE -ne 0) { throw "javac 失败（退出码 $LASTEXITCODE）" }
}
Write-Ok "class 文件 -> $classesDir"

Write-Step "d8：转换出 classes.dex"
$classesJar = Join-Path $work 'classes.jar'
Push-Location $classesDir
try {
    & $jar cf $classesJar .
    if ($LASTEXITCODE -ne 0) { throw "jar 打包失败（退出码 $LASTEXITCODE）" }
} finally {
    Pop-Location
}
$dexDir = Join-Path $work 'dex'
& $d8 --lib $androidJar --min-api $MinSdk --output $dexDir $classesJar
if ($LASTEXITCODE -ne 0) { throw "d8 失败（退出码 $LASTEXITCODE）" }
$dexFile = Join-Path $dexDir 'classes.dex'
if (-not (Test-Path -LiteralPath $dexFile)) { throw "d8 没有生成 classes.dex" }
Write-Ok "classes.dex -> $dexFile"

# ---------------------------------------------------------------- 打包
Write-Step "重新打包：按正确压缩方式组装 manifest + 资源 + classes.dex"
# 注意：Android 11+ 要求 resources.arsc 必须是“未压缩”的，所以这里不用 zip 追加，
# 而是逐条目重新打包，自己决定每个条目的压缩方式。
Add-Type -AssemblyName System.IO.Compression.FileSystem
$unsignedApk = Join-Path $work 'unsigned.apk'
if (Test-Path -LiteralPath $unsignedApk) { Remove-Item -LiteralPath $unsignedApk -Force }
$sourceZip = [System.IO.Compression.ZipFile]::OpenRead($baseApk)
$outZip = [System.IO.Compression.ZipFile]::Open($unsignedApk, 'Create')
try {
    foreach ($entry in $sourceZip.Entries) {
        $level = [System.IO.Compression.CompressionLevel]::Optimal
        if ($entry.FullName -eq 'resources.arsc' -or $entry.FullName -eq 'AndroidManifest.xml') {
            $level = [System.IO.Compression.CompressionLevel]::NoCompression
        }
        $target = $outZip.CreateEntry($entry.FullName, $level)
        $input = $entry.Open()
        $output = $target.Open()
        try {
            $input.CopyTo($output)
        } finally {
            $output.Dispose()
            $input.Dispose()
        }
    }

    $dexTarget = $outZip.CreateEntry('classes.dex', [System.IO.Compression.CompressionLevel]::Optimal)
    $dexInput = [System.IO.File]::OpenRead($dexFile)
    $dexOutput = $dexTarget.Open()
    try {
        $dexInput.CopyTo($dexOutput)
    } finally {
        $dexOutput.Dispose()
        $dexInput.Dispose()
    }
} finally {
    $outZip.Dispose()
    $sourceZip.Dispose()
}
Write-Ok "unsigned.apk -> $unsignedApk"

Write-Step "zipalign：4 字节对齐"
$alignedApk = Join-Path $work 'aligned.apk'
& $zipalign -f -p 4 $unsignedApk $alignedApk
if ($LASTEXITCODE -ne 0) { throw "zipalign 失败（退出码 $LASTEXITCODE）" }
Write-Ok "aligned.apk -> $alignedApk"

# ---------------------------------------------------------------- 签名
Write-Step "签名"
if (-not (Test-Path -LiteralPath $KeystorePath)) {
    if (-not $keytool) { throw "没有 keytool，无法生成签名密钥。请手动创建 $KeystorePath 后重试。" }
    Write-Host "    生成签名密钥：$KeystorePath" -ForegroundColor Yellow
    & $keytool -genkeypair -keystore $KeystorePath -alias $KeystoreAlias -keyalg RSA -keysize 2048 `
        -validity 10000 -storepass $KeystorePass -keypass $KeystorePass `
        -dname "CN=QQ Shell, O=LocalOnly, C=CN"
    if ($LASTEXITCODE -ne 0) { throw "keytool 生成密钥失败（退出码 $LASTEXITCODE）" }
}
$finalApk = Join-Path $OutDir 'qq-shell.apk'
& $apksigner sign --ks $KeystorePath --ks-key-alias $KeystoreAlias `
    --ks-pass ("pass:" + $KeystorePass) --key-pass ("pass:" + $KeystorePass) `
    --out $finalApk $alignedApk
if ($LASTEXITCODE -ne 0) { throw "apksigner 签名失败（退出码 $LASTEXITCODE）" }

Write-Step "校验签名与对齐"
& $apksigner verify --print-certs $finalApk
if ($LASTEXITCODE -ne 0) { throw "apksigner verify 失败（退出码 $LASTEXITCODE）" }
& $zipalign -c 4 $finalApk
if ($LASTEXITCODE -ne 0) {
    Write-Host "    警告：zipalign -c 校验未通过，Android 11+ 可能拒绝安装" -ForegroundColor Yellow
} else {
    Write-Ok "4 字节对齐检查通过"
}

$size = [math]::Round((Get-Item -LiteralPath $finalApk).Length / 1KB, 1)
Write-Host ""
Write-Host "构建完成：$finalApk（$size KB）" -ForegroundColor Green
Write-Host ""
Write-Host "安装到手机（USB 调试已打开）：" -ForegroundColor Cyan
Write-Host "    adb install -r `"$finalApk`""
Write-Host ""
Write-Host "卸载（装回真 QQ 之前必须先做这一步）：" -ForegroundColor Cyan
Write-Host "    adb uninstall $PackageName"
