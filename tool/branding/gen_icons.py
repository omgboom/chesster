"""Generate Chesster icon assets from the 32x32 pixel-art master.

The pixel art itself was drawn by tool/branding/draw_pawn.py (writes pawn_32.png
next to itself). Regenerate everything with:

    python tool/branding/draw_pawn.py
    python tool/branding/gen_icons.py . tool/branding/pawn_32.png "#6B8E4E"

usage: python gen_icons.py <repo> <master_32.png> <background hex>
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

repo = Path(sys.argv[1])
master = Image.open(sys.argv[2]).convert("RGBA")
BG = sys.argv[3]
assert master.size == (32, 32)
W, H = master.size
px = master.load()


def nn(img, size):
    return img.resize(size, Image.NEAREST)


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# --- master art -------------------------------------------------------------
branding = repo / "assets/branding"
master.save(branding / "chesster_pawn_pixel.png")
nn(master, (1024, 1024)).save(branding / "chesster_pawn_pixel_1024.png")

# --- vector drawables built from the pixel grid --------------------------------
# 108dp adaptive canvas, 2dp per art pixel => 64dp art inside the 66dp safe zone.
SCALE = 2
OFF = (108 - W * SCALE) // 2


def rects_for(pred):
    """Greedy merge of matching pixels into rectangles (row runs, then extend down)."""
    used = [[False] * W for _ in range(H)]
    rects = []
    for y in range(H):
        x = 0
        while x < W:
            if used[y][x] or not pred(x, y):
                x += 1
                continue
            x2 = x
            while x2 + 1 < W and not used[y][x2 + 1] and pred(x2 + 1, y):
                x2 += 1
            y2 = y
            while y2 + 1 < H and all(not used[y2 + 1][i] and pred(i, y2 + 1) for i in range(x, x2 + 1)):
                y2 += 1
            for yy in range(y, y2 + 1):
                for xx in range(x, x2 + 1):
                    used[yy][xx] = True
            rects.append((x, y, x2 - x + 1, y2 - y + 1))
            x = x2 + 1
    return rects


def path_data(rects):
    return " ".join(
        f"M{OFF + x * SCALE},{OFF + y * SCALE}h{w * SCALE}v{h * SCALE}h{-w * SCALE}z" for x, y, w, h in rects
    )


def vector(paths):
    body = "".join(
        f'    <path\n        android:fillColor="{c}"\n        android:pathData="{d}" />\n' for c, d in paths
    )
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Generated from assets/branding/chesster_pawn_pixel.png: one square per art pixel. -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="108dp"\n    android:height="108dp"\n'
        '    android:viewportWidth="108"\n    android:viewportHeight="108">\n'
        f"{body}</vector>\n"
    )


colours = []
for y in range(H):
    for x in range(W):
        r, g, b, a = px[x, y]
        if a and (r, g, b) not in colours:
            colours.append((r, g, b))
paths = []
for col in colours:
    rects = rects_for(lambda x, y, col=col: px[x, y][3] and px[x, y][:3] == col)
    paths.append(("#%02X%02X%02X" % col, path_data(rects)))
res = repo / "android/app/src/main/res"
(res / "drawable/ic_launcher_foreground.xml").write_text(vector(paths), encoding="utf-8", newline="\n")

# Monochrome (themed icons): silhouette with the darkest colour (outline,
# eyes, mouth) cut out inside the body, so the face stays visible.
def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


dark = min(colours, key=lum)


def inside(x, y):
    """Opaque pixel that is not part of the outer outline."""
    if not px[x, y][3]:
        return False
    if px[x, y][:3] != dark:
        return True
    # A dark pixel is an outline pixel when it touches transparency (4-neighbour).
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nx, ny = x + dx, y + dy
        if not (0 <= nx < W and 0 <= ny < H) or not px[nx, ny][3]:
            return True  # outline: keep it, so the silhouette keeps its size
    return False  # interior dark detail (eyes, mouth, inner lines): cut out


mono = rects_for(inside)
(res / "drawable/ic_launcher_monochrome.xml").write_text(
    vector([("#FFFFFFFF", path_data(mono))]), encoding="utf-8", newline="\n"
)
(res / "values/colors.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
    f'    <color name="ic_launcher_background">{BG}</color>\n</resources>\n',
    encoding="utf-8",
    newline="\n",
)

# --- legacy PNG mipmaps (pre-Android 8) -------------------------------------
bg = hexrgb(BG) + (255,)
for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    art = round(size * 2 / 3)  # 32, 48, 64, 96, 128 => integer scales except hdpi
    sprite = nn(master, (art, art))
    for name, shape in (("ic_launcher", "square"), ("ic_launcher_round", "circle")):
        big = size * 4
        mask = Image.new("L", (big, big), 0)
        d = ImageDraw.Draw(mask)
        if shape == "circle":
            d.ellipse((0, 0, big - 1, big - 1), fill=255)
        else:
            d.rounded_rectangle((0, 0, big - 1, big - 1), radius=big // 6, fill=255)
        mask = mask.resize((size, size), Image.LANCZOS)
        icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        icon.paste(Image.new("RGBA", (size, size), bg), (0, 0), mask)
        icon.alpha_composite(sprite, ((size - art) // 2, (size - art) // 2))
        icon.save(res / f"mipmap-{density}/{name}.png", optimize=True)

# --- Windows .ico ---------------------------------------------------------------
frames = []
for s in (16, 20, 24, 32, 40, 48, 64, 128, 256):
    if s % 32 == 0 or s == 48:
        frames.append(nn(master, (s, s)))
    else:
        # Downscaling below 32: area-average, then snap alpha so edges stay hard-ish.
        frames.append(nn(master, (s * 8, s * 8)).resize((s, s), Image.BOX))
ico = repo / "windows/runner/resources/app_icon.ico"
frames[-1].save(ico, format="ICO", sizes=[f.size for f in frames], append_images=frames[:-1])

# --- website ----------------------------------------------------------------------
nn(master, (64, 64)).save(repo / "docs/favicon.png", optimize=True)
nn(master, (256, 256)).save(repo / "docs/logo.png", optimize=True)
print("colours", colours, "dark", dark, "fg rects", sum(p[1].count("M") for p in paths), "mono rects", len(mono))
