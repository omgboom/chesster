"""Draw a cute chess-pawn mascot on a crisp 32x32 pixel grid."""

from pathlib import Path

from PIL import Image


PALETTE = {
    ".": (0, 0, 0, 0),       # transparent
    "O": (43, 33, 64, 255),  # outline and features: #2b2140
    "C": (244, 230, 200, 255),  # cream: #f4e6c8
    "H": (255, 246, 224, 255),  # highlight: #fff6e0
    "S": (217, 192, 154, 255),  # shade: #d9c09a
    "W": (255, 255, 255, 255),  # eye sparkle
    "R": (242, 154, 160, 255),  # rosy cheeks: #f29aa0
}

SIZE = 32


def make_grid():
    """Build a symmetric pawn from outlined pixel shapes."""
    grid = [["." for _ in range(SIZE)] for _ in range(SIZE)]

    def filled_shape(rows, shade_width=2):
        """Make a shape from inclusive (left, right) spans by row."""
        return {(x, y) for y, (left, right) in rows.items()
                for x in range(left, right + 1)}

    def paint_shape(shape):
        rows = {}
        for x, y in shape:
            rows.setdefault(y, []).append(x)
        for y, xs in rows.items():
            right = max(xs)
            for x in xs:
                grid[y][x] = "S" if x >= right - 1 else "C"
        for x, y in shape:
            if any((x + dx, y + dy) not in shape for dx, dy in
                   ((1, 0), (-1, 0), (0, 1), (0, -1))):
                grid[y][x] = "O"

    # Near-circular head; the collar overlays its lower contour cleanly.
    head = set()
    for y in range(1, 17):
        for x in range(7, 25):
            if ((x - 15.5) / 8.5) ** 2 + ((y - 8.5) / 8) ** 2 <= 1:
                head.add((x, y))
    paint_shape(head)

    # A soft glint on the upper-left of the head, kept clear of the outline.
    for x, y in head:
        if grid[y][x] != "O" and (
            (y <= 6 and x <= 13 and x + y >= 11) or
            (y == 7 and 10 <= x <= 11)
        ):
            grid[y][x] = "H"

    # Concave, gently flared skirt, widening from 12 to 22 pixels.
    body = filled_shape({
        17: (10, 21), 18: (9, 22), 19: (8, 23), 20: (7, 24),
        21: (7, 24), 22: (6, 25), 23: (6, 25), 24: (5, 26),
        25: (5, 26),
    })
    paint_shape(body)
    # Let the plinth's top edge serve as the skirt's single bottom outline.
    for x in range(6, 26):
        grid[25][x] = "S" if x >= 25 else "C"
    for y in range(18, 25):
        left = min(x for x, py in body if py == y)
        if (left + 1, y) in body:
            grid[y][left + 1] = "H"

    # Separate rounded slab with a closed top and bottom edge.
    base = filled_shape({
        26: (4, 27), 27: (3, 28), 28: (3, 28), 29: (3, 28),
        30: (4, 27),
    })
    paint_shape(base)
    # Top row remains a complete dark separator; the fill rows carry lighting.
    for y in (27, 28, 29):
        for x in range(4, 8):
            grid[y][x] = "H"
        for x in range(25, 28):
            grid[y][x] = "S"

    # Face: 2x3 eyes, sparkle pixels, and cheeks just below/outside them.
    for x0 in (12, 18):
        for y in range(7, 10):
            for x in range(x0, x0 + 2):
                grid[y][x] = "O"
        grid[7][x0] = "W"
    for x in (10, 11, 20, 21):
        grid[10][x] = "R"

    # Four-pixel smile: two raised corners and a two-pixel lower curve.
    for x in (14, 17):
        grid[11][x] = "O"
    for x in (15, 16):
        grid[12][x] = "O"

    # Rounded 18px x 3px disc overlays head and body.
    collar = filled_shape({15: (8, 23), 16: (7, 24), 17: (8, 23)})
    for x, y in collar:
        grid[y][x] = "O" if y in (15, 17) or x in (7, 24) else (
            "H" if x <= 9 else "S" if x >= 22 else "C"
        )

    return ["".join(row) for row in grid]


def main():
    grid = make_grid()
    assert len(grid) == SIZE and all(len(row) == SIZE for row in grid)
    assert set("".join(grid)) <= PALETTE.keys()

    image = Image.new("RGBA", (SIZE, SIZE))
    image.putdata([PALETTE[pixel] for row in grid for pixel in row])

    output_dir = Path(__file__).resolve().parent
    small = output_dir / "pawn_32.png"
    preview = output_dir / "pawn_16_preview.png"
    large = output_dir / "pawn_1024.png"
    image.save(small)
    image.resize((16, 16), Image.Resampling.BOX).save(preview)
    image.resize((1024, 1024), Image.Resampling.NEAREST).save(large)

    # The source and nearest-neighbour artwork remain fully opaque or transparent.
    assert {image.getpixel((x, y))[3] for y in range(SIZE) for x in range(SIZE)} <= {0, 255}
    print("\n".join(grid))


if __name__ == "__main__":
    main()
