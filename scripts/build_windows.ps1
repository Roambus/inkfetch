# InkFetch Windows build script
# Requires Flutter SDK 3.47.0+ and Visual Studio 2022
# with the "Desktop development with C++" workload.

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Host "==> flutter pub get" -ForegroundColor Cyan
flutter pub get

Write-Host "==> flutter build windows --release" -ForegroundColor Cyan
flutter build windows --release

$releaseDir = "build\windows\x64\runner\Release"
if (!(Test-Path $releaseDir)) {
    throw "Build output not found: $releaseDir"
}

$distDir = "dist"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$zipPath = Join-Path $distDir "InkFetch-windows-x64.zip"

Write-Host "==> packaging portable zip" -ForegroundColor Cyan
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipPath

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Run:       $releaseDir\InkFetch.exe"
Write-Host "Portable:  $zipPath (unzip anywhere, no installer needed)"
Write-Host ""
Write-Host "Note: Flutter desktop apps ship as a folder with DLLs and data/."
Write-Host "There is no official single-file EXE target. The zip is fully portable."
