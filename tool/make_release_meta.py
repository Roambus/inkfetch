"""生成发布用的 version.json 与部署清单。

主页的下载链接、版本号、SHA-256 每次发版都要一起变，手改容易漏。
这个脚本从 dist/ 里的实际产物读出文件名、大小、哈希，写出：

  dist/version.json          上传到主站 /inkfetch/version.json
  dist/release.json          本次发布的结构化摘要（给推送脚本用）

用法：
    python tool/make_release_meta.py 2.6.0
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest().upper()


def human_size(n: int) -> str:
    if n >= 1 << 20:
        return f"{n / (1 << 20):.1f} MB"
    return f"{n / 1024:.0f} KB"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法: python tool/make_release_meta.py <version> [notes]", file=sys.stderr)
        return 2
    version = argv[1].lstrip("v")
    notes = argv[2] if len(argv) > 2 else ""

    if not DIST.exists():
        print(f"没有 {DIST}", file=sys.stderr)
        return 1

    files = sorted(p for p in DIST.iterdir() if p.is_file() and p.suffix in (".exe", ".apk"))
    if not files:
        print("dist/ 里没有 exe / apk", file=sys.stderr)
        return 1

    entries = []
    for path in files:
        entries.append(
            {
                "name": path.name,
                "size": path.stat().st_size,
                "sizeLabel": human_size(path.stat().st_size),
                "sha256": sha256_of(path),
                "url": f"/download/{path.name}",
            }
        )
        print(f"  {path.name}  {human_size(path.stat().st_size)}  {entries[-1]['sha256'][:16]}…")

    manifest = {
        "version": version,
        "releasedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "url": "https://www.roambus.me/inkfetch/",
        "notes": notes,
        "files": entries,
    }
    out = DIST / "version.json"
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (DIST / "release.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n写出 {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
