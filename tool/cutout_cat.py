"""把 docs/brand/cat-ink.png 的纸白底抠成透明。

思路是「按到纸色的距离」估一个 alpha：图中纸面不是纯白，而是带一点
青灰的米色（约 #F3F1EE），且边缘因纸张纹理有细微起伏。所以不能简单
地取一个阈值做二值化——那样笔触边缘会变成锯齿，失去水墨的湿边。

做法：
  1. 以图片四周的边框像素统计出纸色基准。
  2. 对每个像素算它相对纸色的「墨量」(如何暗、如何偏离中性灰)。
  3. alpha = 墨量做一次软阈值，保留湿润的过渡带。
  4. 颜色反解：已知 alpha 与纸色，反推出叠在纸上的原始墨色，
     这样抠出来的图放在任何底色上都不会发灰。
  5. 用一次轻微的 unsharp 把笔触边缘找回来，避免整体变糊。
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent


def estimate_paper(rgb: np.ndarray, border: int = 24) -> np.ndarray:
    """用四周一圈像素估计纸色（中位数，抗少量噪点）。"""
    h, w, _ = rgb.shape
    strips = [
        rgb[:border, :, :].reshape(-1, 3),
        rgb[-border:, :, :].reshape(-1, 3),
        rgb[:, :border, :].reshape(-1, 3),
        rgb[:, -border:, :].reshape(-1, 3),
    ]
    return np.median(np.concatenate(strips, axis=0), axis=0)


def cutout(src: Path, dst: Path, keep_bg_darkness: bool = True) -> None:
    im = Image.open(src).convert("RGB")
    rgb = np.asarray(im, dtype=np.float32)
    paper = estimate_paper(rgb)

    # 墨量 = 各通道相对纸色的最大跌幅。用 max 而不是平均，
    # 是因为蓝色尾笔在 R 通道上跌得最多，平均会低估它的不透明度。
    drop = (paper[None, None, :] - rgb) / np.maximum(paper[None, None, :], 1.0)
    ink = drop.max(axis=2)
    ink = np.clip(ink, 0.0, 1.0)

    # 软阈值：低于 LO 完全透明（纸纹噪点），高于 HI 完全不透明（实墨）。
    LO, HI = 0.045, 0.30
    alpha = (ink - LO) / (HI - LO)
    alpha = np.clip(alpha, 0.0, 1.0)
    # 轻微的 S 曲线：压掉低端雾感，保住笔触中段的层次
    alpha = alpha * alpha * (3.0 - 2.0 * alpha)

    # 反解颜色：纸上看到的颜色 = alpha*墨 + (1-alpha)*纸
    #   → 墨 = (看到 - (1-alpha)*纸) / alpha
    a = np.maximum(alpha, 1e-4)[:, :, None]
    color = (rgb - (1.0 - a) * paper[None, None, :]) / a
    color = np.clip(color, 0.0, 255.0)

    # 极淡的区域颜色反解会放大噪点，这些地方反正几乎透明，直接归到纸色
    faint = (alpha < 0.02)[:, :, None]
    color = np.where(faint, paper[None, None, :], color)

    out = np.concatenate([color, (alpha * 255.0)[:, :, None]], axis=2)
    img = Image.fromarray(out.astype(np.uint8), mode="RGBA")

    # 去白边（defringe）。
    # 源图是画在纸上的，笔触边缘那一圈像素是「墨混着纸」，反解之后
    # 颜色仍然偏亮（实测边缘有 110~170 的亮灰），alpha 却已经到了 255。
    # 放在深色底上，这一圈就亮成白边。
    # 做法：只在「实测确实是实墨」的像素上取色（又暗又不透明），
    # 然后一圈圈往外把颜色推出去覆盖这些混了纸色的边缘。
    # 只改 RGB，alpha 不动——笔触的柔软轮廓完整保留。
    arr = np.asarray(img).astype(np.float32)
    rgb_a = arr[:, :, :3].copy()
    a_ch = arr[:, :, 3]
    luma = rgb_a.mean(axis=2)
    seed = (a_ch >= 250) & (luma < paper.mean() * 0.55)
    if seed.any():
        solid = seed.copy()
        for _ in range(64):
            acc = np.zeros_like(rgb_a)
            cnt = np.zeros(a_ch.shape, dtype=np.float32)
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                m = np.roll(np.roll(solid, dy, 0), dx, 1)
                s = np.roll(np.roll(rgb_a, dy, 0), dx, 1)
                acc += np.where(m[:, :, None], s, 0.0)
                cnt += m.astype(np.float32)
            take = (~solid) & (cnt > 0)
            if not take.any():
                break
            rgb_a[take] = acc[take] / cnt[take][:, None]
            solid |= take
            # 蓝尾笔触本身偏亮，给它留一条更长的扩散路径
            if solid.mean() > 0.999:
                break
    arr[:, :, :3] = rgb_a

    # 透明区域里残留的纸色 RGB 清成 0，避免缩放时边缘渗出白边
    arr[arr[:, :, 3] == 0, 0:3] = 0
    img = Image.fromarray(arr.astype(np.uint8), mode="RGBA")

    # 收一圈 alpha：源图笔触外缘有一层半透明的纸灰，不收的话放在深色
    # 底上会显出一圈白边。用幂次收缩而不是阈值，保住湿边的渐变。
    arr = np.asarray(img).astype(np.float32)
    arr[:, :, 3] = np.clip((arr[:, :, 3] / 255.0) ** 1.18 * 255.0, 0, 255)
    img = Image.fromarray(arr.astype(np.uint8), mode="RGBA")

    img.save(dst, optimize=True)
    cov = float((np.asarray(img)[:, :, 3] > 8).mean())
    print(f"{dst.name}: {img.size[0]}x{img.size[1]}  paper={paper.round(1).tolist()}  覆盖率={cov:.1%}")


def main() -> int:
    src = ROOT / "docs" / "brand" / "cat-ink.png"
    targets = [
        ROOT / "assets" / "icon" / "inkfetch_mark.png",
        ROOT / "product" / "site" / "assets" / "cat-ink-cut.png",
    ]
    if not src.exists():
        print(f"缺少源图 {src}", file=sys.stderr)
        return 1
    for dst in targets:
        dst.parent.mkdir(parents=True, exist_ok=True)
        cutout(src, dst)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
