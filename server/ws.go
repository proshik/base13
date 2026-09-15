package main

// WebSocket per RFC 6455, written by hand rather than taken from a library.
//
// Not much is needed here — the handshake, frame parsing and answering a ping —
// and every byte a player sends passes through it, so it stays short enough to
// read in full. The server does have one dependency, Prometheus's client library
// for its metrics, fetched once and checked against go.sum; the socket layer is
// not part of it.

import (
	"bufio"
	cryptorand "crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	mathrand "math/rand/v2"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// The magic string from the standard: it salts the client key during the
// handshake.
const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

// A message is capped as a whole, not frame by frame: a cap on frames alone is
// stepped around by fragmentation, and eight frames of a megabyte were stitched
// into eight megabytes. The largest thing a client legitimately sends is the
// housekeeping packet, under a hundred bytes; relaying is forwarding, not
// storage, so there is no reason to accept much more.
const maxMessageSize = 512

// The standard's cap on a control frame. A pong echoes the ping's payload, so
// without it the server writes back whatever size it is handed.
const maxControlSize = 125

// How long to wait for a farewell in reply before tearing the socket down.
const closeLinger = 500 * time.Millisecond

// How long a connection may stay silent before it is taken for dead. The
// server pings every twenty seconds and every client answers — a browser on its
// own — so a live link is never silent this long, while a laptop that went to
// sleep would otherwise hold its socket forever.
const defaultReadIdle = 60 * time.Second

// How long one write may take. Packets are a few bytes: a write that cannot get
// them into the socket in five seconds is writing to somebody who stopped
// reading.
const defaultWriteLimit = 5 * time.Second

// Close codes from the standard: the message breaks the agreement, and the
// server is going away.
const (
	closePolicy    = 1008
	closeGoingAway = 1001
)

// errClosed is the other side's goodbye: it sent a close frame. Returned bare,
// never wrapped, since callers compare it directly. Our own side closing the
// socket reads back as net.ErrClosed instead, so the two never mix.
var errClosed = errors.New("connection closed")

// errProtocol marks a peer refused for breaking the standard or its limits
// rather than for going away. It is wrapped under a readable explanation, so
// the log says what was broken and the count still knows it was broken.
var errProtocol = errors.New("protocol broken")

// Conn is an accepted WebSocket connection. Reading is single-threaded;
// writing is guarded by a mutex, because relaying happens from another
// connection's goroutine.
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
	// The moment the last ping left, as its stamp, and zero once it has been
	// answered or while nothing was ever sent. The writer stores it and the
	// reader takes it back, from two goroutines, so it is atomic.
	lastPing atomic.Int64
	// Told each round trip a pong measures. Set by whoever reads the connection
	// before any ping goes out, and read only by that reader afterwards.
	onRTT func(time.Duration)
}

// Accept completes the handshake and hijacks the connection from the HTTP
// server.
func Accept(w http.ResponseWriter, r *http.Request) (*Conn, error) {
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		return nil, errors.New("not a WebSocket upgrade request")
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		return nil, errors.New("missing Sec-WebSocket-Key header")
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		return nil, errors.New("connection cannot be hijacked from the server")
	}
	raw, buf, err := hijacker.Hijack()
	if err != nil {
		return nil, err
	}
	response := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + acceptKey(key) + "\r\n\r\n"
	if _, err := buf.WriteString(response); err != nil {
		raw.Close()
		return nil, err
	}
	if err := buf.Flush(); err != nil {
		raw.Close()
		return nil, err
	}
	return &Conn{
		raw:        raw,
		reader:     buf.Reader,
		readIdle:   defaultReadIdle,
		writeLimit: defaultWriteLimit,
	}, nil
}

func acceptKey(key string) string {
	sum := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}

// ReadMessage returns the next data message, whichever kind of frame carried
// it. Control frames are handled inside and never surface: the caller has no
// business with them.
func (c *Conn) ReadMessage() ([]byte, error) {
	_, data, err := c.ReadMessageKind()
	return data, err
}

// ReadMessageKind returns the next data message and whether it came as text.
// After the hello a game packet comes as binary and a player's report about
// its own game as text, and the two go different ways: one to the partner, the
// other to the counts. A message split into frames is the kind its first frame
// named; the frames after it carry no kind of their own.
func (c *Conn) ReadMessageKind() (text bool, data []byte, err error) {
	var assembled []byte
	started := false
	for {
		final, opcode, payload, err := c.readFrame()
		if err != nil {
			return false, nil, err
		}
		switch opcode {
		case opClose:
			c.Close()
			return false, nil, errClosed
		case opPing:
			// Intermediaries read silence in reply to a ping as a broken link.
			if err := c.writeFrame(opPong, payload); err != nil {
				return false, nil, err
			}
			continue
		case opPong:
			c.pong(payload)
			continue
		case opText, opBinary, opContinuation:
			if !started {
				started = true
				text = opcode == opText
			}
			if len(assembled)+len(payload) > maxMessageSize {
				return false, nil, fmt.Errorf("message of more than %d bytes: %w", maxMessageSize, errProtocol)
			}
			assembled = append(assembled, payload...)
			if final {
				return text, assembled, nil
			}
			// Not the final frame — wait for the continuation and stitch.
		default:
			return false, nil, fmt.Errorf("unknown frame kind %d: %w", opcode, errProtocol)
		}
	}
}

func (c *Conn) readFrame() (final bool, opcode byte, payload []byte, err error) {
	if c.readIdle > 0 && !c.leaving.Load() {
		c.raw.SetReadDeadline(time.Now().Add(c.readIdle))
	}
	var head [2]byte
	if _, err = io.ReadFull(c.reader, head[:]); err != nil {
		return
	}
	final = head[0]&0x80 != 0
	opcode = head[0] & 0x0F
	masked := head[1]&0x80 != 0
	length := uint64(head[1] & 0x7F)

	switch length {
	case 126:
		var ext [2]byte
		if _, err = io.ReadFull(c.reader, ext[:]); err != nil {
			return
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err = io.ReadFull(c.reader, ext[:]); err != nil {
			return
		}
		length = binary.BigEndian.Uint64(ext[:])
	}
	if length > maxMessageSize {
		err = fmt.Errorf("frame of %d bytes is too large: %w", length, errProtocol)
		return
	}
	// Control frames are small and whole by the standard.
	if opcode >= opClose && (length > maxControlSize || !final) {
		err = fmt.Errorf("control frame %d breaks the standard: %w", opcode, errProtocol)
		return
	}

	var mask [4]byte
	if masked {
		if _, err = io.ReadFull(c.reader, mask[:]); err != nil {
			return
		}
	}
	payload = make([]byte, length)
	if _, err = io.ReadFull(c.reader, payload); err != nil {
		return
	}
	// The client must mask and the server must not — that is what the standard
	// says.
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return
}

// WriteMessage sends a binary message as a single frame: this is how game
// packets travel.
func (c *Conn) WriteMessage(data []byte) error {
	return c.writeFrame(opBinary, data)
}

// WriteText sends a housekeeping message. The frame kind is what separates
// talk about the room from game data: the client need not guess from the
// content, and we need not invent a marker inside the packet that every
// parser would then have to step over.
func (c *Conn) WriteText(data []byte) error {
	return c.writeFrame(opText, data)
}

// Ping asks the other side to answer. The server sends it on a timer because a
// browser cannot send one at all — its WebSocket has no such call — and a
// waiting browser player would otherwise be silent in both directions.
//
// The ping carries the moment it left, eight bytes of a stamp moved by
// pingOffset. The standard has every client echo a ping's payload in its pong,
// browsers and Godot included, without the page or the game doing anything, so
// the answer measures the round trip to the player for free. A stamp rather
// than the wall clock: a clock stepped between the ping and the pong would turn
// into a round trip that never happened.
func (c *Conn) Ping() error {
	// Wrapping past the top of uint64 is defined, so the offset can be any
	// value at all and still be taken back exactly.
	sent := uint64(stamp()) + pingOffset
	// Stored before the write: a pong can arrive as soon as the frame is on the
	// wire, and it must find the moment it answers already there.
	c.lastPing.Store(int64(sent))
	var payload [8]byte
	binary.BigEndian.PutUint64(payload[:], sent)
	return c.writeFrame(opPing, payload[:])
}

// pingOffset moves every ping's stamp by the same amount for the life of the
// process. A stamp is the time since the process started, and sent as it is,
// every player could read when the server last restarted. Never logged and
// never exported: known, it would give that away again.
var pingOffset = drawPingOffset(cryptorand.Read)

// drawPingOffset takes eight bytes from the random source. The source is a
// parameter so a test can hand it bytes it knows, or one that fails. Since Go
// 1.24 the system source does not return errors at all, so the fallback is for
// a source that is not the system's: an offset of zero would hide nothing.
func drawPingOffset(read func([]byte) (int, error)) uint64 {
	var drawn [8]byte
	if _, err := read(drawn[:]); err != nil {
		return mathrand.Uint64()
	}
	return binary.BigEndian.Uint64(drawn[:])
}

// pong takes a pong as a round trip when it echoes the last ping exactly, and
// only the first time. Anything else is left alone without a word: the
// standard allows a pong nobody asked for, a pong to a ping since replaced is
// merely late, and a payload made up to claim some other moment would
// otherwise be believed. Taking only the exact value means a round trip can be
// drawn out by answering late, but cannot be made up without guessing the
// exact value the server wrote.
func (c *Conn) pong(payload []byte) {
	if len(payload) != 8 {
		return
	}
	sent := binary.BigEndian.Uint64(payload)
	// Zero is what the connection holds when no ping is waiting: matched, it
	// would pass for a real ping. A ping whose stamp and offset happen to add
	// up to zero is then never measured, which costs one sample in 2^64.
	if sent == 0 || !c.lastPing.CompareAndSwap(int64(sent), 0) {
		return
	}
	if c.onRTT != nil {
		c.onRTT(stamp() - time.Duration(sent-pingOffset))
	}
}

func (c *Conn) writeFrame(opcode byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.closed.Load() {
		// Our side closed it, the same as a write to the closed socket itself
		// would report. Not errClosed: a pong that fails here would end the read
		// loop looking like the other side's goodbye.
		return net.ErrClosed
	}
	header := []byte{0x80 | opcode}
	length := len(payload)
	switch {
	case length < 126:
		header = append(header, byte(length))
	case length < 1<<16:
		header = append(header, 126, 0, 0)
		binary.BigEndian.PutUint16(header[2:], uint16(length))
	default:
		header = append(header, 127, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(header[2:], uint64(length))
	}
	if c.writeLimit > 0 {
		c.raw.SetWriteDeadline(time.Now().Add(c.writeLimit))
	}
	// Header and payload go out in one write: as two they can come apart, and
	// on a synchronous connection the second write simply hangs.
	_, err := c.raw.Write(append(header, payload...))
	return err
}

// CloseWith says goodbye properly: a close frame, then end of stream.
//
// Closing the socket in the same breath as the write sends an RST — and the
// farewell sent a moment earlier never reaches the client at all. They see a
// broken link and tell the human "no connection" instead of "no such room".
//
// We do not wait for a reply. Waiting would mean reading, and the reader of
// this connection may be another goroutine: during shutdown it is running,
// and two readers on one buffer crash the program. Instead of waiting, a
// half-close: FIN flushes everything written, the reader gets end of stream
// and closes the socket itself. The deadline covers a silent client;
// otherwise the connection would hang half-open forever.
func (c *Conn) CloseWith(code uint16, reason string) {
	c.leaving.Store(true)
	payload := make([]byte, 2+len(reason))
	binary.BigEndian.PutUint16(payload, code)
	copy(payload[2:], reason)
	if err := c.writeFrame(opClose, payload); err != nil {
		c.Close()
		return
	}
	if tcp, ok := c.raw.(*net.TCPConn); ok {
		tcp.CloseWrite()
		c.raw.SetReadDeadline(time.Now().Add(closeLinger))
		return
	}
	c.Close()
}

// drain reads and discards until the other side closes or CloseWith's deadline
// runs out. Closing a socket with unread data in it sends a reset instead of an
// end of stream, and a reset can take the farewell written just before it down
// with it. Only for the connection's own reader: two readers on one buffer
// crash the program.
func (c *Conn) drain() {
	io.Copy(io.Discard, c.reader)
}

// Close does not take the write lock: closing the socket is what unblocks a
// write stuck on a client who stopped reading, and waiting for that write first
// would wait as long as it does.
func (c *Conn) Close() {
	if c.closed.Swap(true) {
		return
	}
	c.raw.Close()
}
