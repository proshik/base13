# BASE 13: a playable desktop game — design (subproject 1, part B1)

## 1. Goal

Part A produced the core: the whole game computes headless and is covered by tests, but
there is nothing to show it with and nobody to press the buttons. Part B1 ends with a
person sitting down at a keyboard, alone or with someone else, and playing through all
thirty-five levels.

The bar is the same as for the whole project: **recognizable, without frame-by-frame
obsession.**

## 2. What is in and what is out

### In

- Generating the sprites with a script from text sources.
- Drawing the field: terrain, tanks, bullets, eagle, power-ups.
- Blinking and explosions, produced from core events.
- Keyboard input for two people at one keyboard.
- The right-hand HUD panel: enemies remaining, lives, level number.
- Moving between levels carrying over score, lives and upgrades; looping after level
  thirty-five.
- Tuning the `SimConfig` numbers by feel in a live game.

### Out — goes into B2

Sound and jingles, the splash screen, the menu for choosing the number of players, the
stats screen by enemy type, pause, gamepad, hi-score, builds for Windows, macOS and
Linux. Until B2 the game is launched from the editor.

The order is exactly this because until the first launch every number in `SimConfig` is a
guess. Until you have played with them there is nothing to build a shell on.

## 3. Architecture and boundaries

| Module | Responsibility |
|--------|----------------|
| `tools/gen_sprites.py` | Text grids of characters → a PNG atlas; a four-colour palette |
| `presentation/tick_pump.gd` | How many ticks to advance per frame; the ceiling is five catch-up ticks |
| `presentation/view_model.gd` | `WorldState` → a flat list of "what to draw" |
| `presentation/frames.gd` | Frame numbers in the atlases: whose sprite is where |
| `presentation/field.gd` | Drawing the field: terrain and entities |
| `presentation/hud.gd` | The right-hand panel |
| `presentation/banner.gd` | A black screen with a caption: `STAGE N`, `GAME OVER` |
| `presentation/text_painter.gd` | Drawing text in the atlas font |
| `platform/keyboard.gd` | Keys → five bits per player |
| `core/campaign.gd` | Score, lives and upgrades between levels; looping |
| `game.tscn`, `game.gd` | The main scene: holds the simulation and pumps the ticks |

### Why the campaign lives in `core/`

The part A plan said that moving between levels was "a matter of screens". That decision
is revisited here. Carrying lives over, resetting upgrades and looping after level
thirty-five are game rules, not a picture: they change the outcome of a match.

In `core/` this file gets three things for free: the isolation check, headless tests with
the same machinery as the core, and — the important one for subproject 3 — a guarantee
that the campaign state converges on both sides of the network exactly as strictly as
tick state does. `campaign.gd` knows nothing about the engine and breaks neither rule 1
nor rule 2.

`GameSim` meanwhile stays exactly what it was: it lives for one level and raises
`level_cleared`. The campaign creates the next simulation rather than extending the
current one.

### Why there is a translator between the core and the nodes

A picture has no natural failing test, and the project's convention demands one first. So
all the display logic — where a sprite is, in which frame, in which layer, whether it is
visible this frame — moves into a `RefCounted` class with not a single node, and is
tested with the same command as the core. The nodes stay thin and dumb: running them is
their test.

This is a direct continuation of rule 6: the presentation layer reads state and draws,
and holds no state of its own.

## 4. The data flow per frame

```
_process(delta)
  → TickPump.pump(delta)              how many ticks to advance
  → N × GameSim.tick(player bits)     the bits come from platform/keyboard
  → drain_events()                    events → explosions and flashes
  → ViewModel.build(state)            a list of Items
  → Field.sync(list), Hud.sync(state)
```

Positions are not interpolated: sixty ticks against sixty frames, and fractional
positions would only blur the pixel.

The terrain is redrawn not every frame but when `cells_checksum()` has changed — that
function already exists in the core and serves here without modification.

## 5. The translator layer

`ViewModel.build(state) -> Array[Item]`, where an `Item` carries:

- `atlas` — which atlas to look the frame up in.
- `frame` — the frame number in the atlas.
- `pos` — position in pixels, an integer: `units / 16`, in field coordinates.
- `layer` — drawing order.

Anything invisible this frame does not get into the list at all — there is no separate
`visible` flag. That way "a blinking enemy is not visible right now" is checked by the
absence of an entry rather than by inspecting its fields.

The layers, bottom to top: terrain under the tanks (brick, steel, water, ice) → power-up
→ tanks and bullets → forest → flashes and explosions.

Everything is drawn directly, through `_draw()`, rather than with `Sprite2D` nodes or a
`TileMapLayer`. The reason: `TileMapLayer` requires a `TileSet` resource, which cannot be
written by hand in text form, and a separate node per bullet means bookkeeping of the
"entity → node" correspondence and litter when it dies. Direct drawing removes both
problems: the terrain is its own `Node2D`, redrawn when the checksum changes; the
entities are a second `Node2D`, redrawn every frame.

The blinking the translator is responsible for:

| What blinks | Source |
|-------------|--------|
| A spawning enemy | `tank.spawn_ticks > 0` |
| A player's shield | `tank.shield_ticks > 0` |
| A power-up about to vanish | `bonus.ticks_left < bonus_blink_ticks` |
| The steel around the base as the shovel runs out | `shovel_ticks < shovel_blink_ticks` |

The last two fields in `SimConfig` are not used by the core at all — from the very start
they were groundwork for exactly these rules.

## 6. Assets

The sprites are described in the sources as grids of characters, and
`tools/gen_sprites.py` assembles a PNG atlas from them. The palette is four colours per
sprite, as on the NES.

The gain is that the assets live in the repository as text: the diff shows exactly what
changed, editing does not require a graphics editor, and generation is reproducible.

The set for B1:

- **Tanks**, 16×16, four directions with two track frames each: the player in four
  upgrade stages, plus `BASIC`, `FAST`, `POWER`, `ARMOR`. `ARMOR` has four colourings by
  remaining health — that is the hint to the player about how many more hits it takes.
- **Bullet**, 4×4, four directions.
- **Terrain**, 8×8: brick, steel, water in two frames, forest, ice.
- **Eagle**, 16×16: intact and destroyed.
- **Power-ups**, 16×16: six of them.
- **Explosion**: a small one of three frames for a bullet, a big one of five frames for a
  tank.
- **Spawn flash**: four frames.
- **Font**: digits and uppercase Latin for the HUD.

The second player is the same sprite in a different palette, not a separate set.

## 7. The screen

The base resolution is 256×240. The field is 208×208 with a 16-pixel margin at the top
and 8 on the left, and a 40-pixel-wide panel on the right. `stretch/mode = viewport`,
`scale_mode = integer`, nearest-neighbour filtering. An integer scale is mandatory: with
a fractional one the pixels get different sizes and the pixel art falls apart.

The panel is a separate scene and is not tied to the field's position: in subproject 2 it
will move down for portrait orientation without touching how the field is drawn.

Between levels there is a black screen with a `STAGE N` caption for two seconds; the same
screen shows `GAME OVER`. The tally by enemy type is the stats screen, and that is in B2.

## 8. The campaign

`Campaign.new(player_count, config, base_seed)` holds the level number and one slice per
player: lives, score, upgrades. It simulates nothing itself — it hands out the parameters
for the next `GameSim` and takes back the outcome of the level just played.

The next level's seed is not a new random one but a derivative of `base_seed` and the
level number. A whole match reproduces from a single number: that is needed both for bug
reports and for subproject 3, where both sides must get identical enemy waves.

The transition rules:

- Level completed → the number grows, score and lives carry over, upgrades reset.
- After thirty-five it is level one again, and the level number keeps growing: AI
  aggressiveness depends on it (`ai_late_level`).
- The eagle is destroyed, or every player is out of lives → game over.

Upgrades reset between levels deliberately: that is how the original works, and without
it the late levels play themselves.

## 9. Input

Five bits per player, exactly the contract `tick()` accepts.

| | Movement | Fire |
|---|---|---|
| Player 1 | Arrows | Enter |
| Player 2 | W A S D | Space |

The order in which the bits are polled is fixed in the core: up, down, left, right. The
keyboard only collects bits and decides nothing.

## 10. Testing

What gets tested is `ViewModel`, `TickPump` and `campaign.gd` — ordinary GUT tests
headless, with the same `./tools/test.sh` command. The nodes are not tested.

What is checked:

- A spawning enemy is visible every other frame, and a materialized one constantly.
- The shield is drawn over the tank, and the forest over everything.
- A power-up starts blinking exactly `bonus_blink_ticks` before it vanishes.
- A position in pixels is the position in units divided by sixteen, with no fractions and
  no rounding up.
- The accumulator does not advance more than five ticks per frame, however deep the frame
  drop.
- After level thirty-five the campaign goes to level one, lives are preserved, upgrades
  are reset, and the level number keeps growing.
- The sprite generator is deterministic: two runs produce a byte-identical file.

The `core/` isolation check continues to apply to `campaign.gd` as well.

## 11. Order of work

1. The sprite generator and the atlas.
2. `TickPump`.
3. `ViewModel`: tanks and bullets.
4. `ViewModel`: terrain, power-up, eagle, layers and blinking.
5. The field scene: terrain by checksum.
6. The field scene: sprites from the list.
7. Keyboard input.
8. The main scene, `run/main_scene` in `project.godot` — **the first launch: you can
   drive and shoot.**
9. Explosions and flashes from events.
10. `core/campaign.gd`.
11. Moving between levels and the `STAGE N` screen.
12. The HUD panel.
13. Playing through all thirty-five levels by hand, tuning `SimConfig`.

The first launch is at task eight rather than at the end: from there on you can see what
you are doing, and every subsequent task is checked with your eyes rather than your
imagination.

## 12. Numbers to be tuned

Task 13 is not a formality. Until then every value in `SimConfig` is chosen by common
sense and has never been checked by hand. What gets tuned by feel:

- the player tank's speed and the bullet's speed;
- the enemy spawn interval and enemy speeds;
- the share of aimed movement in the AI and how often it fires;
- how long the inertia on ice lasts;
- how long the shield after respawn lasts.

If the regression reference in `tests/core/test_regression.gd` moves after the tuning, it
is re-taken once, in a separate commit with an explicit note about what changed — that is
the one case where the reference is edited on purpose.

## 13. Readiness criteria for B1

1. `./tools/test.sh` green in full, including the `core/` isolation check.
2. The game launches and plays from the keyboard with one player and with two.
3. All thirty-five levels can be played through, and after thirty-five the game loops.
4. Score, lives and the upgrade reset carry over between levels.
5. All sprites are our own, generated by a script from text sources.
6. The numbers in `SimConfig` have been checked by playing, not only by tests.
