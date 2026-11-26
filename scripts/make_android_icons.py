"""从 game/icon.png 生成安卓自适应图标的三层（前景 / 背景 / 单色），输出到 game/android_icons/。

用法（项目根目录）：python scripts/make_android_icons.py
图标改了就重跑一次再提交。目录里有 .gdignore，Godot 不导入、不打进 pck，只在导出安卓时读取。

做法：
- 背景：拟合原图的渐变底色（对每个通道做 x、y 的二次曲面最小二乘），按可见区域铺满 432x432。
- 前景：原图与渐变底色差得多的像素就是赛道和斜纹，按差值求透明度、反算出原色，
  缩到自适应图标的安全区内（108dp 画布里直径 66dp 的圆，432px 下半径 132px）。
- 单色：前景的透明度，白色，给 Android 13 的主题图标用。
"""
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "game", "icon.png")
DST = os.path.join(ROOT, "game", "android_icons")
N = 432            # 自适应图标每层 108dp，按 xxxhdpi 4 倍
SAFE_R = 128.0     # 前景内容的最大半径（略小于安全区 132px，给描边留一点余量）


def basis(x, y):
    return np.stack([np.ones_like(x), x, y, x * x, y * y, x * y], axis=-1)


def main() -> int:
    im = np.asarray(Image.open(SRC).convert("RGB"), dtype=np.float64)
    h, w, _ = im.shape
    yy, xx = np.mgrid[0:h, 0:w]
    u, v = xx / (w - 1), yy / (h - 1)

    # 先用“偏橙红、不黑不白”的像素粗拟合一次，再只用和拟合值接近的像素精修一次
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    mask = (r > 150) & (r - b > 60) & (g < 140)
    A = basis(u, v)
    for _ in range(2):
        coef, *_ = np.linalg.lstsq(A[mask], im[mask], rcond=None)
        bg = A @ coef
        diff = np.abs(im - bg).max(axis=-1)
        mask = diff < 10.0

    # 前景透明度：差值 8 以下算底色，40 以上算完全不透明
    alpha = np.clip((diff - 8.0) / 32.0, 0.0, 1.0)
    a3 = alpha[..., None]
    fg = np.where(a3 > 1e-3, (im - (1.0 - a3) * bg) / np.maximum(a3, 1e-3), 0.0)
    fg = np.clip(fg, 0.0, 255.0)

    ys, xs = np.nonzero(alpha > 0.05)
    cx, cy = (xs.min() + xs.max()) * 0.5, (ys.min() + ys.max()) * 0.5
    rmax = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2).max()
    scale = SAFE_R / rmax
    print(f"前景范围 x {xs.min()}-{xs.max()} y {ys.min()}-{ys.max()}，最大半径 {rmax:.0f}px，缩放 {scale:.3f}")

    rgba = np.dstack([fg, alpha * 255.0]).astype(np.uint8)
    fg_img = Image.fromarray(rgba, "RGBA")
    # 预乘后缩放，避免透明边缘发黑
    pm = np.dstack([fg * a3, alpha[..., None] * 255.0]).astype(np.float64)
    side = int(round(w * scale))
    pm_img = [Image.fromarray(pm[..., c].astype(np.float32), "F").resize((side, side), Image.LANCZOS) for c in range(4)]
    pm_s = np.stack([np.asarray(c) for c in pm_img], axis=-1)
    a_s = np.clip(pm_s[..., 3], 0.0, 255.0)
    rgb_s = np.where(a_s[..., None] > 0.5, pm_s[..., :3] / np.maximum(a_s[..., None] / 255.0, 1e-3), 0.0)
    small = np.dstack([np.clip(rgb_s, 0, 255), a_s]).astype(np.uint8)

    canvas = np.zeros((N, N, 4), dtype=np.uint8)
    # 内容中心放到画布中心
    ox = int(round(N * 0.5 - cx * scale))
    oy = int(round(N * 0.5 - cy * scale))
    x0, y0 = max(ox, 0), max(oy, 0)
    x1, y1 = min(ox + side, N), min(oy + side, N)
    canvas[y0:y1, x0:x1] = small[y0 - oy:y1 - oy, x0 - ox:x1 - ox]
    del fg_img

    # 背景：可见区域（中间 72dp，即 288px）对应原图整幅渐变
    by, bx = np.mgrid[0:N, 0:N]
    bu = (bx - 72.0) / 287.0
    bv = (by - 72.0) / 287.0
    bgi = np.clip(basis(bu, bv) @ coef, 0, 255).astype(np.uint8)

    mono = np.zeros((N, N, 4), dtype=np.uint8)
    mono[..., :3] = 255
    mono[..., 3] = canvas[..., 3]

    os.makedirs(DST, exist_ok=True)
    with open(os.path.join(DST, ".gdignore"), "w", encoding="utf-8") as f:
        f.write("")
    Image.fromarray(canvas, "RGBA").save(os.path.join(DST, "foreground_432.png"), optimize=True)
    Image.fromarray(bgi, "RGB").save(os.path.join(DST, "background_432.png"), optimize=True)
    Image.fromarray(mono, "RGBA").save(os.path.join(DST, "monochrome_432.png"), optimize=True)

    # 预览：前景叠在背景上，再套圆形遮罩，看看会不会被裁
    prev = Image.fromarray(bgi, "RGB").convert("RGBA")
    prev.alpha_composite(Image.fromarray(canvas, "RGBA"))
    circ = Image.new("L", (N, N), 0)
    d = np.sqrt((bx - N * 0.5 + 0.5) ** 2 + (by - N * 0.5 + 0.5) ** 2)
    circ = Image.fromarray(((d < 144.0) * 255).astype(np.uint8), "L")
    out = Image.new("RGBA", (N, N), (40, 40, 40, 255))
    out.paste(prev, (0, 0), circ)
    if len(sys.argv) > 1:
        out.save(sys.argv[1])
        print("预览:", sys.argv[1])
    print("已写入", DST)
    return 0


if __name__ == "__main__":
    sys.exit(main())
