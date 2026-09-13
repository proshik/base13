# Relay and rooms — design (subproject 3, stages 3.2–3.3)

> **Boundaries narrowed on 2026-09-01.** These two stages build only the relay, rooms by
> code and reconnecting from the journal. Accounts, static hosting and deployment are
> moved into a separate stage: first we need to see that playing through a server works
> at all.

## 1. Goal

Two people play through a server: one creates a room and reads out the code, the other
enters by that code. No addresses, no port forwarding and no local network permissions —
both clients dial out themselves.

The distant goal that shapes the solution: **the tanks should become one game among
several.** So the server knows nothing about tanks. It knows about people, rooms and
forwarding bytes; what those bytes are is the game's business.

## 2. What the server does, and what it does not

### It does

- Creates rooms with a short code and lets a second person into them.
- Forwards packets between the participants of a room.
- Keeps a journal of the room's packets so that a dropped player can catch up.

### It does not

**It does not compute the game.** The world is computed by the clients, and it is
identical for both by construction — that was proved in stage 3.0. The server sees only
bytes and cannot interpret them.

That is not laziness but a property: a server that does not know the rules is equally
suitable for any next game. The price is that it cannot check a player's honesty; for
co-op against the computer that is not a problem, and in the subproject about ratings
the decision will have to be revisited.

## 3. Why Go, and with no dependencies

It builds into one self-contained file: copy it to a server and run it, with no runtime,
no package manager and no image layers. For "I will deploy it myself" that is the
decisive convenience.

There is not a single dependency, WebSocket included — it is written by hand from the
standard. The reason is the same as for the sprites and the sound in this game: what
lives in the repository is something you can read, and the build does not depend on
somebody else's servers being available.

## 4. Deferred to the next stage

Accounts, sign-in by name and password, static hosting and deployment. For now a room is
open to anyone who knows the code: for playing with a friend that is enough, and
verifying sign-in makes sense on a working game rather than before one.

## 5. Rooms

A six-character code, with no characters that look alike: no `0`, `O`, `1`, `I`. The code
is read out loud over the phone — that is what determined the alphabet.

There are two people in a room: the creator and the joiner. The creator assigns the
match seed. The room lives as long as somebody is in it, plus the time allowed for
reconnecting.

A room belongs to a game: `game=tanks` in the request. The server does not know what that
means, but it does not mix rooms of different games — the next game will simply call
itself something else.

## 6. Forwarding and the journal

An arriving packet goes out to all the other participants of the room and is appended to
the journal. The journal is a sequence of bytes in arrival order.

Reconnecting: the client says how many journal records it already has and receives the
missing ones in one stream, after which it continues playing as usual. This works only
because the world is computed from the seed and the button presses: there is no state to
restore, replaying is enough.

The journal is bounded in size: an hour-long match is about a megabyte and a half per
room, and there is no reason to keep more.

Bounded in records alone, that held only for the packets this game sends. The server
forwards whatever it is handed, so the bound is also in bytes, a message is capped before
it is read, and the number of rooms and connections has a ceiling of its own — a public
address is reached by scripts as well as by players. See
`docs/plans/2026-09-12-hardening.md`.

## 7. The client

The network screen gets two new entries, and the direct connection by address stays:

```
NETWORK → CREATE ROOM (code on screen) → game
        → JOIN ROOM (enter the code)   → game
        → LAN HOST / LAN JOIN          → game
```

Sign-in by name and password is deferred along with the whole account side: a room is
open to anyone who knows the code.

The direct connection was kept rather than replaced: it works with no internet at all,
it is already written and covered by tests. The two ways of meeting live behind a single
`Link` kind, so everything above it — input, hash comparison, the game screen — knows
nothing of the difference.

The server address is derived from the page's address, and on desktop it is set with the
`--relay=` flag; the default is your own machine. The very same build works both locally
and on your server.

A drop mid-match does not end it: the client comes back to the same room, states how many
records it has already received and catches up from the journal. The game screen writes
`RECONNECTING` while that happens — otherwise a frozen screen reads as a hang. If the
server does not answer for half a minute, the match ends with `CONNECTION LOST`.

## 8. Testing

The server side — Go tests, run by the same `./tools/test.sh` command:

- The WebSocket handshake and frame parsing, including masking and coalescing.
- The room code contains no lookalike characters; a wrong code is refused.
- A packet reaches the second participant and does not come back to the sender.
- Reconnecting hands out exactly the missing tail of the journal.

The client side — GUT tests, as before.

## 9. Order of work

1. WebSocket without dependencies.
2. Rooms and forwarding.
3. The journal and reconnecting.
4. The client: creating a room by code and entering by code.

## 10. Readiness criteria

1. `./tools/test.sh` green, the Go tests included.
2. Two people play one match through the server knowing only the room code.
3. A dropped player comes back to the same match and catches up.
4. The server builds into one file.
5. The server contains not a single mention of tanks — that is guarded by
   `tools/check_server_neutral.sh` in the common run, not by good intentions.

## 11. The default port

`27014` — next door to the direct-connection port. Not 8080: that one is taken on almost
every work machine by a debug server or a port-forward, and by default the client would
silently go to somebody else's service. Connecting to the wrong place is worse than not
connecting: the game freezes with no explanation, and the cause is not visible anywhere.

## 12. What has been verified

- `./tools/test.sh` — 373 GUT tests and 34 Go tests, green.
- Two sides play a level through a real server, and the hashes match —
  `tests/net/test_relay.gd`.
- A dropped player comes back to their place and receives exactly what they missed —
  same file.
- Live: the browser build opened a room, the desktop build entered by code, and they
  played out 1166 ticks with no divergence. Different platforms in one room.

Not verified live: two machines across a network — the server came up on this same one.
That is worth verifying together with deployment, that is, in the next stage.

## 13. What is left before playing over the internet (stage 3.4)

There is already enough code to play over the internet: a room is built precisely so that
both sides dial out. What is missing is a machine with a public address.

Desktop with desktop will work as soon as the server runs there — nothing else. The
browser needs two more things, and only those:

1. Static hosting of the web build from the same host.
2. TLS, and it is mandatory for two independent reasons. The first is well known: from a
   page on `https` the browser will only open `wss`. The second is harsher — the Godot
   web build checks `window.isSecureContext` and without a secure origin does not start
   at all, before any socket. The browser counts HTTPS and `localhost` as secure, but not
   an address like `192.168.x.x` over http: the game opens on your own machine and does
   not open from a second one on the same network. So a certificate is needed for any
   hosting beyond your own machine — via a reverse proxy or TLS in the server itself.

Accounts are not part of 3.4: you can play without them — whoever knows the room code is
in. They are needed later, once there are several games on the platform.
