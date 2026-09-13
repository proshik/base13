class_name SimConfig

## Every tunable number is collected here: the bar of "recognisable, without
## frame-perfect zeal" means the final values are settled by feel while
## playing.

# Speeds, units per tick (1 pixel = 16 units)
var player_speed := 12
var bullet_speed := 32
var bullet_speed_fast := 48

# The enemy wave. Its size comes from the level file rather than from config:
# how many tanks and of which kinds is part of the layout.
var max_enemies_alive := 4
var spawn_blink_ticks := 60
var spawn_interval_ticks := 180

# Effect timers
var shield_ticks := 600          ## helmet
var respawn_shield_ticks := 180  ## shield after respawning
var freeze_ticks := 600          ## clock
var shovel_ticks := 1200         ## shovel
var shovel_blink_ticks := 180    ## blinking before the shovel runs out
var bonus_life_ticks := 900      ## how long a bonus stays on the field
var bonus_blink_ticks := 180
var ice_slide_ticks := 30
var ally_stun_ticks := 60

# Player
var start_lives := 3
var respawn_delay_ticks := 60    ## pause between dying and returning to the field
var bonus_score := 500

# AI
var ai_dir_change_min := 30
var ai_dir_change_max := 120
var ai_fire_min := 90    ## a shot every 1.5-4 seconds: in the original the enemies are lazy
var ai_fire_max := 240
var ai_target_chance := 25        ## chance to move towards the target, %
var ai_target_chance_late := 40   ## the same from level ai_late_level onwards
var ai_base_target_chance := 50   ## target is the base, otherwise the player, %
var ai_late_level := 20

func enemy_speed(tank_type: int) -> int:
	match tank_type:
		Types.TankType.FAST:
			return 16
		_:
			return 8

func enemy_health(tank_type: int) -> int:
	match tank_type:
		Types.TankType.ARMOR:
			return 4
		_:
			return 1

func enemy_score(tank_type: int) -> int:
	match tank_type:
		Types.TankType.BASIC:
			return 100
		Types.TankType.FAST:
			return 200
		Types.TankType.POWER:
			return 300
		Types.TankType.ARMOR:
			return 400
		_:
			return 0

func enemy_bullet_speed(tank_type: int) -> int:
	if tank_type == Types.TankType.POWER:
		return bullet_speed_fast
	return bullet_speed

func ai_target_chance_for_level(level: int) -> int:
	if level >= ai_late_level:
		return ai_target_chance_late
	return ai_target_chance
