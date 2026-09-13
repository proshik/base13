package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/binary"
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
	if _, err := server.ReadMessage(); err == nil {
		t.Fatal("an oversized frame must be refused")
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
	if _, err := server.ReadMessage(); err == nil {
		t.Fatal("a message stitched past the cap must be refused")
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
	if _, err := server.ReadMessage(); err == nil {
		t.Fatal("a control frame over 125 bytes must be refused")
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
