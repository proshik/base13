# BASE 13: network co-op — design (subproject 3)

## 1. Goal

Two people play one match from different machines. First on the local network between
desktops, then over the internet and from the browser.

The foundation is already there and verified: the core is deterministic, and in stage
3.0 the web build produced the same world hash as the desktop. So what travels over the
network can be button presses rather than the state of the world — tens of bytes per
second instead of megabytes.

## 2. Boundaries

### In this subproject

- The packet protocol and the lockstep buffer — pure classes, tested without a network.
- A WebSocket connection, hash comparison, an honest desync screen.
- A room by code through a relay; reconnecting from the journal of button presses.

### Not included

Random partner matchmaking (decided: room code only), voice chat, ratings, anti-cheat.
Rollback with prediction — only if the input delay turns out to be noticeable in a live
game, and that will not become clear before stage 3.2.

**A shared pause** — deferred, and worth writing down because the alternative looks
cheaper than it is.

A pause on one side is not a pause: while a client is paused it computes no ticks and
polls no socket, so the partner's game freezes with no explanation, and past a proxy's
idle timeout it does not freeze but ends — a paused screen does not even send the
heartbeat. So a network match currently has no pause at all: Esc asks whether to leave
and the game runs on behind the question.

A real shared pause means a packet of its own: one side asks, both stop at an agreed
tick, both resume at an agreed tick. Three things make it more than a message:

- The tick must be agreed, or the two worlds diverge at the seam. It has to be a
  future tick, the way input already is.
- The other side may never answer — a partner who closed the tab cannot refuse. The ask
  needs a timeout, and the timeout needs its own caption.
- The pause must not look like a stall to the machinery already watching for one: the
  adaptive input delay would read the gap as jitter and grow for no reason.

None of it is hard; all of it is a feature rather than a line. Worth doing when people
actually ask to stop mid-match, and not before — a game that cannot be paused is the
normal state of affairs online, and the current answer at least tells the truth.

## 3. Transport: one for everything

WebSocket everywhere. The only difference is who listens:

| Stage | Listens | Who with whom |
|-------|---------|---------------|
| 3.1 | One of the players | Desktop ↔ desktop on the same network |
| 3.2 | A relay on the internet | Anyone, the browser included |

The reason for one transport rather than two: the browser can only do WebSocket and
WebRTC, and we need cross-play. Building raw UDP for the LAN and WebSocket for the
internet means two codebases and two sets of bugs for a gain that our traffic does not
produce.

The price: WebSocket sits on TCP, and a lost packet delays the ones behind it. On a good
link with five ticks of input delay that is tolerable. If it turns out to tear, the next
step is WebRTC with an unreliable channel — but that means a signalling server and NAT
traversal relaying, noticeably more work.

The browser cannot listen for incoming connections, so in 3.1 it only joins a desktop
host, and it becomes a full participant in 3.2.

## 4. How a network tick is computed

Today the game screen asks the keyboard every tick and computes immediately. On a
network that is not possible: the partner's input is still in flight.

### Input delay

A press made on tick `N` is applied by both sides on tick `N + DELAY`. In that time the
packet gets across. At `DELAY = 5` that is 83 milliseconds — for a game where a tank
covers three quarters of a pixel per tick, almost imperceptible.

A tick is computed only once the input of **both** sides for that number is known. If a
packet is late, the game freezes for a frame or two and waits. Freezing together is
right; drifting apart is not.

### Why not rollback

Rollback — the simulation runs ahead on predicted input and is recomputed when the real
input arrives — feels like a game with no delay. But it requires snapshotting and
restoring state in microseconds, replaying up to seven ticks per frame, and it makes
events ambiguous: an explosion cancelled by a rollback has already been heard.

We start with input delay. It is simpler, it is enough for this game, and it does not
close the road to rollback later.

## 5. Layers

The core is not touched at all. Everything new lives in `net/`.

| File | Responsibility |
|------|----------------|
| `net/protocol.gd` | Packing and parsing a packet: tick number, input bits, hash |
| `net/lockstep.gd` | The input buffer by tick number; deciding "can tick N be computed" |
| `net/session.gd` | Connection, sending and receiving, hash comparison, link state |
| `ui/net_menu.gd` | The network game screen: host address, waiting for a partner |

`protocol.gd` and `lockstep.gd` are pure classes with not a single node and no network:
they are checked by tests, like the core. `session.gd` is a thin wrapper over
`WebSocketPeer`.

### The input source becomes swappable

Today the game screen reads `Keyboard.bits(i) | Gamepad.bits(i)` hard-wired. That moves
behind an interface: in the single-player game the source stays the keyboard and the
gamepad, in a network game it is `Lockstep`, which hands out both players' input for the
tick in question.

## 6. Comparison and desync

Once a second the sides exchange the world hash for a tick number both of them know. If
they differ, the match stops, a "desync" screen with the tick number is shown, and both
sides go back to the menu.

Carrying on silently is not an option: the players would see different worlds and not
understand why one of them has an exploded tank and the other does not. An honest stop
is better than divergence.

## 7. Seed and starting a match

The campaign seed is assigned by the host and sent in the game-start packet. The level
seeds are then derived from it, as they already are — which means both sides get
identical enemy waves across all thirty-five levels without a single extra byte.

## 8. Testing

- Packing and parsing a packet, including garbage on input.
- The buffer: a tick is computed only with input from both sides; out-of-order input;
  a duplicate packet; a late packet; input far in the future does not break the buffer.
- A hash divergence is detected on the very first comparison.
- Delay: a press on tick N is applied on N + DELAY, not earlier.

Not tested: `WebSocketPeer` itself and the screens — those are checked by running them
on two machines.

## 9. Order of work

**Stage 3.1 — lockstep on the local network**

1. The packet protocol.
2. The lockstep buffer.
3. A swappable input source in the game screen.
4. A WebSocket connection, host and guest.
5. The network game screen and the desync screen.
6. Verification on two machines on the same network.

**Stage 3.2 — relay and rooms**

7. The server: a room by code, handing out the seed, forwarding packets.
8. The client connects to the relay instead of the host.
9. The browser joins the game.

**Stage 3.3 — reconnecting**

10. A journal of button presses on the server; a dropped player catches up by replaying
    the journal.

## 10. What of this is done

Stages 3.1, 3.2 and 3.3 are closed. The details of rooms, the journal and reconnecting
live in a separate document: `2026-09-01-platform-design.md`; what remains here are the
decisions common to every way of connecting — the protocol, the buffer and the hash
comparison.

The direct local-network connection from stage 3.1 was not thrown away when rooms
arrived: it works with no internet at all. Both ways live behind a single `Link` kind,
and everything above it — input, comparison, the game screen — knows nothing of the
difference.

Criterion 2 below has not been checked by hand: two machines on the same network never
did play. Rooms have been checked that way (a browser and a desktop played a level
through the server), a direct connection has not.

## 11. Readiness criteria for stage 3.1

1. `./tools/test.sh` green, including the new protocol and buffer tests.
2. Two people on different machines on the same network complete a level together.
3. A desync is detected and honestly shown, not swept under the rug.
4. The core is not changed by a single line.
