"""用用户提供的原图生成全套应用图标。

不做任何重绘：只对原图做裁切、缩放与背景处理。
原图是 1012x1012 的水墨猫（黑猫头 + 蓝尾巴），纸白底。

处理要点：
  1. 原图四周留白较多，图标要稍微收紧构图，否则缩到 32px 时
     猫会小得看不清。但收紧要保守，别切到胡须与尾巴尖。
  2. 原图背景是纸白（略偏暖 #F6F5F1），不是纯白也不是透明。
     Windows ICO 适合保留这份纸底（在深色任务栏上更像一枚印章）；
     Android 传统图标同样保留纸底；自适应图标的前景层则必须
     把纸底去掉（否则会被裁成一个方块），所以要做扣白处理。
  3. 所有缩放用 LANCZOS，保证缩小后笔触边缘仍然干净。
"""

from __future__ import annotations

import os

from PIL import Image

SOURCE = os.path.join("docs", "brand", "cat-ink.png")

# 原图的有效内容边界（相对比例）。用手工量出的保守值：
# 猫的耳尖约在 y=0.17，尾尖约在 x=0.84，胡须最左约 x=0.18。
# 留一点余量，取 0.10 ~ 0.92 的方形区域，四周各收 ~8%。
CROP_LOW = 0.10
CROP_HIGH = 0.92

# 纸白底：与原图一致，避免图标边缘出现一圈色差。
PAPER = (246, 245, 241)


def load_source(root: str) -> Image.Image:
    path = os.path.join(root, SOURCE)
    if not os.path.exists(path):
        raise SystemExit(f"找不到原图：{path}")
    img = Image.open(path).convert("RGBA")
    return img


def cropped_square(img: Image.Image) -> Image.Image:
    """按保守比例裁出居中的方形，并转回方形画布。"""
    w, h = img.size
    side = min(w, h)
    low = int(side * CROP_LOW)
    high = int(side * CROP_HIGH)
    box = (low, low, high, high)
    return img.crop(box)


def on_paper(img: Image.Image, size: int) -> Image.Image:
    """缩放到 size 并铺纸白底（用于 Windows 与传统 Android 图标）。"""
    resized = img.resize((size, size), Image.LANCZOS)
    base = Image.new("RGBA", (size, size), PAPER + (255,))
    base.alpha_composite(resized)
    return base


def remove_paper(img: Image.Image, size: int, threshold: int = 238) -> Image.Image:
    """缩放到 size，并把接近纸白的像素变透明（用于自适应图标前景层）。

    阀值取得偏保守（238）：水墨有大量淡墨过渡，阈值太高会把
    淡墨也削掉，留下难看的锯齿；只要把接近纯纸白的部分去掉即可。
    """
    resized = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    pixels = resized.load()
    for y in range(size):
        for x in range(size):
            r, g, b, a = pixels[x, y]
            # 三个通道都很亮 => 纸底
            if r >= threshold and g >= threshold and b >= threshold:
                pixels[x, y] = (r, g, b, 0)
    return resized


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = load_source(root)
    square = cropped_square(src)
    print("source:", src.size, "-> cropped:", square.size)

    preview_dir = os.path.join(os.environ.get("TEMP", "."), "iconpreview")
    os.makedirs(preview_dir, exist_ok=True)

    # 预览几档，便于人工确认
    for s in (512, 256, 128, 64, 48, 32, 16):
        on_paper(square, s).save(os.path.join(preview_dir, f"real_{s}.png"))

    # ── Windows ICO ──
    ico_path = os.path.join(root, "windows", "runner", "resources", "app_icon.ico")
    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    frames = [on_paper(square, s) for s in ico_sizes]
    frames[-1].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in ico_sizes],
        append_images=frames[:-1],
    )
    print("wrote", ico_path, os.path.getsize(ico_path), "bytes")

    # ── Android 传统图标（带纸底）──
    legacy = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, s in legacy.items():
        p = os.path.join(root, "android", "app", "src", "main", "res",
                         folder, "ic_launcher.png")
        on_paper(square, s).save(p)
        print("wrote", p)

    # ── Android 自适应图标前景层（透明底）──
    # 108dp 画布的可见安全区是中间 72dp，内容要留边，
    # 否则系统裁切会把耳尖和尾巴尖切掉。
    adaptive = {
        "mipmap-mdpi": 108,
        "mipmap-hdpi": 162,
        "mipmap-xhdpi": 216,
        "mipmap-xxhdpi": 324,
        "mipmap-xxxhdpi": 432,
    }
    for folder, s in adaptive.items():
        p = os.path.join(root, "android", "app", "src", "main", "res",
                         folder, "ic_launcher_foreground.png")
        # 先生成稍大的透明底前景，再贴到画布中间留出安全边距。
        inner = int(s * 0.72)
        fg = remove_paper(square, inner)
        canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        off = (s - inner) // 2
        canvas.alpha_composite(fg, (off, off))
        canvas.save(p)
        print("wrote", p)

    print("preview:", preview_dir)


if __name__ == "__main__":
    main()
