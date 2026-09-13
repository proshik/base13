#!/usr/bin/env python3
"""Generator for the 35 level layouts.

The original's logic, but our own maps: the first level is simple and
symmetric, then the share of concrete, water and ice grows and the enemy wave
gets heavier. Left-right symmetry is what gives the recognisable look.

The result is levels/NN.lvl, which are then edited by hand.
The generator is deterministic: the same run yields the same maps.
"""
import os
import random

GRID = 26
TILES = GRID // 2
LEVELS = 35
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "game", "levels")

EMPTY, BRICK, STEEL, WATER, TREES, ICE = ".", "#", "@", "~", "%", "-"

BASE_TILE = (6, 12)
BASE_CELLS = [(12, 24), (13, 24), (12, 25), (13, 25)]
BASE_WALL = [(11, 23), (12, 23), (13, 23), (14, 23),
             (11, 24), (14, 24), (11, 25), (14, 25)]
ENEMY_SPAWN_TILES = [(0, 0), (6, 0), (12, 0)]
PLAYER_SPAWN_TILES = [(4, 12), (8, 12)]


def reserved_cells():
    """Cells the generator leaves alone: spawn points, their corridors and the base."""
    cells = set()
    for tx, ty in ENEMY_SPAWN_TILES:
        for dy in range(6):          # the tile itself plus two tiles of corridor below
            for dx in range(2):
                cells.add((tx * 2 + dx, ty * 2 + dy))
    for tx, ty in PLAYER_SPAWN_TILES:
        for dy in range(2):
            for dx in range(2):
                cells.add((tx * 2 + dx, ty * 2 + dy))
    cells.update(BASE_CELLS)
    cells.update(BASE_WALL)
    return cells


def put_tile(grid, tx, ty, ch, reserved):
    for dy in range(2):
        for dx in range(2):
            cx, cy = tx * 2 + dx, ty * 2 + dy
            if (cx, cy) in reserved:
                continue
            grid[cy][cx] = ch


def generate(level, rng):
    reserved = reserved_cells()
    grid = [[EMPTY] * GRID for _ in range(GRID)]

    counts = [
        (BRICK, 20 + level // 2),
        (STEEL, max(0, (level - 2) // 3)),
        (WATER, max(0, (level - 5) // 4)),
        (TREES, max(0, (level - 3) // 4)),
        (ICE, max(0, (level - 8) // 5)),
    ]

    for ch, count in counts:
        placed, guard = 0, 0
        while placed < count and guard < 4000:
            guard += 1
            tx = rng.randrange(0, (TILES + 1) // 2)
            ty = rng.randrange(1, TILES - 1)
            mirror = TILES - 1 - tx
            if (tx, ty) == BASE_TILE or (mirror, ty) == BASE_TILE:
                continue
            put_tile(grid, tx, ty, ch, reserved)
            put_tile(grid, mirror, ty, ch, reserved)
            placed += 2

    for cx, cy in BASE_WALL:
        grid[cy][cx] = BRICK
    for cx, cy in BASE_CELLS:
        grid[cy][cx] = EMPTY
    return grid


def enemy_queue(level, rng):
    """Towards the end of the game there are fewer plain tanks and more heavy and fast ones."""
    extra = min(14, (level * 14) // LEVELS)
    armor = extra // 3
    power = extra // 3
    fast = extra - armor - power
    queue = ["B"] * (20 - extra) + ["F"] * fast + ["P"] * power + ["A"] * armor
    rng.shuffle(queue)
    return "".join(queue)


def main():
    os.makedirs(OUT, exist_ok=True)
    for n in range(1, LEVELS + 1):
        rng = random.Random(1000 + n)
        grid = generate(n, rng)
        bonuses = sorted(rng.sample(range(20), 3))
        lines = [
            "enemies: " + enemy_queue(n, rng),
            "bonus: " + ",".join(str(b) for b in bonuses),
            "---",
        ]
        lines += ["".join(row) for row in grid]
        with open(os.path.join(OUT, "%02d.lvl" % n), "w") as handle:
            handle.write("\n".join(lines) + "\n")
    print("Generated %d levels in %s" % (LEVELS, OUT))


if __name__ == "__main__":
    main()
