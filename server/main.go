package main

// A relay of game rooms.
//
// The server does not compute the game and does not know its rules: it sees
// members, a room code and the order of packets. The clients compute the
// world, and by construction it is identical on both. Hence the main property:
// the same server suits any next game — it only needs a different name in the
// request.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// How long to wait for started requests to finish during shutdown.
const shutdownGrace = 5 * time.Second

// How often to report on the evenness of each member's packet stream.
const statsWindow = 5 * time.Second

// How often the server pings. Well inside nginx's default sixty seconds and
// Cloudflare's hundred: whatever stands in front never sees a silent link.
const defaultPingEvery = 20 * time.Second

// The client's first packet is housekeeping: it says what to do. After that
// the connection carries only game bytes, and the server never looks inside.
type hello struct {
	Action string `json:"action"` // create | join | quick
	Game   string `json:"game"`
	Code   string `json:"code"`
	Seed   uint32 `json:"seed"`
	Since  int    `json:"since"` // how many journal records the client already has
	// Where the client plays from and which release it is, as the client wrote
	// them. Older clients send neither. Folded into labels in greet and not
	// kept past it.
	Platform string `json:"platform"`
	Version  string `json:"version"`
}

// The answer to the housekeeping packet. After it, silence: everything else
// belongs to the game.
type welcome struct {
	OK      bool   `json:"ok"`
	Error   string `json:"error,omitempty"`
	Reason  string `json:"reason,omitempty"` // short marker for the client
	Code    string `json:"code,omitempty"`
	Slot    int    `json:"slot,omitempty"`
	Seed    uint32 `json:"seed,omitempty"`
	Replay  int    `json:"replay,omitempty"` // how many journal records follow
	Players int    `json:"players,omitempty"`
}

type server struct {
	hub *Hub
	// Live connections. The HTTP library does not track them: they were
	// hijacked away from it entirely, so only we can say goodbye at shutdown.
	mu    sync.Mutex
	conns map[*Conn]struct{}
	// The most connections held at once; zero means no cap. Two per room at
	// the room cap, plus headroom for those still saying hello.
	maxConns int
	// Zero means the defaults; tests shorten them.
	readIdle  time.Duration
	pingEvery time.Duration
	// Guards a render, not the numbers it reads — those have their own locks.
	// A burst of scrapers waits in line instead of each paying to build the
	// text from scratch at once; the zero value is already usable.
	metricsMu sync.Mutex
}

// remember reports whether there was room for one more connection.
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

func (s *server) forget(c *Conn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.conns, c)
}

// shutdown stops accepting and says goodbye to those already playing.
//
// A connection cut mid-sentence reads to the client as "the link is gone", and
// it spends half a minute knocking at a room that no longer exists after a
// restart. A farewell with code 1001 tells the truth: the server is leaving,
// there is nothing to wait for.
//
// Games are not saved by this: the journal lives in memory and leaves with the
// process. What is saved is clarity — a human sees an explanation instead of a
// frozen screen.
func (s *server) shutdown(httpServer *http.Server, listener net.Listener) {
	// We close the listener ourselves rather than rely on Shutdown: that one
	// closes only the listeners it already knows about, and there is a window
	// between starting Serve in a goroutine and the signal arriving. A signal
	// in that window, and the server would keep accepting players after being
	// told to stop.
	if listener != nil {
		listener.Close()
	}
	ctx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	// Shutdown does not touch hijacked connections and therefore does not wait
	// for them — we say goodbye to those ourselves.
	httpServer.Shutdown(ctx)

	s.mu.Lock()
	live := make([]*Conn, 0, len(s.conns))
	for c := range s.conns {
		live = append(live, c)
	}
	s.mu.Unlock()

	var wg sync.WaitGroup
	for _, c := range live {
		wg.Add(1)
		go func(c *Conn) {
			defer wg.Done()
			c.CloseWith(closeGoingAway, "restart")
		}(c)
	}
	wg.Wait()
	log.Printf("stopped, said goodbye to %d connections", len(live))
}

func main() {
	// The event log goes to standard output as a stream: storing and parsing it
	// is the job of whoever started the process, not of the program. It keeps
	// no files of its own.
	log.SetOutput(os.Stdout)

	// We do not read the flag values here: flag.Visit below collects them.
	// Reading here would also pick up the defaults, and those would override
	// the environment.
	flag.String("addr", "", "address or port; overrides ADDR and PORT")
	flag.String("static", "", "folder with the game files; overrides STATIC_DIR")
	flag.String("tls-cert", "", "certificate; overrides TLS_CERT")
	flag.String("tls-key", "", "certificate key; overrides TLS_KEY")
	flag.String("max-rooms", "", "how many rooms at most; overrides MAX_ROOMS")
	flag.String("metrics-addr", "", "address for the metrics listener; overrides METRICS_ADDR; empty disables it")
	flag.Parse()

	// Only the explicitly set ones: otherwise flag defaults would always beat
	// the environment, and the variables would be useless.
	given := map[string]string{}
	flag.Visit(func(f *flag.Flag) { given[f.Name] = f.Value.String() })
	cfg := settings(given, os.Getenv)

	// Checked before anything is opened: a setting that would put metrics on
	// the public port, or that carries too short a token, must stop the
	// process, not quietly come up unsafe.
	if cfg.MetricsAddr != "" {
		if err := metricsProblem(cfg); err != nil {
			log.Fatal(err)
		}
	}

	s := &server{hub: NewHub(), maxConns: 2*cfg.MaxRooms + 64}
	s.hub.limit = cfg.MaxRooms
	go s.sweepLoop()

	// Listen first, announce second: the other order printed "listening" and
	// then an address-in-use error, which is impossible to read.
	listener, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("rooms up to %d, connections up to %d", cfg.MaxRooms, s.maxConns)
	httpServer := newHTTPServer(s.routes(cfg.Static))
	go func() {
		var err error
		if secure(cfg) {
			err = httpServer.ServeTLS(listener, cfg.CertFile, cfg.KeyFile)
		} else {
			err = httpServer.Serve(listener)
		}
		if err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()
	scheme := "http"
	if secure(cfg) {
		scheme = "https"
	}
	if cfg.Static == "" {
		log.Printf("listening on %s (%s), relay only", listener.Addr(), scheme)
	} else {
		// Without HTTPS the web build does not start at all: Godot requires a
		// secure context, and only HTTPS and localhost qualify.
		log.Printf("listening on %s (%s), game files from %s", listener.Addr(), scheme, cfg.Static)
		if !secure(cfg) {
			log.Print("without a certificate the game opens only over localhost — " +
				"on another machine the browser refuses: Secure Context")
		}
	}

	var metricsServer *http.Server
	if cfg.MetricsAddr != "" {
		metricsListener, err := net.Listen("tcp", cfg.MetricsAddr)
		if err != nil {
			log.Fatal(err)
		}
		// metricsProblem already refused the configured addresses; this checks
		// what the two sockets actually bound to, so nothing they resolve to
		// — however either address was spelled — can put metrics on the
		// public port.
		if boundPortsCollide(listener.Addr(), metricsListener.Addr()) {
			listener.Close()
			metricsListener.Close()
			log.Fatalf("metrics bound to the public port %s; refusing to start", metricsListener.Addr())
		}
		metricsServer = newMetricsServer(s.metricsHandler(cfg.MetricsToken))
		go func() {
			if err := metricsServer.Serve(metricsListener); err != nil && err != http.ErrServerClosed {
				log.Fatal(err)
			}
		}()
		log.Printf("metrics on %s", metricsListener.Addr())
		if !loopbackAddr(cfg.MetricsAddr) && cfg.MetricsToken == "" {
			log.Print("metrics listen beyond this machine with no token set — " +
				"anyone who can reach that address reads the server's state")
		}
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	log.Printf("stopping on signal: %s", <-stop)
	s.shutdown(httpServer, listener)
	if metricsServer != nil {
		metricsServer.Close()
	}
}

// Empty rooms live on for a while after the last member leaves, so that
// whoever dropped out has somewhere to return to.
func (s *server) sweepLoop() {
	for range time.Tick(time.Minute) {
		if removed := s.hub.Sweep(time.Now()); removed > 0 {
			log.Printf("swept empty rooms: %d, %d remain", removed, s.hub.Count())
		}
	}
}

// routes assembles every path of the server. Kept apart from main because
// tests exercise them: standing the whole server up is cheaper than guessing
// whether the paths have drifted.
//
// One port for everything, and not to save ports: the browser derives the
// socket address from the page address, so a single origin means there is
// nothing to configure in the client at all.
func (s *server) routes(static string) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    true,
			"rooms": s.hub.Count(),
		})
	})
	if static != "" {
		mux.Handle("/", noCacheIndex(precompressed(static, http.FileServer(http.Dir(static)))))
	}
	return mux
}

// precompressed hands out a gzipped twin of a file when there is one and the
// browser accepts it. The twins are made once, when the image is built:
// compressing forty megabytes per visitor would redo the same work every time,
// and neither of the two proxies people put in front does it by default. A file
// without a twin, or a client that did not ask for gzip, gets the original.
func precompressed(dir string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := path.Clean("/" + r.URL.Path)
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") ||
			strings.HasSuffix(name, "/") {
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

// noCacheIndex forbids caching the page itself and only it. Godot's files
// carry no fingerprint in their names, so a cached index.html would mean an
// updated game never reaches the player at all. Everything else only benefits
// from caching: the names are stable and the files are large.
func noCacheIndex(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" || strings.HasSuffix(r.URL.Path, "/index.html") {
			w.Header().Set("Cache-Control", "no-cache")
		}
		next.ServeHTTP(w, r)
	})
}

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
				// The queue closes in two cases: the member left, and the
				// socket is going anyway; or the room cut them off for falling
				// behind. In the second an open socket would carry nothing ever
				// again, and they would sit watching a frozen picture. Closed,
				// it is an ordinary drop: the client comes back by code and
				// catches up from the journal.
				conn.Close()
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

func (s *server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := Accept(w, r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	// Counted before the cap is checked: a connection refused for the cap was
	// still opened, and the two together say how hard the cap is being hit.
	s.hub.stats.connectionOpened()
	if s.readIdle > 0 {
		conn.readIdle = s.readIdle
	}
	defer conn.Close()
	if !s.remember(conn) {
		// On the wire the same "busy" a full hub sends: the client has nothing
		// different to do about either.
		s.refuse(conn, "connections_limit", errServerBusy.Error(), reasonCode(errServerBusy))
		return
	}
	defer s.forget(conn)

	room, member, err := s.greet(conn, r)
	if err != nil {
		return
	}
	defer func() {
		room.Leave(member)
		room.Notify(member, event("left", room.Occupants()))
		log.Printf("room %s: %s left, %d remain, journal %d records",
			room.Code, slotName(member.Slot), room.Occupants(), room.JournalLength())
	}()
	room.Notify(member, event("joined", room.Occupants()))

	go pump(conn, member, s.pingInterval())

	// Stream evenness is measured here: the server sees both sides and can say
	// whose channel is breaking up without asking anyone. In lockstep a frozen
	// frame is born from a gap between packets, so we watch the worst gap
	// rather than the average.
	var flow arrivals
	window := time.Now()
	for {
		packet, err := conn.ReadMessage()
		if err != nil {
			s.hub.stats.disconnected(classifyEnd(err))
			return
		}
		now := time.Now()
		flow.note(now)
		if now.Sub(window) >= statsWindow {
			log.Printf("room %s, slot %d: %.0fs, %d packets, worst gap %v",
				room.Code, member.Slot, now.Sub(window).Seconds(),
				flow.count(), flow.worstGap().Round(time.Millisecond))
			flow.forget()
			window = now
		}
		room.Broadcast(member, packet)
	}
}

// greet parses the housekeeping packet, seats the client in a room and, if
// they are returning, sends the missed tail of the journal after.
func (s *server) greet(conn *Conn, r *http.Request) (*Room, *Member, error) {
	raw, err := conn.ReadMessage()
	if err != nil {
		return nil, nil, err
	}
	// Each refusal below names the reason it is counted under right where it is
	// made. The error greet returns cannot be trusted with that: a hello with no
	// game and one with an unknown action both return errNoSuchRoom, the same
	// as a code nobody opened.
	var request hello
	if err := json.Unmarshal(raw, &request); err != nil {
		s.refuse(conn, "bad_hello", "first packet could not be parsed", "bad_hello")
		return nil, nil, err
	}
	if request.Game == "" {
		request.Game = r.URL.Query().Get("game")
	}
	if request.Game == "" {
		s.refuse(conn, "bad_hello", "no game given", "bad_hello")
		return nil, nil, errNoSuchRoom
	}

	// Labelled here, once: nothing past this point sees what the client wrote.
	who := client{platform: platformLabel(request.Platform), version: versionLabel(request.Version)}

	var room *Room
	var member *Member
	switch request.Action {
	case "create":
		room, err = s.hub.Create(request.Game, request.Seed)
	case "join":
		room, err = s.hub.Find(request.Game, request.Code)
	case "quick":
		// Matchmaking seats the player itself: searching and seating cannot be
		// separate, or two people pressing the button in the same instant find
		// one room and one of them gets refused.
		room, member, err = s.hub.QuickAs(request.Game, request.Seed, who)
	default:
		s.refuse(conn, "bad_hello", "unknown action", "bad_hello")
		return nil, nil, errNoSuchRoom
	}
	if err != nil {
		log.Printf("refused (%s): %s", request.Action, err)
		s.refuse(conn, refusalReason(err), err.Error(), reasonCode(err))
		return nil, nil, err
	}

	if member == nil {
		member, err = room.JoinAs(who)
		if err != nil {
			// A room found by its code has only one way to turn a member away:
			// both seats are taken.
			s.refuse(conn, "full", err.Error(), reasonCode(err))
			return nil, nil, err
		}
	}

	// The journal tail is computed before the answer: between the answer and
	// the follow-up, new packets could arrive in the room, and the client
	// would receive them twice.
	tail, tailErr := room.JournalSince(request.Since, member.Slot)
	if tailErr != nil {
		tail = nil
	}

	kind := "private"
	if room.Public {
		kind = "public"
	}
	if request.Since > 0 {
		log.Printf("room %s (%s): %s returned, sending %d records, %d in room",
			room.Code, kind, slotName(member.Slot), len(tail), room.Occupants())
	} else {
		log.Printf("room %s (%s, game %s): %s joined, %d in room",
			room.Code, kind, request.Game, slotName(member.Slot), room.Occupants())
	}

	answer := welcome{
		OK:      true,
		Code:    room.Code,
		Slot:    member.Slot,
		Seed:    room.Seed,
		Replay:  len(tail),
		Players: room.Occupants(),
	}
	body, _ := json.Marshal(answer)
	if err := conn.WriteText(body); err != nil {
		room.Leave(member)
		return nil, nil, err
	}
	for _, packet := range tail {
		if err := conn.WriteMessage(packet); err != nil {
			room.Leave(member)
			return nil, nil, err
		}
	}

	// Counted only now: a player whose welcome or catch-up never went out did
	// not sit down to play. Coming back by code is a join to the room, but a
	// return to whoever reads the count — a flaky link would otherwise pass for
	// new players arriving.
	action := request.Action
	if action == "join" && request.Since > 0 {
		action = "return"
	}
	s.hub.stats.seated(action, member.client.platform)
	return room, member, nil
}

// refuse answers with a refusal and says goodbye. The reason it is counted
// under is a parameter, not something worked out here, so that no refusal can
// be made without naming one; the code is what the client is told, and several
// reasons share one code.
func (s *server) refuse(conn *Conn, reason, explanation, code string) {
	s.hub.stats.refused(reason)
	body, _ := json.Marshal(welcome{OK: false, Error: explanation, Reason: code})
	conn.WriteText(body)
	conn.CloseWith(closePolicy, code)
	conn.drain()
}

// refusalReason names the counted reason for an error the hub refused with.
// Only for the hub's own answers: greet's returned error is not one of them.
func refusalReason(err error) string {
	switch err {
	case errServerBusy:
		return "rooms_limit"
	case errNoSuchRoom:
		return "no_room"
	case errRoomFull:
		return "full"
	}
	return "other"
}

// classifyEnd names how a seated player's connection ended, from the error its
// read loop ended with.
//
// A broken protocol is checked first: its explanation wraps the sentinel, and
// an error carrying it is that whatever else it carries. The other side's
// goodbye is the bare errClosed a close frame produces — the reader closes the
// socket itself in answer, but returns the goodbye, not the closed socket. A
// timeout is the read deadline running out on a silent peer. A closed network
// connection is our own side: the room cut off a member who fell behind, or a
// write to them failed. Anything else — the end of the stream, a reset — is a
// peer that went away without a word.
func classifyEnd(err error) string {
	var netErr net.Error
	switch {
	case errors.Is(err, errProtocol):
		return "protocol"
	case errors.Is(err, errClosed):
		return "goodbye"
	case errors.Is(err, os.ErrDeadlineExceeded),
		errors.As(err, &netErr) && netErr.Timeout():
		return "idle"
	case errors.Is(err, net.ErrClosed):
		return "cut"
	}
	return "lost"
}

// newHTTPServer is the listening side main runs. Kept apart so the tests stand
// up exactly what production does.
//
// Without the timeouts a connection that sends half a request line and then
// nothing holds a goroutine and a descriptor for as long as the sender likes.
// No write timeout: a slow player downloading the engine is not an attack.
// Hijacked sockets set their own deadlines.
func newHTTPServer(handler http.Handler) *http.Server {
	return &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
}

// newMetricsServer is the metrics listener's own http.Server: its own
// timeouts, its own handler, never http.DefaultServeMux. It answers one
// scraper at a time, not a stream of hijacked sockets, so every timeout is
// shorter than the public server's.
func newMetricsServer(handler http.Handler) *http.Server {
	return &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
}

// metricsHandler answers exactly GET /metrics, with an optional bearer token.
// Nothing else lives on this listener — no pprof, no health check — so every
// other path and method is refused rather than routed.
func (s *server) metricsHandler(token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/metrics" {
			http.NotFound(w, r)
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if token != "" && !validMetricsToken(r.Header.Get("Authorization"), token) {
			w.Header().Set("WWW-Authenticate", "Bearer")
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		// One render at a time: a burst of scrapers pays for one buffer
		// instead of each building the whole text at once. The lock covers
		// only the render, in its own function so a deferred unlock still
		// fires if writeMetrics panics: held across the write below, a slow
		// reader on the other end would keep every other scrape waiting for
		// as long as WriteTimeout.
		var buf bytes.Buffer
		func() {
			s.metricsMu.Lock()
			defer s.metricsMu.Unlock()
			s.writeMetrics(&buf)
		}()
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(buf.Len()))
		w.Write(buf.Bytes())
	})
}

// validMetricsToken reports whether the request carries the configured
// bearer token. Compared as sha256 sums through subtle.ConstantTimeCompare
// rather than the raw strings, so neither a timing difference nor the
// comparison's own short-circuit on length leaks how much of the token a
// guess got right.
func validMetricsToken(header, token string) bool {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return false
	}
	got := sha256.Sum256([]byte(strings.TrimPrefix(header, prefix)))
	want := sha256.Sum256([]byte(token))
	return subtle.ConstantTimeCompare(got[:], want[:]) == 1
}

// loopbackAddr reports whether an address's host reaches only this machine.
// Empty, "0.0.0.0" and "::" bind every interface and are not loopback;
// "localhost" and the 127.0.0.0/8 and ::1 addresses are.
func loopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// boundPortsCollide reports whether two listening addresses ended up on the
// same port, whatever host each carries. Checked against what the sockets
// actually bound to rather than the configured strings, so it cannot be
// fooled by a spelling neither metricsProblem nor a human anticipated.
func boundPortsCollide(a, b net.Addr) bool {
	ta, ok := a.(*net.TCPAddr)
	if !ok {
		return false
	}
	tb, ok := b.(*net.TCPAddr)
	if !ok {
		return false
	}
	return ta.Port == tb.Port
}

// event is a housekeeping message saying the room's occupancy changed.
func event(name string, players int) []byte {
	body, _ := json.Marshal(map[string]any{"event": name, "players": players})
	return body
}

// Handy in logs and tests: the slot number reads as a human would say it.
func slotName(slot int) string {
	return "player " + strconv.Itoa(slot+1)
}
