# BASE 13

A remake of Battle City (Namco, NES, 1985) on Godot 4.7.2 / GDScript.
Target: desktop, browser, App Store and Google Play. Two-player co-op — through the
room server by code, or directly on the local network.
Application identifier: `com.proshik.base13`.

## Documents

- Core design: `docs/specs/2026-08-25-battle-city-core-design.md`
- Part A plan (the core): `docs/plans/2026-08-25-battle-city-core-sim.md`
- Part B1 design (picture and input): `docs/specs/2026-08-27-battle-city-presentation-design.md`
- Part B1 plan: `docs/plans/2026-08-27-battle-city-presentation.md`
- Part B2 design (sound, screens, builds): `docs/specs/2026-08-30-battle-city-shell-design.md`
- Part B2 plan: `docs/plans/2026-08-30-battle-city-shell.md`
- Co-op design (stage 3.1): `docs/specs/2026-08-31-lockstep-design.md`
- Rooms and relay design (stages 3.2–3.3): `docs/specs/2026-09-01-platform-design.md`
- Quick game and image design (stage 3.4): `docs/specs/2026-09-03-quick-game-design.md`
- Deployment plan (next up): `docs/plans/2026-09-04-deployment.md`
- Hardening plan (closed, gates the deployment's release): `docs/plans/2026-09-12-hardening.md`
- Homebrew cask plan (after the deployment): `docs/plans/2026-09-04-homebrew-cask.md`

The work is split into four subprojects: **1** the core and the single-player game,
**2** mobile platforms, **3** network co-op, **4** release to the stores.

Subproject 1 is closed in full: **A** the simulation core, **B1** rendering, input and
the campaign, **B2** sound, screens, high score, gamepad and builds.

Subproject 3 goes in stages: **3.0** the web build and the proof that the browser
computes the world exactly as the desktop does — closed; **3.1** co-op on the local
network directly — closed; **3.2** the room server and entry by code — closed;
**3.3** the journal and coming back after a drop — closed; **3.4** quick game, static
hosting and the image — closed.

There is enough code to play over the internet; what is missing is a machine with a
public address. Accounts are deferred — the chosen shape of public play (one button, no
list and no names) does not require them.

**Next up: deployment on a public machine** —
`docs/plans/2026-09-04-deployment.md`. One container from the registry behind the owner's
proxy; TLS and DNS are the owner's. That plan opens with a real defect it found: Godot
leaves `WebSocketPeer.heartbeat_interval` at zero, so a client waiting for a partner
sends nothing and a proxy cuts the connection — invisible on the local network, certain
behind nginx.

Its release was gated on `docs/plans/2026-09-12-hardening.md`, and that plan is closed. A
security and performance review before the release found the server with no limits and no
deadlines at all — a script could take its memory or its descriptors — and the client
heartbeat doing nothing in a browser, because a browser's WebSocket cannot send a ping.
Now every message, journal, room and connection has a ceiling, every read and write has a
deadline, the server pings on its own, and the engine travels gzipped: 9.6 MB instead of
37.7 on the first visit.

The release is out: image `0.4.0` was published on 2026-09-14. What is left of the
deployment plan is making that package public and a machine to put it on.

**After it: installation through Homebrew** —
`docs/plans/2026-09-04-homebrew-cask.md`. Gated on two things only the repository owner
can do: making the repository public — done on 2026-09-13 — and creating a `TAP_TOKEN`
secret with write access to `proshik/homebrew-tap`. Task 1 of that plan runs before the
gate, once a desktop release exists — `v0.1.0` and `v0.1.1` were deleted with the old
history; everything after it does not.

## Repository layout

```
game/     the whole Godot project: project.godot, app.tscn and all the game code
server/   the room server in Go — knows nothing about the game
tools/    content generators, test runner, builds
docs/     design and plans
build/    build output, not kept in the repository
```

Godot is only ever launched with an explicit path: `godot --path game`. The scripts in
`tools/` do that themselves; there is no need to add it by hand.

## Code map

| Path | What is there |
|------|---------------|
| `game/core/consts.gd` | Geometry: units, field size, base layout and spawn points |
| `game/core/types.gd` | Enums for directions, cells, tanks, power-ups, events; input bits |
| `game/core/sim_config.gd` | Every tunable number: speeds, timers, AI probabilities |
| `game/core/rng.gd` | Deterministic xorshift32 |
| `game/core/terrain.gd` | The 26×26 grid: passability and destruction |
| `game/core/level_data.gd` | Parsing the text level format and validating it |
| `game/core/entities.gd` | Tank, bullet, power-up, player state |
| `game/core/events.gd` | A simulation event |
| `game/core/world_state.gd` | World state, counters and the hash |
| `game/core/movement.gd` | Grid movement, the snap on turning, collisions |
| `game/core/sim.gd` | `GameSim`: the tick, order of operations, players, end conditions |
| `game/core/combat.gd` | Firing, bullet flight, hits, tank deaths |
| `game/core/ai.gd` | Enemy tank behaviour |
| `game/core/spawner.gd` | The enemy wave queue |
| `game/core/bonuses.gd` | Power-up appearance, pickup and effects |
| `game/core/event_log.gd` | The event accumulator shared by the core modules |
| `game/core/campaign.gd` | Score, lives, kill counts between levels; looping after level 35 |
| `game/levels/01..35.lvl` | Level layouts |

The presentation layer — it reads state and draws, and holds no state of its own:

| Path | What is there |
|------|---------------|
| `game/presentation/view_model.gd` | `WorldState` → a flat list of "what to draw" and a panel slice |
| `game/presentation/frames.gd` | Frame numbers in the atlases |
| `game/presentation/field.gd` | Drawing the field directly, without a node per entity |
| `game/presentation/hud.gd` | The right-hand panel |
| `game/presentation/effects.gd` | Explosions and flashes from events |
| `game/presentation/audio.gd` | Event → sound, engine hum, ducking |
| `game/presentation/text_painter.gd` | Text in the atlas font |
| `game/presentation/banner.gd` | The `STAGE N` caption over the field |
| `game/presentation/tick_pump.gd` | How many ticks to advance per frame |

Screens and the application:

| Path | What is there |
|------|---------------|
| `game/ui/screen_flow.gd` | Which screen follows which — a pure function |
| `game/ui/app.gd`, `game/app.tscn` | The root: swaps screens, holds the campaign, the window and the high score |
| `game/ui/splash.gd`, `game/ui/menu.gd`, `game/ui/game.gd`, `game/ui/stats.gd`, `game/ui/gameover.gd` | The five screens |
| `game/ui/pause.gd` | The pause overlay on top of the game |

Everything that knows about hardware and disk:

| Path | What is there |
|------|---------------|
| `game/platform/level_loader.gd` | Reading `.lvl` from disk |
| `game/platform/relay_config.gd` | Where the room server address comes from |
| `game/platform/keyboard.gd`, `game/platform/gamepad.gd` | Sources of the same five bits |
| `game/platform/score_store.gd` | The high score in `user://base13.cfg` |
| `game/platform/window_scale.gd` | Picking an integer window scale for the display |

The network — the general shape of a link and its two incarnations:

| Path | What is there |
|------|---------------|
| `game/net/link.gd` | A link: poll it, send, is it alive, has it ended |
| `game/net/session.gd` | A direct connection on the local network |
| `game/net/relay.gd` | A room by code through the server, coming back after a drop |
| `game/net/protocol.gd` | Packing button presses and hashes |
| `game/net/lockstep.gd` | Laying input out over ticks, delay, hash comparison |
| `game/net/net_input.gd` | The input source for a network match |
| `server/*.go` | The server: WebSocket by hand, rooms, matchmaking, journal, game hosting |
| `Dockerfile`, `tools/image.sh` | The deployment image and the command that builds it |
| `justfile` | An index of tasks on top of `tools/`; without it the scripts work as before |
| `.github/workflows/ci.yml` | The test run on every push |
| `.github/workflows/release.yml` | Cutting a release from master by hand: backend and desktop separately |
| `Casks/base13.rb` | The Homebrew cask, source of truth; copied into the tap on release |

Content generators — everything is our own, everything from text sources:

| Path | What is there |
|------|---------------|
| `tools/sprite_data.py`, `tools/gen_sprites.py` | Sprites, font, icon, startup splash |
| `tools/sound_data.py`, `tools/gen_sounds.py` | Fifteen sounds in the style of the NES chip |
| `tools/gen_levels.py` | Level layouts |
| `tools/build.sh` | Builds for three platforms |

There is one way into the simulation: `GameSim.new(level, seed, config, level_number,
player_count, carryover)` and `tick([bits_p1, bits_p2])` — five bits per player per
tick. The core lives for exactly one level: it raises `level_cleared`, and what happens
next is decided by `Campaign` — also in the core, because carrying lives over is a rule,
not a picture.

## The fidelity bar

**Recognizable, without frame-by-frame obsession.** Someone who played the original
should sit down and say "yes, that's it". Timings are not verified against an emulator:
every tunable number is gathered in `SimConfig` and dialed in by feel while playing.

All content (sprites, sound, level layouts) is our own, in the style of the original.
No Namco/Bandai assets or maps are used: the game is going to the stores.

## Hard rules

Everything listed here is not style but a condition of working at all. Breaking the
first three points breaks the network co-op from subproject 3 — not immediately, but as
a desync a month later.

1. **`game/core/` knows nothing about the engine.** No `Node`, no `Input`, no `Time`, no
   `Engine`, no `OS`, no `FileAccess`, no `ResourceLoader`, no `preload`/`load`. Only
   the GDScript language and `RefCounted`. Reading files lives in `game/platform/`.
2. **There is not a single `float` in `game/core/`.** Coordinates are integers in 1/16
   of a pixel (pixel = 16 units, terrain cell = 128, tank = 256, field = 3328).
3. **Randomness only through a seeded `Rng`.** `randi()`, `randf()` and `randomize()`
   are forbidden in the core.
4. **The order of operations inside a tick is part of the contract, not an
   implementation detail.** Timers → player input → enemies → bullets → power-ups →
   spawning → end conditions → cleanup.
5. **Entities are always walked in array order.** No dictionary iteration in tick logic.
6. The presentation layer reads state and draws; it holds no state of its own. The core
   does not play sounds — it accumulates events, and the renderer takes them apart.

## How to check

The tests need Godot 4.7.2 at `/Applications/Godot.app/Contents/MacOS/Godot` (overridden
by the `GODOT` variable). `brew install --cask godot` installs exactly 4.7.2.

```bash
just test              # the same thing, if just is installed
./tools/test.sh        # core/ isolation + server neutrality + atlas and sound
                       # verification + Go tests + all the GUT tests
```

`just --list` shows every task. It is an index, not a dependency: the bodies live in
`tools/`, the scripts are called directly, and CI calls exactly those.

The server tests require Go; without it they and the `.build/relay` build are skipped,
and the client's network tests are marked pending, but the run does not fail.

Assets are assembled from text sources and verified against a fingerprint manifest. If
you edited `tools/*_data.py`, rebuild them or the check will fail:

```bash
cd tools && python3 gen_sprites.py && python3 gen_sounds.py
```

The boundary check can be run on its own:

```bash
./tools/check_core_isolation.sh
```

If the determinism test fails — **do not massage the hash**. A mismatch means
non-determinism in the logic: look for a `float`, a call to `randi()`, dictionary
iteration on a hot path, or a dependency on some changeable order.

The same goes for the regression reference in `game/tests/core/test_regression.gd`: a
value that has moved is a reason to work out which rule changed, not to rewrite the
constant.

Rakes we have already stepped on:

- **There are no associative arrays in the `tools/` scripts.** They need bash 4, and the
  stock shell on macOS is 3.2, where `declare -A` silently turns into an indexed array:
  `[Windows]=windows` tries to evaluate a variable named `Windows` and dies with
  "unbound variable". Platform dispatch is done with `case`.

- **`RefCounted` reference cycles are not collected in Godot.** That is why the core
  modules do not hold a reference to `GameSim` — only to the state, the config, the
  generator and the event log; the dependencies are strictly one-way.

- **`check_core_isolation.sh` looks at comments too.** A `randi()` or `FileAccess.`
  inside a doc comment in `game/core/` fails the check. Silencing comments in the
  checker is not an option: in `level_data.gd` the `#` character is a brick in the level
  format, and cutting out the "comment" would hide code.
- **`var x := tank.pos` does not compile if the parameter is untyped.** There are many
  such functions in `game/core/` (`tank`, `b`) — type inference does not work, so local
  variables need an explicit type: `var x: Vector2i = tank.pos`. The same goes for a
  function with no declared return type.
- **Godot compresses WAV lossily by default** — into QOA. The chip timbre rests on the
  waveform, so `project.godot` specifies lossless import, and a test stands guard over
  it.
- **`edit/loop_mode` in the WAV importer is not "no/yes".** Zero means "detect from the
  file", one means "off", and "forward" is two. The hum loop is set individually on two
  files, and a test checks it.
- **Do not create resources by copying at runtime if they are playing at exit time.** A
  looped sound made with `duplicate()` is not freed, and Godot reports a leak.
- **Tick time is charged for ticks that happened, not for ticks that came due.** In a
  network game a tick may not happen: the other side's input is not there yet. Charged
  for nothing, it is lost forever — the lockstep buffer drains, and the game goes from
  sixty ticks per second to one tick per network round trip. Hence `TickPump` has
  separate `due()` and `spend()`, and the caller reports how many ticks it actually
  computed.
- **Stutter in a network game is about jitter, not about average latency.** At 30±40 ms
  five ticks of input delay is enough; at 30±80 ms smoothness falls to 47%: the average
  is the same, but every late packet is a frozen frame. That is why input delay grows by
  itself (`NetInput.grow_delay`) instead of being a fixed number.
- **When raising the input delay, fill the band between the old and the new horizon.**
  Our input will no longer be submitted for those ticks in the normal course of things,
  and the partner is waiting for them — the result is not a stutter but a match frozen
  solid. The two sides are free to hold different delays: the tick number travels in the
  packet itself.
- **"It lags" without numbers is unverifiable.** Every five seconds `NetInput` prints a
  `[net]` line: how much real time went into three hundred ticks, how many waits there
  were, and how much of the partner's input is buffered. A rate below a hundred percent
  with zero waits means the machine is to blame; waits with a shrinking buffer mean the
  network is. Visible in the terminal on desktop and in the developer console in the
  browser.
- **The macOS export must sign the app itself** (`codesign/codesign=1` in the preset).
  Without it the application carries away the *engine template's* signature, which stops
  matching once the game's bundle is assembled, and macOS says "damaged, move to the
  bin" — wording about a corrupted file, though the problem is the signature. With the
  built-in ad-hoc signature you get the ordinary "unidentified developer" instead.
- **A browser cannot send a WebSocket ping.** The browser's API has no such call, and
  Godot's web peer only stores `heartbeat_interval` — so the setting that keeps a desktop
  client alive through a proxy does nothing in the browser, which is the platform the
  quick game is built around. A waiting player is silent in both directions, and a proxy
  cuts silence. Hence the server pings every twenty seconds: a browser answers a ping by
  itself, without asking the page.
- **A cap on a frame is not a cap on a message.** Ours was a megabyte per frame, and
  continuation frames stitched eight of them into eight megabytes — the sum was bounded by
  nothing. Same shape one level up: the journal was bounded in records, and a record's
  size was assumed rather than checked. Anything a stranger can send needs its total
  bounded, not its piece.
- **`check_server_neutral.sh` looks at comments too**, like the core's own checker. The
  words `tank|bullet|projectile|level|eagle|base13` fail the build anywhere in a non-test
  file of `server/` — "a level of nesting" in a comment is enough to stop it.
- **The web build does not start outside a secure origin.** Godot checks
  `window.isSecureContext === true` and without it shows "Secure Context — Check web
  server configuration" before ever reaching the game. The browser counts HTTPS as
  secure, plus `localhost`/`127.0.0.1` — but not an address like `192.168.x.x` over
  http. Hence: the build opens on your own machine but not from a second one on the same
  network, and that is not a broken server. Serving the game beyond your own machine
  requires a certificate in every case.
- **`TextPainter` silently skips a character the font does not know.** The address
  `192.168.1.5` was drawn as `19216815` for months: there was no dot in the font, and
  `draw_line` on an unknown glyph simply moves on. When adding a caption made of new
  characters, check `glyph_index` — the font has digits, uppercase Latin, the dot and
  the colon, and nothing else.
- **`WebSocketPeer` loses unread data while parsing a close frame.** The server sends a
  refusal as a message and immediately says goodbye — the message never reaches the
  client, and all that is left is `get_close_code()` and `get_close_reason()`. That is
  why the server puts a short refusal marker in the close reason, not only in the
  response body.
- **A GDScript lambda captures local variables by copy.** With `var got := false` and
  `signal.connect(func(): got = true)` the assignment never escapes, and the check will
  see `false` forever. To accumulate a result inside a handler you need an array or a
  dictionary: those are by reference, and the change is visible from outside.
- **Checking "the sound is not silence" byte by byte lies.** For a flat square wave the
  low byte is zero in every sample — you have to decode pairs.
- **Recreating the repository orphans its container package.** A package is tied to the
  repository's id, not its name: after `proshik/base13` was deleted and created again,
  `ghcr.io/proshik/base13` was left with no repository, and the release died on the push
  with `denied: permission_denied: read_package` — wording about reading, from a job that
  was writing. The package page has no "Connect repository" in that state. The way back is
  Package settings → Manage Actions access → add the repository, and then raise its role
  to Write: it is added as Read, which the settings describe as download only. Visibility
  is the package's own as well — it stayed private when the repository went public.

## Conventions

- Development is TDD: a failing test first, then the minimal implementation.
- A commit after every task in the plan. Messages in English: `feat:`, `test:`,
  `chore:`, `docs:`.
- Files are small, with a single responsibility. A file growing is a signal that it is
  doing too much.
- Levels are regenerated with `python3 tools/gen_levels.py` and then edited by hand. The
  tests in `game/tests/levels/` insure that a manual edit broke nothing.
