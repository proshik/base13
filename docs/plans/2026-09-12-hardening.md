# BASE 13: hardening before the public machine — implementation plan

**Goal:** the image can stand on an address the whole internet can reach: one script cannot take the server's memory or descriptors, a browser player waiting for a partner survives any proxy, the engine travels compressed, and a partner or a server cannot swell the client's memory.

**Architecture:** the server gets limits it never had — the size of a message, the bytes in a journal, the number of rooms and connections, and a deadline on every read and write — and starts pinging on its own, because a browser cannot. The static handler serves gzipped twins made once at image build. The client drops input for ticks no honest partner could send and stops taking a server address from a public page's query.

**Tech Stack:** Go 1.26 standard library, GDScript (Godot 4.7.2), GUT, Docker.

**Found by:** the security and performance review of 2026-09-11 (two independent passes over `server/`, `game/net/`, `game/platform/relay_config.gd`, the Dockerfile and the workflows). What each task closes is named in its opening paragraph.

**Gates:** Task 3 of `docs/plans/2026-09-04-deployment.md` (the release). Nothing from this plan reaches a browser player until a server release is cut after it — the web build is baked into the image.

## Global Constraints

- The server knows nothing about the game: `tools/check_server_neutral.sh` fails on `tank|bullet|projectile|level|eagle|base13` in any non-test file of `server/`, **comments included**. Do not write "level" in a server comment.
- `game/core/` is not touched by this plan.
- TDD: a failing test first, then the minimal code. A commit after every task, messages in English: `feat:`, `fix:`, `test:`, `docs:`.
- Go tests: `cd server && go test ./...` (a single one: `go test -run TestName ./...`). The whole run: `./tools/test.sh` — it also rebuilds `.build/relay`, which the GUT tests stand up as a real server.
- Durations the tests must shorten are fields on `server` and `Conn`, never package variables: connections from earlier tests are still alive when the next test runs, and a changed global is a data race under `-race`.

## Not in this plan

Found by the same review, low severity, left for later: quoting client strings in logs, checking `Origin`, `nosniff`, a non-root `USER` in the image, passing `inputs.version` through `env:` in `release.yml`, pinning actions by SHA, the LAN host binding `0.0.0.0`. Client speed-ups (bullets stepping one unit at a time, hashing every tick) are not needed for sixty ticks a second and touch `game/core/`.

Per-address rate limits are not here either, and cannot be: behind a proxy every connection comes from the proxy's address. That is the proxy's job, and the README says so.

## File structure

| File | Responsibility |
|------|----------------|
| `server/ws.go` | Message and control-frame caps; read and write deadlines; `Ping`; `Close` that does not wait for a stuck write; `drain` after a refusal |
| `server/room.go` | Journal byte cap; the hub's room cap and `errServerBusy` |
| `server/config.go` | `MAX_ROOMS` / `-max-rooms` |
| `server/main.go` | HTTP timeouts; the connection cap; the writer loop `pump` with the ping ticker; gzipped twins |
| `Dockerfile`, `tools/image.sh` | Making the twins; checking they are served |
| `game/ui/net.gd` | A caption for the `busy` refusal |
| `game/net/net_input.gd` | Dropping input for ticks too far ahead |
| `game/platform/relay_config.gd` | `?relay=` honoured only on a page from one's own machine |
| `game/net/relay.gd`, `README.md`, `docs/plans/2026-09-04-deployment.md` | What the heartbeat really covers |

---

### Task 1: A message is capped as a whole

**Files:**
- Modify: `server/ws.go`
- Test: `server/ws_test.go`

**Interfaces:**
- Produces: `maxMessageSize = 512` (used by Task 2's test), `maxControlSize = 125`. `maxFrameSize` is removed.

Closes: one connection stitching continuation frames into a message of any size. Each frame was capped at a megabyte; their sum was not. Reproduced: eight megabytes accepted from eight frames; 48 frames took the heap from 0 to 59 MB in 0.3 s. Also closes a ping of up to a megabyte echoed back as a pong — the standard caps control frames at 125 bytes.

Why 512: the largest thing a client legitimately sends is the housekeeping packet, under a hundred bytes of JSON; game packets are six and nine.

- [x] **Step 1: Write the failing tests**

At the end of `server/ws_test.go`:

```go
func TestFragmentsCannotAddUpPastTheCap(t *testing.T) {
	// A cap on each frame alone is stepped around by fragmentation: frames
	// under the cap, stitched into one message far over it.
	client, server := pipeConn(t)
	defer client.Close()
	go func() {
		piece := bytes.Repeat([]byte{1}, 200)
		for i := 0; i < 10; i++ {
			frame := clientFrame(opContinuation, piece)
			if i == 0 {
				frame = clientFrame(opBinary, piece)
			}
			frame[0] &^= 0x80 // never the final one
			if _, err := client.Write(frame); err != nil {
				return
			}
		}
	}()
	if _, err := server.ReadMessage(); err == nil {
		t.Fatal("a message stitched past the cap must be refused")
	}
}

func TestOversizedControlFrameIsRefused(t *testing.T) {
	// The standard caps a control frame at 125 bytes, and the reply to a ping
	// echoes its payload: uncapped, the server writes back whatever it is handed.
	client, server := pipeConn(t)
	defer client.Close()
	go func() { client.Write(clientFrame(opPing, bytes.Repeat([]byte{1}, 126))) }()
	if _, err := server.ReadMessage(); err == nil {
		t.Fatal("a control frame over 125 bytes must be refused")
	}
}
```

- [x] **Step 2: Run them and make sure they fail**

Run: `cd server && go test -run 'TestFragmentsCannotAddUpPastTheCap|TestOversizedControlFrameIsRefused' ./...`
Expected: FAIL — both messages are accepted.

- [x] **Step 3: Cap the message and the control frames in `server/ws.go`**

Replace the `maxFrameSize` constant and its comment with:

```go
// A message is capped as a whole, not frame by frame: a cap on frames alone is
// stepped around by fragmentation, and eight frames of a megabyte were stitched
// into eight megabytes. The largest thing a client legitimately sends is the
// housekeeping packet, under a hundred bytes; relaying is forwarding, not
// storage, so there is no reason to accept much more.
const maxMessageSize = 512

// The standard's cap on a control frame. A pong echoes the ping's payload, so
// without it the server writes back whatever size it is handed.
const maxControlSize = 125
```

In `ReadMessage`, the data branch:

```go
		case opText, opBinary, opContinuation:
			if len(assembled)+len(payload) > maxMessageSize {
				return nil, fmt.Errorf("message of more than %d bytes", maxMessageSize)
			}
			assembled = append(assembled, payload...)
```

In `readFrame`, replace the length check:

```go
	if length > maxMessageSize {
		err = fmt.Errorf("frame of %d bytes is too large", length)
		return
	}
	// Control frames are small and whole by the standard.
	if opcode >= opClose && (length > maxControlSize || !final) {
		err = fmt.Errorf("control frame %d breaks the standard", opcode)
		return
	}
```

- [x] **Step 4: Run the server tests**

Run: `cd server && go test ./...`
Expected: PASS, including `TestOversizedFrameIsRefused`, `TestLongFrameIsRead` (500 bytes, under the cap) and `TestFragmentedMessageIsAssembled`.

- [x] **Step 5: Commit**

```bash
git add server/ws.go server/ws_test.go
git commit -m "fix: a message is capped as a whole, so fragments cannot add up to gigabytes"
```

---

### Task 2: The journal is capped in bytes too

**Files:**
- Modify: `server/room.go`
- Test: `server/room_test.go`

**Interfaces:**
- Consumes: `maxMessageSize` (Task 1).
- Produces: `maxJournalBytes`, `journal.size() int`.

Closes: a room's journal holding any number of bytes. It was capped at 300 000 records, and "an hour is a megabyte and a half" held only for six-byte packets; the server journals whatever it is handed, even from a lone member of a fresh room. Reproduced: a partner who stopped reading plus 309 packets of 64 KB made one room's journal 19.2 MB.

Seven bytes a record, about two megabytes: 300 000 records of six-to-nine-byte packets average about 1.8 MB, so honest play hits the count cap first and nothing changes for it. Derived from the count rather than written as a number, so the two cannot drift apart.

- [x] **Step 1: Write the failing tests**

At the end of `server/room_test.go`:

```go
func TestJournalIsBoundedInBytesToo(t *testing.T) {
	// The server relays whatever it is handed. A cap on the record count alone
	// lets large packets pile up without limit in one room.
	room := newRoom("ABCDEF", "tanks", 1)
	big := bytes.Repeat([]byte{7}, maxMessageSize)
	for i := 0; i < 2*maxJournalBytes/maxMessageSize; i++ {
		room.Broadcast(nil, big)
	}
	if got := room.journal.size(); got > maxJournalBytes {
		t.Fatalf("the journal holds %d bytes, the cap is %d", got, maxJournalBytes)
	}
}

func TestTheByteCapLeavesRoomForAFullHonestMatch(t *testing.T) {
	// Game packets are six bytes and, once a second, nine. If the byte cap bit
	// before the count cap, a long honest match would lose its catch-up.
	if maxJournal*7 > maxJournalBytes {
		t.Fatalf("%d records of seven bytes do not fit in %d", maxJournal, maxJournalBytes)
	}
}
```

- [x] **Step 2: Run them and make sure they fail**

Run: `cd server && go test -run 'TestJournalIsBoundedInBytesToo|TestTheByteCapLeavesRoomForAFullHonestMatch' ./...`
Expected: FAIL to compile — `maxJournalBytes` and `size` are undefined.

- [x] **Step 3: Add the cap in `server/room.go`**

In the constant block, after `maxJournal`:

```go
	// Records are capped in bytes as well as in count. The count alone assumed
	// six-byte packets, but the server journals whatever it is handed, and a
	// count of large packets is gigabytes. Seven bytes a record leaves honest
	// play reaching the count first: its packets are six bytes and, once a
	// second, nine.
	maxJournalBytes = maxJournal * 7
```

After `count()`:

```go
// size reports how many bytes of records the journal holds.
func (j *journal) size() int {
	return len(j.buf)
}
```

In `Broadcast`:

```go
	if r.journal.count() < maxJournal && r.journal.size()+len(data) <= maxJournalBytes {
```

- [x] **Step 4: Run the server tests**

Run: `cd server && go test ./...`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add server/room.go server/room_test.go
git commit -m "fix: a room's journal is capped in bytes, not only in records"
```

---

### Task 3: Rooms and connections have a ceiling

**Files:**
- Modify: `server/room.go`, `server/config.go`, `server/main.go`, `server/ws.go`, `game/ui/net.gd`, `README.md`
- Test: `server/room_test.go`, `server/config_test.go`, `server/server_test.go`

**Interfaces:**
- Produces: `errServerBusy` with reason `"busy"`; `Hub.limit int` (default `defaultMaxRooms = 250`); `config.MaxRooms`; `server.maxConns int` (zero — no cap, which is what the existing tests construct); `serve(t, s *server)` test helper; `(*Conn).drain()`.

Closes: memory with no ceiling at all. Tasks 1–2 bound one room; nothing bounded the number of rooms, and nothing bounded connections — 300 idle ones stayed open, reproduced. A room at its caps is about 4 MB, so 250 rooms is about a gigabyte in the worst case: the figure section 13 of the quick-game spec already sizes the server by. Past the cap a newcomer is refused with `busy` instead of the process being killed for memory, which would end every match at once.

Refusing before the hello is read would close the socket with unread data, and closing with unread data sends a reset that can swallow the refusal. So `refuse` now drains after saying goodbye, as `CloseWith`'s own comment always assumed the reader would.

- [x] **Step 1: Write the failing tests**

At the end of `server/room_test.go`:

```go
func TestHubRefusesRoomsPastItsLimit(t *testing.T) {
	// Past the cap a new room is refused rather than the process being killed
	// for memory — which would end every match on it at once.
	hub := NewHub()
	hub.limit = 2
	hub.Create("tanks", 1)
	hub.Create("tanks", 2)
	if _, err := hub.Create("tanks", 3); err != errServerBusy {
		t.Fatalf("a room past the limit was not refused: %v", err)
	}
	if reasonCode(errServerBusy) != "busy" {
		t.Fatalf("refusal marker %q instead of busy", reasonCode(errServerBusy))
	}
}

func TestAFullServerStillSeatsWhoeverIsWaiting(t *testing.T) {
	// Seating someone in a waiting room opens nothing new, so the cap must not
	// stop it: the waiter would otherwise wait forever beside a free seat.
	hub := NewHub()
	hub.limit = 1
	if _, _, err := hub.Quick("tanks", 1); err != nil {
		t.Fatalf("the waiter was not seated: %v", err)
	}
	if _, _, err := hub.Quick("tanks", 2); err != nil {
		t.Fatalf("the partner was refused though a seat was free: %v", err)
	}
	if _, _, err := hub.Quick("tanks", 3); err != errServerBusy {
		t.Fatalf("a third quick player needs a new room, which is past the limit: %v", err)
	}
}
```

At the end of `server/config_test.go`:

```go
func TestRoomLimitComesFromTheEnvironment(t *testing.T) {
	// The ceiling is memory, and memory is the machine's: the image is the same
	// everywhere, so the number comes from the launch.
	if got := settings(nil, env(nil)); got.MaxRooms != defaultMaxRooms {
		t.Fatalf("default room limit %d instead of %d", got.MaxRooms, defaultMaxRooms)
	}
	if got := settings(nil, env(map[string]string{"MAX_ROOMS": "40"})); got.MaxRooms != 40 {
		t.Fatalf("room limit %d instead of 40", got.MaxRooms)
	}
	given := map[string]string{"max-rooms": "7"}
	if got := settings(given, env(map[string]string{"MAX_ROOMS": "40"})); got.MaxRooms != 7 {
		t.Fatalf("room limit %d: a flag must beat a variable", got.MaxRooms)
	}
	// Zero or garbage would mean "refuse everyone" — a typo, not a setting.
	if got := settings(nil, env(map[string]string{"MAX_ROOMS": "lots"})); got.MaxRooms != defaultMaxRooms {
		t.Fatalf("garbage in MAX_ROOMS gave a limit of %d", got.MaxRooms)
	}
}
```

In `server/server_test.go`, after `startServer`:

```go
// serve stands up a given server the way main does — with its routes and its
// timeouts — so a test can set the server's own limits first.
func serve(t *testing.T, s *server) (addr string, stop func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	httpServer := newHTTPServer(s.routes(""))
	go httpServer.Serve(listener)
	return listener.Addr().String(), func() { httpServer.Close(); listener.Close() }
}
```

At the end of `server/server_test.go`:

```go
func TestConnectionsPastTheLimitAreRefused(t *testing.T) {
	// Idle sockets alone would use up the process's descriptors: a script opens
	// thousands and says nothing.
	s := &server{hub: NewHub(), maxConns: 3}
	addr, stop := serve(t, s)
	defer stop()
	for i := 0; i < 3; i++ {
		c := dial(t, addr)
		c.sendJSON(t, hello{Action: "create", Game: "tanks"})
		if answer := c.welcome(t); !answer.OK {
			t.Fatalf("connection %d was refused under the limit: %s", i+1, answer.Error)
		}
	}
	extra := dial(t, addr)
	extra.sendJSON(t, hello{Action: "create", Game: "tanks"})
	if answer := extra.welcome(t); answer.OK || answer.Reason != "busy" {
		t.Fatalf("a connection past the limit got %+v instead of busy", answer)
	}
}
```

`newHTTPServer` does not exist until Task 4. For this task add it to `server/main.go` in its minimal form, and make `main` use it:

```go
// newHTTPServer is the listening side main runs. Kept apart so the tests stand
// up exactly what production does.
func newHTTPServer(handler http.Handler) *http.Server {
	return &http.Server{Handler: handler}
}
```

- [x] **Step 2: Run them and make sure they fail**

Run: `cd server && go test ./...`
Expected: FAIL to compile — `limit`, `errServerBusy`, `MaxRooms`, `defaultMaxRooms`, `maxConns` are undefined.

- [x] **Step 3: The room cap in `server/room.go`**

Beside the other errors:

```go
	errServerBusy   = errors.New("the server holds as many rooms as it can")
```

In `reasonCode`:

```go
	case errServerBusy:
		return "busy"
```

After the constant block:

```go
// How many rooms one process holds by default. A room at its caps is about
// 4 MB, so this is about a gigabyte in the worst case. Past it a new room is
// refused with "busy" rather than the process being killed for memory, which
// would end every match on it at once.
const defaultMaxRooms = 250
```

In `Hub`, a field after `waiting`:

```go
	// The most rooms at once; see defaultMaxRooms.
	limit int
```

In `NewHub`, `limit: defaultMaxRooms,`. At the top of `create`, before the loop:

```go
	if len(h.rooms) >= h.limit {
		return nil, errServerBusy
	}
```

- [x] **Step 4: The setting in `server/config.go`**

`import ("strconv"; "strings")`. In `config`, `MaxRooms int`. In `settings`: start from `config{Addr: defaultAddr, MaxRooms: defaultMaxRooms}`; after reading `TLS_KEY`:

```go
	if rooms := positive(env("MAX_ROOMS")); rooms > 0 {
		c.MaxRooms = rooms
	}
```

after the `tls-key` flag:

```go
	if rooms := positive(given["max-rooms"]); rooms > 0 {
		c.MaxRooms = rooms
	}
```

and at the end of the file:

```go
// positive reads a count. Zero, a negative or garbage reads as "not given": a
// room limit of zero would refuse everyone, which is a typo rather than a
// setting.
func positive(value string) int {
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || n <= 0 {
		return 0
	}
	return n
}
```

- [x] **Step 5: The connection cap and the drain in `server/main.go` and `server/ws.go`**

In `server/ws.go`, after `CloseWith`:

```go
// drain reads and discards until the other side closes or CloseWith's deadline
// runs out. Closing a socket with unread data in it sends a reset instead of an
// end of stream, and a reset can take the farewell written just before it down
// with it. Only for the connection's own reader: two readers on one buffer
// crash the program.
func (c *Conn) drain() {
	io.Copy(io.Discard, c.reader)
}
```

In `server/main.go`, in `server`:

```go
	// The most connections held at once; zero means no cap. Two per room at the
	// room cap, plus headroom for those still saying hello.
	maxConns int
```

`remember` reports whether there was room:

```go
func (s *server) remember(c *Conn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.maxConns > 0 && len(s.conns) >= s.maxConns {
		return false
	}
	if s.conns == nil {
		s.conns = map[*Conn]struct{}{}
	}
	s.conns[c] = struct{}{}
	return true
}
```

In `handleWS`:

```go
	defer conn.Close()
	if !s.remember(conn) {
		refuse(conn, errServerBusy.Error(), reasonCode(errServerBusy))
		return
	}
	defer s.forget(conn)
```

`refuse` ends with `conn.drain()` after `CloseWith`.

In `main`: a flag `flag.String("max-rooms", "", "how many rooms at most; overrides MAX_ROOMS")`, and

```go
	s := &server{hub: NewHub(), maxConns: 2*cfg.MaxRooms + 64}
	s.hub.limit = cfg.MaxRooms
```

and the first startup line says the ceiling: `log.Printf("rooms up to %d, connections up to %d", cfg.MaxRooms, s.maxConns)`.

- [x] **Step 6: The caption in `game/ui/net.gd`**

In `REFUSALS`: `"busy": "SERVER IS BUSY",`. `test_net_screen.gd` already checks every caption can be drawn by the atlas font.

- [x] **Step 7: The README**

In "Deployment image", the variables table gains:

```markdown
| `MAX_ROOMS` | How many rooms at once, 250 by default. A room at its caps is about 4 MB, so 250 is about a gigabyte in the worst case; past it newcomers see `SERVER IS BUSY` |
```

and in "What the proxy in front must do", after the nginx block:

```markdown
Limits per address belong to the proxy too: behind it the server sees every connection
come from the proxy's own address, so it can cap the total but cannot tell one person from
a thousand. With nginx that is `limit_conn` in a `server` block.
```

- [x] **Step 8: Run everything**

Run: `./tools/test.sh`
Expected: all green.

- [x] **Step 9: Commit**

```bash
git add server/ game/ui/net.gd README.md
git commit -m "fix: rooms and connections have a ceiling, and past it the answer is busy"
```

---

### Task 4: Nobody holds a connection for free, and the server speaks first

**Files:**
- Modify: `server/ws.go`, `server/main.go`, `game/net/relay.gd`, `README.md`, `docs/plans/2026-09-04-deployment.md`
- Test: `server/ws_test.go`, `server/server_test.go`

**Interfaces:**
- Consumes: `serve(t, s)` (Task 3).
- Produces: `Conn.readIdle`, `Conn.writeLimit` (zero — no deadline); `defaultReadIdle = 60s`, `defaultWriteLimit = 5s`; `(*Conn).Ping()`; `server.readIdle`, `server.pingEvery` (zero — the defaults); `defaultPingEvery = 20s`; `pump(conn *Conn, member *Member, every time.Duration)`.

Closes three things.

**No deadlines.** `http.Server` had no timeouts, and after the hijack nothing read or wrote with a deadline: half a request line held a goroutine forever (reproduced), and so did a socket that went silent. A write to a client who stopped reading blocked forever too, holding `writeMu` — and `Close` took the same lock, so a shutdown farewell waited on it (reproduced: one of two farewells returned in 3 s).

**The browser never pings.** Task 1 of the deployment plan set `heartbeat_interval` on the client, and it works on desktop. In the browser it does nothing: the browser's WebSocket has no way to send a ping frame, and Godot's web peer only stores the value. A browser player waiting for a partner — the main case — stayed silent in both directions, exactly what that plan's opening section showed a proxy cuts. The fix belongs on the server: it pings on a timer, and every client answers by itself, browsers included. It is also what makes the read deadline safe: a waiting browser now has pongs to show it is alive.

Twenty seconds: well inside nginx's sixty and Cloudflare's hundred. The read deadline is three pings' worth.

- [x] **Step 1: Write the failing tests**

At the end of `server/ws_test.go`:

```go
func TestAWriteToAReaderWhoStoppedGivesUp(t *testing.T) {
	// A client that stopped reading fills the socket, and the next write blocks.
	// Without a limit it blocks forever, holding the connection's lock.
	_, server := pipeConn(t)
	server.writeLimit = 100 * time.Millisecond
	start := time.Now()
	if err := server.WriteMessage([]byte{1}); err == nil {
		t.Fatal("a write nobody reads must fail")
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("the write gave up only after %v", took)
	}
}

func TestCloseDoesNotWaitForAStuckWrite(t *testing.T) {
	// Close is how a stuck connection is got rid of. If it waits for the stuck
	// write first, it waits as long as the write does.
	_, server := pipeConn(t)
	failed := make(chan error, 1)
	go func() { failed <- server.WriteMessage([]byte{1}) }()
	time.Sleep(50 * time.Millisecond) // let the write block
	closed := make(chan struct{})
	go func() { server.Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("Close waited for a write that will never finish")
	}
	if err := <-failed; err == nil {
		t.Fatal("the stuck write must fail once the socket is closed")
	}
}
```

At the end of `server/server_test.go` (add `"io"` is already imported):

```go
func TestTheListenerDoesNotWaitForeverForARequest(t *testing.T) {
	// Half a request line and then nothing holds a goroutine and a descriptor
	// for as long as the sender likes.
	srv := newHTTPServer(http.NewServeMux())
	if srv.ReadHeaderTimeout <= 0 || srv.IdleTimeout <= 0 {
		t.Fatalf("the listener waits forever: header %v, idle %v",
			srv.ReadHeaderTimeout, srv.IdleTimeout)
	}
}

func TestServerPingsAWaitingClient(t *testing.T) {
	// A browser cannot send a ping: its WebSocket has no such call. A player
	// waiting for a partner is then silent both ways, and a proxy cuts a silent
	// connection. The server has to speak first; the browser answers by itself.
	addr, stop := serve(t, &server{hub: NewHub(), pingEvery: 50 * time.Millisecond})
	defer stop()
	waiting := dial(t, addr)
	waiting.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 1})
	waiting.welcome(t)
	for step := 0; step < 8; step++ {
		if opcode, _ := waiting.receiveFrame(t); opcode == opPing {
			return
		}
	}
	t.Fatal("the server never pinged a waiting client")
}

func TestASilentConnectionIsCut(t *testing.T) {
	// A laptop that went to sleep never says goodbye. Without a read deadline its
	// connection holds a goroutine and a descriptor forever — and a script can
	// open thousands of such on purpose.
	s := &server{hub: NewHub(), readIdle: 200 * time.Millisecond, pingEvery: time.Hour}
	addr, stop := serve(t, s)
	defer stop()
	mute := dial(t, addr)
	mute.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 1})
	mute.welcome(t)
	mute.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := io.ReadAll(mute.reader); err != nil {
		t.Fatalf("the server never cut a silent connection: %v", err)
	}
}

func TestAnsweringPingsKeepsTheConnection(t *testing.T) {
	// The deadline must cut the dead, not the patient: a client that answers
	// pings is alive however long it waits for a partner.
	// Five pings to an idle window, and the wait lasts three windows: a slow
	// machine must not be able to turn this into a flake.
	s := &server{hub: NewHub(), readIdle: 500 * time.Millisecond, pingEvery: 100 * time.Millisecond}
	addr, stop := serve(t, s)
	defer stop()
	waiting := dial(t, addr)
	waiting.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 1})
	code := waiting.welcome(t).Code
	for until := time.Now().Add(1500 * time.Millisecond); time.Now().Before(until); {
		if opcode, payload := waiting.receiveFrame(t); opcode == opPing {
			waiting.conn.Write(clientFrame(opPong, payload))
		}
	}
	partner := dial(t, addr)
	partner.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 2})
	if got := partner.welcome(t); got.Code != code {
		t.Fatalf("the patient waiter was cut: the partner got room %q instead of %q", got.Code, code)
	}
}
```

- [x] **Step 2: Run them and make sure they fail**

Run: `cd server && go test ./...`
Expected: FAIL to compile — `writeLimit`, `readIdle`, `pingEvery` are undefined.

- [x] **Step 3: Deadlines, `Ping` and a lock-free `Close` in `server/ws.go`**

`import "sync/atomic"`. After `closeLinger`:

```go
// How long a connection may stay silent before it is taken for dead. The
// server pings every twenty seconds and every client answers — a browser on its
// own — so a live link is never silent this long, while a laptop that went to
// sleep would otherwise hold its socket forever.
const defaultReadIdle = 60 * time.Second

// How long one write may take. Packets are a few bytes: a write that cannot get
// them into the socket in five seconds is writing to somebody who stopped
// reading.
const defaultWriteLimit = 5 * time.Second
```

`Conn` becomes:

```go
type Conn struct {
	raw     net.Conn
	reader  *bufio.Reader
	writeMu sync.Mutex
	closed  atomic.Bool
	// Set once a farewell is on its way: from then on the read deadline is the
	// farewell's own short one and must not be pushed back.
	leaving atomic.Bool
	// Zero means no deadline. Accept sets the defaults; tests shorten them.
	readIdle   time.Duration
	writeLimit time.Duration
}
```

`Accept` returns `&Conn{raw: raw, reader: buf.Reader, readIdle: defaultReadIdle, writeLimit: defaultWriteLimit}`.

At the top of `readFrame`:

```go
	if c.readIdle > 0 && !c.leaving.Load() {
		c.raw.SetReadDeadline(time.Now().Add(c.readIdle))
	}
```

In `writeFrame`: `if c.closed.Load() {` instead of `if c.closed {`, and before the write:

```go
	if c.writeLimit > 0 {
		c.raw.SetWriteDeadline(time.Now().Add(c.writeLimit))
	}
```

After `WriteText`:

```go
// Ping asks the other side to answer. The server sends it on a timer because a
// browser cannot send one at all — its WebSocket has no such call — and a
// waiting browser player would otherwise be silent in both directions.
func (c *Conn) Ping() error {
	return c.writeFrame(opPing, nil)
}
```

At the top of `CloseWith`: `c.leaving.Store(true)`.

`Close` becomes:

```go
// Close does not take the write lock: closing the socket is what unblocks a
// write stuck on a client who stopped reading, and waiting for that write first
// would wait as long as it does.
func (c *Conn) Close() {
	if c.closed.Swap(true) {
		return
	}
	c.raw.Close()
}
```

- [x] **Step 4: Timeouts and the pinging writer in `server/main.go`**

After `statsWindow`:

```go
// How often the server pings. Well inside nginx's default sixty seconds and
// Cloudflare's hundred: whatever stands in front never sees a silent link.
const defaultPingEvery = 20 * time.Second
```

In `server`:

```go
	// Zero means the defaults; tests shorten them.
	readIdle  time.Duration
	pingEvery time.Duration
```

`newHTTPServer` gets its timeouts:

```go
// newHTTPServer is the listening side main runs. Without the timeouts a
// connection that sends half a request line and then nothing holds a goroutine
// and a descriptor forever. No write timeout: a slow player downloading the
// engine is not an attack. Hijacked sockets set their own deadlines.
func newHTTPServer(handler http.Handler) *http.Server {
	return &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
}
```

In `handleWS`, right after `Accept` succeeds:

```go
	if s.readIdle > 0 {
		conn.readIdle = s.readIdle
	}
```

and the inline sending goroutine becomes `go pump(conn, member, s.pingInterval())`, with:

```go
func (s *server) pingInterval() time.Duration {
	if s.pingEvery > 0 {
		return s.pingEvery
	}
	return defaultPingEvery
}

// pump carries a member's queue into the socket and pings on a timer. Sending
// runs in its own goroutine: a slow member must not hold up those who read on
// time.
func pump(conn *Conn, member *Member, every time.Duration) {
	ping := time.NewTicker(every)
	defer ping.Stop()
	for {
		select {
		case packet, open := <-member.Send:
			if !open {
				return
			}
			var err error
			if packet.Text {
				err = conn.WriteText(packet.Data)
			} else {
				err = conn.WriteMessage(packet.Data)
			}
			if err != nil {
				conn.Close()
				return
			}
		case <-ping.C:
			if err := conn.Ping(); err != nil {
				conn.Close()
				return
			}
		}
	}
}
```

- [x] **Step 5: Run the server tests**

Run: `cd server && go test ./...`
Expected: PASS. `TestShutdownSaysGoodbyeToEveryone` must stay green — it is the check that the farewell's short deadline is not pushed back by `readFrame`.

- [x] **Step 6: Say what the heartbeat really covers**

In `game/net/relay.gd`, the comment over `HEARTBEAT_SECONDS` becomes:

```gdscript
## How often the socket pings by itself. Godot leaves the heartbeat at zero, and
## a connection with no traffic is cut by whatever stands in the middle: nginx
## gives an idle connection sixty seconds by default.
##
## This covers desktop only. In a browser it does nothing: the browser's
## WebSocket has no way to send a ping, and Godot's web peer only stores the
## value. The server pings every twenty seconds for exactly that reason, and a
## browser answers by itself — so a waiting browser player is kept alive from
## the other end.
```

In `README.md`, point 3 of "What the proxy in front must do":

```markdown
3. **Allow a connection that is quiet for a while.** A person waiting for a partner sends
   nothing for minutes. The server pings every twenty seconds and every client answers —
   a browser by itself — so the link is never silent longer than that; a proxy timeout
   under twenty seconds still cuts it.
```

In `docs/plans/2026-09-04-deployment.md`, at the end of "What was found before writing this plan":

```markdown
**Correction, 2026-09-12.** The client heartbeat covers desktop only. The browser's
WebSocket cannot send a ping, and Godot's web peer only stores `heartbeat_interval`, so a
browser player waiting for a partner — the main case — stayed silent after Task 1. Found
by the review before the release; fixed on the server, which now pings on its own. See
Task 4 of `docs/plans/2026-09-12-hardening.md`.
```

- [x] **Step 7: Run everything**

Run: `./tools/test.sh`
Expected: all green, including `test_a_heartbeat_is_what_lets_a_waiting_player_be_found` — its intermediary cuts at 0.8 s, far below the server's twenty-second ping, so it still measures the client's heartbeat alone.

- [x] **Step 8: Commit**

```bash
git add server/ game/net/relay.gd README.md docs/plans/2026-09-04-deployment.md
git commit -m "fix: every read and write has a deadline, and the server pings because a browser cannot"
```

---

### Task 5: A member cut off for falling behind is disconnected

**Files:**
- Modify: `server/main.go`
- Test: `server/server_test.go`

**Interfaces:**
- Consumes: `pump(conn, member, every)` (Task 4).

Closes: the ghost. When a member's queue overflows, `Broadcast` closes their channel and removes them from the room, and the writer simply returned — leaving the socket open. The member kept a live connection that would never carry anything again: they see `WAITING FOR PARTNER` until they quit by hand, while the journal they could catch up from sits one reconnect away. Closing the socket turns the cut into an ordinary drop: the client retries by code, gets the missed tail, and plays on.

What the member sends in the moment before the socket closes still reaches the partner and the journal, and that is right: those are real presses for real ticks, already applied on the member's side, and they will not be sent again.

- [x] **Step 1: Write the failing test**

At the end of `server/server_test.go`:

```go
func TestAMemberCutOffForFallingBehindIsDisconnected(t *testing.T) {
	// The room drops a member whose queue overflowed. Unless the socket goes
	// too, they sit on a connection that will never carry anything again and
	// never learn to come back and catch up from the journal.
	client, conn := pipeConn(t)
	member := &Member{Slot: 0, Send: make(chan outgoing, 1)}
	done := make(chan struct{})
	go func() { pump(conn, member, time.Hour); close(done) }()
	close(member.Send)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("the writer did not stop when the queue closed")
	}
	client.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := client.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("the socket was left open: read gave %v instead of the end", err)
	}
}
```

- [x] **Step 2: Run it and make sure it fails**

Run: `cd server && go test -run TestAMemberCutOffForFallingBehindIsDisconnected ./...`
Expected: FAIL — the read times out: the socket is still open.

- [x] **Step 3: Close the socket when the queue closes**

In `pump`:

```go
		case packet, open := <-member.Send:
			if !open {
				// The queue closes in two cases: the member left, and the
				// socket is going anyway; or the room cut them off for
				// falling behind. In the second, an open socket would carry
				// nothing ever again. Closed, it is an ordinary drop: the
				// client comes back by code and catches up from the journal.
				conn.Close()
				return
			}
```

- [x] **Step 4: Run the server tests**

Run: `cd server && go test ./...`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add server/main.go server/server_test.go
git commit -m "fix: a member cut off for falling behind is disconnected and can come back"
```

---

### Task 6: The engine travels compressed

**Files:**
- Modify: `server/main.go`, `Dockerfile`, `tools/image.sh`, `README.md`
- Test: `server/server_test.go`

**Interfaces:**
- Produces: `precompressed(dir string, next http.Handler) http.Handler`.

Closes: the first visit carrying four times the bytes it needs. `index.wasm` is 39.5 MB, 10 MB in gzip, and `http.FileServer` knows no `Content-Encoding`. Neither nginx nor Caddy compresses by default either. The twins are made once, at image build, rather than per visitor.

- [x] **Step 1: Write the failing test**

In `server/server_test.go`, add `"compress/gzip"` to the imports, and at the end:

```go
func TestTheEngineIsServedCompressedToABrowserThatAcceptsIt(t *testing.T) {
	// The engine is forty megabytes and ten in gzip: served plain, every first
	// visit carries four times what it needs.
	dir := writeStatic(t)
	var packed bytes.Buffer
	zw := gzip.NewWriter(&packed)
	zw.Write([]byte("not-a-real-wasm"))
	zw.Close()
	if err := os.WriteFile(dir+"/index.wasm.gz", packed.Bytes(), 0o644); err != nil {
		t.Fatalf("file was not written: %v", err)
	}
	addr, stop := startServerWithStatic(t, dir)
	defer stop()

	// Our own transport, or Go would ask for gzip and unpack it behind our back.
	client := &http.Client{Transport: &http.Transport{DisableCompression: true}}
	request, _ := http.NewRequest(http.MethodGet, "http://"+addr+"/index.wasm", nil)
	request.Header.Set("Accept-Encoding", "gzip, deflate, br")
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("the engine was not served: %v", err)
	}
	defer response.Body.Close()
	if response.Header.Get("Content-Encoding") != "gzip" {
		t.Fatal("a browser that accepts gzip got the engine uncompressed")
	}
	// Streaming compilation of wasm demands exactly this type.
	if kind := response.Header.Get("Content-Type"); kind != "application/wasm" {
		t.Fatalf("the engine came as %q", kind)
	}
	unpacked, err := gzip.NewReader(response.Body)
	if err != nil {
		t.Fatalf("the body is not gzip: %v", err)
	}
	if body, _ := io.ReadAll(unpacked); string(body) != "not-a-real-wasm" {
		t.Fatalf("the twin unpacks to %q", body)
	}

	plain, _ := http.NewRequest(http.MethodGet, "http://"+addr+"/index.wasm", nil)
	answer, err := client.Do(plain)
	if err != nil {
		t.Fatalf("the engine was not served plain: %v", err)
	}
	defer answer.Body.Close()
	if body, _ := io.ReadAll(answer.Body); string(body) != "not-a-real-wasm" {
		t.Fatalf("a client without gzip got %q", body)
	}
}
```

- [x] **Step 2: Run it and make sure it fails**

Run: `cd server && go test -run TestTheEngineIsServedCompressedToABrowserThatAcceptsIt ./...`
Expected: FAIL — "a browser that accepts gzip got the engine uncompressed".

- [x] **Step 3: Serve the twins in `server/main.go`**

Imports gain `"mime"`, `"path"`, `"path/filepath"`. In `routes`:

```go
		mux.Handle("/", noCacheIndex(precompressed(static, http.FileServer(http.Dir(static)))))
```

After `noCacheIndex`:

```go
// precompressed hands out a gzipped twin of a file when there is one and the
// browser accepts it. The twins are made once, when the image is built:
// compressing forty megabytes per visitor would redo the same work every time.
// A file without a twin, or a client without gzip, gets the original.
func precompressed(dir string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := path.Clean("/" + r.URL.Path)
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") || strings.HasSuffix(name, "/") {
			next.ServeHTTP(w, r)
			return
		}
		twin := filepath.Join(dir, filepath.FromSlash(name)) + ".gz"
		info, err := os.Stat(twin)
		if err != nil || info.IsDir() {
			next.ServeHTTP(w, r)
			return
		}
		// The type is the original's: left to itself the file server would name
		// the twin's own, and a browser compiling wasm as it streams insists on
		// application/wasm.
		kind := mime.TypeByExtension(path.Ext(name))
		if kind == "" {
			kind = "application/octet-stream"
		}
		w.Header().Set("Content-Type", kind)
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Add("Vary", "Accept-Encoding")
		http.ServeFile(w, r, twin)
	})
}
```

- [x] **Step 4: Run the server tests**

Run: `cd server && go test ./...`
Expected: PASS.

- [x] **Step 5: Make the twins in the image**

In `Dockerfile`, in the `game` stage after the `test -f` check:

```dockerfile
# The engine is forty megabytes and ten in gzip. Compressed once here rather than per
# visitor: the server hands the twin to a browser that accepts gzip, the original to
# anyone else.
RUN for f in /web/*.wasm /web/*.pck /web/*.js; do gzip -9 -c "$f" > "$f.gz"; done
```

In `tools/image.sh`, after `echo "the game page is served"`:

```bash
      if ! curl -fsS -o /dev/null -D - -H 'Accept-Encoding: gzip' \
          http://127.0.0.1:27099/index.wasm | grep -qi '^content-encoding: gzip'; then
        echo "ERROR: the engine is served uncompressed"
        exit 1
      fi
      echo "the engine is served compressed"
```

In `README.md`, "Deployment image", after the paragraph about `scratch`:

```markdown
The engine is forty megabytes and ten in gzip. The image carries a gzipped twin of each
large file, made at build time, and the server hands it to any browser that accepts gzip.
The proxy in front need not compress anything.
```

- [x] **Step 6: Check the image for real**

Run: `./tools/image.sh`
Expected: the tests, the web build, the image, then `the game page is served` and `the engine is served compressed`.

- [x] **Step 7: Commit**

```bash
git add server/main.go server/server_test.go Dockerfile tools/image.sh README.md
git commit -m "feat: the engine travels gzipped, four times lighter on the first visit"
```

---

### Task 7: The client does not hoard input from the far future

**Files:**
- Modify: `game/net/net_input.gd`
- Test: `game/tests/net/test_net_input.gd`

**Interfaces:**
- Produces: `NetInput.FARTHEST_AHEAD`.

Closes: a partner — any stranger in a quick game — or a hostile server swelling the client's memory until the game stalls. `Lockstep.submit_remote` accepts any tick up to two billion, and `forget_before` only forgets the past, so input for future ticks stays forever. It also stalls before it runs out of memory: `forget_before` walks every key on every tick.

An honest partner is never more than both input delays ahead — they cannot compute a tick without our input for it, and ours runs at most `MAX_DELAY` ahead. `Lockstep.KEEP` already bounds the buffer's past; the same number bounds its future.

- [x] **Step 1: Write the failing test**

At the end of `game/tests/net/test_net_input.gd`:

```gdscript
func test_input_for_a_tick_far_ahead_is_dropped() -> void:
	# An honest partner is never further ahead than both input delays: they
	# cannot compute a tick without our input for it. A packet for tick two
	# billion would sit in the buffer forever, and a stream of them grows it until
	# the game stalls.
	var before: int = input._lockstep._remote.size()
	input.handle_packet(Protocol.pack_input(2000000000, Types.IN_FIRE))
	input.handle_packet(Protocol.pack_input(NetInput.FARTHEST_AHEAD + 1, Types.IN_FIRE))
	assert_eq(input._lockstep._remote.size(), before, "input from the far future was kept")
	assert_lt(input._lockstep.cover(0), NetInput.FARTHEST_AHEAD,
		"a dropped packet must not count as input the game can rest on")
	input.handle_packet(Protocol.pack_input(NetInput.FARTHEST_AHEAD, Types.IN_FIRE))
	assert_eq(input._lockstep._remote.size(), before + 1, "input within reach was dropped")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path game -s addons/gut/gut_cmdln.gd -gtest=res://tests/net/test_net_input.gd -gexit`
Expected: FAIL — `FARTHEST_AHEAD` does not exist.

- [x] **Step 3: Drop what no honest partner could send**

In `game/net/net_input.gd`, after `STALLS_BEFORE_GROWING`:

```gdscript
## How far ahead of our last computed tick the partner's input may be. An honest
## partner is never further than both input delays together: they cannot compute
## a tick without our input for it, and ours runs at most MAX_DELAY ahead.
## Lockstep.KEEP bounds the buffer's past; the same number bounds its future.
## Without it a packet for tick two billion sits in the buffer for good, and a
## stream of them stalls the game: forget_before walks every key on every tick.
const FARTHEST_AHEAD := Lockstep.KEEP
```

In `handle_packet`:

```gdscript
		Protocol.Kind.INPUT:
			if packet["tick"] > _last_tick + FARTHEST_AHEAD:
				return
			_lockstep.submit_remote(packet["tick"], packet["bits"])
```

- [x] **Step 4: Run everything**

Run: `./tools/test.sh`
Expected: all green, including the two-sided relay match and the growing-delay tests.

- [x] **Step 5: Commit**

```bash
git add game/net/net_input.gd game/tests/net/test_net_input.gd
git commit -m "fix: input for ticks no honest partner could reach is dropped"
```

---

### Task 8: A public page does not take a server from its query

**Files:**
- Modify: `game/platform/relay_config.gd`, `README.md`
- Test: `game/tests/platform/test_relay_config.gd`

Closes: a link that sends a player's game somewhere else. `https://<our domain>/?relay=wss://evil/ws` opened our page, with our address in the bar, and connected the game to the link's server — which then feeds the client whatever it likes. The parameter exists for a developer pointing a local page at another server without rebuilding, so it stays for pages on one's own machine.

- [x] **Step 1: Write the failing test**

In `game/tests/platform/test_relay_config.gd`, after `test_page_query_can_point_elsewhere` (whose comment becomes "Checking a page on one's own machine against somebody else's server"):

```gdscript
func test_a_public_page_ignores_the_query() -> void:
	# A link to our own page must not send the game somewhere else: the address
	# bar would show us while the server is the link's.
	assert_eq(RelayConfig.from_page(
		"https://base13.example/?relay=wss%3A%2F%2Fevil.example%2Fws"),
		"wss://base13.example/ws")

func test_a_local_page_still_takes_the_query() -> void:
	assert_eq(RelayConfig.from_page(
		"http://127.0.0.1:8000/?relay=ws%3A%2F%2Fhost%3A8080%2Fws"),
		"ws://host:8080/ws")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path game -s addons/gut/gut_cmdln.gd -gtest=res://tests/platform/test_relay_config.gd -gexit`
Expected: FAIL — the public page returns the link's server.

- [x] **Step 3: Honour the parameter on one's own machine only**

In `from_page`, the tail from `var override` on becomes:

```gdscript
	var slash := rest.find("/")
	var host := rest.substr(0, slash) if slash >= 0 else rest
	if host == "":
		return DEFAULT
	# The parameter is for a developer's own machine: a local build pointed at
	# another server without rebuilding. On a public page it would let a link send
	# a player's game to any server, with our address still in the bar.
	var override := _query_value(query, "relay")
	if override != "" and _is_local(host):
		return override
	return scheme + host + PATH

static func _is_local(host: String) -> bool:
	var name := host
	var colon := name.rfind(":")
	if colon >= 0 and not name.ends_with("]"):
		name = name.substr(0, colon)
	return name == "localhost" or name == "127.0.0.1" or name == "[::1]"
```

- [x] **Step 4: The README**

In "Room server", the sentence about the page parameter becomes:

```markdown
A page parameter works for testing too, on a page opened from your own machine:
`?relay=ws://localhost:27014/ws`. A page served from anywhere else ignores it — otherwise a
link to the real site could send the game to any server it names.
```

- [x] **Step 5: Run everything**

Run: `./tools/test.sh`
Expected: all green.

- [x] **Step 6: Commit**

```bash
git add game/platform/relay_config.gd game/tests/platform/test_relay_config.gd README.md
git commit -m "fix: a public page no longer takes the server address from its query"
```

---

## Readiness

1. `./tools/test.sh` green, with the new Go and GUT tests.
2. `./tools/image.sh` builds the image and reports the engine served compressed.
3. The web build opens from the image in a browser, `?selftest` prints `SELFTEST OK 2233634213`, and the network tab shows `index.wasm` with `content-encoding: gzip`.
4. Then, and only then, the release in Task 3 of `docs/plans/2026-09-04-deployment.md`.

## What came out, 2026-09-12

All eight tasks are done, one commit each.

- `./tools/test.sh`: 409 GUT tests and 81 Go tests, green. The server tests also pass
  under `-race`, repeatedly.
- `./tools/image.sh`: the image builds at 80 MB — 20 more than before, which is what the
  gzipped twins weigh — comes up, serves the page, and answers a request that accepts
  gzip with a compressed engine.
- The image was run locally and opened in a browser: `?selftest` printed
  `SELFTEST OK 2233634213`, the same number as on desktop. Chrome always sends
  `Accept-Encoding: gzip`, so what booted there was the twin: 9.6 MB in place of 37.7.

One thing is honestly unresolved. The very first `-race` run failed once, and the test's
name was lost with the output. It did not come back: nine repeats of the six timing-
sensitive tests and several full runs are clean. The tightest of those tests was given
three times the slack it needs, but that is a precaution, not an explanation.
