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
- Network lag plan (adaptive delay, carried between levels; shipped in `0.5.0`, the live
  check waits for a public machine): `docs/plans/2026-09-14-network-lag.md`
- Metrics plan (closed, shipped in `0.5.0`): `docs/plans/2026-09-14-metrics.md`
- Rollback design (replaces lockstep in network play): `docs/specs/2026-09-16-rollback-design.md`
- Rollback plan: `docs/plans/2026-09-16-rollback.md`

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

The current release is `0.6.5`, published on 2026-09-24: the image
`ghcr.io/proshik/base13:0.6.5` (also `latest`) and the desktop builds under the `v0.6.5`
GitHub release. The `0.6` line carries the rollback — network play no longer waits for the
partner — and the core it needed, a simulation tick three and a half times cheaper; a
server whose delay histogram has a bound at two, so it tells a client that steps back from
one still on `0.5.0`; since `0.6.2`, a client that keeps a partner's stand out of the waits
it reports, as `0.5.0` did; and since `0.6.3`, a side that stood for its partner sheds the
lead the stand left inside the stand, rather than dropping frames for seconds after it;
and since `0.6.4`, both sides end a level on the same tick — counted from the tick it
ended in, not the frame it was seen on — where before a transition could hang both, and
the client and the server log each level's end and who is waiting for whom; and since
`0.6.5`, two tanks that overlap can part and an occupied spawn point passes its turn, where
before a player on an enemy's spawn point locked both tanks or held back the wave; a tap
between two captured ticks is latched rather than lost in a hung frame or a stand; the
tally between levels in a network game is waited out on both sides, where a key on one
side started its next level seconds early; the pace rule weighs the least of its last
three lead readings; and the `[net]` line names the longest frame, the server's window
line what came at once after the worst gap.
Earlier `0.6` releases are superseded.
The image is built for amd64 only; on an arm64 Mac run it with `--platform linux/amd64`.
The package is public and pulls without a login. What is left of the deployment plan is a
machine to put it on; run the image with the metrics port as the plan's Task 4 shows.

Nobody has yet played the rollback over the internet: it is proven by the lag profiles
and by a match against a `0.5.0` client, not by two people at two laptops. That check
waits for the public machine.

**After it: installation through Homebrew** —
`docs/plans/2026-09-04-homebrew-cask.md`. Gated on two things only the repository owner
can do: making the repository public — done on 2026-09-13 — and creating a `TAP_TOKEN`
secret with write access to `proshik/homebrew-tap`. Task 1 of that plan runs before the
gate and needed a desktop release; `v0.5.0` is the first one since `v0.1.0` and `v0.1.1`
were deleted with the old history, so it can go now. Everything after it waits for the
token.

## Repository layout

```
game/     the whole Godot project: project.godot, app.tscn and all the game code
server/   the room server in Go — knows nothing about the game
deploy/   Prometheus, Alloy and Grafana files for whoever runs the server
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
| `game/core/snapshot.gd` | A copy of everything the simulation changes, for stepping back |
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
| `game/platform/press_latch.gd`, `game/platform/press_feed.gd` | Presses since the last tick captured, so a tap between two captures is not lost |
| `game/platform/score_store.gd` | The high score in `user://base13.cfg` |
| `game/platform/window_scale.gd` | Picking an integer window scale for the display |
| `game/platform/client_info.gd` | The platform and version the client names in its hello, and in a browser its family and system |
| `game/platform/presence.gd` | A tab going out of sight and a window losing focus, as one word each |

The network — the general shape of a link and its two incarnations:

| Path | What is there |
|------|---------------|
| `game/net/link.gd` | A link: poll it, send, is it alive, has it ended |
| `game/net/session.gd` | A direct connection on the local network |
| `game/net/relay.gd` | A room by code through the server, coming back after a drop |
| `game/net/protocol.gd` | Packing button presses and hashes |
| `game/net/rollback.gd` | Both sides' input by tick: guesses, the confirmed tick, where to step back to, hashes |
| `game/net/net_match.gd` | One level's ticks per frame: forward, back and forward again; the confirmed world |
| `game/net/event_filter.gd` | What a tick computed again may still add to the screen and speakers |
| `game/net/net_input.gd` | The input source for a network match: the wire, resends, pace, reports |
| `server/*.go` | The server: WebSocket by hand, rooms, matchmaking, journal, game hosting; outside code only for metrics: Prometheus's `client_golang` and what it brings |
| `server/metrics.go` | Metric families over closed label sets, recording, and the collector that reads rooms and connections at scrape time |
| `server/report.go` | Players' pace and desync reports: parsing, clamping, the allowance, the verdict, the log line |
| `server/notes.go` | Players' events for the log: a closed set of words and the whole numbers each takes |
| `server/client.go` | Who sat down, for the join line: release, platform, a browser's family and system |
| `deploy/` | Prometheus scrape and alert rules, a Grafana Alloy example, the Grafana dashboard |
| `Dockerfile`, `tools/image.sh` | The deployment image and the command that builds it |
| `justfile` | An index of tasks on top of `tools/`; without it the scripts work as before |
| `.github/workflows/ci.yml` | The test run on every push |
| `.github/workflows/release.yml` | Cutting a release from master by hand: backend and desktop separately |
| `tools/stamp_version.sh` | Writing the release version into `project.godot` before a build |
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
tick. It can also `save()` a copy of itself and `restore()` one, which is what lets a
network game step back to a tick and compute it again. The core lives for exactly one level: it raises `level_cleared`, and what happens
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
and the client's network tests are marked pending, but the run does not fail. The first run
on a machine downloads the server's modules, so it needs the network once.

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
  network game a tick may not happen: the other side's input is not there yet. Hence
  `TickPump` has separate `due()` and `spend()`, and the caller reports how many ticks it
  actually computed and whether it stopped for the partner.
- **But a wait is caught up only by half.** A lockstep pair has one pace, the slower
  side's. A side that caught up all of its waiting raced to the very edge of the
  partner's input and stood there: every late packet froze its picture alone, and its
  own delay growing did nothing for it — our delay is the partner's slack, not ours.
  After a partner's two-second tab switch the side that came back waited on every tick
  until the level ended. Letting half go moves the waiting side back and shares the
  slack; letting all of it go costs speed while the network falls short.
- **A freeze is forgotten whole, and on both sides alike.** Cutting a long stand down to
  `MAX_DEBT` instead left two sides holding different debts after one tab switch — the
  imbalance above, from another door. And forget only on a frame that actually waited:
  forgetting on every frame of a long stand froze the game for good, because a 60 Hz
  frame (16.666 ms) is a hair short of a tick and nothing was ever due again.
- **The lag profiles are the numbers to argue from, not impressions.**
  `game/tests/net/test_lag_profiles.gd` plays two sides through a link with delays and
  jitter on a clock it turns by hand, and its header records where each profile settles:
  stops, the deepest rollback and the share of the clock kept.
- **Input sent while the relay link was down is lost, and the partner waits for it
  forever.** The relay journals only what reached it and replays to a returning side the
  partner's stream, never its own. `NetInput` sends its recent input again when the link
  comes back — from `RESEND_BACK` ticks back, not from its last tick: the partner may be
  a window behind their own confirmed tick, and that tick a window behind ours. And whether
  the link was up is read from the link when the input is built, not assumed: a level
  built while the relay was still greeting lost its band, and the welcome arriving with
  the first pump looked like a link that had never been down.
- **A link can lose input without going down.** The partner still finishing the last
  level — a tab hidden at the level clear — takes our new level's first input into
  their old `NetInput`; the packets are gone from the socket, and their new level waits
  for tick five for good. So a tick standing a second on a live link sends our recent
  input again, once a second. Duplicates are ignored, and a few dozen packets a second
  of standing is not waiting breeding traffic.
- **"It lags" without numbers is unverifiable.** Every five seconds `NetInput` prints a
  `[net]` line: real time for three hundred ticks, the speed against the clock, `stops`
  (short stands past the window), `frozen` (stands past `FROZEN_MS`), `rollbacks` and
  `deepest`, `resim` (what the stepping back cost this machine), `skips`, the two
  sides' leads and the `longest frame`. `frozen` means the partner went quiet; stops that keep coming mean the
  network; a large `resim` with the speed below a hundred means the machine. `L` puts the last second's numbers on
  screen. Visible in the terminal on desktop and in the developer console in the browser.
  Beside it, one `[net]` line an event: a level begins (with the slot), ends (the end
  tick, the tick it ended in, the confirmed tick it was seen at — both sides must agree on
  the first two), is done; and the first time a stand sends input again, with why. On the
  server, the window line of a side still sending names a partner silent past a window
  and the last round trip — the first ping goes out as a player sits down, not twenty
  seconds later — and a side leaving says how long it had been silent.
- **A console nobody kept is no evidence.** On 2026-09-24 the `[net]` lines of one side
  survived only because its tab stayed open, and the other side's were never seen. A
  server whose welcome says `notes: true` now hears every figure of the `[net]` line, the
  events above, a desync with its tick, and each tab going out of sight or window losing
  focus, and writes each as a line `room X, slot N client: …` beside its window line;
  the join line names the release, the platform and, in a browser, its family and system —
  never the user agent. So a complaint is read from one log by the room's code. The server
  calls a level a stage — it knows no game. Nothing is logged as a stranger wrote it:
  figures are whole numbers clamped to their bounds, words come from the server's closed
  sets, and a rejected message is a count, not a line. One word is not from a closed set:
  the game's name in the join line. Written as it came, a line break in it wrote a line of
  its own that read like the server's, so it is logged only when it is a plain word —
  `[a-z0-9_]`, up to 32 — and as `other` otherwise. A plain word is still the client's own:
  `game slot_0_tab_hidden` is what a stranger chose to write there, not something the
  server checked. A server from 0.6.5 or before reads each of these shapes as malformed,
  so a client sends it the older ones. About forty-eight lines a minute a room in play,
  twice the window lines alone.
- **A hidden tab has no next frame.** An engine notification about the tab reaches the
  game on its next frame, and a hidden tab gets none until it is shown: "hidden" would
  reach the server together with "visible". In a browser `Presence` listens to the
  page's own `visibilitychange`, `blur` and `focus`, whose callbacks run at once, and the
  note is on the socket before the loop stops. Checking it locally: two players in one
  headless Chrome are not a pair — the tab in the background is hidden and stands — so
  each player needs a browser of its own, and a second tab opened in one of them hides
  the game the way a person switching tabs does.
- **A gap in a player's stream does not say whose fault it is.** On 2026-09-24 one side's
  stream stood 100–460 ms nearly every window at a normal packet count, and the log could
  not tell a machine standing still from a network holding packets: both send the same
  number over five seconds, and the lag profiles and a local browser pair show the client
  itself never makes such a gap (17–19 ms at the worst). The window line now ends with
  `then N at once` — the packets that came together with the end of the worst gap: a
  stall's worth when the network let go of what it held (15–19 for 250 ms), fewer when
  the machine stood and caught up five ticks a frame (8–9, but 12–13 in another run: a
  browser may run its missed frames back to back, and then the catch-up comes at once
  too) — and the `[net]` line with the `longest frame`, which is the one that settles it. A window whose time is up waits for that burst
  if the packet that closed it ended its worst gap — or a stall ending past its edge would
  always read as the machine's — but only while the burst keeps coming, `mostHeldOpen` at
  most. The first packet that does not come with it opens the next window before it is
  counted: it may end another stall with a burst of its own, and a wait that restarted
  the count read `then 1 at once`. A gap of a
  second or more followed by two dozen is neither cause: it is a side that stood for its
  partner and sent its recent input again. The side whose
  own network stood also steps back deep, nine to twelve ticks: it went on guessing
  through the stall, where a machine that stood guessed nothing.
- **The tally between levels is waited out in a network game.** Each side shows its own,
  and a key swept away only the side's that pressed it. That side began the next level up
  to five and a half seconds early and stood frozen on its twelfth tick — `tick 17 stood,
  confirmed through 4` in its log, then `frozen` of 2.5–5 s — until the partner came.
- **Restoring a world must write into the same `WorldState`.** `Combat`, `EnemyAi`,
  `Bonuses` and `Spawner` hold a reference to it; a restore that swapped the object left
  them computing the world that was thrown away. `SimSnapshot.copy_world` writes into the
  destination, and `test_snapshot.gd` sets every script variable to an odd value to catch
  a field that was not copied.
- **Only a confirmed world ends a level or is hashed.** On a guess the base may fall that
  did not. A partner's hash that arrives before our tick is confirmed waits for ours;
  dropped as "unknown", as the lockstep buffer did, a divergence would pass unseen.
- **A level ends on a tick, not after a time.** The outro is `OUTRO_TICKS` past the
  confirmed end, with a horizon, so both sides carry the same score out. The count starts
  from `WorldState.ended_at`, the tick of the world the clear happened in, which the core
  records with the flag. A partner leaving mid-outro is handled like one leaving
  mid-level, or the outro waits for a confirmation that never comes.
- **The end of a level cannot be counted from the frame the end was seen on.** The
  confirmed tick moves on as the partner's packets come, and they come in bunches: one
  frame confirms a tick on one side and five on the other. Counted from the confirmed
  world on the frame the clear showed up, two sides ended a level ticks apart — the
  earlier finished and fell silent, the later stood for input that never came, and
  neither said a word, since both were still in the room. It hung the game after
  level 2 on 2026-09-16 and after level 3 on 2026-09-22. And a side standing at the
  horizon sends its input again once a second, like one standing at the window: the
  loop used to stop there before it asked, and one lost packet did the same.
- **Keys read by level lose a tap.** A tick takes the keys held at the moment it is
  captured, so a press that went down and up between two captures reached no tick: a
  frame hanging for a third of a second in the browser swallowed a tap of fire or a
  turn, and a tick standing for the partner swallowed every tap made while it stood.
  `PressFeed` hands the engine's key and pad events to `PressLatch` while the ticks
  run, and the next capture takes what was pressed along with what is held — once.
  Presses behind the STAGE caption, the pause, WAITING FOR PARTNER or RECONNECTING are
  not noted, and a caption going up forgets what the second before it latched: they
  would play once the world moved again. A stick is pressed only as it leaves the dead
  zone — on its way back to the centre it still reads -0.7, and taken as a press that
  drove the tank a tick after it was let go. An axis the latch has not seen since the
  level began is not a press: the stick may have been held since the menu.
- **A bullet and a tank walk unit by unit, so nothing invariant may be asked inside the
  walk.** Thirty-two steps a tick each re-asked where the base was, which tanks were
  about and which cells were covered — none of which changes while they walk. Settling it
  beforehand, and re-checking the cells only at a cell boundary, took the tick from
  423 µs to 121 µs on desktop and from 1.15 ms to 0.4 ms in the browser, which is what
  brings a twelve-tick rollback inside a browser frame. Anything added to those loops
  must be invariant-free, and `Golden.EXPECTED` is what proves it did not change the
  game.
- **Two tanks can come to overlap, and overlapping tanks must be able to part.** A
  blinking enemy does not block, so a player drives onto its spawn point, and the enemy
  materialises on top of the player; a player can also come back on top of an enemy. Each
  then found the other in its way on both axes, and neither moved again — reported from a
  network game on 2026-09-24 as "everything stops". `Movement` lets a tank that already
  overlaps another make any move that does not bring it closer. Beside it, the spawner
  waited on an occupied point, so a player parked there held back the whole wave; an
  occupied point now passes its turn to the next.
- **A stand is not a wait.** The server scores a slow window `network` if it waited and
  `machine` if it did not, and 0.5.0 kept stands longer than `FROZEN_MS` (150 ms) out of
  its waits: they are a frame loop standing still, not a network falling short. The
  rollback rewrite dropped that line, and `0.6.0` sent a partner's hidden tab to the
  server as a slow network; `NetInput` now counts those as `frozen`, apart. A window with
  a stand can still carry one-frame stops right after it while the two sides fall back
  into step, and those still count.
- **A stand leaves the side that stood a window ahead.** It went on guessing for twelve
  ticks before it stood, and the partner comes back from where they stopped. Shed by the
  pace rule, one tick in twenty, that lead cost three and a half seconds of dropped frames
  and rollbacks ten deep even on a local network. It is shed inside the stand now, while
  the picture is still, judged against our own lead as it read while the partner kept
  pace — the least of the last three readings, since a late packet only reads high — and
  down to one tick, the pace rule's own tolerance. The partner's word is no use there: it
  is from before the stand and up to a span stale, and a burst judged by it overshoots.
  `RECOVERY_LIMIT` bounds the burst, or a misread lead would hold the game still for good.
- **Only the pace packet keeps the two sides level.** A side half a second ahead guesses
  at the very edge of the window for the whole match — measured: depth 11–12 every second
  and forty-two stops, against none for the partner. `TickPump` does not close that gap
  by itself; `should_skip` lets one tick in twenty go until the leads match. It weighs
  our lead as the least of its last three readings: a late packet only reads high, and
  weighed as it came, every burst on a ragged path let a tick go for nothing — up to nine
  a stretch on 2026-09-24. The partner still hears the reading as it is: a least-of lags a
  rising lead, and a partner back from a stand would be heard as behind.
- **The macOS export must sign the app itself** (`codesign/codesign=1` in the preset).
  Without it the application carries away the *engine template's* signature, which stops
  matching once the game's bundle is assembled, and macOS says "damaged, move to the
  bin" — wording about a corrupted file, though the problem is the signature. With the
  built-in ad-hoc signature you get the ordinary "unidentified developer" instead.
- **A version in the macOS preset wins over the project's.** `application/short_version`
  and `application/version` held `0.1.0`, so `Info.plist` said 0.1.0 whatever the release
  stamped into `application/config/version`. Left empty, the export takes the project's
  version — a trial export stamped 9.9.9 came out as 9.9.9.
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
- **An inner class named after an engine global does not compile.** `class Side` meets
  the `Side` enum from `@GlobalScope` ("Cannot get property from enum value"), and
  `class Window` fails with "Class "Window" hides a native class". Pick a name the engine
  has not taken.
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
- **A `ResponseWriter` wrapper without `ReadFrom` silently turns off sendfile.** The
  engine is forty megabytes, and a wrapper that only counts the response still hides the
  socket's `ReadFrom` from the file server, which then copies it through user space. The
  recorder passes `ReadFrom` on, and a test checks that the socket is handed the file.
- **The metrics port is compared with the public one by number, not by string.**
  `027014` and `+27014` bind as 27014, and on macOS `127.0.0.1:27014` binds right next to
  `:27014` — a proxy on loopback would land on the metrics.
- **An older server relays a new text frame to the partner as a game packet.** So the
  client sends reports only after the welcome announces `reports: true`.
- **A test client the test stops referencing is closed by the garbage collector
  mid-test**, and the server sees a player leave. `dial` keeps every socket alive with
  `t.Cleanup` until the test ends.
- **A worst-gap window that closed on one packet recorded a full-window stall as zero.**
  The gap across a window boundary belongs to the window it ends in.
- **A ping carrying a plain monotonic stamp tells every client the server's uptime.** The
  payload carries a random per-process offset.
- **CI must read `go.mod` and `go.sum` as committed**: `-mod=readonly` plus
  `go mod tidy -diff`. `-mod=mod` repaired them in a throwaway checkout, and the first
  failure would have come in the release's image build.
- **Godot's `JSON.stringify` writes a float as `60.0`**, and `get_frames_per_second()` is
  a float. The server reads a whole-valued float as a whole number.
- **`go test` caches a result without looking at files outside `server/`.**
  `deploy_test.go` reads `../deploy`, so an edited dashboard would pass on the result from
  before the edit; `tools/test.sh` runs the Go tests with `-count=1`.

## Conventions

- Development is TDD: a failing test first, then the minimal implementation.
- A commit after every task in the plan. Messages in English: `feat:`, `test:`,
  `chore:`, `docs:`.
- Files are small, with a single responsibility. A file growing is a signal that it is
  doing too much.
- Levels are regenerated with `python3 tools/gen_levels.py` and then edited by hand. The
  tests in `game/tests/levels/` insure that a manual edit broke nothing.
