# Quick game and the deployment image — design (subproject 3, stage 3.4)

## 1. Goal

Two strangers play together having exchanged nothing: one presses "quick game", the
other presses the same thing, and they end up in one match. And the game opens in the
browser at an address rather than being launched from a folder.

Playing with a specific person stays as it was — a room code read out loud.

## 2. What is in

- A `quick` action on the server: matchmaking among those waiting.
- Serving the game's files from the same server, on the same port.
- A Docker image and the command that builds it.

## 3. What is out

**Accounts.** The chosen shape of public play — one button, no list and no names — does
not require them. Whoever pressed it plays.

**A list of open rooms.** While the players are anonymous, a row in the list shows only
the code and how long someone has been waiting: there is nothing to choose between. The
list becomes meaningful together with names, that is, together with accounts.

**More than two in a match.** The core knows two player spawn points.

**TLS.** The image listens on plain HTTP. The certificate and whatever stands in front
of the image are the machine owner's business.

## 4. Matchmaking

### How it works

A room gets a "public" flag. `create` makes a private one, `quick` makes a public one;
in nothing else do they differ.

On a `quick` request for game G the server looks for a public room of that game with a
free seat. Found one — it seats you there; not found — it creates a new public room and
leaves the person waiting.

A room's capacity is two, so "a public room with one person in it" *is* "somebody is
waiting". No separate queue is needed — the state is already described by the rooms.

### What must be indivisible

The search and the seating happen under a single hub lock. Separately they produce a
race: two people who pressed the button at the same moment find the same room, and the
second gets a "full" refusal — even though there were two people waiting and they should
have met.

The lock acquisition order is hub first, then room; the same as in the cleanup of empty
rooms. The reverse order anywhere gives a deadlock.

### A waiting player who dropped

A room that has lost its last participant stops being offered in matchmaking, even though
it lives on for another five minutes.

The reason is not tidiness. Such a room's journal is not empty: it holds the button
presses sent before the drop. The next arrival would sit down there as if into a new
match and would get a catch-up of somebody else's presses — the world would go off from
the very first tick, and it would look like a random desync.

A dropped player can still come back to their own room: the code reaches them in the
welcome, and reconnecting works exactly as it does for a private room.

### What there will not be

There will be no counter of waiting players on screen. For it not to lie, the server
would have to broadcast queue changes to people who are not in a room yet — a separate
broadcast channel for the sake of one number. A number taken once on entry is stale a
second later, and a stale number is worse than no number.

Instead there is a stopwatch: it promises nothing and cannot lie.

## 5. The screen

The `QUICK GAME` entry goes first — it is the most frequent one.

```
NETWORK GAME              LOOKING FOR PLAYER
                                 0:14
▸ QUICK GAME        →
  CREATE ROOM                ESC CANCEL
  JOIN ROOM
  LAN HOST
  LAN JOIN
```

Whoever has been matched goes into the game by exactly the path someone entering by code
takes today: the welcome says there are two people in the room — so there is nobody left
to wait for.

The match seed is assigned by whoever started waiting first, and it reaches the second
person in the welcome. This is the same rule as for a private room; no special case
appears.

## 6. Serving the game's files

The `-static <folder>` flag. Not set — the server stays a pure relay, as it is today. Set
— a file server appears on `/`, while `/ws` and `/health` stay where they are.

One port for everything, and this is not about saving ports. The browser derives the
socket address from the page's address: one origin means there is nothing to configure in
the client at all. That path is already written and covered by tests —
`RelayConfig.from_page`.

Caching headers: `index.html` is served with no cache, everything else with the file
server's default. Godot's files carry no fingerprint in their names, so an eternal cache
on them would mean an updated game never reaching the player.

Compression: the engine is 37.7 MB and 9.6 MB in gzip, and `http.FileServer` knows no
`Content-Encoding`. The image carries a gzipped twin of every large file, made once at
build time, and the server hands the twin to anyone whose `Accept-Encoding` allows it and
the original to the rest. Compressing per visitor would redo the same work every time, and
neither of the two proxies people put in front compresses by default.

## 7. The image

Two-stage. The first stage builds the binary without CGO, the second is `scratch` with
that binary and the game folder. There is no system and no shell inside: the server
starts no subprocesses and makes no outbound calls.

The web build is made by Godot, and Godot is deliberately not in the image. Godot inside
`docker build` would be a second binding to the engine version, living apart from
`project.godot` and silently drifting away from it. Building the game is the job of what
already knows how to build it.

Hence the image's obligation: **fail clearly** if the web build is missing, rather than
assemble a working server with no game.

```dockerfile
COPY build/web /web
RUN test -f /web/index.html || (echo "no web build: run ./tools/build.sh first" && exit 1)
```

The stage that copies the game also compresses it: a `.gz` twin beside every large file,
made once here rather than per visitor by the server.

So that the order of the steps does not have to be remembered, `tools/image.sh` does
both: exporting the web build and building the image. It also checks what it built — the
page is served, and the engine comes back gzipped to a request that accepts it.

Running it: `docker run -p 27014:27014 base13`.

There will be no compose file: someone else's proxy stands in front of the image, and how
it is arranged is unknown. Inventing on the machine owner's behalf means writing a config
they will throw away anyway.

## 8. Testing

Go:

- Two `quick` requests end up in one room, in different seats, with one seed.
- A lone `quick` stays waiting and receives its seat and code.
- A room whose waiting player left is not offered to the next arrival.
- Matchmaking does not touch a private room: `create` and `quick` do not mix.
- Rooms of different games do not mix in matchmaking either.
- Static files are served when the flag is set; `/ws` and `/health` still work.
- Without the flag `/` serves nothing, and the relay works as before.

GUT:

- `Relay.quick` against a real built server: two clients meet.
- Screen wiring: the `QUICK GAME` entry leads to waiting, and waiting leads to the game.

The image is not covered by tests: that would need Docker, which may not be on a
developer's machine. The check lives in `tools/image.sh` — build it and ask `/health`.

## 9. Order of work

1. Public rooms and matchmaking on the server.
2. Static hosting from the same server.
3. `Relay.quick` on the client.
4. The menu entry and the waiting screen.
5. The Dockerfile and `tools/image.sh`.
6. Documentation.

## 10. Readiness criteria

1. `./tools/test.sh` green, including the new Go and GUT tests.
2. Two people who pressed "quick game" play together having exchanged nothing.
3. The game opens in the browser from the server's address and is played through it.
4. `./tools/image.sh` builds the image, `docker run` brings it up, `/health` answers.
5. The server still contains not a single mention of tanks.

## 11. What has been verified

All five criteria above are closed.

- `./tools/test.sh` — 409 GUT tests and 81 Go tests, green. The server tests are also run
  under `-race`: matchmaking is checked with forty simultaneous requests, and every one
  of them must get its own seat.
- Live: a browser served by the image itself pressed "quick game"; a desktop client
  pressed the same thing; the server brought them together, and they played out 310 ticks
  with no divergence. Nobody read out a code, nobody typed an address.
- `./tools/image.sh` builds the image (80 MB, `scratch` — 20 of them the gzipped twins),
  brings it up and checks that `/health` answers, the game page is served, and the engine
  comes back compressed to a request that accepts gzip.
- The image was opened in a browser from a local container: `?selftest` printed
  `SELFTEST OK 2233634213`, the same number as on desktop, and what booted was the
  gzipped engine — 9.6 MB in place of 37.7.
- `tools/check_server_neutral.sh` still finds not a single mention of tanks in the server.

Not verified: the image on a real VPS behind somebody else's proxy. That will be verified
on the first deployment — there is no machine yet.

## 12. The twelve factors

Checked against the list. Eight were satisfied straight away, three had to be finished,
and two are violated irreducibly — and that is a property of the problem, not an
oversight.

### Finished

**III. Config in the environment.** There were only flags: the image would have had to be
rebuilt for every machine. Now there are `PORT`, `ADDR` and `STATIC_DIR`; the flag stays
on top — it is handy for bringing up a second copy alongside without touching the
environment.

The address is deliberately not set in the image. If it were, it would override the
`PORT` the hosting platform supplies, and the container would listen somewhere other than
where it was placed. The default lives in the program, not in the image.

**IX. Disposability.** On `SIGTERM` the server stops accepting and says goodbye with a
`1001` close frame. A connection cut off mid-sentence is read by the client as "the link
is gone", and it spends half a minute knocking at a room that no longer exists after the
restart; a goodbye tells the truth.

This does not save the matches — the in-memory journal goes with the process. What it
saves is clarity: a person sees an explanation rather than a frozen screen.

**XI. Logs as event streams.** They were written to standard error and said almost
nothing. Now they go to standard output: storing and parsing them is the job of whoever
launched the process, and the program keeps no files of its own.

### Violated irreducibly

**VI. Stateless processes** and **VIII. Concurrency via the process model.**

The server keeps rooms and journals in memory. That is not laziness: the journal must lie
next to the pair, because a returning player catches up by replaying the other side's
presses in order. Moving it outside would mean going to somebody else's service on every
packet, sixty times a second per room.

Two consequences follow, and they are worth knowing in advance:

- **A restart ends the matches.** Rooms do not survive the process.
- **A second instance does not help.** A pair must land on the same process; without
  shared state or routing by room code the second copy would simply create its own rooms,
  invisible to the first.

While this fits inside one machine's headroom — and that headroom is large, see
section 13 — there is nothing to pay for shared state with. When we hit the wall, routing
by room code will be cheaper than moving the journal out.

## 13. How many people it will take

The measurement: `BASE13_LOAD=1 go test -run TestLoadManyPairs -v ./server`. It brings up
pairs of real connections, pushes presses at tick rate and counts delivery.

| Pairs | Delivered | Late | Journal per record |
|---|---|---|---|
| 10 | 100% | 0 | 14 bytes |
| 50 | 100% | 0 | 14 bytes |
| 200 | 100% | 0 | 14 bytes |

Two hundred pairs — four hundred people — go through with no losses and nothing late;
above that it was the measurement itself that hit the wall, not the server: the clients
live in the same process.

The measurement found two things that a back-of-the-envelope estimate had missed.

**The journal cost 112 bytes per 6 useful ones.** Every record was its own slice: a
header, a seat number, size rounding on allocation. A room at the limit took 32 MB, and a
hundred long matches took three gigabytes. The records were laid into one buffer: 14 bytes
per record, and a room at the limit is 4 MB.

**Matchmaking walked every room on the server** under the shared lock that also holds
creation and lookup by code. At two hundred that goes unnoticed; at ten thousand it is a
stalled server. A waiting queue was introduced: it holds only those who are waiting, and
matchmaking looks into it rather than at everything.

What remains the limit: memory for the journals. A match fills its journal in forty
minutes, and a full journal is 4 MB per room. A gigabyte of memory is about two hundred
and fifty simultaneous long matches, that is, five hundred people.

Those numbers describe honest play. On a public address the figure that matters is the
one nobody can exceed, so every count now has a ceiling: a message is refused past 512
bytes, a journal past seven bytes a record, the process past `MAX_ROOMS` rooms — 250 by
default, the gigabyte above — and past twice that many connections plus a little. A
newcomer beyond any of them is refused with `busy` and sees `SERVER IS BUSY`. That is a
denial of new games, which a restart cures; memory exhausted is every live match ending
at once, which it does not.
