# 产品主页

墨取的产品主页部署在 `https://www.roambus.me/inkfetch/`。

## 文件在哪

| 用途 | 服务器路径 |
|---|---|
| 页面与资源 | `/var/www/roambus/inkfetch/` |
| 版本清单 | `/var/www/roambus/inkfetch/version.json` |
| 安装包 | `/var/www/roambus/download/` |

源码在本仓库 `product/site/`。静态文件由已有站点直接服务，不需要改 nginx 配置。

## 页面设计

一屏到底，四块：标题区 / 四个数字 / 下载 / 页脚。

三个约束：

- **单一墨阶**。只有纸色、三档墨色、一点松绿、一点朱砂。朱砂只出现在页脚那枚印章上。
- **标题用衬线**（Noto Serif SC 优先，回退宋体）。正文用系统无衬线，数字与哈希用 `InkMono`。这是「水墨感」的来处——没有它整页就是普通的极简落地页。
- **不放大装饰**。猫是唯一的图形，它是应用图标本身，不是另画的插画。

无外部请求：字体与图片都是同源资源，断网可用。

## 应用内的版本检查

应用启动约 2 秒后请求 `version.json`，拿到比当前新的版本就弹窗。用户可以选择：

- **去下载** → 打开 `version.json` 里的 `url`（即本页）
- **跳过此版本** → 记下这个版本号，只在下一个版本出现前不再提示
- **稍后** → 什么都不记，下次启动再问

取不到 `version.json` 时回退到 GitHub Release 的 tag；两个都取不到就安静退出，不打扰用户。

跳过记录与上次检查时间存在 `AppSettings` 里（Windows 走注册表，Android 走 shared_preferences）。

## 发布新版本

不要手改版本号和哈希，容易漏。按顺序跑：

```powershell
# 1. 改 pubspec.yaml 的 version（例如 2.6.0 → 2.7.0，build 号 +1）
# 2. 构建
flutter build windows --release
powershell -File scripts\build_single_exe.ps1 -SkipBuild
flutter build apk --release --target-platform android-arm64
# ...每个 ABI 各构建一次，复制到 dist\

# 3. 生成版本清单（读 dist\ 里的实际文件，算 SHA-256）
python tool\make_release_meta.py 2.7.0 "这一版改了什么"

# 4. 把版本号/哈希/体积同步进页面
python tool\sync_site.py

# 5. 上传：index.html、version.json、assets\、dist\ 里的安装包
```

`tool/sync_site.py` 会改这几处：按钮与链接里的版本号、Windows 的 `data-sha` 与展示用短哈希、四个体积数字、三个 APK 的下载文件名。跑完可以搜一下页面里还有没有旧版本号残留。

`test/brand_assets_test.dart` 会检查页面版本与 `pubspec.yaml` 是否一致，不一致就失败——所以忘了改会在这里被拦下。

## 主页入口

`www.roambus.me` 主页的「桌面工具」分组里有墨取的入口，指向 `/inkfetch/`。

主页不是本仓库的文件，改动记录如下，方便以后核对：

- 分组计数：`桌面工具` 从 2 处改为 3 处（导航栏 `<span class="n">`、分组头 `<span class="num">`）
- hero 文案：`两件桌面工具` → `三件桌面工具`
- 卡片插在「桌面工具」的 `<ul class="stops">` 最前面，按站内链接（非下载）的写法

改动前的备份留在服务器：`/var/www/roambus/index.html.bak-before-inkfetch-20261126-150450`。

## 截图验证的坑

不要用 `msedge --headless --screenshot` 判断这一页好不好看：

- 它抓不到 canvas 的内容（会得到空白）；
- `--virtual-time-budget` 让 `requestAnimationFrame` 只跑两次，动画走不到终态；
- `--window-size` 与实际布局视口可能不一致，看起来像内容被截断，其实没有。

判断横向是否真的溢出，要看 `document.documentElement.scrollWidth == clientWidth`，不要凭截图。
