# BASE 13: the core and the single-player game — design

Date: 2026-08-25
Status: approved for implementation
Subproject: 1 of 4

## 1. Goal

Make a remake of Battle City (Namco, NES, 1985) on Godot, aimed at release on the App
Store and Google Play as well as on desktop.

The game is called **BASE 13**: both words are facts about it. You defend a base, and the
field is 13×13 tiles. The name was chosen partly for search reasons: the niche is
overflowing with games that have Brick and Tank in the title, and one more of those would
be lost among them. The word "tanks" moves into the subtitle and the store keywords —
a nostalgic search will lead to the game anyway.

Application identifier: `com.proshik.base13`.

The fidelity bar: **recognizable, without frame-by-frame obsession**. Someone who played
the original should sit down and say "yes, that's it" — from the feel of the controls, the
set of rules and the visual language. The original's exact timings are not verified
against an emulator.

All content (sprites, sound, level layouts) is our own, made in the style of the original.
No Namco/Bandai assets are used: the game is going to the stores, and borrowing there
creates a real risk.

## 2. Decomposition

The full idea — the game plus network co-op plus two mobile stores — is too big for one
spec. It is cut into four independently deliverable subprojects:

| # | Subproject | Result |
|---|-----------|--------|
| 1 | **The core and the single-player game** (this document) | A playable desktop game: 35 levels, AI, power-ups, score |
| 2 | Mobile platforms | Touch controls, adaptive layout, Android and iOS builds |
| 3 | Local-network co-op | Finding a host over Wi-Fi, a lobby, synchronous two-player play |
| 4 | Store release | Icons, screenshots, signatures, privacy policy, review |

Each gets its own spec, plan and implementation cycle. This document describes subproject
1 in full and fixes the boundaries that 2 and 3 depend on.

### In subproject 1

The simulation and all the game rules; 35 level layouts of our own; rendering and sound;
the menu, game, stats and game over screens; local two-player co-op at one keyboard (it
follows from the architecture for free); builds for Windows, macOS, Linux; tests.

### Out

Touch controls and mobile builds (subproject 2). Any networking (subproject 3). Store
assets and metadata (subproject 4). A level editor, online leaderboards, skins and extra
modes — outside the idea entirely.

## 3. Architecture

Four layers with strictly one-way dependencies:

```
platform/      input sources → five bits per player
     ↓
core/          the simulation: rules, state, events. Not a single node
     ↓
presentation/  reads state, draws it and sounds it. Has no state of its own
ui/            screens, HUD, transitions
```

**The main rule: `core/` imports nothing from the other folders and does not touch the
engine's subsystems.** Inside there is only the GDScript language and `RefCounted`. No
`Node`, `Input`, `Time`, `randi()`, resource loading or physics. The rule is checked in CI
by searching the imports: without an automated check, boundaries like this go stale within
a month.

That buys three things, and they are why the architecture was chosen:

1. **Testability.** The rules are checked without graphics and without opening a window,
   in seconds.
2. **Determinism**, and therefore cheap lockstep co-op in subproject 3: only button
   presses travel over the network.
3. **Independence from the input device**: touch from subproject 2 becomes another
   supplier of the same five bits.

## 4. The model of the world

### The coordinate system

- The field is **13×13 tiles** of 16 pixels: 208×208 pixels.
- The terrain is kept on a **twice-finer 26×26 grid of 8-pixel cells**: in the original a
  bullet chews a quarter out of a brick rather than the whole block.
- Entity positions are integers in **1/16 of a pixel**. The field is 3328×3328 units. That
  gives fractional speeds ("0.75 pixels per tick") without a single floating-point number.

From here on in this document `u` = 1/16 of a pixel, `px` = 16 u.

### Terrain

A 26×26 array of enum values:

| Value | Tank passes | Bullet passes | Behaviour |
|-------|-------------|---------------|-----------|
| `EMPTY` | yes | yes | — |
| `BRICK` | no | no | destroyed by any bullet |
| `STEEL` | no | no | destroyed only by a player bullet at the 3rd star |
| `WATER` | no | **yes** | ripple animation |
| `TREES` | **yes** | **yes** | drawn over the tanks — you hide in it |
| `ICE` | yes | yes | inertia after the button is released |

### Entities

**Tank**: position (top-left, u), direction, speed, player/enemy flag, type, health, star
level (for a player), shield and freeze timers, a "drops a power-up" flag (for an enemy),
spawn state.

Its extent is 256×256 u (16×16 px).

**Bullet**: position, direction, speed, owner, a "pierces steel" flag. Its extent is 64×64
u (4×4 px).

**Power-up**: position (aligned to a tile), type, lifetime timer.

**Base (eagle)**: one 16×16 px tile at (column 6, row 12), surrounded by a ring of brick.
Alive or destroyed.

All entities live in arrays with stable integer identifiers. New ones are appended at the
end, removed ones are marked dead and swept at the end of the tick. The iteration order is
always array order: it is part of the determinism.

## 5. The simulation loop

### The core's interface

```gdscript
class_name GameSim

func _init(level: LevelData, seed: int, config: SimConfig) -> void
func tick(inputs: Array[int]) -> void        # [p1_bits, p2_bits]
func get_state() -> WorldState               # read-only
func drain_events() -> Array[SimEvent]       # events from the tick just past
func state_hash() -> int                     # for tests and network comparison
```

Input bits: `1` up, `2` down, `4` left, `8` right, `16` fire. In a single-player game the
second element of the array is always `0` — co-op mode changes not one line in the core.

### The order within one tick

Fixed, not to be changed — reproducibility depends on it:

1. Decrement the global timers (freeze, shovel, spawn delay).
2. Handle player input: turning, movement, firing.
3. Update the enemy AI and their movement.
4. Move the bullets and resolve their collisions.
5. Resolve power-up pickups.
6. Handle the spawning of new enemies.
7. Update the counters and check the level end conditions.
8. Sweep dead entities.

A tick is exactly 1/60 of a second. The presentation layer accumulates real time and calls
`tick()` the required number of times; when the frame rate drops, the simulation neither
slows down nor speeds up. The upper bound is no more than 5 catch-up ticks per frame, so
that after the window is minimized the game does not "fast-forward" in a lurch.

### Movement and the half-tile snap

A tank moves along its current direction by its speed. When the direction **changes**, its
position on the cross axis snaps to the nearest 8 px (128 u). This mechanic is exactly what
creates the feeling that you land in the gaps by yourself; without it the rules are the
same and the game feels foreign.

Collisions are a manual rectangle-intersection check: first with the terrain cells in the
area of the future position, then with other tanks. On a collision the tank is pressed
flush and stops.

Ice: if a tank was standing on an `ICE` cell and the button is released, it keeps moving
for another 30 ticks (0.5 s) at the same speed until it hits something.

### Determinism

Four rules, all of them checkable:

1. Integer arithmetic only. Not one `float` in `core/`.
2. Randomness comes from our own generator (xorshift32) with the seed from `_init`. There
   are no calls to `randi()`/`randf()`.
3. The entity iteration order is fixed (arrays, stable identifiers, no dictionary
   iteration).
4. There are no calls to the system clock or to engine state.

Checked by a test: two simulations with one seed and identical input are run for 10,000
ticks, and the state hashes are compared every tick. A divergence is detected at the moment
it is introduced, not a month later as "my friend's tank is somewhere else".

### Events

The core plays no sounds and creates no animations — over a tick it accumulates a list of
events, which the presentation layer collects:

`SHOT_FIRED`, `BULLET_HIT_BRICK`, `BULLET_HIT_STEEL`, `BULLET_HIT_BULLET`,
`TANK_DESTROYED`, `PLAYER_DESTROYED`, `BASE_DESTROYED`, `BONUS_SPAWNED`, `BONUS_TAKEN`,
`ENEMY_SPAWNED`, `LEVEL_CLEARED`, `GAME_OVER`.

Events are not sent over the network: with identical simulations they are identical on
both sides. Every event carries coordinates so the presentation can put an explosion in
the right place.

## 6. Game rules

### The player's tank

Three lives per player. Star upgrades, reset to zero on death:

| Stars | Effect |
|-------|--------|
| 0 | one bullet in flight, normal speed |
| 1 | fast bullet |
| 2 | two bullets in flight at once |
| 3 | the bullet pierces steel |

After dying, a player reappears at their starting point with a shield for 3 seconds.
Starting positions: player 1 — column 4, player 2 — column 8, row 12.

### Enemies

| Type | Speed | Health | Special | Points |
|------|-------|--------|---------|--------|
| `BASIC` | 8 u/tick | 1 | — | 100 |
| `FAST` | 16 u/tick | 1 | drives fast | 200 |
| `POWER` | 8 u/tick | 1 | fast bullet | 300 |
| `ARMOR` | 8 u/tick | 4 | changes colour as it takes damage | 400 |

The player's speed is 12 u/tick. A bullet's speed is 32 u/tick, and a fast one's 48 u/tick.

Twenty enemies per level, no more than four on the field at once. The spawn points are
columns 0, 6 and 12 on row 0, in rotation. A spawn is accompanied by 60 ticks of blinking,
during which the tank does not exist yet: it cannot be hit and it blocks nobody. The pause
between spawns is 180 ticks, and a new enemy does not appear while there are four on the
field.

The composition of the wave and which enemies by count drop a power-up are set in the level
file.

### Bullets

One tank can keep as many bullets in flight as it is allowed (usually one). A bullet flies
straight until it collides:

- **Brick** — the bullet chews out a strip 16 px wide (two cells, exactly the width of a
  tank) and 8 px deep, aligned to the grid: one shot is enough to open a passage. A player
  bullet at the 3rd star takes 16 px of depth.
- **Steel** — the bullet vanishes; it destroys the cell only if the shooter has the 3rd
  star.
- **The field boundary** — the bullet vanishes, with a ricochet event.
- **Water, forest, ice** — it flies straight through.
- **A tank** — takes one point of health. Enemy bullets do not harm other enemies. Player
  bullets do not harm the other player (in co-op a hit only stuns for 60 ticks — that is
  how the original works).
- **An oncoming bullet** — both vanish.
- **The eagle** — the base is destroyed and the game is over, whoever's bullet it was.

### Power-ups

They appear when a marked enemy is destroyed, at a random free point on the field, and
live for 900 ticks (15 s), blinking for the last 180.

| Power-up | Effect |
|----------|--------|
| Helmet | a shield for 600 ticks (10 s) |
| Clock | enemies are immobilized for 600 ticks |
| Shovel | the brick around the base becomes steel for 1200 ticks (20 s), blinking for the last 180 |
| Star | +1 to the upgrade level |
| Grenade | instantly destroys every enemy on the field, awards no points |
| Tank | +1 life |

Picking up any power-up gives 500 points. A new power-up appearing removes the previous
one if it is still lying there.

### The end of a level and of the game

A level is completed when all twenty enemies are destroyed. Then comes the stats screen
with a breakdown by type and the transition to the next level; upgrades and lives carry
over.

The game is over if the base is destroyed or every player is out of lives. After level 35
it returns to the first with the score preserved.

### The AI

Deliberately simple: in the original it is a bit dim, and that is part of the charm. We are
not going to make it smarter — the game would stop being that game.

Every enemy keeps two timers: direction change (random 30–120 ticks) and firing (random
20–60 ticks). On running into an obstacle the direction changes immediately.

Choosing a direction: with a probability of 25% the one that gets closer to the target,
otherwise a random one from those available. The target is chosen on every change: with a
probability of 50% the base, otherwise the nearest living player. From level 20 on, the
aiming probability rises to 40%.

Firing happens on the timer, and also immediately if the base or a player is in the line of
sight along the current direction (checked on the grid up to the first block a bullet
cannot pass).

Enemies immobilized by the clock neither move nor fire.

## 7. The level format

One text file per level, `levels/01.lvl` … `levels/35.lvl`:

```
enemies: BBBBBBBBBBBBBBFFFFPP
bonus: 3,10,17
---
..........................
..........................
....####....####....####..
(26 lines of 26 characters in total)
```

`enemies` — twenty types in order of appearance (`B` basic, `F` fast, `P` power, `A`
armor). `bonus` — the indices of the enemies that drop a power-up. After `---` come 26
lines of 26 terrain characters: `.` empty, `#` brick, `@` steel, `~` water, `%` forest,
`-` ice.

The loader checks the dimensions, the alphabet, the length of the enemy list and that the
ring of brick around the base is in place, and fails with a clear error — a silently
malformed level is worse than a missing one.

The layouts are our own, 35 of them, built on the original's logic: the first level is
simple and symmetric, after that the share of steel and water grows, corridor and labyrinth
maps alternate, and the base is always covered by brick.

## 8. The presentation layer

### Resolution and scale

The base resolution is **256×240**, as on the NES. The 208×208 field is placed with a
margin of 16 at the top and 8 on the left; on the right there is a 40 px panel with the
count of remaining enemies, the lives and the level number.

Project settings: `display/window/stretch/mode = viewport`,
`display/window/stretch/scale_mode = integer`, nearest-neighbour filtering. An integer
scale is mandatory: with a fractional one the pixels get different sizes and the pixel art
falls apart.

The panel is moved into a separate scene and is not tied to the field's position — in
subproject 2 it will move down for portrait orientation without touching how the field is
drawn.

### Drawing

Every frame the presentation reads `get_state()` and brings the picture in line with it.
It holds no state of its own; the sole exception is short-lived decoration (explosion
particles, floating score) produced from events.

The terrain is a tile map on the 8 px grid, in two layers: under the tanks (brick, steel,
water, ice) and over the tanks (forest). Tanks and bullets are sprites. Positions are not
interpolated: 60 ticks against 60 frames, and fractional positions would only blur the
pixel.

### Assets

16×16 sprites in a four-colour palette are described in the sources as grids of characters,
and a script in `tools/` assembles a PNG atlas from them. The sound effects are synthesized
there too into WAV from a square wave and noise: firing, a ricochet off steel, crumbling
brick, a tank explosion, picking up a power-up, the level start, the loss.

The gain is that the assets live in the repository as text: the diff shows exactly what
changed, editing does not require a graphics editor, and generation is reproducible.

There is almost no music in the original — only short jingles at the level start and on
losing; those are what we make.

## 9. Screens

```
Splash → Menu (1 player / 2 players) → Level ⇄ Stats → Game Over → Menu
```

The HUD during play is that right-hand panel. Pause on Esc. The stats show the tally by
enemy type for each player and the total score.

## 10. Project structure

```
core/            the simulation: sim, world, terrain, tank, bullet, bonus, ai, rng, events
levels/          35 .lvl files
presentation/    field drawing, sprites, sound, effects
ui/              screens, HUD, transitions
platform/        input sources: keyboard, gamepad
tools/           sprite and sound generators
tests/           tests
docs/            specs and plans
```

We keep the files small and single-responsibility: a file growing is a signal that it is
doing too much.

## 11. Testing

Development is TDD. The test framework is GUT (Godot Unit Test), run headless with a single
command. If GUT does not work under 4.7, the fallback is a minimal runner of our own on
`godot --headless --script`; the one requirement for any option is that it runs in CI with
no graphics session.

Three layers of tests:

1. **Rules** — fast tests without graphics: a bullet does not pass through steel; it does
   after the third star; the shovel gives brick back after 1200 ticks; the grenade does not
   touch an enemy that is still blinking; a tank snaps to the grid when turning; an enemy's
   bullet does not harm an enemy; ice gives exactly 30 ticks of inertia.
2. **Determinism** — two runs of 10,000 ticks, comparing hashes.
3. **Regression** — recorded runs: an input file plus a reference hash of the final state.
   A hash that has moved shows immediately that a rule has changed.

A separate check in CI: `core/` contains no imports from the other folders and no calls to
`Input`, `Time`, `randi`, `randf`, `Node`.

## 12. Technology

- **Godot 4.7.2** (the current stable one as of 2026-08-18), the 4.7.x branch.
- **GDScript**, not C#: it exports more reliably to iOS and the web, and the performance is
  many times more than enough for 2D on this scale.
- Git from the first commit.

## 13. Groundwork for the following subprojects

None of the following is implemented now, but the architecture was chosen so that it will
not require rework:

- **Subproject 2 (mobile).** Touch input is a new file in `platform/` handing out the same
  five bits. The HUD panel is not tied to the field, so a portrait layout comes down to
  moving it.
- **Subproject 3 (network co-op).** A deterministic core that takes both players' input
  allows lockstep: only presses travel over the network, with a delay of a couple of ticks.
  The determinism test will have been working for a long time by then, and `state_hash()`
  gives a ready-made desync check.

## 14. Numbers to be tuned

All the speeds, intervals and probabilities above are starting values chosen by common
sense and from open descriptions of the original. They are gathered in a single `SimConfig`
object so that they can be tuned in one place: the "recognizable, without obsession" bar
means the final values are determined by feel while playing, not by comparison against an
emulator.

Tuned by feel specifically: the tank's and the bullet's speed, the enemy spawn interval,
the share of aimed movement in the AI, and how long the inertia on ice lasts.

## 15. Readiness criteria for the subproject

1. The game runs on desktop, all 35 levels can be played through, and looping works.
2. Every rule from section 6 is implemented and covered by tests.
3. Two-player co-op at one keyboard works.
4. The determinism test is green over 10,000 ticks.
5. The `core/` isolation check is green.
6. Builds are produced for Windows, macOS and Linux.
7. All assets are our own, generated by scripts in `tools/`.
