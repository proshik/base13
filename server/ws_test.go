package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestAcceptKeyMatchesTheStandardExample(t *testing.T) {
	// The example from RFC 6455: the client key and the server's expected reply.
	if got := acceptKey("dGhlIHNhbXBsZSBub25jZQ=="); got != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatalf("handshake diverged from the standard: %q", got)
	}
}

// A client frame: the client must mask, so a mask is always present here.
func clientFrame(opcode byte, payload []byte) []byte {
	var mask [4]byte
	rand.Read(mask[:])
	out := []byte{0x80 | opcode}
	switch {
	case len(payload) < 126:
		out = append(out, 0x80|byte(len(payload)))
	default:
		out = append(out, 0x80|126, 0, 0)
		binary.BigEndian.PutUint16(out[2:], uint16(len(payload)))
	}
	out = append(out, mask[:]...)
	for i, b := range payload {
		out = append(out, b^mask[i%4])
	}
	return out
}

// A pair of connections: the "client" writes on the left, the server reads
// on the right.
func pipeConn(t *testing.T) (client net.Conn, server *Conn) {
	t.Helper()
	a, b := net.Pipe()
	return a, &Conn{raw: b, reader: bufio.NewReader(b)}
}

func TestMaskedFrameIsUnmasked(t *testing.T) {
	client, server := pipeConn(t)
	payload := []byte{1, 2, 3, 4, 5, 6}
	go func() { client.Write(clientFrame(opBinary, payload)) }()

	got, err := server.ReadMessage()
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("payload diverged: %v against %v", got, payload)
	}
}

func TestLongFrameIsRead(t *testing.T) {
	client, server := pipeConn(t)
	payload := bytes.Repeat([]byte{7}, 500) // the length does not fit in seven bits
	go func() { client.Write(clientFrame(opBinary, payload)) }()

	got, err := server.ReadMessage()
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	if len(got) != len(payload) {
		t.Fatalf("length diverged: %d against %d", len(got), len(payload))
	}
}

func TestFragmentedMessageIsAssembled(t *testing.T) {
	client, server := pipeConn(t)
	go func() {
		// The first frame without the final bit, the continuation with it.
		first := clientFrame(opBinary, []byte{1, 2})
		first[0] &^= 0x80
		client.Write(first)
		client.Write(clientFrame(opContinuation, []byte{3, 4}))
	}()

	got, err := server.ReadMessage()
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	if !bytes.Equal(got, []byte{1, 2, 3, 4}) {
		t.Fatalf("reassembly is broken: %v", got)
	}
}

func TestPingIsAnsweredWithPong(t *testing.T) {
	client, server := pipeConn(t)
	go func() {
		client.Write(clientFrame(opPing, []byte("hey")))
		client.Write(clientFrame(opBinary, []byte{9}))
	}()

	done := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 64)
		n, _ := client.Read(buf)
		done <- buf[:n]
	}()

	got, err := server.ReadMessage()
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	if !bytes.Equal(got, []byte{9}) {
		t.Fatalf("a control frame must not surface: %v", got)
	}
	select {
	case answer := <-done:
		if len(answer) == 0 || answer[0]&0x0F != opPong {
			t.Fatalf("ping was not answered with pong: %v", answer)
		}
	case <-time.After(time.Second):
		t.Fatal("no answer to ping: intermediaries read that as a broken link")
	}
}

// serverFrame reads one frame the server wrote to the far end of a pipe. The
// server never masks, and every frame these tests read is short.
func serverFrame(r io.Reader) (byte, []byte, error) {
	var head [2]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return 0, nil, err
	}
	payload := make([]byte, head[1]&0x7F)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	return head[0] & 0x0F, payload, nil
}

// pingFrom makes the server ping and returns what the ping carried, as the far
// end of the pipe read it.
func pingFrom(t *testing.T, client net.Conn, server *Conn) []byte {
	t.Helper()
	type frame struct {
		opcode  byte
		payload []byte
		err     error
	}
	read := make(chan frame, 1)
	go func() {
		opcode, payload, err := serverFrame(client)
		read <- frame{opcode, payload, err}
	}()
	if err := server.Ping(); err != nil {
		t.Fatalf("the ping was not written: %v", err)
	}
	got := <-read
	if got.err != nil || got.opcode != opPing {
		t.Fatalf("the far end did not read a ping: opcode %d, %v", got.opcode, got.err)
	}
	return got.payload
}

// replyWith writes frames from the client's side and then one data message, and
// returns once the server has read up to that message: every frame before it
// has been handled by then.
func replyWith(t *testing.T, client net.Conn, server *Conn, frames ...[]byte) {
	t.Helper()
	go func() {
		for _, frame := range frames {
			if _, err := client.Write(frame); err != nil {
				return
			}
		}
		client.Write(clientFrame(opBinary, []byte{9}))
	}()
	got, err := server.ReadMessage()
	if err != nil {
		t.Fatalf("the connection did not survive the answer: %v", err)
	}
	if !bytes.Equal(got, []byte{9}) {
		t.Fatalf("a control frame surfaced as data: %v", got)
	}
}

// roundTrips collects the round trips a connection reports. It is called on the
// reading goroutine, the test's own, so a plain slice is enough.
func roundTrips(server *Conn) *[]time.Duration {
	var rtts []time.Duration
	server.onRTT = func(d time.Duration) { rtts = append(rtts, d) }
	return &rtts
}

func TestPongWithTheLastPingPayloadGivesRTT(t *testing.T) {
	// The server pings every connection anyway, and every client answers by
	// itself, echoing what the ping carried. A ping that carries the moment it
	// left comes back as a measurement of the network between the two, with
	// nothing asked of the client.
	client, server := pipeConn(t)
	defer client.Close()
	rtts := roundTrips(server)

	began := time.Now()
	payload := pingFrom(t, client, server)
	if len(payload) != 8 || binary.BigEndian.Uint64(payload) == 0 {
		t.Fatalf("a ping must carry eight bytes of a moment that is not zero, carried %v", payload)
	}
	time.Sleep(30 * time.Millisecond) // the way back takes a while
	replyWith(t, client, server, clientFrame(opPong, payload))
	took := time.Since(began)

	if len(*rtts) != 1 {
		t.Fatalf("one answered ping gave %d round trips, expected 1", len(*rtts))
	}
	// At least the thirty milliseconds the answer was held back, and at most
	// the time the test watched pass since before the ping: both hold on a
	// machine under any load.
	if rtt := (*rtts)[0]; rtt < 30*time.Millisecond || rtt > took {
		t.Fatalf("a round trip held back thirty milliseconds was measured as %v, "+
			"expected at least 30ms and at most the %v since before the ping", rtt, took)
	}
}

// answeringConn is a network so fast that the answer to a frame is read before
// the write that sent the frame has returned.
type answeringConn struct {
	net.Conn
	answer func(frame []byte)
}

func (c answeringConn) Write(frame []byte) (int, error) {
	c.answer(frame)
	return len(frame), nil
}

func TestAPongBeforeThePingWriteReturnsIsCounted(t *testing.T) {
	// A pong can be on its way back before the write that sent its ping has
	// returned. The moment the ping left has to be where the pong looks for it
	// by then, or the fastest links are the ones never measured.
	far, near := net.Pipe()
	defer far.Close()
	server := &Conn{reader: bufio.NewReader(near)}
	rtts := roundTrips(server)
	var survived error
	server.raw = answeringConn{Conn: near, answer: func(frame []byte) {
		payload := append([]byte{}, frame[2:]...) // the server does not mask
		go func() {
			far.Write(clientFrame(opPong, payload))
			far.Write(clientFrame(opBinary, []byte{9}))
		}()
		_, survived = server.ReadMessage()
	}}
	if err := server.Ping(); err != nil {
		t.Fatalf("the ping was not written: %v", err)
	}
	if survived != nil {
		t.Fatalf("the connection did not survive the answer: %v", survived)
	}
	if len(*rtts) != 1 {
		t.Fatalf("a pong read before its ping's write returned gave %d round trips, expected 1", len(*rtts))
	}
}

func TestUnsolicitedPongIsIgnored(t *testing.T) {
	// The standard lets either side send a pong nobody asked for. It measures
	// nothing — there is no ping it answers — and it is no reason to drop the
	// connection either.
	client, server := pipeConn(t)
	defer client.Close()
	rtts := roundTrips(server)

	var zero, plausible [8]byte
	// A moment the server could well have sent, had it pinged.
	binary.BigEndian.PutUint64(plausible[:], uint64(stamp()))
	replyWith(t, client, server,
		clientFrame(opPong, nil),
		clientFrame(opPong, []byte("hey")),
		// Zero is what a connection that never pinged holds: taken as a
		// match, it would report the whole time since the process started.
		clientFrame(opPong, zero[:]),
		clientFrame(opPong, plausible[:]),
	)
	if len(*rtts) != 0 {
		t.Fatalf("pongs to no ping gave round trips: %v", *rtts)
	}
}

func TestAPongIsCountedOnce(t *testing.T) {
	// One ping is one round trip. A client that echoes the same pong again,
	// by mistake or to weigh the numbers, adds nothing to them.
	client, server := pipeConn(t)
	defer client.Close()
	rtts := roundTrips(server)

	payload := pingFrom(t, client, server)
	replyWith(t, client, server,
		clientFrame(opPong, payload),
		clientFrame(opPong, payload),
		clientFrame(opPong, payload),
	)
	if len(*rtts) != 1 {
		t.Fatalf("one ping answered three times gave %d round trips, expected 1", len(*rtts))
	}
}

func TestAForgedPongPayloadIsIgnored(t *testing.T) {
	// A client cannot answer a ping before it arrives, so the round trip can
	// only be made to look longer by claiming the ping left earlier. The claim
	// has to name the exact nanosecond the server wrote, or it is not taken.
	client, server := pipeConn(t)
	defer client.Close()
	rtts := roundTrips(server)

	payload := pingFrom(t, client, server)
	if len(payload) != 8 {
		t.Fatalf("a ping must carry eight bytes, carried %v", payload)
	}
	sent := binary.BigEndian.Uint64(payload)
	earlier := binary.BigEndian.AppendUint64(nil, sent-uint64(time.Second))
	later := binary.BigEndian.AppendUint64(nil, sent+1)
	backwards := binary.LittleEndian.AppendUint64(nil, sent)
	replyWith(t, client, server,
		clientFrame(opPong, earlier),
		clientFrame(opPong, later),
		clientFrame(opPong, backwards),
		clientFrame(opPong, payload[:7]),
		clientFrame(opPong, append(append([]byte{}, payload...), 0)),
	)
	if len(*rtts) != 0 {
		t.Fatalf("forged pongs gave round trips: %v", *rtts)
	}

	// Nor did any of them use the ping up: the true answer still counts.
	replyWith(t, client, server, clientFrame(opPong, payload))
	if len(*rtts) != 1 {
		t.Fatalf("the true answer after the forgeries gave %d round trips, expected 1", len(*rtts))
	}
}

func TestCloseFrameEndsTheConversation(t *testing.T) {
	client, server := pipeConn(t)
	go func() { client.Write(clientFrame(opClose, nil)) }()

	if _, err := server.ReadMessage(); err != errClosed {
		t.Fatalf("a close must be reported as a close, got: %v", err)
	}
}

func TestOversizedFrameIsRefused(t *testing.T) {
	client, server := pipeConn(t)
	go func() {
		// The declared length is far past the cap: one connection must not be
		// able to eat the server's memory.
		head := []byte{0x80 | opBinary, 0x80 | 127, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF}
		client.Write(head)
	}()
	if _, err := server.ReadMessage(); !errors.Is(err, errProtocol) {
		t.Fatalf("an oversized frame must be refused as a broken protocol, got: %v", err)
	}
}

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
			frame[0] &^= 0x80 // not the final one
			if _, err := client.Write(frame); err != nil {
				return
			}
		}
		client.Write(clientFrame(opContinuation, piece))
	}()
	if _, err := server.ReadMessage(); !errors.Is(err, errProtocol) {
		t.Fatalf("a message stitched past the cap must be refused as a broken protocol, got: %v", err)
	}
}

func TestOversizedControlFrameIsRefused(t *testing.T) {
	// The standard caps a control frame at 125 bytes, and the reply to a ping
	// echoes its payload: uncapped, the server writes back whatever it is handed.
	client, server := pipeConn(t)
	defer client.Close()
	go io.Copy(io.Discard, client) // whatever comes back, so the pipe never blocks
	go func() {
		client.Write(clientFrame(opPing, bytes.Repeat([]byte{1}, 126)))
		client.Write(clientFrame(opBinary, []byte{9}))
	}()
	if _, err := server.ReadMessage(); !errors.Is(err, errProtocol) {
		t.Fatalf("a control frame over 125 bytes must be refused as a broken protocol, got: %v", err)
	}
}

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

func TestHandshakeRejectsPlainRequest(t *testing.T) {
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/ws", nil)
	if _, err := Accept(recorder, request); err == nil {
		t.Fatal("a plain HTTP request must not turn into a WebSocket")
	}
}
