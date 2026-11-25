# InkFetch 单文件 EXE 打包脚本
#
#   powershell -ExecutionPolicy Bypass -File scripts\build_single_exe.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build_single_exe.ps1 -SkipBuild
#   powershell -ExecutionPolicy Bypass -File scripts\build_single_exe.ps1 -SkipSmoke
#
# 流程：
#   1. flutter build windows --release（-SkipBuild 时跳过，复用现有产物）
#   2. 用刚构建的 runner 当“打包器”，把 Release 目录里的运行所需文件
#      压进 dist\InkFetch-<版本>-windows-x64.exe
#   3. 校验单文件：拷到空目录里启动，确认不落盘、能起窗口、退出后无残留
#
# 单文件版运行时把内嵌资源解到 %TEMP%\InkFetch-<pid>-<计数>，窗口退出后
# 由同程序的 --gc 子进程删除；设置 / 记录 / 队列 / 断点续传状态存在
# HKCU\Software\InkFetch（注册表），因此磁盘上只会留下用户自己下载的文件。

param(
    [switch]$SkipBuild,
    [switch]$SkipSmoke
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

$root = Get-Location
$releaseDir = Join-Path $root "build\windows\x64\runner\Release"
$distDir = Join-Path $root "dist"

# flutter 不在 PATH 时，回退到常见的 SDK 位置。
$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
$flutter = if ($flutterCommand) { $flutterCommand.Source } else { $null }
if (!$flutter) {
    foreach ($candidate in @("C:\flutter\flutter\bin\flutter.bat", "C:\flutter\bin\flutter.bat")) {
        if (Test-Path $candidate) { $flutter = $candidate; break }
    }
}
if (!$flutter) { throw "找不到 flutter 命令，请先安装 Flutter SDK 或把它加入 PATH" }

if (!$SkipBuild) {
    Write-Host "==> flutter pub get" -ForegroundColor Cyan
    & $flutter pub get | Out-Host

    Write-Host "==> flutter build windows --release" -ForegroundColor Cyan
    & $flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败" }
}

if (!(Test-Path (Join-Path $releaseDir "InkFetch.exe"))) {
    throw "找不到构建产物：$releaseDir\InkFetch.exe"
}

# 版本号取自 pubspec.yaml（例如 2.1.0+4 -> 2.1.0）
$version = (Select-String -Path (Join-Path $root "pubspec.yaml") -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$version = ($version -split '\+')[0]
$outFile = Join-Path $distDir "InkFetch-$version-windows-x64.exe"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

Write-Host "==> 打包单文件 EXE：$outFile" -ForegroundColor Cyan
# runner 自身既是 GUI 程序也是打包器：--pack 时不开窗口，只做压缩写入。
# GUI 子系统程序用 Start-Process -Wait 才能拿到退出码。
$packArgs = @("--pack", "--release", $releaseDir, "--out", $outFile)
$packProcess = Start-Process -FilePath (Join-Path $releaseDir "InkFetch.exe") `
    -ArgumentList $packArgs -PassThru -Wait -NoNewWindow
if ($packProcess.ExitCode -ne 0 -or !(Test-Path $outFile)) {
    throw "单文件打包失败（退出码 $($packProcess.ExitCode)）"
}

$sizeMb = [math]::Round((Get-Item $outFile).Length / 1MB, 1)
Write-Host "    产物大小：$sizeMb MB" -ForegroundColor Green

# ---------------------------------------------------------------- 冒烟验证
if ($SkipSmoke) {
    Write-Host ""
    Write-Host "完成（已跳过冒烟验证）。" -ForegroundColor Green
    Write-Host "单文件：$outFile"
    Write-Host "SHA256：$((Get-FileHash $outFile -Algorithm SHA256).Hash)"
    exit 0
}

Write-Host "==> 冒烟验证：空目录启动 + 退出后无残留" -ForegroundColor Cyan

$tempBefore = @(Get-ChildItem $env:TEMP -Directory -Filter "InkFetch-*" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName)

$sandbox = Join-Path $env:TEMP ("inkfetch-smoke-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$exeInSandbox = Join-Path $sandbox (Split-Path $outFile -Leaf)
Copy-Item $outFile $exeInSandbox

try {
    $proc = Start-Process -FilePath $exeInSandbox -PassThru
    $deadline = (Get-Date).AddSeconds(60)
    $windowSeen = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if ($proc.HasExited) { break }
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne 0) { $windowSeen = $true; break }
    }
    if (!$windowSeen) {
        throw "单文件版没有显示窗口（进程退出=$($proc.HasExited)）"
    }
    Start-Sleep -Seconds 2

    # 运行期间 exe 旁边除了自己不该多出任何文件（不允许解压到原位）。
    $extras = @(Get-ChildItem $sandbox -Force | Where-Object { $_.FullName -ne $exeInSandbox })
    if ($extras.Count -gt 0) {
        throw "运行时在 exe 同目录留下了文件：$($extras.Name -join ', ')"
    }
    Write-Host "    OK：窗口已显示，exe 同目录无新增文件" -ForegroundColor Green

    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $proc.Id -Timeout 30 -ErrorAction SilentlyContinue
} finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 3
# PowerShell 的 -Filter 不区分大小写，会顺带匹配到冒烟沙盒（inkfetch-smoke-*），
# 这里只认程序自己解压出来的目录（InkFetch-<pid>-<计数>）。
$leftovers = @(Get-ChildItem $env:TEMP -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -cmatch '^InkFetch-\d+-\d+$' -and
        ($tempBefore -notcontains $_.FullName)
    })
if ($leftovers.Count -gt 0) {
    throw "退出后仍有解压目录残留：$($leftovers.FullName -join ', ')"
}
Write-Host "    OK：退出后临时目录已清理，无残留" -ForegroundColor Green

# 同目录不应有 .octopart 之类的散落状态文件（解压目录已清理，这里再确认一次）。
$stray = @(Get-ChildItem $root -Recurse -File -Filter "*.octopart" -ErrorAction SilentlyContinue)
if ($stray.Count -gt 0) {
    Write-Warning "发现 .octopart 状态文件：$($stray.FullName -join ', ')"
}

Write-Host ""
Write-Host "完成。" -ForegroundColor Green
Write-Host "单文件：$outFile"
Write-Host "SHA256：$((Get-FileHash $outFile -Algorithm SHA256).Hash)"
