#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
冥想闹钟 Logo 生成器 —— 「圆相」

概念
----
SetupView 的核心视觉是那颗 132pt 的空心圆环「开始」按钮。Logo 把它升格：

  * 一道笔势渐变的青瓷圆环（ensō / 圆相）—— 一段冥想的完整时间；
  * 顶端留一道缺口 —— 时间有起止，不追求圆满无缺；
  * 缺口上方悬浮一粒实心青瓷点 —— 钵音被敲响的那一瞬（间隔提示）；
  * 两圈极淡的同心涟漪 —— 声音向外荡开，间隔次第响起。

色板取自 Shared/Palette.swift（宣纸 · 青瓷 · 水墨）：
  浅色：宣纸 #F7F5F1 底 + 青瓷 #7E9E92
  深色：岛底 #1C1B19 底 + 青瓷(深) #8FB3A6

用法
----
  python3 make_logo.py        # 重新生成全部产物

产物
----
  Resources/Logo/logo-mark.svg            矢量主文件（透明底，仅图形，可任意缩放）
  Resources/Logo/logo-mark-1024.png       透明底位图（仅图形）
  Resources/Logo/preview-sheet.png        预览拼版（人工检查观感用）
  MeditationAlarmApp/Resources/Assets.xcassets/AppIcon.appiconset/
                                        1024×1024 浅色 + 深色两张 + Contents.json
                                        （Xcode 14+ 单一尺寸方案，随系统深色模式切换）
"""

import math
import os

from PIL import Image, ImageDraw, ImageFont

# --------------------------------------------------------------------------
# 色板（与 Palette.swift 保持一致）
# --------------------------------------------------------------------------

PAPER = (0xF7, 0xF5, 0xF1)          # 宣纸
CELADON = (0x7E, 0x9E, 0x92)        # 青瓷
ISLAND_BG = (0x1C, 0x1B, 0x19)      # 灵动岛底
CELADON_DARK = (0x8F, 0xB3, 0xA6)   # 青瓷（深色变体）

# --------------------------------------------------------------------------
# 几何参数（主画布 2048×2048，最后缩放出各尺寸）
# --------------------------------------------------------------------------

MASTER = 2048
C = MASTER / 2                       # 圆心
R = 550.0                            # 主环半径
W_MAX = 82.0                         # 主环最大笔宽（≈15% R，ensō 的典型比例）
GAP_CENTER_DEG = 90.0                # 缺口朝正上方
GAP_WIDTH_DEG = 44.0                 # 缺口张角
DOT_DIST = 0.72 * R                  # 实心点距圆心
DOT_R = 0.115 * R                    # 实心点半径
RIPPLE1 = 1.22 * R                   # 内圈涟漪
RIPPLE1_W = 13.0
RIPPLE1_ALPHA = 0.22
RIPPLE2 = 1.46 * R                   # 外圈涟漪
RIPPLE2_W = 11.0
RIPPLE2_ALPHA = 0.11

# --------------------------------------------------------------------------
# 笔势剖面：入口细 → 行笔略蓄 → 收笔提锋出尖
# --------------------------------------------------------------------------

def _ease_out_cubic(u: float) -> float:
    return 1.0 - (1.0 - u) ** 3


def _ease_in_cubic(u: float) -> float:
    return u ** 3


def brush_profile(t: float) -> float:
    """t ∈ [0,1] 沿环周的位置，返回相对 W_MAX 的笔宽系数。"""
    if t < 0.09:                                   # 起笔：细入
        return 0.06 + 0.94 * _ease_out_cubic(t / 0.09)
    if t < 0.72:                                   # 行笔：微微蓄势
        return 1.0 + 0.05 * ((t - 0.09) / 0.63)
    return max(0.02, 1.05 * (1.0 - _ease_in_cubic((t - 0.72) / 0.28)))  # 收笔：出尖


def wobble(theta_deg: float) -> float:
    """圆心线的低频扰动 —— 正圆太几何，加 ±2% 的手绘起伏才有 ensō 的气质。"""
    th = math.radians(theta_deg)
    return 1.0 + 0.011 * math.sin(2 * th + 0.7) + 0.007 * math.sin(3 * th + 2.1)


def ring_polygon(n: int = 300):
    """渐变笔宽圆环的外/内边界多边形（逆时针扫过，避开顶端缺口）。"""
    start = GAP_CENTER_DEG + GAP_WIDTH_DEG / 2      # 112°
    sweep = 360.0 - GAP_WIDTH_DEG                   # 316°
    outer, inner = [], []
    for i in range(n + 1):
        t = i / n
        th_deg = start + sweep * t
        th = math.radians(th_deg)
        w = W_MAX * brush_profile(t)
        r_c = R * wobble(th_deg)
        outer.append((C + (r_c + w / 2) * math.cos(th), C - (r_c + w / 2) * math.sin(th)))
        inner.append((C + (r_c - w / 2) * math.cos(th), C - (r_c - w / 2) * math.sin(th)))
    return outer + inner[::-1]


def polygon_to_path(pts) -> str:
    d = f"M {pts[0][0]:.2f} {pts[0][1]:.2f}"
    for x, y in pts[1:]:
        d += f" L {x:.2f} {y:.2f}"
    return d + " Z"


def dot_center():
    th = math.radians(GAP_CENTER_DEG)
    return (C + DOT_DIST * math.cos(th), C - DOT_DIST * math.sin(th))


# --------------------------------------------------------------------------
# SVG 输出
# --------------------------------------------------------------------------

def build_svg(mark_color: str, dot_color: str,
              r1_color: str, r1_op: float, r2_color: str, r2_op: float) -> str:
    dx, dy = dot_center()
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {MASTER} {MASTER}">
  <!-- 外圈涟漪：间隔提示的声音向外荡开 -->
  <circle cx="{C}" cy="{C}" r="{RIPPLE2:.1f}" fill="none"
          stroke="{r2_color}" stroke-opacity="{r2_op}" stroke-width="{RIPPLE2_W}"/>
  <!-- 内圈涟漪 -->
  <circle cx="{C}" cy="{C}" r="{RIPPLE1:.1f}" fill="none"
          stroke="{r1_color}" stroke-opacity="{r1_op}" stroke-width="{RIPPLE1_W}"/>
  <!-- 圆相：一笔带过，起笔细、行笔蓄、收笔尖 -->
  <path d="{polygon_to_path(ring_polygon())}" fill="{mark_color}"/>
  <!-- 敲响的一瞬 -->
  <circle cx="{dx:.1f}" cy="{dy:.1f}" r="{DOT_R:.1f}" fill="{dot_color}"/>
</svg>
'''


# --------------------------------------------------------------------------
# PNG 渲染（Pillow）
# --------------------------------------------------------------------------

def _layer():
    return Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))


def render_mark(ring, dot, ripple) -> Image.Image:
    """在透明底上绘制完整图形（ring/dot/ripple 为 RGBA 元组）。"""
    img = _layer()

    # 涟漪：各自一层，避免半透明互相覆盖
    for radius, width, color in ((RIPPLE2, RIPPLE2_W, ripple[0]), (RIPPLE1, RIPPLE1_W, ripple[1])):
        layer = _layer()
        d = ImageDraw.Draw(layer)
        pad = width
        d.ellipse([C - radius, C - radius, C + radius, C + radius],
                  outline=color, width=int(width))
        # Pillow 的 outline 居中于路径，此处已满足；pad 变量仅示意边界
        img = Image.alpha_composite(img, layer)

    # 主环
    layer = _layer()
    ImageDraw.Draw(layer).polygon(ring_polygon(), fill=ring)
    img = Image.alpha_composite(img, layer)

    # 实心点
    layer = _layer()
    dx, dy = dot_center()
    ImageDraw.Draw(layer).ellipse([dx - DOT_R, dy - DOT_R, dx + DOT_R, dy + DOT_R], fill=dot)
    return Image.alpha_composite(img, layer)


def make_icon(size: int, bg, mark_colors) -> Image.Image:
    icon = Image.new("RGBA", (size, size), bg + (255,))
    mark = render_mark(*mark_colors)
    mark = mark.resize((size, size), Image.LANCZOS)
    return Image.alpha_composite(icon, mark)


# --------------------------------------------------------------------------
# 预览拼版
# --------------------------------------------------------------------------

def load_font(size: int):
    # STHeiti Light：与 App 的轻字重排版同源。
    # 注意：不能用 getbbox 判断有没有中文字形 —— 缺字时返回的 .notdef
    #  advance 与全角汉字同宽（都是 24px），会误判。必须比对渲染 mask。
    for path in ("/System/Library/Fonts/STHeiti Light.ttc",
                 "/System/Library/Fonts/STHeiti Medium.ttc",
                 "/System/Library/Fonts/Supplemental/Songti.ttc"):
        try:
            f = ImageFont.truetype(path, size)
            if bytes(f.getmask("冥", mode="L")) != bytes(f.getmask("\uFFFF", mode="L")):
                return f
        except Exception:
            continue
    return ImageFont.load_default()


def preview_sheet(light_mark, dark_mark, out_path: str):
    """人工检查用拼版：大图 / 真实小尺寸 / 深色 / Setup 页内效果。"""
    W, H = 1560, 1180
    sheet = Image.new("RGB", (W, H), (0xEC, 0xEA, 0xE5))
    d = ImageDraw.Draw(sheet)

    # --- 面板 1：浅色图标大图 ---
    d.rectangle([40, 40, 560, 560], fill=PAPER)
    sheet.paste(make_icon(520, PAPER, light_mark).convert("RGB"), (40, 40))
    d.text((60, 580), "浅色 App 图标", font=load_font(30), fill=(0x2B, 0x2A, 0x28))

    # --- 面板 2：深色图标 ---
    d.rectangle([600, 40, 1120, 560], fill=ISLAND_BG)
    sheet.paste(make_icon(520, ISLAND_BG, dark_mark).convert("RGB"), (600, 40))
    d.text((620, 580), "深色 App 图标", font=load_font(30), fill=(0x2B, 0x2A, 0x28))

    # --- 面板 3：真实小尺寸可读性 ---
    x = 40
    for s in (180, 120, 87, 80, 60, 40):
        icon = make_icon(s, PAPER, light_mark).convert("RGB")
        sheet.paste(icon, (x, 680))
        d.text((x, 680 + s + 14), f"{s}px", font=load_font(26), fill=(0x6E, 0x6B, 0x66))
        x += s + 56
    d.text((40, 640), "小尺寸可读性（真实像素）", font=load_font(30), fill=(0x2B, 0x2A, 0x28))

    # --- 面板 4：Setup 页内效果 ---
    px, py, pw, ph = 1180, 640, 300, 500
    d.rectangle([px, py, px + pw, py + ph], fill=PAPER, outline=(0xE2, 0xDE, 0xD6), width=2)
    mark = render_mark(*light_mark).resize((150, 150), Image.LANCZOS)
    sheet.paste(mark.convert("RGB"), (px + (pw - 150) // 2, py + 36), mark.convert("RGBA"))
    f_label = load_font(22)
    f_big = load_font(54)
    f_small = load_font(22)
    for txt, f, y, col in (("冥想时长", f_label, py + 210, (0x9A, 0x96, 0x8F)),
                           ("20", f_big, py + 238, (0x2B, 0x2A, 0x28)),
                           ("分钟", f_small, py + 296, (0x9A, 0x96, 0x8F))):
        bb = d.textbbox((0, 0), txt, font=f)
        d.text((px + (pw - (bb[2] - bb[0])) / 2, y), txt, font=f, fill=col)
    # 胶囊
    cx = px + 60
    for label, sel in (("无", False), ("3 分", True), ("5 分", False)):
        bb = d.textbbox((0, 0), label, font=f_small)
        w = bb[2] - bb[0] + 28
        if sel:
            d.rounded_rectangle([cx, py + 340, cx + w, py + 376], radius=18, fill=(0xE6, 0xEF, 0xEB))
        d.text((cx + 14, py + 348), label, font=f_small,
               fill=(0x2B, 0x2A, 0x28) if sel else (0x6E, 0x6B, 0x66))
        cx += w + 8
    # 空心圆按钮
    bx, by, br = px + pw // 2, py + 428, 52
    d.ellipse([bx - br, by - br, bx + br, by + br], outline=(0xE2, 0xDE, 0xD6), width=2)
    bb = d.textbbox((0, 0), "开始", font=f_small)
    d.text((bx - (bb[2] - bb[0]) / 2, by - (bb[3] - bb[1]) / 2 - 2), "开始",
           font=f_small, fill=(0x2B, 0x2A, 0x28))

    sheet.save(out_path)
    print(f"  preview -> {out_path}")


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------

def write_appiconset(light, dark):
    """写入 MeditationAlarmApp/Resources/Assets.xcassets/AppIcon.appiconset/。

    Xcode 14+ 的单一尺寸方案：只需一张 1024×1024 universal；
    深色变体用 appearances/luminosity 声明，随系统深色模式自动切换。
    """
    here = os.path.dirname(os.path.abspath(__file__))
    set_dir = os.path.normpath(os.path.join(
        here, "..", "..", "MeditationAlarmApp", "Resources", "Assets.xcassets",
        "AppIcon.appiconset"))
    os.makedirs(set_dir, exist_ok=True)

    make_icon(1024, PAPER, light).convert("RGB").save(
        os.path.join(set_dir, "AppIcon-1024.png"))
    make_icon(1024, ISLAND_BG, dark).convert("RGB").save(
        os.path.join(set_dir, "AppIcon-1024-dark.png"))

    contents = {
        "images": [
            {
                "filename": "AppIcon-1024.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
            {
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
                "filename": "AppIcon-1024-dark.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
        ],
        "info": {"author": "xcode", "version": 1},
    }
    import json
    with open(os.path.join(set_dir, "Contents.json"), "w", encoding="utf-8") as f:
        json.dump(contents, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"  AppIcon.appiconset/ -> {set_dir}")


def main():
    here = os.path.dirname(os.path.abspath(__file__))

    light = (CELADON + (255,), CELADON + (255,),
             (CELADON + (int(255 * RIPPLE1_ALPHA),), CELADON + (int(255 * RIPPLE2_ALPHA),)))
    dark = (CELADON_DARK + (255,), CELADON_DARK + (255,),
            (CELADON_DARK + (int(255 * RIPPLE1_ALPHA),), CELADON_DARK + (int(255 * RIPPLE2_ALPHA),)))

    # 1. 矢量主文件（浅色图形；深色场景直接换描边色即可）
    svg = build_svg("#7E9E92", "#7E9E92", "#7E9E92", RIPPLE1_ALPHA, "#7E9E92", RIPPLE2_ALPHA)
    with open(os.path.join(here, "logo-mark.svg"), "w", encoding="utf-8") as f:
        f.write(svg)
    print("  logo-mark.svg")

    # 2. 透明底位图
    render_mark(*light).save(os.path.join(here, "logo-mark-1024.png"))
    print("  logo-mark-1024.png")

    # 3. App 图标（直接进 asset catalog）
    write_appiconset(light, dark)

    # 4. 预览拼版
    preview_sheet(light, dark, os.path.join(here, "preview-sheet.png"))


if __name__ == "__main__":
    main()
