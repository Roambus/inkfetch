# 产品主页

墨取的产品主页部署在 `https://www.roambus.me/inkfetch/`。

## 文件在哪

| 用途 | 服务器路径 |
|---|---|
| 页面与资源 | `/var/www/roambus/inkfetch/` |
| 安装包 | `/var/www/roambus/download/` |

源码在本仓库 `product/site/`，改完用 SFTP 覆盖到服务器同名路径即可，不需要改动 nginx 配置（静态文件由已有站点直接服务）。

## 主页入口

`www.roambus.me` 主页的「桌面工具」分组里有墨取的入口，指向 `/inkfetch/`。

主页不是本仓库的文件，改动记录如下，方便以后核对：

- 分组计数：`桌面工具` 从 2 处改为 3 处（导航栏 `<span class="n">`、分组头 `<span class="num">`）
- hero 文案：`两件桌面工具` → `三件桌面工具`
- 卡片插在「桌面工具」的 `<ul class="stops">` 最前面，按站内链接（非下载）的写法

改动前的备份留在服务器：`/var/www/roambus/index.html.bak-before-inkfetch-20261126-150450`。

## 发布新版本时要改什么

`product/site/index.html` 里搜 `2.5.1`，共 5 处需要替换成新版本号：

1. 顶部 eyebrow 里的版本文字
2. Windows 卡片的下载链接文件名
3. Windows 卡片的 `dl-btn` 内的版本号
4. Windows 卡片的 `data-sha`（完整 SHA-256）
5. 三个 Android 卡片各自的下载链接文件名与体积

同时把新的安装包上传到 `/var/www/roambus/download/`，旧版本的包可以删掉。

SHA-256 用这个命令算：

```powershell
Get-FileHash dist\InkFetch-<版本>-windows-x64.exe -Algorithm SHA256
```

## 设计说明

页面的视觉是围绕产品的工作方式做的，不是通用模板：

- **分片带**：主视觉下方那条彩色横条用应用里同一套分片配色生成。每一格是一个分片，前段实色表示已完成、中段呼吸表示正在写、后段纸影表示未开始。格数随视口宽度自适应。
- **排版**：标题用宋体族（与应用界面同源），正文无衬线，数字等宽。
- **色彩**：一套墨阶（`--ink-0` ~ `--ink-4`）+ 纸色 `--paper` + 一点松烟绿 `--pine`，不引入别的色系。
- **无外部依赖**：不引 CDN、不引字体服务，`assets/` 里的字体与图标都是本地文件，离线也能完整打开。

## 验证过什么

- 页面与三个资源线上均返回 200
- 四个下载链接均返回 200，且以 `Content-Disposition: attachment` 下发
- 服务器实测 SHA-256 与本地产物一致
- 横向溢出：`viewport 360 = scrollWidth 360`，无溢出、无文本被裁切

> 注意：headless 浏览器用 `--window-size` 截图时，截图视口与布局视口可能不同步，
> 会看起来像内容被截断。判断是否真的溢出，请看 `documentElement.scrollWidth`
> 与 `clientWidth` 是否相等，不要只看截图。
