package main

// WebSocket per RFC 6455, with no external dependencies.
//
// The reason to write it by hand is the same as for this game's sprites and
// sound: the repository holds what can be read, and the build does not depend
// on somebody else's servers staying up. Not much is needed here — the
// handshake, frame parsing and answering a ping.

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
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

var errClosed = errors.New("connection closed")

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

// ReadMessage returns the next data message. Control frames are handled
// inside and never surface: the caller has no business with them.
func (c *Conn) ReadMessage() ([]byte, error) {
	var assembled []byte
	for {
		final, opcode, payload, err := c.readFrame()
		if err != nil {
			return nil, err
		}
		switch opcode {
		case opClose:
			c.Close()
			return nil, errClosed
		case opPing:
			// Intermediaries read silence in reply to a ping as a broken link.
			if err := c.writeFrame(opPong, payload); err != nil {
				return nil, err
			}
			continue
		case opPong:
			continue
		case opText, opBinary, opContinuation:
			if len(assembled)+len(payload) > maxMessageSize {
				return nil, fmt.Errorf("message of more than %d bytes", maxMessageSize)
			}
			assembled = append(assembled, payload...)
			if final {
				return assembled, nil
			}
			// Not the final frame — wait for the continuation and stitch.
		default:
			return nil, fmt.Errorf("unknown frame kind: %d", opcode)
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
		err = fmt.Errorf("frame of %d bytes is too large", length)
		return
	}
	// Control frames are small and whole by the standard.
	if opcode >= opClose && (length > maxControlSize || !final) {
		err = fmt.Errorf("control frame %d breaks the standard", opcode)
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
func (c *Conn) Ping() error {
	return c.writeFrame(opPing, nil)
}

func (c *Conn) writeFrame(opcode byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.closed.Load() {
		return errClosed
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
