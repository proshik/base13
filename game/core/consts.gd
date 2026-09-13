class_name Consts

## Units per pixel. All of the core's arithmetic is in these units.
const SUBPIXEL := 16

const TILE_PX := 16   ## A field tile
const CELL_PX := 8    ## A terrain cell — half a tile
const GRID := 26      ## Cells along one side of the field

const FIELD_PX := GRID * CELL_PX        ## 208
const FIELD := FIELD_PX * SUBPIXEL      ## 3328 units
const CELL := CELL_PX * SUBPIXEL        ## 128 units
const TILE := TILE_PX * SUBPIXEL        ## 256 units
const TANK := TILE_PX * SUBPIXEL        ## 256 units
const BULLET := 4 * SUBPIXEL            ## 64 units

const TICKS_PER_SECOND := 60

## Field layout in tiles (13x13 tiles of 16 pixels).
const BASE_TILE := Vector2i(6, 12)
const PLAYER_SPAWN_TILES: Array[Vector2i] = [Vector2i(4, 12), Vector2i(8, 12)]
const ENEMY_SPAWN_TILES: Array[Vector2i] = [Vector2i(0, 0), Vector2i(6, 0), Vector2i(12, 0)]

## Cells occupied by the eagle (tile 6,12 means cells 12..13 x 24..25).
const BASE_CELLS: Array[Vector2i] = [
	Vector2i(12, 24), Vector2i(13, 24),
	Vector2i(12, 25), Vector2i(13, 25),
]

## The ring of brick around the eagle. The shovel turns it into concrete and
## back again.
const BASE_WALL_CELLS: Array[Vector2i] = [
	Vector2i(11, 23), Vector2i(12, 23), Vector2i(13, 23), Vector2i(14, 23),
	Vector2i(11, 24), Vector2i(14, 24),
	Vector2i(11, 25), Vector2i(14, 25),
]

static func tile_to_unit(t: Vector2i) -> Vector2i:
	return Vector2i(t.x * TILE, t.y * TILE)
