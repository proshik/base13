extends GutTest

const NAMES := [
	"shot", "hit_brick", "hit_steel", "hit_bullet",
	"boom_tank", "boom_player", "boom_base",
	"bonus_appear", "bonus_take", "enemy_spawn",
	"jingle_clear", "jingle_gameover",
	"engine_idle", "engine_move", "score_tick",
]

func _stream(name: String) -> AudioStreamWAV:
	var path := "res://assets/sfx/%s.wav" % name
	var stream: AudioStreamWAV = ResourceLoader.load(path)
	assert_not_null(stream, "sound %s is missing" % path)
	return stream

## The largest amplitude. Computed by decoding byte pairs rather than checking
## individual bytes: in an even square wave the low byte can be zero in every
## sample, and a naive check would declare such a sound silent.
func _peak(stream: AudioStreamWAV) -> int:
	var peak := 0
	for i in range(0, stream.data.size() - 1, 2):
		var value: int = stream.data[i] | (stream.data[i + 1] << 8)
		if value >= 32768:
			value -= 65536
		peak = maxi(peak, absi(value))
	return peak

func test_every_sound_exists_and_is_not_silent() -> void:
	for name in NAMES:
		var stream := _stream(name)
		assert_gt(stream.data.size(), 0, "sound %s is empty" % name)
		assert_gt(_peak(stream), 0, "sound %s is made of silence" % name)

func test_format_matches_the_chip() -> void:
	for name in NAMES:
		var stream := _stream(name)
		assert_eq(stream.mix_rate, 44100, "the sample rate of %s" % name)
		assert_false(stream.stereo, "%s must be mono" % name)

func test_sounds_are_not_compressed_with_loss() -> void:
	# Godot compresses WAV into QOA by default. The chip's timbre rests on the
	# wave shape, so losses are unacceptable here — the import is set to plain
	# PCM.
	for name in NAMES:
		assert_eq(_stream(name).format, AudioStreamWAV.FORMAT_16_BITS,
			"sound %s was compressed lossily" % name)

func test_engine_sounds_are_short_enough_to_loop() -> void:
	# A looped hum a second long is audible as a repeat; a hundred milliseconds
	# is not.
	for name in ["engine_idle", "engine_move"]:
		assert_lt(_stream(name).get_length(), 0.2, "%s is too long for a loop" % name)

func test_explosions_are_longer_than_clicks() -> void:
	assert_gt(_stream("boom_player").get_length(), _stream("hit_bullet").get_length(),
		"a player's death must sound weightier than a click")
	assert_gt(_stream("jingle_gameover").get_length(), _stream("shot").get_length())

func test_nothing_clips() -> void:
	# The sum of the channels must not hit the ceiling: hard clipping produces a
	# rasp the chip never had.
	for name in NAMES:
		assert_lt(_peak(_stream(name)), 32000, "sound %s hits the ceiling" % name)

func test_engine_sounds_loop() -> void:
	# The loop is set in the import settings rather than in code. If the .import
	# file is ever regenerated with defaults, the hum would start cutting off —
	# and this test says so, rather than an ear six months later.
	for name in ["engine_idle", "engine_move"]:
		assert_eq(_stream(name).loop_mode, AudioStreamWAV.LOOP_FORWARD,
			"the hum %s must be looped" % name)
