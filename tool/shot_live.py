"""抓取线上页面，确认部署后的观感与本地一致。

无头截图抓不到 canvas，但这一版页面已经没有 canvas 了，
所以可以放心用 headless 直接截线上地址。
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
URL = "https://www.roambus.me/inkfetch/"


def main() -> int:
    out = Path(__file__).resolve().parent.parent / "product" / "site" / "_live.png"
    profile = Path(tempfile.gettempdir()) / "inkfetch-live-profile"
    res = subprocess.run(
        [
            EDGE,
            "--headless=old",
            "--disable-gpu",
            "--hide-scrollbars",
            "--no-first-run",
            "--no-default-browser-check",
            f"--user-data-dir={profile}",
            "--window-size=1440,1500",
            "--virtual-time-budget=9000",
            f"--screenshot={out}",
            URL,
        ],
        capture_output=True,
        text=True,
        timeout=180,
    )
    if not out.exists():
        print(res.stderr[-1000:], file=sys.stderr)
        return 1
    print(f"{out}  {out.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
