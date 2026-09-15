package main

// A load measurement: how many pairs the server carries and what it runs into.
// Not part of the ordinary run — enabled with BASE13_LOAD=1.
//
// It measures what it was written for: whether packets arrive on time and what
// a game costs in memory. Pencil-and-paper estimates lie here: the overhead of
// a journal record is several times the record itself, and that is invisible
// by eye.

import (
	"encoding/binary"
	"fmt"
	"net"
	"net/http"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const (
	tickHz     = 60
	packetSize = 6
)

func TestLoadManyPairs(t *testing.T) {
	if os.Getenv("BASE13_LOAD") == "" {
		t.Skip("load measurement: BASE13_LOAD=1")
	}
	for _, pairs := range []int{10, 50, 200} {
		t.Run(fmt.Sprintf("%d_pairs", pairs), func(t *testing.T) {
			measure(t, pairs, 5*time.Second)
		})
	}
}

func measure(t *testing.T, pairs int, duration time.Duration) {
	t.Helper()
	s := &server{hub: NewHub()}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	httpServer := &http.Server{Handler: s.routes("")}
	go httpServer.Serve(listener)
	defer func() { httpServer.Close(); listener.Close() }()
	addr := listener.Addr().String()

	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)

	var sent, received, late atomic.Int64
	var wg sync.WaitGroup
	stop := make(chan struct{})

	for i := 0; i < pairs*2; i++ {
		client := dial(t, addr)
		client.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: uint32(i)})
		if answer := client.welcome(t); !answer.OK {
			t.Fatalf("player %d was not seated: %s", i, answer.Error)
		}
		wg.Add(2)
		go writer(client, stop, &sent, &wg)
		go reader(client, stop, &received, &late, &wg)
	}

	matchStart := time.Now()
	time.Sleep(duration)
	close(stop)
	wg.Wait()
	elapsed := time.Since(matchStart)

	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)

	// Delivered is compared against sent, not against a computed expectation:
	// a time-based estimate lies, because the clients live in the same process
	// and may themselves fail to emit sixty packets a second.
	journalRecords, journalBytes := 0, 0
	for _, room := range s.hub.rooms {
		journalRecords += room.JournalLength()
		journalBytes += room.JournalBytes()
	}
	wanted := float64(pairs*2) * elapsed.Seconds() * tickHz

	t.Logf("%d pairs: sent %d of ~%.0f possible, delivered %d (%.1f%% of sent), late %d",
		pairs, sent.Load(), wanted, received.Load(),
		100*float64(received.Load())/float64(sent.Load()), late.Load())
	t.Logf("%d pairs: journal %d records and %d KB (%.1f bytes per record), heap +%.1f MB, goroutines %d",
		pairs, journalRecords, journalBytes/1024,
		float64(journalBytes)/float64(journalRecords),
		float64(after.HeapAlloc-before.HeapAlloc)/1024/1024, runtime.NumGoroutine())

	if received.Load() < sent.Load()*9/10 {
		t.Fatalf("more than a tenth lost: delivered %d of %d",
			received.Load(), sent.Load())
	}
	if late.Load() > sent.Load()/100 {
		t.Fatalf("every hundredth packet was late or worse: %d of %d", late.Load(), sent.Load())
	}
}

// writer sends key presses at the tick rate, like a real client.
func writer(c *wsClient, stop <-chan struct{}, sent *atomic.Int64, wg *sync.WaitGroup) {
	defer wg.Done()
	ticker := time.NewTicker(time.Second / tickHz)
	defer ticker.Stop()
	packet := make([]byte, packetSize)
	packet[0] = 1
	for tick := uint32(0); ; tick++ {
		select {
		case <-stop:
			return
		case <-ticker.C:
			binary.BigEndian.PutUint32(packet[1:5], tick)
			if _, err := c.conn.Write(clientFrame(opBinary, packet)); err != nil {
				return
			}
			sent.Add(1)
		}
	}
}

// reader counts what arrived and what arrived later than reasonable: a
// lockstep game stalls if a packet is more than a few ticks late.
func reader(c *wsClient, stop <-chan struct{}, received, late *atomic.Int64, wg *sync.WaitGroup) {
	defer wg.Done()
	budget := 100 * time.Millisecond
	for {
		select {
		case <-stop:
			return
		default:
		}
		c.conn.SetReadDeadline(time.Now().Add(time.Second))
		began := time.Now()
		var head [2]byte
		if _, err := c.reader.Read(head[:1]); err != nil {
			return
		}
		if _, err := c.reader.Read(head[1:]); err != nil {
			return
		}
		length := int(head[1] & 0x7F)
		payload := make([]byte, length)
		for read := 0; read < length; {
			n, err := c.reader.Read(payload[read:])
			if err != nil {
				return
			}
			read += n
		}
		received.Add(1)
		if time.Since(began) > budget {
			late.Add(1)
		}
	}
}
