# BASE 13: deployment on a public machine — implementation plan

**Goal:** the game is played over the internet from a real address: the browser opens `https://<domain>/`, `QUICK GAME` pairs two strangers, and a desktop client joins through the same server.

**Architecture:** one container from the registry on the owner's machine. Inside is the image already built by the release workflow: the relay and the web build of the game on one port, plain HTTP. TLS, DNS and the reverse proxy in front belong to the machine's owner. Nothing about the game changes — except one line in the client, which is what Task 1 is for.

**Tech Stack:** Docker, the existing `ghcr.io/proshik/base13` image, someone else's reverse proxy.

**Spec:** `docs/specs/2026-09-03-quick-game-design.md` (sections 6, 7, 12, 13 — hosting, the image, the twelve factors, capacity).

**Not in this plan:** certificates and DNS (the owner's), the proxy's own configuration beyond the requirements it must satisfy, accounts, a second instance (impossible by design — a pair must land on one process, see section 12 of the spec).

## Global Constraints

- The image listens on plain HTTP. **Without HTTPS in front of it the browser build does not start at all**: Godot checks `window.isSecureContext` and shows "Secure Context — Check web server configuration" before reaching the game.
- A restart ends every match in progress: the journal lives in memory. Plan deploys accordingly.
- One process. Two instances behind a balancer would quietly create separate rooms invisible to each other.
- Capacity: 200 pairs measured with no losses; the ceiling is memory for journals — about 250 simultaneous long matches per gigabyte.
- A commit after every task. Messages in English: `feat:`, `test:`, `chore:`, `docs:`.

## What was found before writing this plan

**An idle connection carries no traffic in either direction, and a proxy will cut it.**

Godot's `WebSocketPeer` has a `heartbeat_interval`, and its default is `0.0` — no pings. We never set it. The server answers a ping with a pong (`server/ws.go`, covered by `TestPingIsAnsweredWithPong`) but never sends one of its own.

On the local network nothing exposed this: there is no intermediary between the two machines. Behind a reverse proxy there is, and it counts silence. Nginx's default `proxy_read_timeout` is 60 seconds; Cloudflare cuts at around 100.

The moment this shows up is the exact one the whole quick game is built around: a person presses `QUICK GAME` and waits for a partner. While waiting, the client sends nothing and receives nothing.

What that costs was measured rather than reasoned about. `test_a_heartbeat_is_what_lets_a_waiting_player_be_found` puts a deliberately dumb intermediary between the client and the server — one that closes a connection nothing has travelled through for a while, which is all a proxy's idle timeout is — and then has a second player press the same button later:

| | no heartbeat | heartbeat on |
|---|---|---|
| the intermediary cut the link | yes, at the timeout | no |
| the waiting client afterwards | stuck in `CONNECTING` | `READY` |
| the partner's room | a different one | the same one |
| they met | **no** | yes |

So it is not a stutter and not a reconnect people would sit through. The room is emptied, the client is left retrying through the same cutting intermediary, and the partner who arrives is seated in a room of their own: two people watching a stopwatch in separate rooms, and nothing that will ever join them.

The client does notice the drop — `_dropped()` puts it into `RETRYING` and it tries to rejoin by code — which is why the first guess, that it simply fails to notice, was wrong. It notices and cannot recover, because every retry goes back through the same thing that cut it.

The fix is one line on the client, and it belongs there rather than on the server: a ping from the client draws a pong back, so one setting covers a timeout in either direction, including on proxies we do not control.

The specific figures above — nginx's sixty seconds, Cloudflare's hundred — are documented defaults, not something measured here. What was measured is the mechanism: silence gets cut, a heartbeat prevents it. The real-machine confirmation is Task 5 step 3.

**Correction, 2026-09-12.** The client heartbeat covers desktop only. The browser's WebSocket cannot send a ping, and Godot's web peer only stores `heartbeat_interval`, so a browser player waiting for a partner — the main case — stayed silent after Task 1. Found by the review before the release; fixed on the server, which now pings on its own. See Task 4 of `docs/plans/2026-09-12-hardening.md`.

## File structure

| File | Responsibility |
|------|----------------|
| `game/net/relay.gd` | The socket to the server; the heartbeat is set here |
| `game/tests/net/test_relay.gd` | A test that the heartbeat is actually on |
| `README.md` | What the proxy in front must do, and the run command |

---

### Task 1: Keep the connection alive through a proxy

**Files:**
- Modify: `game/net/relay.gd`
- Test: `game/tests/net/test_relay.gd`

**Interfaces:**
- Consumes: nothing
- Produces: `Relay.HEARTBEAT_SECONDS`; a socket opened by `_open` pings on its own.

Ten seconds: comfortably inside nginx's default sixty and Cloudflare's hundred, and rare enough that the traffic is nothing — a ping and a pong are a few bytes against the sixty packets a second a match already sends.

Only `relay.gd` is touched. `session.gd` is the direct connection on the local network, where there is no intermediary to time anything out.

- [x] **Step 1: Write the failing test**

At the end of `game/tests/net/test_relay.gd`:

```gdscript
func test_the_socket_pings_on_its_own() -> void:
	# A person waiting for a partner sends nothing and receives nothing. A proxy
	# counts that silence: nginx cuts an idle connection at sixty seconds by
	# default. Godot's heartbeat is off unless it is switched on.
	if not _start_server(70):
		pending("no built server binary")
		return
	var relay := Relay.new()
	assert_eq(relay.quick(_url, 12345), OK)
	assert_gt(relay._socket.heartbeat_interval, 0.0,
		"without a heartbeat the connection dies while waiting for a partner")
	assert_lt(relay._socket.heartbeat_interval, 60.0,
		"a heartbeat rarer than the usual proxy timeout protects nothing")
	relay.close()
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `heartbeat_interval` is `0.0`.

- [x] **Step 3: Set the heartbeat in `game/net/relay.gd`**

Next to the other constants:

```gdscript
## How often the socket pings by itself. Godot leaves the heartbeat off, and a
## connection with no traffic is cut by anything standing in the middle: nginx
## gives an idle connection sixty seconds by default. Waiting for a partner in a
## quick game is exactly such a connection — silent, and possibly for minutes.
## A ping from us also draws a pong back, so one setting covers a timeout in
## either direction.
const HEARTBEAT_SECONDS := 10.0
```

And in `_open`, right after the peer is created and before `connect_to_url`:

```gdscript
	_socket = WebSocketPeer.new()
	_socket.heartbeat_interval = HEARTBEAT_SECONDS
	var err := _socket.connect_to_url(url)
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green, the new one included.

- [x] **Step 5: Commit**

```bash
git add game/net/relay.gd game/tests/net/test_relay.gd
git commit -m "fix: the relay socket pings on its own so a proxy does not cut the wait"
```

---

### Task 2: Write down what the proxy in front must do

**Files:**
- Modify: `README.md`

Three requirements, and every one of them is a symptom people spend an evening on when it is missing. The proxy itself is the owner's, so what belongs here is the requirements — plus the shortest form they take in the two proxies people actually run.

- [x] **Step 1: Add the section to `README.md`**

After "Deployment image", before "Testing on two laptops":

````markdown
### What the proxy in front must do

The image speaks plain HTTP. Whatever terminates TLS in front of it has to do
three things, and each one fails visibly when it is missing:

1. **Pass the WebSocket upgrade through** on `/ws`. Without it the page loads
   and the game starts, but every attempt to connect ends in `NO CONNECTION`.
2. **Not buffer the response.** A buffering proxy holds packets back and turns
   the match into a slideshow while every `[net]` line still reads 100%.
3. **Allow a long idle connection.** A person waiting for a partner sends
   nothing for minutes. The client pings every ten seconds so that the link is
   never actually silent, but a timeout shorter than that still cuts it.

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

One `location` for everything: the page, `/ws` and `/health` live on one origin
on purpose — that is what leaves the client with nothing to configure.
````

- [x] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: what a reverse proxy in front of the image must do"
```

---

### Task 3: Cut a server release carrying the fix

**Files:** none — the release workflow does the work.

The heartbeat from Task 1 is client code, but the client that browser players run is **inside the image**: `build/web` is baked in at build time. Without a new server release the fix reaches desktop players who download a build and nobody else.

**Gated on `docs/plans/2026-09-12-hardening.md`.** Images `0.2.0` and `0.3.0` were cut on 2026-09-04, before the review that found the server with no limits or deadlines and the heartbeat doing nothing in a browser. Neither goes on a public machine; the first that does is `0.4.0`, cut after that plan.

- [x] **Step 1: Ask before cutting it**

A release is something people are handed. Show what is going out and wait for an answer.

- [x] **Step 2: Run the release**

Actions → `release` → Run workflow, version `0.4.0`, target `server`.

The workflow builds the web export, publishes the image and checks it by running it and asking `/health` and `/`. A desktop release is not needed for this: the fix reaches desktop players with the next one.

**Done 2026-09-14, on the second attempt.** The first run built everything and died on
the push with `denied: permission_denied: read_package`. The repository had been deleted
and created again the day before, and a package is tied to a repository's id, not its
name: `ghcr.io/proshik/base13` was left with no repository at all, and the new
repository's token had no rights to it. The package page offers no "Connect repository"
in this state. What worked: Package settings → Manage Actions access → add `base13`,
then raise its role from Read, which is what it is added with, to Write. The rerun of
the same run passed, and the push linked the package to the repository again.

- [x] **Step 3: Check what was published**

```bash
docker pull ghcr.io/proshik/base13:0.4.0
docker run --rm -d --name check -p 27014:27014 ghcr.io/proshik/base13:0.4.0
curl -fsS localhost:27014/health && echo
curl -fsS localhost:27014/ | grep -c "BASE 13"
docker stop check
```

Expected: `/health` answers and the page is served.

Checked 2026-09-14: `0.4.0`, `latest` and `sha-afb7383…` are one image, it answers
`{"ok":true,"rooms":0}` and serves the page. The pull needed a login — see Step 0 of
Task 4 for why — and on Apple Silicon `--platform linux/amd64`, since the workflow
builds for amd64 only.

---

### Task 4: Run it on the machine

**Files:** none — this is a runbook, not code.

- [ ] **Step 0: Make the image reachable from the machine**

The package is private, and an anonymous `docker pull ghcr.io/proshik/base13:0.4.0` is
refused with `unauthorized`. Checked by hand, not assumed — and it will look on the
server like a typo in the tag rather than a permission.

A package's visibility is its own setting, not the repository's. It was created private
while the repository was private, and it stayed private when the repository went public
on 2026-09-13 — this step once assumed it would follow, and it does not.

Two ways out:

- make the package public: Package settings → Danger zone → Change visibility. **There
  is no way back** — a public package cannot be made private again. Delete the versions
  that must not be handed to anyone first: `0.1.0`, `0.2.0`, `0.3.0` and `feat-platform`
  predate the hardening plan. The machine then pulls with no credentials at all;
- or log in on the machine once, with a token that has `read:packages`:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u proshik --password-stdin
```

The second one keeps a credential on the machine for a game that is public anyway. Prefer
the first, and reach for the second only to try the image before the package is opened.

A third way avoids the registry entirely — build for the machine's architecture and carry
the file:

```bash
docker buildx build --platform linux/amd64 -t base13:amd64 --load .
docker save base13:amd64 | gzip > base13-amd64.tar.gz     # about 13 MB
scp base13-amd64.tar.gz <machine>:
ssh <machine> 'gunzip -c base13-amd64.tar.gz | docker load'
```

`--platform` is not optional on a machine whose own architecture differs. Built without
it on Apple Silicon the image comes out `linux/arm64`, and on an x86_64 server it fails
with `exec format error` — a message that says nothing about the cause.

- [ ] **Step 1: Start the container**

```bash
docker run -d --name base13 \
  --restart unless-stopped \
  -p 127.0.0.1:27014:27014 \
  -p 127.0.0.1:27015:27015 -e METRICS_ADDR=:27015 \
  --env-file /etc/base13/metrics.env \
  -e MAX_ROOMS=50 \
  ghcr.io/proshik/base13:0.4.0
```

The second port is the metrics listener for Prometheus or Alloy on the same machine
(README, "Metrics"); `0.4.0` predates it and ignores both lines, and the image that carries
`docs/plans/2026-09-14-metrics.md` answers on it. It is published on the loopback for the
same reason as the game's port, and it still wants a token: any container on the same
docker bridge reaches an unpublished port directly. `/etc/base13/metrics.env` holds one
line, `METRICS_TOKEN=<openssl rand -hex 32>`, readable only by root — a file rather than
`-e METRICS_TOKEN=…`, which would stay in the shell's history. Prometheus reads the same
token from its own file (`deploy/prometheus/scrape.yml`). Without metrics wanted, drop both
lines; the listener stays off.

`MAX_ROOMS=50` rather than the default 250, and the reason is memory: rooms are the only thing in the server that grows, each holding a journal of up to about 4 MB so a dropped player can come back. The default is sized for a gigabyte of journals, and this machine shares its memory with the proxy and the system. Fifty rooms at their caps are about 200 MB of journals, and Go's collector may let the process grow to about twice its live data, so budget 400 MB; an idle server takes under 2 MB. That is a hundred players; past that a newcomer sees `SERVER IS BUSY` and live matches are untouched. An empty room keeps its place for up to six minutes after the last player leaves, so with fifteen-minute matches expect about thirty-five live at once, not fifty. Raising it is a restart with another number, not a new image.

`127.0.0.1` in the publish is deliberate: only the proxy needs to reach the container. Published on all interfaces, the port answers from the outside over plain HTTP, and someone will eventually find the game there and wonder why it does not start.

`--restart unless-stopped` brings it back after a reboot. Matches do not survive that — the journal is in memory — but the service does.

- [ ] **Step 2: Check it before the proxy sees it**

```bash
curl -fsS localhost:27014/health && echo
```

Expected: the health response. If this is silent, the proxy is not the problem yet.

- [ ] **Step 3: Point the proxy at it**

The owner's job: a certificate, DNS, and the three requirements from Task 2.

- [ ] **Step 4: Check it through the proxy**

```bash
curl -fsS https://<domain>/health && echo
```

Expected: the same response, now over TLS.

---

### Task 5: Verify it the way a player would

Everything above can pass while the game is still unplayable. These are the checks that say it works.

- [ ] **Step 1: The page opens and the world is computed correctly**

Open `https://<domain>/?selftest`.

Expected: `SELFTEST OK 2233634213` on screen. That number is `Golden.EXPECTED`, and the same run on desktop (`godot -- --selftest`) must print it too. A different number means the browser computes a different world, and cross-platform co-op is off the table until it is explained.

- [ ] **Step 2: Two strangers meet**

Two tabs of one browser will not do, and the reason is worth knowing before it is
mistaken for a fault of ours. Chrome stops driving animation frames in a hidden tab, and
only one tab of a window is ever visible; a network match needs both sides ticking — the
visible side guesses for 200 ms and then stands — so the match freezes on `STAGE 1`. Seen locally against this very image: the pairing went through and
the room filled, and then neither side advanced.

The same thing follows for real players: a person who switches away from the tab
mid-match freezes their partner. Worth watching for once people are actually playing —
today the partner just sees the picture stop, which reads as a network fault rather than
as somebody looking at another tab.


From two different machines, on different networks — not two tabs on one: what is being checked is the path through the internet, not the code.

Both open `https://<domain>/`, both press `QUICK GAME`.

Expected: they are seated in one match and play a level together.

- [ ] **Step 3: The wait survives the proxy**

One person presses `QUICK GAME` and waits **more than two minutes** before the second one joins.

Expected: they still meet. This is the check for Task 1; before the fix the connection would have been cut at around a minute, with the stopwatch still counting on screen.

- [ ] **Step 4: Desktop and browser in one room**

One side in the browser at `https://<domain>/`, the other a desktop build:

```bash
godot -- --relay=wss://<domain>/ws
```

`CREATE ROOM` on one, `JOIN ROOM` with the code on the other.

Expected: they play. Note `wss`, not `ws`: behind TLS the plain scheme is refused.

- [ ] **Step 5: Read the numbers, not the impressions**

While playing, watch the `[net]` lines — the terminal on desktop, the developer console in the browser. `L` puts the last second's numbers on screen as well:

```
[net] 300 ticks in 5000 ms (norm 5000), speed 100%, stops 0 (longest 0 ms), rollbacks 8 (deepest 8), resim 3 ms, skips 1, lead 9 against 6
```

This is the `0.6.0` line; the game guesses the partner's keys and steps back when a guess was wrong, instead of waiting (`docs/specs/2026-09-16-rollback-design.md`). A line every five seconds: real time for three hundred ticks, the speed against the clock, `stops` — times the game stood because the partner had been silent past 200 ms — and the longest, how many `rollbacks` and the `deepest`, the time `resim` cost this machine, and the `skips` and leads that keep the two sides level.

Expected on a path to Moscow: your own tank answers the key at once, `stops` at zero after the first second, `deepest` around eight (the lag profiles settle there at 60 ± 20 ms a leg), `resim` a few milliseconds, speed at a hundred. Stops with no rollbacks mean the partner went quiet; a speed below a hundred with a large `resim` means the machine. Stops that keep coming on a live link, a `deepest` pinned at twelve, or a desync are what to report, with these lines from both sides.

On the server side:

```bash
docker logs --tail 50 base13
```

The arrival lines show the worst gap per connection. On the local network that was 10–28 ms on loopback and 104–272 ms over bad Wi-Fi; over the internet it is the baseline to compare later complaints against.

- [ ] **Step 6: Write down what came out**

Add the measured numbers to section 12 of `docs/specs/2026-09-03-quick-game-design.md`, where it currently says the image on a real VPS behind someone else's proxy is not verified. That line stops being true here, and a spec that lies about what was checked is worse than one that admits a gap.

```bash
git add docs/specs/2026-09-03-quick-game-design.md
git commit -m "docs: the image verified on a real machine behind a proxy"
```

---

## Readiness

1. Two people on different networks play a level through `https://<domain>/`, having exchanged nothing.
2. A wait of more than two minutes for a partner ends in a match rather than a dead connection.
3. A browser and a desktop client play in one room.
4. `?selftest` in the browser prints the same hash as `--selftest` on desktop.
5. The container comes back by itself after a reboot of the machine.
6. `./tools/test.sh` green, including the new heartbeat test.

After this the Homebrew cask — `docs/plans/2026-09-04-homebrew-cask.md`. It is independent of everything here except the order: both need the repository to be public, and there is no point installing through brew a game whose server is not up yet.
