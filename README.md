# 墨取 InkFetch

<p align="center">
  <img src="assets/icon/inkfetch_mark_320.png" width="140" alt="墨取 InkFetch" />
</p>

原生 Flutter 实现的 GitHub 多镜像高速下载器，支持 Android 手机 / 平板与 Windows / Linux 桌面端。中文名「墨取」，英文名 InkFetch。

不套 WebView、不启动本地网页服务，桌面端是真正的原生窗口，Android 端使用 SAF 直接写入你选择的文件夹。

## 功能

- **多镜像分片下载**：内置 108 个下载源（GitHub 官方、codeload、jsDelivr、GitMirror 与各类加速代理），按实测速度加权分配连接
- **分层探测**：先测常用镜像，可用分片源不足时才扩展到长尾与实验源，探测不再每次扫全部 108 个
- **首段哈希隔离**：镜像返回的首段内容哈希不一致时直接排除，避免把错误页 / 篡改文件拼进结果
- **动态配权**：每轮下载后按实测速度重新分配连接，被限流的源不会永久作废
- **断点续传**：`.octopart` 状态文件记录已完成分片，取消或退出后可继续，只补未完成的部分
- **SHA-256 校验**：完成后计算哈希；Release 资产会与 GitHub 官方 digest 比对，界面上明确标注是否已核对
- **下载队列**：连续粘贴多个链接会排队依次下载，队列持久化，重启不丢
- **重启恢复**：启动时扫描磁盘上的未完成任务，可一键继续或删除
- **Android 前台服务**：下载期间保持进程优先级，切到后台不易被系统回收
- **复制进度与取消**：下载完成复制到 SAF 文件夹时显示进度，可随时取消
- **实时可视化**：分片热力图、实时速度 / 剩余时间、每个源的线程与流量统计
- **无存储权限**：手机 / 平板首次启动引导选择保存文件夹，不需要申请存储权限

## 下载

在 [Releases](https://github.com/Roambus/inkfetch/releases) 或[官网](https://www.roambus.me/inkfetch/)获取最新版本。

应用启动后会自动检查官网有没有新版本，弹窗里可以直接去下载，也可以跳过这个版本。

| 产物 | 说明 |
| --- | --- |
| `InkFetch-android-universal.apk` | 通用 APK，不确定机型时选这个 |
| `InkFetch-android-arm64-v8a.apk` | 现代 Android 设备（体积更小） |
| `InkFetch-android-armeabi-v7a.apk` | 较老的 32 位设备 |
| `InkFetch-android-x86_64.apk` | 模拟器 / x86 设备 |
| `InkFetch-windows-x64.exe` | Windows 单文件版，双击即用，不安装、不解压到固定位置 |
| `InkFetch-windows-x64.zip` | Windows 便携版，解压即用，无需安装 |

每个 Release 附带 `SHA256SUMS.txt`，可用 `sha256sum -c SHA256SUMS.txt` 校验下载结果。

### Windows 单文件版

单文件 EXE 把一个 Flutter 桌面应用所需的引擎 DLL 与 `data/` 全部压进 exe 尾部
（Windows 自带 Compression API，LZMS 算法，约 2.8× 压缩），双击即用。

运行时的落盘范围只有用户自己要下载的文件：

- 引擎 DLL 与 `data/` 解到 `%TEMP%\InkFetch-<pid>-<计数>`（启动前先清理陈旧目录），
  程序退出后由同程序的 `--gc` 子进程删除，正常退出、崩溃、任务管理器强杀都会清理。
- 设置、下载记录、队列、断点续传状态存在注册表 `HKCU\Software\InkFetch\Store`，
  不再写 `%APPDATA%\...\shared_preferences.json`。
- 断点续传状态不再以下载目录里的 `xxx.octopart` 文件形式存在，因此下载文件夹里
  只有你要下载的文件本身（Android 端仍使用 `.octopart` 文件，行为不变）。
- exe 旁边不会解压出任何东西：把 exe 单独拷到空目录或桌面运行都可以。

## 构建

需要 Flutter 3.47.0 或更高版本。

### Android

```bash
flutter pub get
flutter build apk --release --split-per-abi   # 按 ABI 拆分
flutter build apk --release                   # 通用 APK
```

产物位于 `build/app/outputs/flutter-apk/`。

发布签名通过 `android/key.properties` 配置（该文件已被 git 忽略）：

```properties
storeFile=inkfetch-release.jks
storePassword=******
keyAlias=inkfetch
keyPassword=******
```

缺少该文件时会回退到 debug 签名，方便本地 `flutter run --release`；正式分发请务必配置自己的 keystore。

### Windows

安装 Visual Studio 2022（Desktop development with C++）后：

```powershell
# 便携目录 + ZIP
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1

# 单文件 EXE（含冒烟验证）
powershell -ExecutionPolicy Bypass -File scripts\build_single_exe.ps1
```

目录版产物位于 `build\windows\x64\runner\Release\`，脚本会打包成 `dist\InkFetch-windows-x64.zip`。

单文件版产物是 `dist\InkFetch-<版本>-windows-x64.exe`。打包不需要额外工具：
runner 二进制自己带 `--pack` 参数即可当打包器用（`InkFetch.exe --pack --release <Release 目录> --out <输出 exe>`）。
脚本最后会把 exe 拷进一个空临时目录启动一次，确认窗口能起来、exe 同目录没有新增文件、
退出后 `%TEMP%` 里的解压目录已删除。

Flutter 官方没有单文件 EXE 目标，这个单文件版由 runner 自身实现：把引擎 DLL 声明为
延迟加载（`/DELAYLOAD`），启动时先从自身尾部解压出资源再加载，因此不需要外部
7z/tar 之类的解包器，也不会在磁盘上留下长期驻留的安装目录。

### Linux

```bash
flutter pub get
flutter build linux --release
```

## CI / 发布

`.github/workflows/build.yml` 包含四个任务：

1. `check`：`flutter analyze` + `flutter test`
2. `android`：构建通用与三种 ABI 的 APK（配置了签名 secrets 时使用正式签名）
3. `windows`：构建 Windows release，打包便携 ZIP 与单文件 EXE（含冒烟验证）
4. `release`：推送 `v*` 标签时自动创建 Release、上传产物并生成 `SHA256SUMS.txt`

可选签名 secrets：`KEYSTORE_BASE64`、`KEYSTORE_PASSWORD`、`KEY_ALIAS`、`KEY_PASSWORD`。

发布新版本：

```bash
git tag v2.1.0
git push origin v2.1.0
```

## 测试

```bash
flutter analyze
flutter test
```

覆盖 URL 解析、镜像候选生成、连接调度、本地 HTTP Range 分片下载、SHA-256 校验与界面布局。

golden 截图基线依赖具体字体环境，默认跳过；需要时运行：

```bash
INKFETCH_GOLDEN=1 flutter test test/golden_ui_test.dart
```

## 代码结构

```
lib/
├── core/
│   ├── mirrors.dart      # 108 个镜像定义与候选生成
│   ├── probe.dart        # 分层探测、首段哈希校验
│   ├── scheduler.dart    # 按速度加权分配连接
│   ├── downloader.dart   # 分片下载、断点续传、SHA-256
│   ├── url_parser.dart   # GitHub 链接解析与文件名净化
│   ├── platform.dart     # 原生通道（SAF / 前台服务 / 文件夹复制）
│   ├── kv_store.dart     # 键值存储（Windows 注册表 / 其他平台 prefs）
│   ├── resume_store.dart # 断点续传状态（Windows 注册表 / 其他平台 .octopart）
│   └── storage.dart      # 设置、历史、队列持久化
├── state/app_controller.dart  # 应用状态与下载编排
└── ui/                   # 页面与组件

windows/runner/
├── native_store.cpp      # app.inkfetch/store 方法通道（HKCU 注册表）
├── payload.cpp           # 单文件版：内嵌资源打包 / 解压 / 延迟加载 / 退出清理
└── main.cpp              # 启动入口（普通构建与单文件版共用）
```

## 说明

- 镜像均为第三方服务，可用性与速度会随时间变化；应用会自动跳过失效的源。
- 本工具只做下载加速，请遵守所在地区法律与 GitHub 服务条款。
- 卸载 / 清理：单文件版没有安装目录，删掉 exe 即可；应用状态在注册表
  `HKCU\Software\InkFetch`，需要彻底清空时删掉该键。
- Windows 与 Android 产物均在 GitHub Actions 上构建，本地 Linux 无法交叉编译。

## 许可证

[MIT](LICENSE) © 2026 Roambus
