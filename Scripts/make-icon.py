#!/usr/bin/env python3
"""
SwiftDown 应用图标生成器（Adobe 字标风格）
==========================================
风格参照 Adobe CC 系列（Ps / Ai / Ae / Id）：实色圆角块 + 内嵌细边框 + 两位字母矩标。
字母取 "Md"——按 Adobe 命名惯例，首字母大写、次字母小写（Markdown → Md）。

母版是全出血（铺满 1024、无透明边）：macOS 26+ 会把图标放进自己的圆角遮罩里，
自带透明留白会导致"圆角套圆角 + 浅色底板"的双层边框（实测 NSWorkspace 取图如此）。

导出：icon.svg（128 及以上用）/ icon-small.svg（16/32/64 用：字号更大、边框更粗、内缩更小）
—— 小尺寸不是等比缩放，而是重新配平视觉重量，这是系统级图标的通行做法。

用法：
    python3 Scripts/make-icon.py [配色] [字形]
    python3 Scripts/make-icon.py ink rounded     # 墨蓝 + 圆体
    python3 Scripts/make-icon.py --list          # 列出所有配色 / 字形
"""
import math
import pathlib

CANVAS = 1024
CX = CY = CANVAS / 2
SQ_N = 5.0

# —— 配色方案 ——
# 结构：深色块 + 同色系细边 + 单一高饱和字色（Adobe 的组合逻辑）
# frame 一律用「实色」：半透明暖色叠在深底上会被 alpha 混合拉低饱和度，出来是发褐的脏线
SCHEMES = {
    # ── 深色系 ──
    "ink":   dict(bg=("#1A2742", "#0A1120"), mark="#FF6B45", frame="#EF7B57"),  # 墨蓝 + 朱红（默认）
    "white": dict(bg=("#1A2742", "#0A1120"), mark="#FFFFFF", frame="#EF7B57"),  # 墨蓝 + 白
    "slate": dict(bg=("#2A3340", "#141A24"), mark="#F6F3EA", frame="#8C97A8"),  # 灰蓝 + 米白
    "ocean": dict(bg=("#0F3038", "#04141A"), mark="#4FE3C1", frame="#237468"),  # 深青 + 薄荷
    "iris":  dict(bg=("#241C4A", "#0C0820"), mark="#BCA4FF", frame="#6E55BF"),  # 深靛 + 薰衣草
    "ember": dict(bg=("#312B24", "#120E0B"), mark="#FFC24F", frame="#A6752C"),  # 石墨 + 琥珀
    "rose":  dict(bg=("#341420", "#16060D"), mark="#FF92A8", frame="#B85C72"),  # 酒红 + 珊瑚粉
    # ── 浅色系（深色 Dock 上最跳）──
    "paper": dict(bg=("#FDFBF6", "#E8DEC9"), mark="#BE3F19", frame="#E3B29A", sheen=0.0,
                   size=(414, 449)),   # 浅底深字视觉收缩，字号要比深底方案大一档
}

# —— 字形 ——
# sf     : SF Pro Display Bold（系统无衬线，Adobe 常规气质）
# rounded: Arial Rounded MT Bold（圆头笔画，友好感）
# 系数全部由 CoreText 实测 "Md" 的墨迹包围盒得到（见 Scripts 下 metrics 脚本），
# 必须按墨迹而非排版框居中，否则字母整体偏一截。
FONTS = {
    "sf": dict(
        css="-apple-system, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif",
        weight=700, tracking=-0.028,
        size=(410, 456),                       # (完整版, 小尺寸版)
        baseline_em=0.3468, dx_em=-0.0191,     # cap 0.7046 / 下沿 -0.0098 / 偏右 0.0191
    ),
    "rounded": dict(
        css="'Arial Rounded MT Bold', 'Arial Rounded MT', Arial, sans-serif",
        weight=400, tracking=0.0,              # 只有一档字重：写 700 会被合成加粗而糊
        size=(402, 436),
        baseline_em=0.3579, dx_em=-0.0034,     # cap 0.7280 / 下沿 -0.0122 / 偏右 0.0034
    ),
}


def squircle(a: float, b: float, cx: float, cy: float, n: float = SQ_N, steps: int = 720) -> str:
    """超椭圆 |x|^n+|y|^n=1：连续曲率，用于画与外框同心缩进的内嵌边框。"""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(c) ** (2.0 / n), c)
        y = cy + b * math.copysign(abs(s) ** (2.0 / n), s)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"


def build_svg(scheme: str = "paper", small: bool = False, font: str = "rounded") -> str:
    s = SCHEMES[scheme]
    f = FONTS[font]

    # 小尺寸：字号更大、边框更粗、内缩更小——缩放后视觉重量才一致
    # 配色可覆盖字号（浅底深字会视觉收缩，需要单独配一档）
    size = s.get("size") or f["size"]
    if small:
        font_size, inset, frame_w = size[1], 56, 11
    else:
        font_size, inset, frame_w = size[0], 62, 8

    frame = squircle(CX - inset, CY - inset, CX, CY, SQ_N)
    baseline = CY + font_size * f["baseline_em"]
    optical_dx = font_size * f["dx_em"]
    sheen = s.get("sheen", 0.10)

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}"
     viewBox="0 0 {CANVAS} {CANVAS}">
<defs>
  <linearGradient id="bg" x1="0.15" y1="0" x2="0.85" y2="1">
    <stop offset="0" stop-color="{s['bg'][0]}"/><stop offset="1" stop-color="{s['bg'][1]}"/>
  </linearGradient>
  <radialGradient id="sheen" cx="0.34" cy="0.04" r="0.9">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="{sheen:.2f}"/>
    <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="{sheen * 0.2:.2f}"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
  </radialGradient>
</defs>

<rect width="{CANVAS}" height="{CANVAS}" fill="url(#bg)"/>
<rect width="{CANVAS}" height="{CANVAS}" fill="url(#sheen)"/>

<path d="{frame}" fill="none" stroke="{s['frame']}" stroke-opacity="1"
      stroke-width="{frame_w}"/>

<text x="{CX + optical_dx:.1f}" y="{baseline:.1f}" text-anchor="middle"
      font-family="{f['css']}"
      font-weight="{f['weight']}" font-size="{font_size}"
      letter-spacing="{f['tracking']}em"
      fill="{s['mark']}">Md</text>
</svg>
'''


if __name__ == "__main__":
    import sys
    root = pathlib.Path(__file__).resolve().parent.parent
    (root / "Assets").mkdir(parents=True, exist_ok=True)

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--list" in sys.argv:
        print("配色：", " ".join(SCHEMES))
        print("字形：", " ".join(FONTS))
        raise SystemExit

    # 参数顺序不限：命中哪个字典就用哪个
    scheme = next((a for a in args if a in SCHEMES), "paper")
    font = next((a for a in args if a in FONTS), "rounded")

    if "compare" in sys.argv:                      # 每个配色各出一张对比稿
        for name in SCHEMES:
            p = root / "Assets" / f"_cmp-{name}.svg"
            p.write_text(build_svg(name, font=font), encoding="utf-8")
            print(p)
    else:
        for name, small in (("icon.svg", False), ("icon-small.svg", True)):
            p = root / "Assets" / name
            p.write_text(build_svg(scheme, small, font), encoding="utf-8")
            print(p)
