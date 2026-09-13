class_name Entities

class Tank:
	var id := 0
	var type := Types.TankType.BASIC
	var player_index := -1        ## -1 for enemies
	var pos := Vector2i.ZERO      ## top-left, units
	var dir := Types.Dir.UP
	var speed := 0
	var health := 1
	var stars := 0                ## players only
	var alive := true
	var spawn_ticks := 0          ## while > 0 the tank still blinks and does not physically exist
	var shield_ticks := 0
	var stun_ticks := 0
	var slide_ticks := 0          ## inertia on ice
	var slide_dir := Types.Dir.UP
	var drops_bonus := false
	var ai_dir_timer := 0
	var ai_fire_timer := 0
	var ai_target_is_base := true

	func center() -> Vector2i:
		return pos + Vector2i(Consts.TANK / 2, Consts.TANK / 2)

	func is_materialized() -> bool:
		return alive and spawn_ticks == 0

class Bullet:
	var id := 0
	var owner_id := 0
	var owner_is_player := false
	var pos := Vector2i.ZERO      ## top-left, units
	var dir := Types.Dir.UP
	var speed := 0
	var power := false            ## punches through concrete
	var alive := true

	func center() -> Vector2i:
		return pos + Vector2i(Consts.BULLET / 2, Consts.BULLET / 2)

class Bonus:
	var type := Types.BonusType.STAR
	var pos := Vector2i.ZERO
	var ticks_left := 0
	var active := false

class PlayerState:
	var index := 0
	var lives := 0
	var stars := 0
	var score := 0
	var kills: Array[int] = [0, 0, 0, 0]   ## by index: BASIC, FAST, POWER, ARMOR
	var active := false
	var respawn_timer := 0
	var tank_id := -1

class Carryover:
	## What travels with a player to the next level.
	## Star upgrades land here, but the campaign clears them — see
	## core/campaign.gd.
	var lives := 0
	var score := 0
	var stars := 0
	var kills: Array[int] = [0, 0, 0, 0]   ## by index: BASIC, FAST, POWER, ARMOR
