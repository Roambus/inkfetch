# 运行期落盘差异检查（单文件版）
#
#   powershell -ExecutionPolicy Bypass -File tool\fs_diff_check.ps1
#
# 只盯程序可能落盘的那几个位置，不递归扫整个 %LOCALAPPDATA%：
#   - exe 所在目录（不应该出现任何解压出来的文件）
#   - 下载目录（不应该出现 .octopart 等旁挂文件）
#   - %APPDATA% 下的 InkFetch 目录（新版不再写 shared_preferences）
#   - %TEMP% 下的 InkFetch-<pid>-<计数> 解压目录（退出后应清空）

param(
    [string]$ExePath = (Join-Path $PSScriptRoot "..\dist\InkFetch-2.1.0-windows-x64.exe")
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ExePath)) { throw "找不到单文件 exe：$ExePath" }

$downloads = Join-Path $env:USERPROFILE "Downloads"
$watchDirs = @($downloads, (Join-Path $env:APPDATA "app.inkfetch"), (Join-Path $env:APPDATA "app.octofetch.downloader"))

function Get-Listing([string[]]$dirs) {
    $items = foreach ($dir in $dirs) {
        if (!(Test-Path $dir)) { continue }
        Get-ChildItem $dir -Force -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    }
    return @($items)
}

function Get-ExtractDirs {
    return @(Get-ChildItem $env:TEMP -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '^InkFetch-\d+-\d+$' } |
        Select-Object -ExpandProperty FullName)
}

$sandbox = Join-Path $env:TEMP "inkfetch-fsdiff"
Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$exe = Join-Path $sandbox (Split-Path $ExePath -Leaf)
Copy-Item $ExePath $exe

$beforeWatched = Get-Listing $watchDirs
$beforeExtract = Get-ExtractDirs
Write-Host "基线：监视目录 $($beforeWatched.Count) 项，已有解压目录 $($beforeExtract.Count) 个"

$process = Start-Process -FilePath $exe -PassThru
for ($i = 0; $i -lt 160; $i++) {
    Start-Sleep -Milliseconds 250
    $process.Refresh()
    if ($process.HasExited) { break }
    if ($process.MainWindowHandle -ne 0) { break }
}
if ($process.HasExited) { throw "单文件版启动失败（退出码 $($process.ExitCode)）" }
Write-Host "窗口已显示"
Start-Sleep -Seconds 5

$failures = @()

# 1) exe 同目录不允许出现任何新增文件
$sandboxExtras = @(Get-ChildItem $sandbox -Force | Where-Object { $_.FullName -ne $exe })
if ($sandboxExtras.Count -gt 0) {
    $failures += "exe 同目录出现新增文件：$($sandboxExtras.Name -join ', ')"
} else {
    Write-Host "  OK：exe 同目录无新增文件"
}

# 2) 运行中应该有且只有一个解压目录（在 %TEMP%）
$duringExtract = @(Get-ExtractDirs | Where-Object { $beforeExtract -notcontains $_ })
if ($duringExtract.Count -ne 1) {
    $failures += "运行中解压目录数量异常：$($duringExtract.Count)"
} else {
    Write-Host "  OK：解压目录在 %TEMP%\\$(Split-Path $duringExtract[0] -Leaf)"
}

# 3) 监视目录不允许出现 .octopart 之类的旁挂文件
$straySidecars = @(Get-ChildItem $downloads -Recurse -Force -File -Filter "*.octopart" -ErrorAction SilentlyContinue)
if ($straySidecars.Count -gt 0) {
    $failures += "下载目录出现 .octopart：$($straySidecars.FullName -join ', ')"
} else {
    Write-Host "  OK：下载目录无 .octopart 旁挂文件"
}

# 4) 不允许再写 shared_preferences.json
$afterWatched = Get-Listing $watchDirs
$newWatched = @($afterWatched | Where-Object { $beforeWatched -notcontains $_ })
if ($newWatched.Count -gt 0) {
    $failures += "运行中在 AppData 新增文件：$($newWatched -join ', ')"
} else {
    Write-Host "  OK：AppData 无新增文件（设置走注册表）"
}

# 5) 强制结束（模拟任务管理器结束进程）后解压目录也要被清掉
Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 8
$afterExtract = Get-ExtractDirs
$left = @($afterExtract | Where-Object { $beforeExtract -notcontains $_ })
if ($left.Count -gt 0) {
    $failures += "强杀后解压目录残留：$($left -join ', ')"
} else {
    Write-Host "  OK：强杀后 %TEMP% 里无残留解压目录"
}

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
Write-Host "PASS：运行过程中除下载文件外没有零散文件落盘" -ForegroundColor Green
exit 0
