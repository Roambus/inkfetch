"""核对界面用到的图标是否都在 tree-shaken 后的 MaterialIcons 子集里。

Flutter 只把「源码里出现过的」图标打进字体子集。任何一个没进子集的
图标在界面上都会渲染成一个方块——而且只在 release 包里出现，
debug 下看着是好的。这个脚本把这件事变成一次可重复的检查。

用法：
    python tool/check_icons.py                    # 默认查 Windows release 产物
    python tool/check_icons.py <path-to-otf>
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
ICONS_DART = Path(r"C:\flutter\flutter\packages\flutter\lib\src\material\icons.dart")
DEFAULT_SUBSET = (
    ROOT / "build/windows/x64/runner/Release/data/flutter_assets/fonts"
    / "MaterialIcons-Regular.otf"
)


def parse_available_codepoints() -> dict[str, int]:
    """从 Flutter SDK 的 icons.dart 里读出 名字 -> 码位。"""
    if not ICONS_DART.exists():
        raise SystemExit(f"找不到 {ICONS_DART}")
    text = ICONS_DART.read_text(encoding="utf-8", errors="replace")
    table: dict[str, int] = {}
    # static const IconData foo_rounded = IconData(0xf0123, fontFamily: ...)
    pattern = re.compile(
        r"static\s+const\s+IconData\s+(\w+)\s*=\s*IconData\(\s*(0x[0-9a-fA-F]+)"
    )
    for name, code in pattern.findall(text):
        table[name] = int(code, 16)
    return table


def used_icons() -> set[str]:
    """扫 lib/ 下所有 Icons.xxx 引用。"""
    names: set[str] = set()
    pattern = re.compile(r"\bIcons\.([A-Za-z_][A-Za-z0-9_]*)")
    for path in (ROOT / "lib").rglob("*.dart"):
        for name in pattern.findall(path.read_text(encoding="utf-8", errors="replace")):
            names.add(name)
    return names


def main(argv: list[str]) -> int:
    subset_path = Path(argv[1]) if len(argv) > 1 else DEFAULT_SUBSET
    if not subset_path.exists():
        raise SystemExit(f"找不到字体子集 {subset_path}（先构建一次 release）")

    available = parse_available_codepoints()
    subset = set(TTFont(str(subset_path)).getBestCmap().keys())
    used = used_icons()

    unknown = sorted(n for n in used if n not in available)
    known = {n: available[n] for n in used if n in available}
    missing = sorted(n for n, cp in known.items() if cp not in subset)

    print(f"字体子集 {subset_path.name}: {len(subset)} 个码位")
    print(f"源码引用 {len(used)} 个图标名，其中 {len(known)} 个能在 SDK 里查到码位")
    if unknown:
        print(f"\n[警告] 查不到码位的图标名（可能是拼写错误）：{unknown}")

    if missing:
        print(f"\n[失败] 以下 {len(missing)} 个图标不在子集里，界面上会是方块：")
        for name in missing:
            print(f"   Icons.{name}  U+{known[name]:04X}")
        return 1

    print("\n[通过] 所有引用的图标都在子集内。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
