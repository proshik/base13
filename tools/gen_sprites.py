#!/usr/bin/env python3
"""Assembles the PNG atlases from text sources.

PNG bytes depend on the zlib version, so it is the pixels that are checked and
not the file: assets/atlas.manifest sits alongside with sha256 of the raw data.
That way --check catches a forgotten rebuild and does not break on another
machine.
"""
import hashlib
import os
import struct
import sys
import zlib

import sprite_data as data

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ASSETS = os.path.join(ROOT, "game", "assets")
MANIFEST = os.path.join(ASSETS, "atlas.manifest")


def rotate_cw(grid):
    """Rotates a grid 90 degrees clockwise."""
    n = len(grid)
    return ["".join(grid[n - 1 - x][y] for x in range(n)) for y in range(n)]


def raw_rgba(width, height, cells, cell_size, columns):
    """Lays the frames out on a grid and returns raw RGBA rows."""
    rows = [bytearray(width * 4) for _ in range(height)]
    for index, (grid, palette) in enumerate(cells):
        ox = (index % columns) * cell_size
        oy = (index // columns) * cell_size
        for y, line in enumerate(grid):
            for x, ch in enumerate(line):
                color = palette[0] if ch == "." else palette[int(ch)]
                at = (ox + x) * 4
                rows[oy + y][at:at + 4] = bytes(color)
    return rows


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(tag, payload):
        head = struct.pack(">I", len(payload)) + tag + payload
        return head + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(blob)


def tank_cells():
    """Tanks: every drawing is unfolded into four directions."""
    order = ["player0", "player1", "player2", "player3",
             "basic", "fast", "power", "armor"]
    cells = []
    for name in order:
        palette = data.PALETTES["player" if name.startswith("player") else "enemy"]
        frames = data.TANKS[name]
        for direction in range(4):
            for frame in frames:
                grid = frame
                for _ in range(direction):
                    grid = rotate_cw(grid)
                cells.append((grid, palette))
    return cells


def sprites_atlas():
    cells = tank_cells()
    extras = ["eagle_alive", "eagle_dead",
              "flash0", "flash1", "flash2", "flash3",
              "boom_small0", "boom_small1", "boom_small2",
              "boom_big0", "boom_big1", "boom_big2", "boom_big3", "boom_big4",
              "bonus_helmet", "bonus_clock", "bonus_shovel",
              "bonus_star", "bonus_grenade", "bonus_tank",
              "shield0", "shield1"]
    palettes = {"eagle": "eagle", "flash": "flash", "boom": "fire",
                "bonus": "bonus", "shield": "flash"}
    for name in extras:
        key = next(p for p in palettes if name.startswith(p))
        cells.append((data.SPRITES16[name], data.PALETTES[palettes[key]]))
    return cells, 16, 16


def terrain_atlas():
    order = ["brick", "steel", "water_a", "water_b", "trees", "ice"]
    palettes = ["brick", "steel", "water", "water", "trees", "ice"]
    cells = [(data.TERRAIN[n], data.PALETTES[p]) for n, p in zip(order, palettes)]
    return cells, 8, 8


def bullets_atlas():
    cells = []
    for direction in range(4):
        rotated = data.BULLET
        for _ in range(direction):
            rotated = rotate_cw(rotated)
        cells.append((rotated, data.PALETTES["bullet"]))
    return cells, 4, 4


def font_atlas():
    # The order is fixed: digits, letters, punctuation. TextPainter.glyph_index
    # computes the glyph number — a reshuffle would shift every caption in the
    # game.
    order = [str(d) for d in range(10)] + [chr(c) for c in range(65, 91)] + [".", ":"]
    cells = [(data.FONT[g], data.PALETTES["font"]) for g in order]
    return cells, 8, 16


ICON_SIZE = 256
ICON_SCALE = 12
ICON_BACKGROUND = (24, 24, 24, 255)


def icon_rows():
    """The application icon: the player tank scaled by a whole multiplier.

    Ours rather than somebody else's: the project rule is that all content is
    original. The multiplier is whole for the same reason as the window scale:
    a fractional one would smear the pixels.
    """
    grid = data.TANKS["player0"][0]
    palette = data.PALETTES["player"]
    rows = [bytearray(ICON_SIZE * 4) for _ in range(ICON_SIZE)]
    for y in range(ICON_SIZE):
        for x in range(ICON_SIZE):
            at = x * 4
            rows[y][at:at + 4] = bytes(ICON_BACKGROUND)
    span = len(grid) * ICON_SCALE
    offset = (ICON_SIZE - span) // 2
    for gy, line in enumerate(grid):
        for gx, ch in enumerate(line):
            if ch == ".":
                continue
            color = palette[int(ch)]
            for dy in range(ICON_SCALE):
                row = rows[offset + gy * ICON_SCALE + dy]
                for dx in range(ICON_SCALE):
                    at = (offset + gx * ICON_SCALE + dx) * 4
                    row[at:at + 4] = bytes(color)
    return rows


BOOT_W, BOOT_H = 512, 480
BOOT_SCALE = 10
BOOT_TEXT = "BASE 13"
BOOT_TEXT_SCALE = 6
BOOT_BACKGROUND = (16, 16, 16, 255)


def _paint(rows, x0, y0, grid, palette, scale):
    """Draws a character grid scaled by a whole multiplier."""
    for gy, line in enumerate(grid):
        for gx, ch in enumerate(line):
            if ch == ".":
                continue
            color = palette[int(ch)]
            for dy in range(scale):
                y = y0 + gy * scale + dy
                if not 0 <= y < len(rows):
                    continue
                row = rows[y]
                for dx in range(scale):
                    x = x0 + gx * scale + dx
                    if 0 <= x * 4 < len(row):
                        row[x * 4:x * 4 + 4] = bytes(color)


def boot_rows():
    """The boot splash: our tank and the title instead of the engine logo."""
    rows = [bytearray(BOOT_W * 4) for _ in range(BOOT_H)]
    for row in rows:
        for x in range(BOOT_W):
            row[x * 4:x * 4 + 4] = bytes(BOOT_BACKGROUND)

    tank = data.TANKS["player0"][0]
    span = len(tank) * BOOT_SCALE
    glyph_w = 8 * BOOT_TEXT_SCALE
    glyph_h = 8 * BOOT_TEXT_SCALE
    gap = BOOT_TEXT_SCALE * 4

    # The tank and the caption are centred as one group rather than separately:
    # otherwise the composition drifts upward and leaves a gap below.
    group_h = span + gap + glyph_h
    top = (BOOT_H - group_h) // 2

    _paint(rows, (BOOT_W - span) // 2, top, tank,
           data.PALETTES["player"], BOOT_SCALE)

    text_w = len(BOOT_TEXT) * glyph_w
    x = (BOOT_W - text_w) // 2
    y = top + span + gap
    for ch in BOOT_TEXT:
        if ch in data.FONT:
            _paint(rows, x, y, data.FONT[ch], data.PALETTES["font"], BOOT_TEXT_SCALE)
        x += glyph_w
    return rows


# The macOS icon follows the guidelines: a 1024 canvas, an 824 rounded square
# centred on it (corner radius about 22.5% of the side), 100 px margins and a
# soft shadow below. The system does not do this for you — macOS applies no
# mask of its own, so the shape must live in the file itself, or a square juts
# out among the rounded ones in the dock.
MAC_CANVAS = 1024
MAC_BODY = 824
MAC_RADIUS = 185
MAC_TANK_SCALE = 40      # 16 px of art x 40 = 640, with air inside the 824
MAC_SHADOW_DROP = 12
MAC_SHADOW_ALPHA = 90


def _rounded_alpha(x, y, size, radius):
    """Coverage of a point by a rounded square [0..size) with corner radius."""
    cx = min(max(x, radius), size - radius)
    cy = min(max(y, radius), size - radius)
    dx, dy = x - cx, y - cy
    return dx * dx + dy * dy <= radius * radius


def _mac_mask():
    """Alpha mask of the icon body with a smoothed edge: four subsamples per point."""
    mask = [bytearray(MAC_CANVAS) for _ in range(MAC_CANVAS)]
    off = (MAC_CANVAS - MAC_BODY) // 2
    for y in range(MAC_BODY):
        for x in range(MAC_BODY):
            hits = 0
            for sx, sy in ((0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)):
                if _rounded_alpha(x + sx, y + sy, MAC_BODY, MAC_RADIUS):
                    hits += 1
            mask[off + y][off + x] = hits * 255 // 4
    return mask


def mac_icon_rows():
    mask = _mac_mask()
    rows = [bytearray(MAC_CANVAS * 4) for _ in range(MAC_CANVAS)]

    # Shadow: the same body shifted down and blurred by three averaging passes.
    shadow = [row[:] for row in mask]
    for _ in range(3):
        blurred = [bytearray(MAC_CANVAS) for _ in range(MAC_CANVAS)]
        r = 6
        for y in range(MAC_CANVAS):
            acc = 0
            row = shadow[y]
            for x in range(MAC_CANVAS + r):
                if x < MAC_CANVAS:
                    acc += row[x]
                if x - 2 * r - 1 >= 0:
                    acc -= row[x - 2 * r - 1]
                cx = x - r
                if 0 <= cx < MAC_CANVAS:
                    blurred[y][cx] = acc // (2 * r + 1)
        shadow = blurred
        blurred = [bytearray(MAC_CANVAS) for _ in range(MAC_CANVAS)]
        for x in range(MAC_CANVAS):
            acc = 0
            for y in range(MAC_CANVAS + r):
                if y < MAC_CANVAS:
                    acc += shadow[y][x]
                if y - 2 * r - 1 >= 0:
                    acc -= shadow[y - 2 * r - 1][x]
                cy = y - r
                if 0 <= cy < MAC_CANVAS:
                    blurred[cy][x] = acc // (2 * r + 1)
        shadow = blurred

    for y in range(MAC_CANVAS):
        sy = y - MAC_SHADOW_DROP
        for x in range(MAC_CANVAS):
            a = shadow[sy][x] if 0 <= sy < MAC_CANVAS else 0
            if a:
                rows[y][x * 4 + 3] = a * MAC_SHADOW_ALPHA // 255

    # Body: a dark fill with a slight vertical gradient.
    base = ICON_BACKGROUND
    for y in range(MAC_CANVAS):
        shade = 12 - (y * 20 // MAC_CANVAS)
        for x in range(MAC_CANVAS):
            a = mask[y][x]
            if a == 0:
                continue
            at = x * 4
            body = (min(255, base[0] + 12 + shade),
                    min(255, base[1] + 12 + shade),
                    min(255, base[2] + 14 + shade), 255)
            if a == 255:
                rows[y][at:at + 4] = bytes(body)
            else:
                # Edge: the body over the shadow already laid down, by coverage.
                back_a = rows[y][at + 3]
                out_a = a + back_a * (255 - a) // 255
                for i in range(3):
                    rows[y][at + i] = body[i] * a // max(1, out_a)
                rows[y][at + 3] = out_a

    # The tank by a whole multiplier, like everything else in this project.
    grid = data.TANKS["player0"][0]
    span = len(grid) * MAC_TANK_SCALE
    off = (MAC_CANVAS - span) // 2
    _paint(rows, off, off, grid, data.PALETTES["player"], MAC_TANK_SCALE)
    return rows


def build():
    """Builds every atlas; returns name -> (width, height, rows)."""
    out = {
        "icon": (ICON_SIZE, ICON_SIZE, icon_rows()),
        "boot": (BOOT_W, BOOT_H, boot_rows()),
        "icon_macos": (MAC_CANVAS, MAC_CANVAS, mac_icon_rows()),
    }
    for name, maker in [("sprites", sprites_atlas), ("terrain", terrain_atlas),
                        ("bullets", bullets_atlas), ("font", font_atlas)]:
        cells, cell_size, columns = maker()
        rows_count = (len(cells) + columns - 1) // columns
        width = columns * cell_size
        height = rows_count * cell_size
        out[name] = (width, height, raw_rgba(width, height, cells, cell_size, columns))
    return out


def digest(width, height, rows):
    h = hashlib.sha256()
    h.update(struct.pack(">II", width, height))
    for row in rows:
        h.update(bytes(row))
    return h.hexdigest()


def main():
    check = "--check" in sys.argv
    built = build()
    lines = ["%s %d %d %s" % (name, w, h, digest(w, h, rows))
             for name, (w, h, rows) in sorted(built.items())]
    text = "\n".join(lines) + "\n"

    if check:
        if not os.path.exists(MANIFEST):
            print("ERROR: assets/atlas.manifest is missing — run gen_sprites.py")
            return 1
        with open(MANIFEST) as handle:
            if handle.read() != text:
                print("ERROR: atlases diverged from their sources — rebuild them")
                return 1
        print("Atlases: OK")
        return 0

    os.makedirs(ASSETS, exist_ok=True)
    for name, (w, h, rows) in built.items():
        write_png(os.path.join(ASSETS, name + ".png"), w, h, rows)
    with open(MANIFEST, "w") as handle:
        handle.write(text)
    print("Atlases built: %d" % len(built))
    return 0


if __name__ == "__main__":
    sys.exit(main())
