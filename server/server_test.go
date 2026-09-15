package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

// A real connection to a real server: handshake, housekeeping packet,
// relaying. The whole conversation is exercised, not pieces of it.

// wsClient is the test's own end of a socket. Not named client: that name
// belongs to the server's record of what a player's hello said about them.
type wsClient struct {
	conn   net.Conn
	reader *bufio.Reader
}

// dial connects and completes the handshake. The socket is closed when the test
// ends, and not before. A client the test stops mentioning is still a player in
// a room: left to the garbage collector, its socket's finalizer closes it
// mid-test, the server sees the player leave and frees the seat, and the test
// then fails on a state it never set up — a third let into a full room, a
// returning guest seated in the host's slot, a waiter's room gone. The cleanup
// holds the socket until the end, so every client lives exactly as long as its
// test.
func dial(t *testing.T, url string) *wsClient {
	t.Helper()
	conn, err := net.Dial("tcp", url)
	if err != nil {
		t.Fatalf("could not connect: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	var nonce [16]byte
	rand.Read(nonce[:])
	key := base64.StdEncoding.EncodeToString(nonce[:])
	request := "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n" +
		"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n\r\n"
	conn.Write([]byte(request))

	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatalf("handshake reply could not be read: %v", err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("server did not upgrade to WebSocket: %d", response.StatusCode)
	}
	if response.Header.Get("Sec-WebSocket-Accept") != acceptKey(key) {
		t.Fatal("handshake acceptance did not match")
	}
	return &wsClient{conn: conn, reader: reader}
}

func (c *wsClient) send(t *testing.T, payload []byte) {
	t.Helper()
	if _, err := c.conn.Write(clientFrame(opBinary, payload)); err != nil {
		t.Fatalf("send failed: %v", err)
	}
}

func (c *wsClient) sendJSON(t *testing.T, value any) {
	t.Helper()
	body, _ := json.Marshal(value)
	c.send(t, body)
}

// receive returns the next game packet, skipping housekeeping messages.
func (c *wsClient) receive(t *testing.T) []byte {
	t.Helper()
	for {
		opcode, payload := c.receiveFrame(t)
		if opcode == opBinary {
			return payload
		}
	}
}

// receiveText returns the next housekeeping message.
func (c *wsClient) receiveText(t *testing.T) []byte {
	t.Helper()
	for {
		opcode, payload := c.receiveFrame(t)
		if opcode == opText {
			return payload
		}
	}
}

// receiveFrame reads one frame from the server; the server does not mask.
func (c *wsClient) receiveFrame(t *testing.T) (byte, []byte) {
	t.Helper()
	c.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var head [2]byte
	if _, err := c.reader.Read(head[:1]); err != nil {
		t.Fatalf("no frame arrived: %v", err)
	}
	opcode := head[0] & 0x0F
	if _, err := c.reader.Read(head[1:]); err != nil {
		t.Fatalf("length did not arrive: %v", err)
	}
	length := uint64(head[1] & 0x7F)
	switch length {
	case 126:
		var ext [2]byte
		c.reader.Read(ext[:])
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		c.reader.Read(ext[:])
		length = binary.BigEndian.Uint64(ext[:])
	}
	payload := make([]byte, length)
	read := 0
	for read < int(length) {
		n, err := c.reader.Read(payload[read:])
		if err != nil {
			t.Fatalf("payload was not fully read: %v", err)
		}
		read += n
	}
	return opcode, payload
}

func (c *wsClient) welcome(t *testing.T) welcome {
	t.Helper()
	var answer welcome
	if err := json.Unmarshal(c.receiveText(t), &answer); err != nil {
		t.Fatalf("server reply could not be parsed: %v", err)
	}
	return answer
}

func startServer(t *testing.T) (addr string, stop func()) {
	t.Helper()
	s := &server{hub: NewHub()}
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	httpServer := &http.Server{Handler: mux}
	go httpServer.Serve(listener)
	return listener.Addr().String(), func() { httpServer.Close(); listener.Close() }
}

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

func TestConnectionsPastTheLimitAreRefused(t *testing.T) {
	// Idle sockets alone would use up the process's descriptors: a script opens
	// thousands and says nothing.
	s := &server{hub: NewHub(), maxConns: 3}
	addr, stop := serve(t, s)
	defer stop()
	// The three stay connected while the extra one knocks: dial holds each
	// socket until the test ends.
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

func TestCreateAndJoinByCode(t *testing.T) {
	addr, stop := startServer(t)
	defer stop()

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 12345})
	hostAnswer := host.welcome(t)
	if !hostAnswer.OK || len(hostAnswer.Code) != codeLength {
		t.Fatalf("room was not created: %+v", hostAnswer)
	}
	if hostAnswer.Slot != 0 {
		t.Fatalf("the creator must be first, got slot %d", hostAnswer.Slot)
	}

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: hostAnswer.Code})
	guestAnswer := guest.welcome(t)
	if !guestAnswer.OK {
		t.Fatalf("the guest did not get in: %s", guestAnswer.Error)
	}
	if guestAnswer.Slot != 1 {
		t.Fatalf("the guest must be second, got slot %d", guestAnswer.Slot)
	}
	// The creator sets the seed — otherwise the sides get different enemy
	// waves.
	if guestAnswer.Seed != 12345 {
		t.Fatalf("the guest got seed %d instead of 12345", guestAnswer.Seed)
	}
}

func TestPacketsTravelBetweenPlayers(t *testing.T) {
	addr, stop := startServer(t)
	defer stop()

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 1})
	code := host.welcome(t).Code

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	guest.welcome(t)

	host.send(t, []byte{2, 0, 0, 0, 0, 31})
	if got := guest.receive(t); !bytes.Equal(got, []byte{2, 0, 0, 0, 0, 31}) {
		t.Fatalf("the guest got the wrong thing: %v", got)
	}

	guest.send(t, []byte{2, 1, 0, 0, 0, 16})
	if got := host.receive(t); !bytes.Equal(got, []byte{2, 1, 0, 0, 0, 16}) {
		t.Fatalf("the host got the wrong thing: %v", got)
	}
}

func TestUnknownCodeIsAnsweredWithRefusal(t *testing.T) {
	addr, stop := startServer(t)
	defer stop()

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: "ZZZZZZ"})
	answer := guest.welcome(t)
	if answer.OK || answer.Error == "" {
		t.Fatalf("a foreign code must get a clear refusal: %+v", answer)
	}
	// The client draws with its own atlas font and cannot render arbitrary
	// text — it needs a short marker, not a human explanation.
	if answer.Reason != "no_room" {
		t.Fatalf("refusal marker %q instead of no_room", answer.Reason)
	}
}

func TestThirdPlayerIsRefused(t *testing.T) {
	addr, stop := startServer(t)
	defer stop()

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks"})
	code := host.welcome(t).Code
	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	guest.welcome(t)

	third := dial(t, addr)
	third.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	answer := third.welcome(t)
	if answer.OK {
		t.Fatal("a third must not be let into a room for two")
	}
	if answer.Reason != "full" {
		t.Fatalf("refusal marker %q instead of full", answer.Reason)
	}
}

func TestGarbageFirstPacketDoesNotCrashTheServer(t *testing.T) {
	addr, stop := startServer(t)
	defer stop()

	bad := dial(t, addr)
	bad.send(t, []byte{0xFF, 0x00, 0x13})
	if answer := bad.welcome(t); answer.OK {
		t.Fatal("garbage instead of a housekeeping packet must be refused")
	}

	// The server must keep working after somebody else's garbage.
	good := dial(t, addr)
	good.sendJSON(t, hello{Action: "create", Game: "tanks"})
	if answer := good.welcome(t); !answer.OK {
		t.Fatal("the server stopped accepting after a garbage packet")
	}
}

func TestReconnectReceivesOnlyTheMissingTail(t *testing.T) {
	addr, stop := startServer(t)
	defer stop()

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 7})
	code := host.welcome(t).Code

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	guest.welcome(t)

	// The host sends three packets; the guest saw them.
	for i := 0; i < 3; i++ {
		host.send(t, []byte{2, byte(i), 0, 0, 0, 0})
		guest.receive(t)
	}
	guest.conn.Close()

	// While the guest is away, two more packets arrive.
	for i := 3; i < 5; i++ {
		host.send(t, []byte{2, byte(i), 0, 0, 0, 0})
	}
	time.Sleep(100 * time.Millisecond)

	// The guest returns, saying they saw three records.
	back := dial(t, addr)
	back.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code, Since: 3})
	answer := back.welcome(t)
	if !answer.OK {
		t.Fatalf("returning failed: %s", answer.Error)
	}
	if answer.Replay != 2 {
		t.Fatalf("%d records promised instead of two", answer.Replay)
	}
	for i := 3; i < 5; i++ {
		got := back.receive(t)
		if got[1] != byte(i) {
			t.Fatalf("the catch-up stream delivered %v, expected packet %d", got, i)
		}
	}
}

func TestHealthReportsRoomCount(t *testing.T) {
	s := &server{hub: NewHub()}
	s.hub.Create("tanks", 1)
	recorder := httptest.NewRecorder()
	json.NewEncoder(recorder).Encode(map[string]any{"ok": true, "rooms": s.hub.Count()})
	var body map[string]any
	json.Unmarshal(recorder.Body.Bytes(), &body)
	if body["rooms"].(float64) != 1 {
		t.Fatalf("server status reports %v rooms", body["rooms"])
	}
}

func TestSlotNameIsReadable(t *testing.T) {
	if slotName(0) != "player 1" || slotName(1) != "player 2" {
		t.Fatal("slot names must read as a human would say them")
	}
}

func TestCreatorLearnsThatThePartnerArrived(t *testing.T) {
	// The creator sits on the waiting screen and cannot see the arrival: the
	// two sides have separate connections. Without this message the game would
	// never start.
	addr, stop := startServer(t)
	defer stop()

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 3})
	code := host.welcome(t).Code

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	guest.welcome(t)

	var notice map[string]any
	if err := json.Unmarshal(host.receiveText(t), &notice); err != nil {
		t.Fatalf("notice could not be parsed: %v", err)
	}
	if notice["event"] != "joined" || notice["players"].(float64) != 2 {
		t.Fatalf("the creator got the wrong thing: %v", notice)
	}
}

func TestGamePacketsAndNoticesDifferByFrameKind(t *testing.T) {
	addr, stop := startServer(t)
	defer stop()

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks"})
	code := host.welcome(t).Code
	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})

	// The welcome comes as text.
	if opcode, _ := guest.receiveFrame(t); opcode != opText {
		t.Fatalf("the welcome arrived as frame kind %d, text expected", opcode)
	}
	// A game packet comes as binary.
	guest.send(t, []byte{2, 0, 0, 0, 0, 31})
	host.receiveText(t) // first the notice about the guest arriving
	if opcode, _ := host.receiveFrame(t); opcode != opBinary {
		t.Fatalf("the game packet arrived as frame kind %d, binary expected", opcode)
	}
}

func TestRefusalIsFollowedByAProperGoodbye(t *testing.T) {
	// Tearing the socket down right after the refusal sends an RST, and the
	// refusal is lost with it: the client shows "no connection" instead of the
	// reason.
	addr, stop := startServer(t)
	defer stop()

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: "ZZZZZZ"})
	if answer := guest.welcome(t); answer.Reason != "no_room" {
		t.Fatalf("the wrong refusal arrived: %+v", answer)
	}
	opcode, payload := guest.receiveFrame(t)
	if opcode != opClose {
		t.Fatalf("a farewell must follow the refusal, got frame %d", opcode)
	}
	if len(payload) < 2 || binary.BigEndian.Uint16(payload[:2]) != closePolicy {
		t.Fatalf("wrong close code: %v", payload)
	}
}

func TestQuickBringsTwoStrangersTogether(t *testing.T) {
	// No code, no address: both pressed the same thing and ended up together.
	addr, stop := startServer(t)
	defer stop()

	first := dial(t, addr)
	first.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 606})
	waiting := first.welcome(t)
	if !waiting.OK {
		t.Fatalf("the first one did not start waiting: %s", waiting.Error)
	}
	if waiting.Slot != 0 {
		t.Fatalf("whoever waits first is player one, got slot %d", waiting.Slot)
	}
	if waiting.Players != 1 {
		t.Fatalf("one player is waiting, the server counted %d", waiting.Players)
	}

	second := dial(t, addr)
	second.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 909})
	matched := second.welcome(t)
	if !matched.OK {
		t.Fatalf("the second one was not matched: %s", matched.Error)
	}
	if matched.Slot != 1 {
		t.Fatalf("the matched one is player two, got slot %d", matched.Slot)
	}
	if matched.Code != waiting.Code {
		t.Fatalf("ended up in different rooms: %q and %q", matched.Code, waiting.Code)
	}
	// Whoever waits first sets the seed — otherwise the sides get different
	// enemy waves.
	if matched.Seed != 606 {
		t.Fatalf("the matched one got seed %d instead of 606", matched.Seed)
	}

	// The waiter cannot see the arrival: their connections are separate.
	var notice map[string]any
	if err := json.Unmarshal(first.receiveText(t), &notice); err != nil {
		t.Fatalf("notice could not be parsed: %v", err)
	}
	if notice["event"] != "joined" {
		t.Fatalf("the waiter got the wrong thing: %v", notice)
	}
}

func TestQuickPlayersExchangePackets(t *testing.T) {
	addr, stop := startServer(t)
	defer stop()

	first := dial(t, addr)
	first.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 1})
	first.welcome(t)
	second := dial(t, addr)
	second.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 2})
	second.welcome(t)

	first.send(t, []byte{2, 5, 0, 0, 0, 31})
	if got := second.receive(t); !bytes.Equal(got, []byte{2, 5, 0, 0, 0, 31}) {
		t.Fatalf("the matched one got the wrong thing: %v", got)
	}
}

func TestQuickRoomIsAlsoReachableByItsCode(t *testing.T) {
	// Whoever dropped out returns by the code from the welcome — otherwise
	// reconnecting would work only for private rooms.
	addr, stop := startServer(t)
	defer stop()

	first := dial(t, addr)
	first.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 3})
	code := first.welcome(t).Code

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	if answer := guest.welcome(t); !answer.OK {
		t.Fatalf("a public room refused entry by its code: %s", answer.Error)
	}
}

// --- serving the game files ---

func startServerWithStatic(t *testing.T, dir string) (addr string, stop func()) {
	t.Helper()
	s := &server{hub: NewHub()}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	httpServer := &http.Server{Handler: s.routes(dir)}
	go httpServer.Serve(listener)
	return listener.Addr().String(), func() { httpServer.Close(); listener.Close() }
}

func writeStatic(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(dir+"/index.html", []byte("<b>BASE 13</b>"), 0o644); err != nil {
		t.Fatalf("file was not written: %v", err)
	}
	if err := os.WriteFile(dir+"/index.wasm", []byte("not-a-real-wasm"), 0o644); err != nil {
		t.Fatalf("file was not written: %v", err)
	}
	return dir
}

func TestStaticIsServedWhenAFolderIsGiven(t *testing.T) {
	addr, stop := startServerWithStatic(t, writeStatic(t))
	defer stop()

	response, err := http.Get("http://" + addr + "/")
	if err != nil {
		t.Fatalf("the page was not served: %v", err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if !bytes.Contains(body, []byte("BASE 13")) {
		t.Fatalf("the wrong thing was served: %q", body)
	}
}

func TestIndexIsNotCachedButTheRestIs(t *testing.T) {
	// Godot's files carry no fingerprint in their names: caching index.html
	// forever would mean an updated game never reaches the player at all.
	addr, stop := startServerWithStatic(t, writeStatic(t))
	defer stop()

	page, err := http.Get("http://" + addr + "/")
	if err != nil {
		t.Fatalf("the page was not served: %v", err)
	}
	page.Body.Close()
	if page.Header.Get("Cache-Control") == "" {
		t.Fatal("index.html must forbid caching explicitly")
	}

	wasm, err := http.Get("http://" + addr + "/index.wasm")
	if err != nil {
		t.Fatalf("the file was not served: %v", err)
	}
	wasm.Body.Close()
	if wasm.Header.Get("Cache-Control") != "" {
		t.Fatal("forbidding cache on the other files only hurts")
	}
}

func TestRelayKeepsWorkingBesideTheStatic(t *testing.T) {
	// One port for everything: the browser derives the socket address from the
	// page address.
	addr, stop := startServerWithStatic(t, writeStatic(t))
	defer stop()

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 11})
	if answer := host.welcome(t); !answer.OK {
		t.Fatalf("the relay does not work alongside the static files: %s", answer.Error)
	}

	health, err := http.Get("http://" + addr + "/health")
	if err != nil {
		t.Fatalf("status was not served: %v", err)
	}
	defer health.Body.Close()
	body, _ := io.ReadAll(health.Body)
	if !bytes.Contains(body, []byte(`"ok":true`)) {
		t.Fatalf("status answers the wrong thing: %q", body)
	}
}

func TestWithoutAFolderTheServerStaysAPureRelay(t *testing.T) {
	addr, stop := startServerWithStatic(t, "")
	defer stop()

	response, err := http.Get("http://" + addr + "/")
	if err != nil {
		t.Fatalf("the request did not go through: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("with no folder there is nothing to serve at /, got code %d", response.StatusCode)
	}

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks"})
	if answer := host.welcome(t); !answer.OK {
		t.Fatal("the relay must work without static files too")
	}
}

// --- shutdown ---

func TestShutdownSaysGoodbyeToEveryone(t *testing.T) {
	// A connection cut mid-sentence reads to the client as "the link is gone",
	// and it spends half a minute knocking at a room that no longer exists.
	// A farewell with code 1001 tells the truth: the server is leaving.
	s := &server{hub: NewHub()}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	httpServer := &http.Server{Handler: s.routes("")}
	go httpServer.Serve(listener)
	addr := listener.Addr().String()

	first := dial(t, addr)
	first.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 1})
	first.welcome(t)
	second := dial(t, addr)
	second.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 2})
	second.welcome(t)

	s.shutdown(httpServer, listener)

	for i, c := range []*wsClient{first, second} {
		// Before the farewell the player may have received occupancy notices —
		// skip them and look for the close frame itself.
		var payload []byte
		found := false
		for step := 0; step < 8 && !found; step++ {
			opcode, body := c.receiveFrame(t)
			if opcode == opClose {
				payload, found = body, true
			}
		}
		if !found {
			t.Fatalf("player %d never got the farewell", i+1)
		}
		if len(payload) < 2 || binary.BigEndian.Uint16(payload[:2]) != closeGoingAway {
			t.Fatalf("player %d got close code %v instead of going-away", i+1, payload)
		}
	}
}

func TestShutdownStopsAcceptingNewPlayers(t *testing.T) {
	s := &server{hub: NewHub()}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	httpServer := &http.Server{Handler: s.routes("")}
	go httpServer.Serve(listener)
	addr := listener.Addr().String()

	s.shutdown(httpServer, listener)

	if conn, err := net.DialTimeout("tcp", addr, time.Second); err == nil {
		conn.Close()
		t.Fatal("after shutdown the server keeps accepting connections")
	}
}

func TestArrivalStatsNoticeUnevenPackets(t *testing.T) {
	// An even stream and a ragged one differ not in packet count but in the
	// gaps between them. In lockstep it is the gap that turns into a frozen
	// frame, so the worst one is measured, not the average.
	var flow arrivals
	base := time.Unix(0, 0)
	for i := 0; i < 60; i++ {
		flow.note(base.Add(time.Duration(i) * 16 * time.Millisecond))
	}
	if got := flow.worstGap(); got > 20*time.Millisecond {
		t.Fatalf("an even stream reported a gap of %v", got)
	}

	var torn arrivals
	torn.note(base)
	torn.note(base.Add(16 * time.Millisecond))
	torn.note(base.Add(200 * time.Millisecond)) // a spike
	torn.note(base.Add(216 * time.Millisecond))
	if got := torn.worstGap(); got < 150*time.Millisecond {
		t.Fatalf("a ragged stream reported a gap of only %v", got)
	}
	if torn.count() != 4 {
		t.Fatalf("counted %d packets instead of four", torn.count())
	}
}

func TestServesOverTLSWhenGivenACertificate(t *testing.T) {
	// Without HTTPS the web build does not start at all: Godot requires a
	// secure context. So the server must be able to serve over TLS itself —
	// otherwise a second program is always needed in front of it.
	dir := t.TempDir()
	certPath, keyPath := writeSelfSigned(t, dir)

	s := &server{hub: NewHub()}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	httpServer := &http.Server{Handler: s.routes(writeStatic(t))}
	go httpServer.ServeTLS(listener, certPath, keyPath)
	defer func() { httpServer.Close(); listener.Close() }()

	client := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}}
	response, err := client.Get("https://" + listener.Addr().String() + "/health")
	if err != nil {
		t.Fatalf("no answer over TLS: %v", err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if !bytes.Contains(body, []byte(`"ok":true`)) {
		t.Fatalf("the wrong thing was served over TLS: %q", body)
	}
}

func TestTLSIsOnlyUsedWhenBothHalvesAreGiven(t *testing.T) {
	// A key without a certificate is a typo, not a setting. Quietly coming up
	// over plain HTTP would serve the game in the clear when the human asked
	// for the opposite.
	if secure(config{}) {
		t.Fatal("TLS must not switch on without a certificate")
	}
	if secure(config{CertFile: "a.pem"}) {
		t.Fatal("a certificate without a key is not a setting")
	}
	if secure(config{KeyFile: "b.pem"}) {
		t.Fatal("a key without a certificate is not a setting")
	}
	if !secure(config{CertFile: "a.pem", KeyFile: "b.pem"}) {
		t.Fatal("both halves given — TLS must be on")
	}
}

func writeSelfSigned(t *testing.T, dir string) (string, string) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("key was not created: %v", err)
	}
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "base13-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("certificate was not created: %v", err)
	}
	certPath := dir + "/cert.pem"
	keyPath := dir + "/key.pem"
	certOut, _ := os.Create(certPath)
	pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: der})
	certOut.Close()
	keyOut, _ := os.Create(keyPath)
	pem.Encode(keyOut, &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	keyOut.Close()
	return certPath, keyPath
}

// --- deadlines and pings ---

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
	// Compiling wasm as it streams demands exactly this type.
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

	// Whoever does not ask for gzip gets the original, not a packed file they
	// cannot read.
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

// --- counting connections and how they end ---

func TestRefusalsAreCountedByTheirOwnReason(t *testing.T) {
	// A refusal is counted under the reason named where it is made. Read back
	// from what greet returns it would be wrong twice over: a hello with no game
	// and one with an unknown action come back as the same "no room" error a
	// wrong code does, and both limits reach the client as the same "busy".
	s := &server{hub: NewHub(), maxConns: 4}
	s.hub.limit = 1
	addr, stop := serve(t, s)
	defer stop()

	want := map[string]float64{}
	check := func(step string) {
		t.Helper()
		for _, reason := range []string{"rooms_limit", "connections_limit", "full", "no_room", "bad_hello", "other"} {
			series := `relay_refusals_total{reason="` + reason + `"}`
			if got := metricValue(t, s, series); got != want[reason] {
				t.Errorf("after %s: %s is %v, expected %v", step, series, got, want[reason])
			}
		}
	}
	// refusedWith sends a first packet, expects a refusal with the given marker
	// on the wire, and hangs up at once: the server then lets go of the socket
	// now rather than after its farewell's linger.
	refusedWith := func(first []byte, marker string) {
		t.Helper()
		c := dial(t, addr)
		c.send(t, first)
		if answer := c.welcome(t); answer.OK || answer.Reason != marker {
			t.Fatalf("expected a refusal marked %q, got %+v", marker, answer)
		}
		c.conn.Close()
	}
	packet := func(h hello) []byte {
		body, _ := json.Marshal(h)
		return body
	}
	check("nothing at all")

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 5})
	code := host.welcome(t).Code
	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	if answer := guest.welcome(t); !answer.OK {
		t.Fatalf("the guest was refused: %+v", answer)
	}

	refusedWith(packet(hello{Action: "join", Game: "tanks", Code: code}), "full")
	want["full"] = 1
	check("a third knocking at a full room")

	refusedWith(packet(hello{Action: "join", Game: "tanks", Code: "ZZZZZZ"}), "no_room")
	want["no_room"] = 1
	check("a code nobody opened")

	refusedWith(packet(hello{Action: "create", Game: "tanks"}), "busy")
	want["rooms_limit"] = 1
	check("a room past the room limit")

	refusedWith([]byte{0xFF, 0x00, 0x13}, "bad_hello")
	refusedWith(packet(hello{Action: "create"}), "bad_hello")
	refusedWith(packet(hello{Action: "dance", Game: "tanks"}), "bad_hello")
	want["bad_hello"] = 3
	check("three hellos the server could not act on")

	// The cap on connections: the two seated ones and two that never say hello
	// fill it, and the fifth is refused before it is read at all.
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 2 })
	dial(t, addr)
	dial(t, addr)
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 4 })
	refusedWith(packet(hello{Action: "create", Game: "tanks"}), "busy")
	want["connections_limit"] = 1
	check("a connection past the connection limit")

	// A plain request to the socket path never became a connection, so it is
	// neither opened nor refused.
	response, err := http.Get("http://" + addr + "/ws")
	if err != nil {
		t.Fatalf("the plain request did not go through: %v", err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("a plain request to the socket path got %d", response.StatusCode)
	}
	check("a request that never upgraded")
	// Every upgrade is opened, refused or not: two seated, seven refused, two
	// that never said hello.
	if got := metricValue(t, s, "relay_connections_opened_total"); got != 11 {
		t.Errorf("relay_connections_opened_total is %v, expected 11", got)
	}
	checkExposition(t, renderMetrics(s))

	// Whatever else the hub may answer with has no reason of its own, and is
	// counted as other rather than dropped.
	for _, c := range []struct {
		err  error
		want string
	}{
		{errServerBusy, "rooms_limit"},
		{errNoSuchRoom, "no_room"},
		{errRoomFull, "full"},
		{errors.New("could not find a free code"), "other"},
	} {
		if got := refusalReason(c.err); got != c.want {
			t.Errorf("the hub's %q is counted as %q, expected %q", c.err, got, c.want)
		}
	}
}

func TestAGoodbyeIsCountedAsGoodbye(t *testing.T) {
	// A player who leaves on purpose sends a close frame, and the server closes
	// the socket itself in reply. Looked at only through the socket, that is our
	// own side cutting them off; the goodbye has to be told apart first, or every
	// ordinary exit reads as a cut.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()

	check := func(step string, want map[string]float64) {
		t.Helper()
		for _, cause := range []string{"goodbye", "idle", "lost", "cut", "protocol"} {
			series := `relay_disconnects_total{cause="` + cause + `"}`
			if got := metricValue(t, s, series); got != want[cause] {
				t.Errorf("after %s: %s is %v, expected %v", step, series, got, want[cause])
			}
		}
	}

	// Connections that never took a seat are not a player's connection ending:
	// one is a refusal, the other hung up before saying anything.
	silent := dial(t, addr)
	stranger := dial(t, addr)
	stranger.sendJSON(t, hello{Action: "join", Game: "tanks", Code: "ZZZZZZ"})
	stranger.welcome(t)
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 2 })
	silent.conn.Close()
	stranger.conn.Close()
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 0 })
	check("two that never sat down", nil)

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 9})
	code := host.welcome(t).Code
	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	guest.welcome(t)

	// 1000, a normal closure, as a browser sends when the page closes the socket.
	host.conn.Write(clientFrame(opClose, []byte{0x03, 0xE8}))
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 1 })
	check("the host said goodbye", map[string]float64{"goodbye": 1})

	// The partner hears that the host left, and then simply vanishes: no close
	// frame, only the end of the stream. The notice is read first so the server
	// has nothing left to write to a socket that is gone.
	guest.receiveText(t)
	guest.conn.Close()
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 0 })
	check("the guest vanished", map[string]float64{"goodbye": 1, "lost": 1})
	checkExposition(t, renderMetrics(s))
}

// tcpPair is a real socket pair on loopback: the client writes on the left, the
// server reads on the right. A pipe will not do where the error matters, because
// a pipe closed on our side reads back as a pipe error, not as the closed
// network connection a real socket reports.
func tcpPair(t *testing.T) (net.Conn, *Conn) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("no listener: %v", err)
	}
	defer listener.Close()
	client, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatalf("could not connect: %v", err)
	}
	raw, err := listener.Accept()
	if err != nil {
		t.Fatalf("could not accept: %v", err)
	}
	t.Cleanup(func() { client.Close(); raw.Close() })
	return client, &Conn{raw: raw, reader: bufio.NewReader(raw)}
}

// timeoutError is a timeout from some layer other than the socket's deadline.
type timeoutError struct{}

func (timeoutError) Error() string   { return "timed out" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }

func TestHowAConnectionEndedIsClassified(t *testing.T) {
	// The cause is read from the error a read really ends with, not from one
	// made up to match: a classifier shown only its own sentinels says nothing
	// about the sockets it will actually be handed.
	readEnd := func(t *testing.T, conn *Conn) error {
		t.Helper()
		ended := make(chan error, 1)
		go func() {
			_, err := conn.ReadMessage()
			ended <- err
		}()
		select {
		case err := <-ended:
			return err
		case <-time.After(2 * time.Second):
			t.Fatal("the read never ended")
			return nil
		}
	}
	unfinished := func(opcode byte, payload []byte) []byte {
		frame := clientFrame(opcode, payload)
		frame[0] &^= 0x80
		return frame
	}

	for _, c := range []struct {
		name string
		want string
		end  func(t *testing.T) error
	}{
		{"a close frame", "goodbye", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.Write(clientFrame(opClose, []byte{0x03, 0xE8}))
			return readEnd(t, server)
		}},
		{"silence past the read deadline", "idle", func(t *testing.T) error {
			_, server := tcpPair(t)
			server.readIdle = 20 * time.Millisecond
			return readEnd(t, server)
		}},
		{"a timeout from another layer", "idle", func(t *testing.T) error {
			return fmt.Errorf("reading: %w", timeoutError{})
		}},
		{"the other side hung up", "lost", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.Close()
			return readEnd(t, server)
		}},
		{"the other side hung up mid-frame", "lost", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.Write(clientFrame(opBinary, []byte{1, 2, 3, 4, 5, 6})[:5])
			client.Close()
			return readEnd(t, server)
		}},
		{"the other side reset the connection", "lost", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.(*net.TCPConn).SetLinger(0)
			client.Close()
			return readEnd(t, server)
		}},
		{"our side closed the socket under the read", "cut", func(t *testing.T) error {
			_, server := tcpPair(t)
			go func() {
				time.Sleep(20 * time.Millisecond)
				server.Close()
			}()
			return readEnd(t, server)
		}},
		{"a ping already buffered when our side closed", "cut", func(t *testing.T) error {
			// The reader still holds a ping it read before the socket was
			// closed, and answering it is what fails. That is our side's close
			// too, not a goodbye from theirs.
			left, right := net.Pipe()
			t.Cleanup(func() { left.Close() })
			conn := &Conn{raw: right, reader: bufio.NewReader(bytes.NewReader(clientFrame(opPing, nil)))}
			conn.Close()
			return readEnd(t, conn)
		}},
		{"a message stitched past the cap", "protocol", func(t *testing.T) error {
			client, server := tcpPair(t)
			piece := bytes.Repeat([]byte{1}, 300)
			client.Write(append(unfinished(opBinary, piece), clientFrame(opContinuation, piece)...))
			return readEnd(t, server)
		}},
		{"a frame past the cap", "protocol", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.Write([]byte{0x80 | opBinary, 0x80 | 127, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF})
			return readEnd(t, server)
		}},
		{"a control frame past 125 bytes", "protocol", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.Write(clientFrame(opPing, bytes.Repeat([]byte{1}, 126)))
			return readEnd(t, server)
		}},
		{"a control frame in pieces", "protocol", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.Write(unfinished(opPing, []byte("hey")))
			return readEnd(t, server)
		}},
		{"an unknown frame kind", "protocol", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.Write(clientFrame(0x3, []byte{1}))
			return readEnd(t, server)
		}},
		{"a protocol error wrapped once more", "protocol", func(t *testing.T) error {
			client, server := tcpPair(t)
			client.Write(clientFrame(0x3, []byte{1}))
			return fmt.Errorf("greeting: %w", readEnd(t, server))
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			err := c.end(t)
			if got := classifyEnd(err); got != c.want {
				t.Errorf("a read that ended with %v is counted as %q, expected %q", err, got, c.want)
			}
		})
	}
}

func TestSeatingsAreCountedByActionAndPlatform(t *testing.T) {
	// Who sits down to play, how, and from what. A seating is counted once the
	// welcome has gone out, so a refused knock is not one, and coming back by
	// code after a drop is told apart from joining for the first time.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()

	actions := []string{"create", "join", "quick", "return"}
	seatings := func(action, platform string) string {
		return `relay_seatings_total{action="` + action + `",platform="` + platform + `"}`
	}
	players := func(platform string) string {
		return `relay_players{platform="` + platform + `"}`
	}
	// Every combination from the very first scrape, zeros included: a series
	// that appears only when first counted breaks rate() across that moment.
	first := renderMetrics(s)
	checkExposition(t, first)
	for _, platform := range testPlatforms {
		for _, action := range actions {
			if got, found := seriesValue(first, seatings(action, platform)); !found || got != "0" {
				t.Errorf("before anyone sat down %s is %q (found %v)", seatings(action, platform), got, found)
			}
		}
		if got, found := seriesValue(first, players(platform)); !found || got != "0" {
			t.Errorf("before anyone sat down %s is %q (found %v)", players(platform), got, found)
		}
	}

	counted := map[string]float64{}
	live := map[string]float64{}
	check := func(step string) {
		t.Helper()
		for _, platform := range testPlatforms {
			for _, action := range actions {
				series := seatings(action, platform)
				if got := metricValue(t, s, series); got != counted[series] {
					t.Errorf("after %s: %s is %v, expected %v", step, series, got, counted[series])
				}
			}
			if got := metricValue(t, s, players(platform)); got != live[platform] {
				t.Errorf("after %s: %s is %v, expected %v", step, players(platform), got, live[platform])
			}
		}
	}
	// seated waits for a seating counted on the server's own goroutine: the
	// client may read its welcome before the count lands.
	seated := func(action, platform string) {
		t.Helper()
		counted[seatings(action, platform)]++
		want := counted[seatings(action, platform)]
		eventually(t, func() bool { return metricValue(t, s, seatings(action, platform)) == want })
	}

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 5, Platform: "macos", Version: "0.5.0"})
	code := host.welcome(t).Code
	seated("create", "macos")
	live["macos"] = 1
	check("the host opened a room")

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code, Platform: "web_ios", Version: "0.5.0"})
	if answer := guest.welcome(t); !answer.OK {
		t.Fatalf("the guest was refused: %+v", answer)
	}
	seated("join", "web_ios")
	live["web_ios"] = 1
	check("the guest joined by code")
	if got := metricValue(t, s, `relay_players_by_version{version="0.5.0"}`); got != 2 {
		t.Errorf(`relay_players_by_version{version="0.5.0"} is %v, expected 2`, got)
	}

	// Knocks the server refused sit nobody down.
	for _, knock := range []hello{
		{Action: "join", Game: "tanks", Code: code, Platform: "linux"},
		{Action: "join", Game: "tanks", Code: "ZZZZZZ", Platform: "windows"},
	} {
		c := dial(t, addr)
		c.sendJSON(t, knock)
		if answer := c.welcome(t); answer.OK {
			t.Fatalf("a knock that should have been refused was let in: %+v", answer)
		}
		c.conn.Close()
	}
	check("a knock at a full room and one at a code nobody opened")

	// The guest drops and comes back with part of the journal: a return, not a
	// second join.
	host.send(t, []byte{2, 0, 0, 0, 0, 0})
	guest.receive(t)
	guest.conn.Close()
	eventually(t, func() bool { return metricValue(t, s, players("web_ios")) == 0 })
	back := dial(t, addr)
	back.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code, Since: 1, Platform: "web_ios", Version: "0.5.0"})
	if answer := back.welcome(t); !answer.OK {
		t.Fatalf("the guest could not come back: %+v", answer)
	}
	seated("return", "web_ios")
	check("the guest came back")

	// Two strangers meet through the quick game; one names a platform the
	// server does not know.
	waiter := dial(t, addr)
	waiter.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 8, Platform: "android", Version: "0.5.0"})
	waiter.welcome(t)
	seated("quick", "android")
	stranger := dial(t, addr)
	stranger.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 9, Platform: "PlayStation", Version: "0.5.0"})
	stranger.welcome(t)
	seated("quick", "other")
	live["android"] = 1
	live["other"] = 1
	check("two strangers met through the quick game")

	// Leaving takes a player out of the live count and leaves the seatings as
	// they were: those are what happened, not who is here.
	waiter.conn.Close()
	stranger.conn.Close()
	eventually(t, func() bool {
		return metricValue(t, s, players("android")) == 0 && metricValue(t, s, players("other")) == 0
	})
	live["android"] = 0
	live["other"] = 0
	check("the strangers left")
	checkExposition(t, renderMetrics(s))
}

func TestAnOldClientCountsAsUnknown(t *testing.T) {
	// A client released before the hello named its platform and version sends
	// neither. It still plays: counted as unknown, not refused and not dropped
	// from the count.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()

	host := dial(t, addr)
	host.send(t, []byte(`{"action":"create","game":"tanks","seed":7}`))
	answer := host.welcome(t)
	if !answer.OK {
		t.Fatalf("an old client was refused: %+v", answer)
	}
	guest := dial(t, addr)
	guest.send(t, []byte(`{"action":"join","game":"tanks","code":"`+answer.Code+`"}`))
	if answer := guest.welcome(t); !answer.OK {
		t.Fatalf("an old client could not join: %+v", answer)
	}
	eventually(t, func() bool {
		return metricValue(t, s, `relay_seatings_total{action="join",platform="unknown"}`) == 1
	})
	for series, want := range map[string]float64{
		`relay_seatings_total{action="create",platform="unknown"}`: 1,
		`relay_seatings_total{action="join",platform="other"}`:     0,
		`relay_players{platform="unknown"}`:                        2,
		`relay_players{platform="other"}`:                          0,
		`relay_players_by_version{version="unknown"}`:              2,
		`relay_players_by_version{version="other"}`:                0,
	} {
		if got := metricValue(t, s, series); got != want {
			t.Errorf("%s is %v, expected %v", series, got, want)
		}
	}
	checkExposition(t, renderMetrics(s))

	// Seated without a hello at all, the way a bare Join seats one, a member is
	// unknown the same way.
	room, err := s.hub.Create("tanks", 1)
	if err != nil {
		t.Fatalf("no room: %v", err)
	}
	if _, err := room.Join(); err != nil {
		t.Fatalf("not seated: %v", err)
	}
	for series, want := range map[string]float64{
		`relay_players{platform="unknown"}`:           3,
		`relay_players_by_version{version="unknown"}`: 3,
	} {
		if got := metricValue(t, s, series); got != want {
			t.Errorf("with a member seated by a bare Join, %s is %v, expected %v", series, got, want)
		}
	}
}

func TestASeatingIsCountedOnlyOnceTheWelcomeWentOut(t *testing.T) {
	// A player whose welcome, or whose catch-up after it, could not be written
	// is let go again at once: they never sat down to play, and counting them
	// would turn a flaky link into players arriving.
	s := &server{hub: NewHub()}
	request := httptest.NewRequest(http.MethodGet, "/ws", nil)
	room, err := s.hub.Create("tanks", 1)
	if err != nil {
		t.Fatalf("no room: %v", err)
	}
	host, _ := room.JoinAs(client{platform: "web"})
	room.Broadcast(host, []byte{2, 0, 0, 0, 0, 0})
	room.Broadcast(host, []byte{2, 1, 0, 0, 0, 0})
	knock := func(platform string) []byte {
		body, _ := json.Marshal(hello{Action: "join", Game: "tanks", Code: room.Code, Platform: platform})
		return clientFrame(opBinary, body)
	}

	// Gone before the welcome: the pipe has nobody left to write to.
	far, conn := pipeConn(t)
	go func() {
		far.Write(knock("ios"))
		far.Close()
	}()
	if _, _, err := s.greet(conn, request); err == nil {
		t.Fatal("a welcome to a closed pipe was written")
	}

	// Gone after the welcome, before the two records owed to it.
	far, conn = pipeConn(t)
	go func() {
		far.Write(knock("android"))
		far.Read(make([]byte, 1024))
		far.Close()
	}()
	if _, _, err := s.greet(conn, request); err == nil {
		t.Fatal("a catch-up to a closed pipe was written")
	}

	if got := room.Occupants(); got != 1 {
		t.Errorf("%d in the room after two failed greetings, expected the host alone", got)
	}
	text := renderMetrics(s)
	for _, action := range []string{"create", "join", "quick", "return"} {
		for _, platform := range testPlatforms {
			series := `relay_seatings_total{action="` + action + `",platform="` + platform + `"}`
			if got, _ := seriesValue(text, series); got != "0" {
				t.Errorf("%s is %s after two greetings that never went out", series, got)
			}
		}
	}
}
