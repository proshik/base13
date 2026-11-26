# Room server

A separate Go program. Its one outside dependency is Prometheus's own client library, for
the metrics; the WebSocket layer is still written by hand. It builds into one file that
you only have to copy onto a machine and run. It knows nothing about tanks: it sees a room
code, the participants and the order of packets, and what those bytes mean is the game's
business. So the same server will do for the next game too.

```bash
cd server && go run .            # on this machine, port 27014
cd server && go build -o relay . # one file you can carry away
./relay -addr=:27014
```

To check that it is alive: `curl localhost:27014/health`.

The port is deliberately not 8080: that one is taken on almost every work machine, and
the client would silently have gone to somebody else's service.

By default the client looks for the server on its own machine. Another address is set
with a flag:

```bash
godot --path game -- --relay=ws://your-server:27014/ws
```

In the browser the address is derived from the page's address (`https` → `wss`), so it
is enough to serve the static files and the room server from one host. A page parameter
works for testing too, on a page opened from your own machine:
`?relay=ws://localhost:27014/ws`. A page served from anywhere else ignores it — otherwise
a link to the real site could send the game to any server the link names.

A room lives as long as somebody is in it, plus five minutes for a dropped player to
come back. There are no accounts yet: whoever knows the code gets in.

The same server also serves the game for the browser — with the `-static` flag:

```bash
./relay -static ./web        # game on / , socket on /ws , state on /health
```

One port for everything is not about thrift: the browser derives the socket address
from the page's address, so from a single origin there is nothing to configure in the
client at all.

## Deployment image

```bash
./tools/image.sh             # web build, image, check that it comes up
docker run -p 27014:27014 base13:latest
```

Inside is `scratch`: the binary and the game's files, about eighty megabytes with the
gzipped twins below, no system
and no shell. Godot is deliberately kept out of the image — that would be a second
binding to the engine version, living apart from `project.godot`; so `docker build`
requires a ready `build/web` and fails with an explanation if it is missing.

The engine alone is forty megabytes, and ten in gzip. The image carries a gzipped twin of
each large file, made once at build time, and the server hands it to any browser that
accepts gzip. The proxy in front need not compress anything.

The image does no TLS: it listens on plain HTTP, and the certificate and the proxy in
front of it are the machine owner's business. But **without HTTPS the game will not
start in the browser**: Godot requires a secure origin, and only HTTPS and `localhost`
qualify. Opening the build at `http://192.168.x.x:27014/` from a second computer will
not work — you get "Secure Context — Check web server configuration".

Settings come from environment variables; a flag overrides a variable, in case you need
to bring up a second copy alongside:

| Variable | What it sets |
|---|---|
| `PORT` | The port (the common convention among hosting platforms) |
| `ADDR` | The whole address, if you need to bind to one interface |
| `STATIC_DIR` | The folder with the game's files; empty means relay only |
| `MAX_ROOMS` | How many rooms at once, 250 by default. A room at its caps is about 4 MB, so 250 is about a gigabyte in the worst case; past it newcomers see `SERVER IS BUSY` |
| `METRICS_ADDR` | Where Prometheus reads the server's figures, for example `:27015`. Empty, the default, means no metrics listener at all. Its port must differ from the public one — compared as a number, so `027014` is still 27014 — or the server refuses to start |
| `METRICS_TOKEN` | A bearer token the metrics listener demands, at least 16 bytes. Environment only: a flag would show in `ps` |

On `SIGTERM` the server stops accepting and says goodbye to the players with a close
frame instead of cutting the connection: otherwise the client spends half a minute
knocking at a room that is already gone. A restart ends matches anyway — the journal
lives in memory.

How much it takes: the measurement `BASE13_LOAD=1 go test -run TestLoadManyPairs
./server` shows two hundred pairs (four hundred people) with no losses and nothing late.
The limit is memory for the journals: a full match takes 4 MB, so a gigabyte is about
two hundred and fifty simultaneous long matches.

You cannot scale out with a second instance: a pair must land on the same process,
because the journal it catches up from lives next to it. Details are in the design doc.

## What the proxy in front must do

The image speaks plain HTTP. Whatever terminates TLS in front of it has to do three
things, and each one fails visibly when it is missing:

1. **Pass the WebSocket upgrade through** on `/ws`. Without it the page loads and the
   game starts, but every attempt to connect ends in `NO CONNECTION`.
2. **Not buffer the response.** A buffering proxy holds packets back and turns the match
   into a slideshow while every `[net]` line still reads 100%.
3. **Allow a connection that is quiet for a while.** A person waiting for a partner sends
   nothing for minutes. The server pings every twenty seconds and every client answers —
   a browser by itself — so the link is never silent longer than that; a proxy timeout
   under twenty seconds still cuts it.

Caddy does all three by itself:

```
game.example.com {
	reverse_proxy 127.0.0.1:27014
}
```

Nginx needs saying:

```nginx
location / {
	proxy_pass http://127.0.0.1:27014;
	proxy_http_version 1.1;
	proxy_set_header Upgrade $http_upgrade;
	proxy_set_header Connection "upgrade";
	proxy_set_header Host $host;
	proxy_buffering off;
	proxy_read_timeout 3600s;
}
```

One `location` for everything: the page, `/ws` and `/health` live on one origin on
purpose — that is what leaves the client with nothing to configure.

Limits per address belong to the proxy too: behind it the server sees every connection
come from the proxy's own address, so it can cap the total but cannot tell one person from
a thousand. With nginx that is `limit_conn` in a `server` block.

Publish the container's port on the loopback only — `-p 127.0.0.1:27014:27014`. Only the
proxy needs to reach it; published on every interface it answers from the outside over
plain http, where the browser build refuses to start and nobody can tell why.

## Metrics

The server can show Prometheus and Grafana what stdout only hints at: connections and
rooms against their limits, refusals and how connections ended, how many people sit down
to play and how long they wait for a partner, and how the game actually runs for them —
the round trip to each player, the server's own delay, and the pace players' games report.
With the alert rules below, a full server or a desync reaches a person instead of a log.

It is off unless asked for. The figures go out on a port of their own, never the public
one: the proxy in front forwards every path, so `/metrics` on the public port would be on
the internet. There it is a 404, and `tools/image.sh` checks that it stays one.

```bash
openssl rand -hex 32 > metrics-token          # once; readable only by whoever runs the container
printf 'METRICS_TOKEN=%s\n' "$(cat metrics-token)" > metrics.env

docker run -d --name base13 --restart unless-stopped \
  -p 127.0.0.1:27014:27014 \
  -p 127.0.0.1:27015:27015 -e METRICS_ADDR=:27015 \
  --env-file metrics.env \
  ghcr.io/proshik/base13:<version>
```

`127.0.0.1` in the second publish matters as much as in the first: without it the figures
answer from outside. If Prometheus or Alloy runs in a container of its own, a docker network
shared with `base13` is better still — it reaches `base13:27015` with nothing published at
all. A binary without Docker listens on the loopback only: `METRICS_ADDR=127.0.0.1:27015`.
Given an address beyond the machine and no token, it says so at startup.

The token is needed even with the loopback publish. `-p 127.0.0.1:…` only limits where the
port is published on the host; any other container on the same docker bridge reaches the
container's address directly, published or not. With `METRICS_TOKEN` set, a scrape without
`Authorization: Bearer <token>` gets a 401. The token goes in through the environment, not a
flag, because flags show in `ps`, and through `--env-file`, not `-e METRICS_TOKEN=…`, so it
does not stay in the shell's history.

The image has no `EXPOSE` for the metrics port on purpose: `docker run -P` publishes every
exposed port on every interface.

Ready-made examples live in `deploy/`:

| File | What it is |
|---|---|
| `deploy/prometheus/scrape.yml` | A Prometheus configuration with the `relay` job and the token read from a file |
| `deploy/alloy/relay.alloy` | The same scrape through Grafana Alloy, sent on to Grafana Cloud or any remote-write store |
| `deploy/prometheus/alerts.yml` | Alert rules: down, restarting, near the limits, adding lag, starved of CPU, desyncs |
| `deploy/grafana/relay.json` | The dashboard: Now, Product, Lag and performance, Health, Resources |

The job must be called `relay`: every rule and panel selects `job="relay"`. Alloy does not
evaluate rules — with Alloy, load `alerts.yml` into the store's ruler. The dashboard imports
through Dashboards → New → Import and asks which Prometheus to read. `server/deploy_test.go`
checks that every figure these files name is one the server really exposes, so a renamed
metric fails the tests instead of leaving a panel quietly empty.

Point an uptime monitor at `/health`, not at `/`. A request for the page counts as a page
load, and a monitor that checks every minute adds 1440 page loads a day that no player made.

## What the server counts

Events, and what players' games say about themselves. A seating, a pairing, a refusal, a
relayed packet, a window of ticks reported by a player's side — each is added to a count or
a histogram and forgotten. The server keeps no list of who did what.

It never records an address, a room code, a seed, a game name, or any text a client sent as
it was sent. Every label comes from a closed set the server defines: a platform it does not
know becomes `other`, a version that is not three numbers becomes `other`, and only the ten
most common versions among players seated right now get a series of their own. A test seats
players in a room with a known code and seed and checks that neither appears in the scrape.

It does not count people. There is no identifier to count by, deliberately: "players" is who
is seated right now, a seating is an event, and one person who plays three matches is three
seatings. How many different people played is not something this server can say.

Figures from players' games — pace, waits, input delay, frame rate, desyncs, and the platform
and version in the hello — are self-reported, and a client can forge them. The server reads a
report into a fixed shape, clamps every figure to what a real window can be, takes at most one
every four seconds per connection over time, and never relays, journals or logs it. That
bounds what a forger can do; it does not stop a handful of fake clients from bending a
distribution. The round trip is measured by the server's own pings, but a client can make its
own figure worse by answering late.

The metrics carry no room codes; the logs do. Every line about a room names its code and game
(`room K7QX2M (private, game tanks): player 2 joined`), so stdout deserves the same care as the
machine itself.

## Reading the lag panels

A match that stutters has one of three causes, and the Lag and performance row tells them
apart with the same rule as the `[net]` lines:

- **Speed below 95% with waits** — the game stood waiting for the partner's input: the
  network. Look at the round trip for that platform, and at the worst gap.
- **Speed below 95% without waits** — nothing was waited for: the player's machine, or a
  frozen stand. The frame rate by platform shows a machine that cannot keep up; the worst
  gap shows a stand.
- **Round trip high, worst gap low** — a slow but steady path. Guessing the partner's keys
  absorbs it for as long as the round trip fits in 200 ms: the speed holds and nothing
  waits. Past that the game stands, and the stands show as waits.
- **Worst gap high, round trip normal** — jitter: Wi-Fi or a mobile link. A burst shorter
  than 200 ms is guessed through; a longer one stands the game.
- **Input delay above two** — a player still on a build older than `0.6.0`, which raised
  its delay from five to sixteen instead of guessing. Both lines under two mean everyone
  is on the current build.
- **Forward delay high** — the server itself. Check the Go scheduler latency and CPU first.

The log tells a ragged stream's two causes apart, which the panels cannot. Every five
seconds a line per player:

```
room J3LADB, slot 0: 5s, 330 packets, worst gap 214ms, then 14 at once
```

`then N at once` counts the packets that came together, within 4 ms, with the end of the
worst gap. A network that stood held what the player went on sending and lets it all go
together: about one for every fifteen milliseconds of the gap. A machine that stood sent
nothing while it stood and catches up five ticks a frame, so when the browser draws its
next frames at the display's pace, under ten come at once. But a browser may run the
frames it missed back to back, and then a machine's catch-up comes at once as well. On one
machine, with a stall of 250 ms made each way, a proxy holding the bytes gave 15 to 18 at
once, and a busy page gave 8 in one run and 12 to 13 in another. So a count well under a stall's worth means the machine, and a large one is only a
hint. The answer is in that player's own `[net]` line: `longest frame` near the gap means
the machine stood, a frame of a tick means the network.

One burst is neither. A side that stood a second waiting for its partner sends its recent
input again, two dozen packets in one frame, so `worst gap 1s, then 27 at once` is a side
that waited, not a network that held; its `[net]` log says `input sent again` at the same
moment. The same goes for a side coming back after a drop.

The `machine` share includes frozen stands. A window in which the game stood still — a
partner's hidden tab, a relay drop and return, the player's own hidden tab — is reported like
any other, and it reads as low speed with no waits, which is the `machine` verdict. So before
blaming players' machines, look at `relay_packet_gap_worst_seconds`: a stand shows there as a
gap of seconds, and a slow machine does not. The same windows pull down the speed and frame
rate panels.

Two things bend that rule. Players on `0.6.0` sent such stands as waits, so their frozen
windows read as `network`. And on any build a window with a partner's stand can still carry
a few one-frame stops right after it, while the two sides fall back into step, which also
tips it to `network`.

What else the figures do not say:

- `cut` disconnects include players whose socket failed on a write (a broken pipe, a reset),
  not only players evicted for falling behind.
- A code room's wait for a partner includes the time the code took to reach them. Time played
  together and abandoned waits are observed when the empty room is swept, five to six minutes
  late, and rooms still open at a restart are never observed.
- The forward delay misses writes that hit the five-second write limit; those become
  disconnects or evictions. Right after an eviction a burst of slow forwards is normal.
  `relay_packets_total` counts packets read from players, not packets delivered.
- The worst gap includes whole pauses in the middle of a connection — menus, the STATS screen,
  a hidden tab. Read its buckets, not its mean.
- Godot answers a ping once a frame, so desktop and native round trips include up to about
  16 ms of the game loop; a browser answers at once.
- The engine download time is a lower bound: socket and proxy buffers hide the rest, and behind
  nginx with `proxy_buffering on` it measures only the hop to the proxy. HEAD and 206 count as
  successful downloads; a 304 on the gzipped twin counts as `identity`.
- iPadOS Safari sends a Macintosh user agent, so iPads count as `web`, not `web_ios`.
- Versions are live players only, the ten most common plus `other`; while real traffic is low,
  a few fake clients can rotate fake versions through the ten.
- A development build reports version `0.0.0`: `project.godot` carries that placeholder, and
  only `tools/stamp_version.sh` at release time stamps the real number. So a local `godot`
  run and the web build `tools/image.sh` makes both show up as `0.0.0` in the version label,
  not as `other` and not as the repository's own version.
- Single-player and LAN games never talk to the server, so they are not measured at all.

