# OctoFetch

原生 Flutter 实现的 GitHub 多镜像高速下载器，适配 Android 手机 / 平板与桌面端。

不使用 WebView、不启动本地网页服务，桌面端直接打开原生窗口。

## 功能

- 内置 108 个下载源：GitHub 官方、codeload、jsDelivr、GitMirror 与加速代理
- 下载前快速实测全部适配镜像（128KB Range 采样），校验首段内容一致性，隔离错误镜像
- 按实测速度加权分配连接，默认 32 线程、最多 8 个源协同下载
- 剩余任务不足时自动把分片再对半拆分，避免最后几 MB 被慢源拖住
- 分片热力图、实时速度 / ETA、每源线程与流量统计
- 断点续传（`.octopart` 状态文件）、SHA-256 校验
- 手机 / 平板首次启动引导选择保存文件夹（SAF），无需存储权限
- 下载完成后可打开文件或所在文件夹
- 下载按钮固定在底部，无需滚动查找

## 构建

### Android APK

```bash
flutter pub get
flutter build apk --release
# 产物: build/app/outputs/flutter-apk/app-release.apk
```

### Windows

在 Windows 10/11 上安装 Flutter 3.47.9、Visual Studio 2022（Desktop development with C++）后：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
```

产物位于 `build\windows\x64\runner\Release\`，打包后的便携版为 `dist\OctoFetch-windows-x64.zip`。
Flutter 桌面应用官方只提供“可执行文件 + DLL + data 目录”的发布形式，没有单文件 EXE 目标；该 ZIP 解压即用，无需安装。

GitHub Actions 工作流 `.github/workflows/build-windows.yml` 可在云端构建并下载该 ZIP。

### Linux

```bash
flutter pub get
flutter build linux --release
```

## 测试

```bash
flutter test
```

包含 URL 解析、镜像候选、调度分配、本地 HTTP Range 分片下载、SHA-256、界面固定下载栏与黄金截图测试。

## 说明

- Android Release APK 当前使用调试签名，正式发布请配置自己的签名。
- Windows 构建无法在 Linux 上交叉编译，需在 Windows 或 CI 中执行。
