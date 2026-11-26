"""把 dist/version.json 里的真实版本、大小、哈希写进产品页。

手改这些数字一定会漏，而且漏了之后页面上的 SHA-256 和实际下载到的
文件对不上——那比不写更糟。发版时先跑 make_release_meta.py，
再跑这个脚本。

用法：
    python tool/sync_site.py
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
SITE = ROOT / "product" / "site" / "index.html"


def main() -> int:
    meta = json.loads((DIST / "version.json").read_text(encoding="utf-8"))
    version = meta["version"]
    files = {f["name"]: f for f in meta["files"]}

    html = SITE.read_text(encoding="utf-8")
    original = html

    def find(suffix: str) -> dict:
        for name, entry in files.items():
            if name.endswith(suffix):
                return entry
        raise SystemExit(f"version.json 里没有 {suffix}")

    exe = find("-windows-x64.exe")
    arm64 = find("-android-arm64-v8a.apk")
    v7a = find("-android-armeabi-v7a.apk")
    x64 = find("-android-x86_64.apk")

    # 1) 版本号出现在按钮与链接里
    html = re.sub(r"v\d+\.\d+\.\d+", f"v{version}", html)
    html = re.sub(r"InkFetch-\d+\.\d+\.\d+-", f"InkFetch-{version}-", html)

    # 2) SHA-256（完整值 + 展示用的前后缀）
    sha = exe["sha256"]
    html = re.sub(r'data-sha="[0-9A-F]{64}"', f'data-sha="{sha}"', html)
    html = re.sub(
        r'(<code id="shaText">)[^<]*(</code>)',
        rf"\g<1>{sha[:8]}…{sha[-4:]}\g<2>",
        html,
    )

    # 3) 体积
    def size_mb(entry: dict) -> str:
        return f"{entry['size'] / (1 << 20):.1f}"

    html = re.sub(
        r'(<div class="size">)[\d.]+(<i>MB</i></div>)',
        rf"\g<1>{size_mb(exe)}\g<2>",
        html,
        count=1,
    )
    html = re.sub(
        r'(<div class="size">)[\d.]+(<i>–</i>)[\d.]+(<i>MB</i></div>)',
        rf"\g<1>{size_mb(v7a)}\g<2>{size_mb(x64)}\g<3>",
        html,
    )

    for label, entry in (("arm64-v8a", arm64), ("armeabi-v7a", v7a), ("x86_64", x64)):
        html = re.sub(
            rf"({re.escape(label)} <small>[^<·]*· )[\d.]+ MB(</small>)",
            rf"\g<1>{size_mb(entry)} MB\g<2>",
            html,
        )

    # 4) 降级提示用真实体积
    SITE.write_text(html, encoding="utf-8")
    changed = html != original
    print(f"{'已更新' if changed else '无变化'} {SITE.name}  版本 {version}")
    print(f"  exe {size_mb(exe)} MB  {sha[:16]}…")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
