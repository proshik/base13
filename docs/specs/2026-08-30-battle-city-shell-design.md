# BASE 13: sound, screens and builds — design (subproject 1, part B2)

## 1. Goal

Part B1 produced a playable game: rules, picture, input, transitions between levels. It
plays, but it does not look or sound finished — it launches straight into battle, stays
silent and remembers no results.

Part B2 closes subproject 1 in full: sound, the flow of screens, pause, gamepad, high
score and builds for Windows, macOS and Linux.

## 2. What is in and what is out

### In

- Sound synthesis in the style of the NES sound chip, and playing it from core events.
- A constant engine hum with different tones while moving and while standing still.
- The flow of screens: splash → menu → level ⇄ stats → game over → menu.
- Pause on Esc.
- A high score that survives a restart.
- The gamepad as another source of the same five bits.
- Builds for three desktop platforms.

### Out

Touch input and mobile builds (subproject 2), network co-op (subproject 3), signing,
notarization and store publishing (subproject 4).

## 3. Screens

### A scene per screen

Every screen is a separate scene in `ui/`: splash, menu, game, stats, game over. The root
node `app.tscn` holds the current one and swaps it on request.

The "extend the state machine in `game.gd`" option was rejected deliberately: that file
already carries the level loop, the campaign and the rendering, and with the menu and the
stats it would turn into exactly what the rule about file size forbids. We already have
`core/sim.gd` at over five hundred lines as a cautionary tale.

The game screen's internal machine (`INTRO → PLAY → OUTRO → OVER`) stays: it is about a
level's lifecycle, not about screens, and there is no need to mix the two.

### The flow

```
Splash ──► Menu ──► Level ──► Stats ──► next Level
             ▲        │          │
             │        ▼          ▼
             └──── Game over ◄───┘
```

Pause is not a screen but an overlay on top of the game: the simulation stops ticking and
the picture stays. That way you can see what is happening on the field and lose no
context.

## 4. Sound

### The bar

The bar here is higher than "similar": the sound is made **as close to the original as
possible**. That means not "a square wave and noise in general" but reproducing exactly
what the NES sound chip had — otherwise the timbre comes out foreign, and recognizability
by ear is lost faster than by eye.

### What is emulated

| Channel | What it is | Where it is needed |
|---------|-----------|--------------------|
| Square with duty cycle | 12.5%, 25%, 50%, 75% — four different timbres | firing, jingles, power-ups, engine hum |
| Triangle | a stepped saw of sixteen levels, a muffled bottom end | the bottom of jingles, the big explosion |
| Noise | a fifteen-bit shift register, as in the chip | explosions, crumbling brick, ricochet |

The volume envelope is a stepped decay rather than a smooth one: the chip had sixteen
volume levels, and the characteristic "rattle" on the decay comes from exactly that.

Sample rate 44100, mono, sixteen bits. The files are WAV in `assets/sfx/`, assembled by
`tools/gen_sounds.py` from parameters in the source. The same device as with the sprites,
and for the same reason: what lives in the repository is a description of the sound, not
a binary of unknown origin; generation is reproducible, and the `--check` verification
against the manifest catches a forgotten rebuild.

### The engine hum

Section 8 of the subproject 1 design skips it, and that is an omission: in the original
the engine sounds continuously, in one tone for a standing tank and another for a moving
one. Without it the game sounds like a set of clicks in silence — that is half of the
recognizability by ear.

The hum is looped and switches on the state of the player's tank, not on an event. When
two people play, there is one hum: two layered give mush, and in the original there was
one channel.

### Imitating the shortage of channels

The chip had two square channels, one triangle and one noise, so an effect would cut over
the engine hum — that is audible in the original and is part of how it sounds. We
reproduce the most noticeable part: the hum is ducked for the duration of an effect. Full
voice stealing is not implemented — the complexity is out of proportion to the difference
by ear.

### Event → sound

| Core event | Sound |
|------------|-------|
| `SHOT_FIRED` | a short descending square sweep |
| `BULLET_HIT_BRICK` | a short mid-band noise |
| `BULLET_HIT_STEEL` | noise, higher and brighter, with a square overtone |
| `BULLET_HIT_BULLET` | a dry click |
| `TANK_DESTROYED` | noise with a decay |
| `PLAYER_DESTROYED` | the same, lower and longer, with a triangle |
| `BASE_DESTROYED` | a big explosion, then the losing jingle |
| `BONUS_SPAWNED` | a two-tone blip |
| `BONUS_TAKEN` | a quick ascending arpeggio |
| `ENEMY_SPAWNED` | a quiet click |
| `LEVEL_CLEARED` | a jingle, then the stats screen |
| `GAME_OVER` | a descending jingle |

Outside of events: the level start jingle on the `STAGE N` screen, and clicking while the
score is tallied on the stats screen.

The core still plays no sounds. `presentation/audio.gd` takes `drain_events()` apart in
exactly the way `presentation/effects.gd` takes them apart into explosions.

## 5. High score

One shared number that survives a restart. Stored in `user://base13.cfg`.

`platform/score_store.gd`: parsing and assembling the line are pure functions and are
tested; reading and writing the file is a thin wrapper over them. A broken or missing
file means "there is no high score" and never means a crash: a corrupted config is no
reason to keep someone from playing.

The high score is shown on the splash, in the menu and on the stats screen.

## 6. Gamepad

`platform/gamepad.gd` hands out the same five bits as the keyboard. The sources are
OR-ed together bitwise, so the keyboard and the gamepad work at the same time and there
is nothing to switch between.

The d-pad and the left stick are movement, the bottom and right face buttons are fire,
`Start` is pause. Two gamepads make two players, in order of connection.

## 7. Builds

`tools/build.sh` on top of `godot --export-release` for Windows, macOS and Linux, with
the result in `build/`. The presets are `export_presets.cfg`.

**The presets file has to come off `.gitignore`.** Right now it is ignored, and the build
is therefore not reproducible: everyone would get their own. It holds no secrets for
desktop. When Android arrives in subproject 2, the keystore passwords will live
separately, in environment variables, not in this file.

An honest boundary for verification: from a MacBook you can make sure that all three
builds are produced and are not empty, and run only the macOS build. Whether Windows and
Linux work will become clear on those machines. The macOS build is unsigned: on somebody
else's Mac it opens through System Settings → Privacy & Security → "Open Anyway" — it is
signed ad hoc but not notarized. Right-click → "Open" does not work for this case on
macOS 15 and newer. Notarization requires a paid Apple account — subproject 4.

## 8. Testing

What gets tested is the same as before: pure classes, headless, with the same command.

- Sound synthesis: determinism and the manifest, as with the sprites; the shape of the
  envelope; that the noise shift register produces the stated period.
- The "event → sound" mapping: complete, with no event left out.
- Parsing and assembling the high score file, including broken input.
- OR-ing the keyboard and gamepad bits.
- Screen switching: which screen follows which.

Not tested: the screen nodes themselves and the actual playback — those are verified by
running the game.

## 9. Order of work

1. The sound generator and the manifest.
2. Playing events.
3. The engine hum.
4. The root screen switcher; the game moves into `ui/`.
5. The splash screen.
6. The menu for one and two players.
7. Pause.
8. The stats screen.
9. The high score store.
10. Game over with the high score.
11. The gamepad.
12. The builds.

Sound first, because it is audible immediately and depends on nothing; screens after,
because they change where everything else fits in.

## 10. Readiness criteria

1. `./tools/test.sh` green in full, including `core/` isolation and atlas and sound
   verification.
2. The game sounds: engine, shots, explosions, power-ups, jingles.
3. The screen flow works from the splash to game over and back to the menu.
4. Pause stops the simulation and releases it without a jerk.
5. The high score survives a restart, and a broken file does not bring the game down.
6. The gamepad plays on equal terms with the keyboard.
7. Three builds are produced, and the macOS build runs.
