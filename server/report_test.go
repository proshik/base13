package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"log"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// A player's own side reports how its game runs: the pace of each window and a
// desync. The server takes those reports only because it said it would, keeps
// them out of the game's stream entirely, and believes none of the numbers
// past what a real window can hold.

// sendText writes a text frame, the kind a player's side reports in.
func (c *wsClient) sendText(t *testing.T, payload []byte) {
	t.Helper()
	if _, err := c.conn.Write(clientFrame(opText, payload)); err != nil {
		t.Fatalf("send failed: %v", err)
	}
}

// paceBody is a pace report as the client writes it.
func paceBody(p pace) []byte {
	body, _ := json.Marshal(map[string]pace{"report": p})
	return body
}

var desyncBody = []byte(`{"desync":true}`)

// seatPair opens a room by code from macos and seats a partner from web in it.
// The host's notice that the partner arrived is already read, so the next frame
// either of them receives is whatever the other sends.
func seatPair(t *testing.T, addr string) (host, guest *wsClient, code string) {
	t.Helper()
	host = dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 1, Platform: "macos"})
	code = host.welcome(t).Code
	guest = dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code, Platform: "web"})
	if answer := guest.welcome(t); !answer.OK {
		t.Fatalf("the guest was refused: %+v", answer)
	}
	host.receiveText(t)
	return host, guest, code
}

// expectPacket checks that a client's very next frame is exactly this game
// packet, with nothing ahead of it.
func expectPacket(t *testing.T, c *wsClient, want []byte) {
	t.Helper()
	opcode, got := c.receiveFrame(t)
	if opcode != opBinary || !bytes.Equal(got, want) {
		t.Fatalf("the next frame was kind %d carrying %q, expected the game packet %v", opcode, got, want)
	}
}

// expectQuiet checks that nothing arrives for a client within a short wait.
func expectQuiet(t *testing.T, c *wsClient, why string) {
	t.Helper()
	c.conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if _, err := c.reader.ReadByte(); err == nil {
		t.Fatalf("%s: a frame arrived", why)
	} else if !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("%s: the socket failed instead of staying quiet: %v", why, err)
	}
}

func TestWelcomeAnnouncesReports(t *testing.T) {
	// A server from before reports hands whatever follows the hello to the
	// partner as a game packet, and a report arriving there would be taken for
	// input. So a client reports only to a server that says it takes reports:
	// every welcome says so, and a refusal, which seats nobody, does not.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()

	announced := func(who string, c *wsClient) welcome {
		t.Helper()
		raw := c.receiveText(t)
		var answer welcome
		if err := json.Unmarshal(raw, &answer); err != nil || !answer.OK {
			t.Fatalf("%s was not welcomed: %s (%v)", who, raw, err)
		}
		if !bytes.Contains(raw, []byte(`"reports":true`)) {
			t.Errorf("the welcome for %s does not announce reports: %s", who, raw)
		}
		return answer
	}

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 1})
	code := announced("a player opening a room", host).Code
	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	announced("a player joining by code", guest)

	host.send(t, []byte{1, 0, 0, 0, 0, 31})
	guest.receive(t)
	guest.conn.Close()
	eventually(t, func() bool { return metricValue(t, s, `relay_players{platform="unknown"}`) == 1 })
	back := dial(t, addr)
	back.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code, Since: 1})
	announced("a player coming back", back)

	quick := dial(t, addr)
	quick.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 2})
	announced("a quick player", quick)

	refused := dial(t, addr)
	refused.sendJSON(t, hello{Action: "join", Game: "tanks", Code: "ZZZZZZ"})
	if raw := refused.receiveText(t); bytes.Contains(raw, []byte("reports")) {
		t.Errorf("a refusal announces reports: %s", raw)
	}
}

func TestAReportIsNeitherJournaledNorRelayed(t *testing.T) {
	// The partner's game takes every packet it is handed as input, and a
	// returning player's catch-up is replayed the same way: a report reaching
	// either would read as a key press nobody made, and the two worlds would
	// part. A report goes no further than the server's counts. Nor is it the
	// game's traffic, so the packet counts do not see it.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, code := seatPair(t, addr)

	host.sendText(t, paceBody(pace{Speed: 100, Waits: 0, Delay: 4, FPS: 60}))
	host.sendText(t, desyncBody)
	expectQuiet(t, guest, "the host reported and the partner was sent something")

	// A packet sent after the reports is the partner's very next frame: a
	// report relayed in any form would have come ahead of it.
	packet := []byte{1, 0, 0, 0, 0, 31}
	host.send(t, packet)
	expectPacket(t, guest, packet)
	expectSeries(t, s, map[string]float64{
		"relay_packets_total":      1,
		"relay_packet_bytes_total": 6,
		`relay_client_windows_total{platform="macos",verdict="smooth"}`: 1,
		`relay_desynced_matches_total{kind="code"}`:                     1,
	})
	room, err := s.hub.Find("tanks", code)
	if err != nil {
		t.Fatalf("the room is gone: %v", err)
	}
	if got := room.JournalLength(); got != 1 {
		t.Errorf("the journal holds %d records, expected the packet alone", got)
	}

	// The partner drops and comes back from the very start: the catch-up holds
	// the packet and nothing else.
	guest.conn.Close()
	eventually(t, func() bool { return room.Occupants() == 1 })
	back := dial(t, addr)
	back.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	if answer := back.welcome(t); !answer.OK || answer.Replay != 1 {
		t.Fatalf("the returning partner was promised %+v, expected one record", answer)
	}
	expectPacket(t, back, packet)
	expectQuiet(t, back, "the catch-up ran past its one packet")
}

func TestReportFieldsAreClamped(t *testing.T) {
	// A report says whatever the other end chose to write, and a histogram's sum
	// takes it at its word: one report of a billion waits would outweigh every
	// honest window there ever was. Each field is held to what a real window can
	// be before anything is counted.
	for _, c := range []struct{ sent, want pace }{
		{pace{Speed: -50, Waits: -3, Delay: -1, FPS: -60}, pace{}},
		{pace{Speed: 1e9, Waits: 1e9, Delay: 1e9, FPS: 1e9}, pace{Speed: 200, Waits: 300, Delay: 64, FPS: 1000}},
		{pace{Speed: 200, Waits: 300, Delay: 64, FPS: 1000}, pace{Speed: 200, Waits: 300, Delay: 64, FPS: 1000}},
		{pace{Speed: 97, Waits: 2, Delay: 5, FPS: 59}, pace{Speed: 97, Waits: 2, Delay: 5, FPS: 59}},
	} {
		if got := clamp(c.sent); got != c.want {
			t.Errorf("%+v clamped to %+v, expected %+v", c.sent, got, c.want)
		}
	}

	s := &server{hub: NewHub()}
	room, _ := s.hub.Create("tanks", 1)
	member, _ := room.JoinAs(client{platform: "linux"})
	// Each on a connection of its own, so the pace limit turns neither away.
	for _, body := range []string{
		`{"report":{"speed":-50,"waits":-3,"delay":-1,"fps":-60}}`,
		`{"report":{"speed":1000000000,"waits":1000000000,"delay":1000000000,"fps":1000000000}}`,
	} {
		var reports reportGate
		s.takeReport(&reports, member, room, []byte(body), time.Now())
	}
	expectSeries(t, s, map[string]float64{
		`relay_client_speed_ratio_count{platform="linux"}`:               2,
		`relay_client_speed_ratio_bucket{platform="linux",le="0.5"}`:     1,
		`relay_client_speed_ratio_bucket{platform="linux",le="1.01"}`:    1,
		`relay_client_speed_ratio_sum{platform="linux"}`:                 2,
		`relay_client_waits_total`:                                       300,
		`relay_client_input_delay_ticks_bucket{le="3"}`:                  1,
		`relay_client_input_delay_ticks_bucket{le="16"}`:                 1,
		`relay_client_input_delay_ticks_count`:                           2,
		`relay_client_input_delay_ticks_sum`:                             64,
		`relay_client_fps_bucket{platform="linux",le="15"}`:              1,
		`relay_client_fps_bucket{platform="linux",le="120"}`:             1,
		`relay_client_fps_sum{platform="linux"}`:                         1000,
		`relay_client_windows_total{platform="linux",verdict="machine"}`: 1,
		`relay_client_windows_total{platform="linux",verdict="smooth"}`:  1,
		`relay_client_reports_rejected_total{why="malformed"}`:           0,
	})
	checkExposition(t, renderMetrics(s))
}

func TestVerdictFollowsWaitsAndSpeed(t *testing.T) {
	// A window short of full speed was lost to the network or to the machine,
	// and the player's own side can tell which: waits for the partner's input
	// mean the network, and a slow window with no waits at all means the
	// machine could not keep up. Close enough to full speed, a window is smooth
	// whatever else happened in it.
	for _, c := range []struct {
		speed, waits int
		want         string
	}{
		{95, 0, "smooth"},
		{80, 0, "machine"},
		{80, 5, "network"},
		{95, 5, "smooth"},
		{94, 0, "machine"},
		{94, 1, "network"},
		{200, 300, "smooth"},
		{0, 0, "machine"},
	} {
		if got := verdict(c.speed, c.waits); got != c.want {
			t.Errorf("speed %d%% with %d waits is %q, expected %q", c.speed, c.waits, got, c.want)
		}
	}

	// Every series is there from the first scrape, before anyone reports: one
	// that appears only once first counted breaks rate() across that moment.
	s := &server{hub: NewHub()}
	first := renderMetrics(s)
	checkExposition(t, first)
	zero := []string{
		"relay_client_input_delay_ticks_count", "relay_client_waits_total",
		`relay_desynced_matches_total{kind="code"}`, `relay_desynced_matches_total{kind="quick"}`,
		`relay_client_reports_rejected_total{why="early"}`, `relay_client_reports_rejected_total{why="malformed"}`,
	}
	for _, platform := range testPlatforms {
		zero = append(zero,
			`relay_client_speed_ratio_count{platform="`+platform+`"}`,
			`relay_client_fps_count{platform="`+platform+`"}`)
		for _, v := range []string{"smooth", "network", "machine"} {
			zero = append(zero, `relay_client_windows_total{platform="`+platform+`",verdict="`+v+`"}`)
		}
	}
	for _, series := range zero {
		if got, found := seriesValue(first, series); !found || got != "0" {
			t.Errorf("before any report %s is %q (found %v)", series, got, found)
		}
	}

	// The verdict is counted under the platform the player's hello named.
	room, _ := s.hub.Create("tanks", 1)
	member, _ := room.JoinAs(client{platform: "web_android"})
	for _, p := range []pace{
		{Speed: 95, Waits: 0, Delay: 4, FPS: 60},
		{Speed: 80, Waits: 0, Delay: 4, FPS: 30},
		{Speed: 80, Waits: 5, Delay: 6, FPS: 60},
	} {
		var reports reportGate
		s.takeReport(&reports, member, room, paceBody(p), time.Now())
	}
	// A pace of exactly 99% sits on the bound just under full speed, the way 95%
	// sits on the smooth line.
	tablet, _ := room.JoinAs(client{platform: "ios"})
	var reports reportGate
	s.takeReport(&reports, tablet, room, paceBody(pace{Speed: 99, Delay: 4, FPS: 60}), time.Now())

	expectSeries(t, s, map[string]float64{
		`relay_client_windows_total{platform="web_android",verdict="smooth"}`:  1,
		`relay_client_windows_total{platform="web_android",verdict="machine"}`: 1,
		`relay_client_windows_total{platform="web_android",verdict="network"}`: 1,
		`relay_client_windows_total{platform="ios",verdict="smooth"}`:          1,
		`relay_client_windows_total{platform="web",verdict="smooth"}`:          0,
		`relay_client_waits_total`: 5,
		`relay_client_speed_ratio_bucket{platform="web_android",le="0.75"}`: 0,
		`relay_client_speed_ratio_bucket{platform="web_android",le="0.9"}`:  2,
		`relay_client_speed_ratio_bucket{platform="web_android",le="0.95"}`: 3,
		`relay_client_speed_ratio_sum{platform="web_android"}`:              2.55,
		`relay_client_speed_ratio_bucket{platform="ios",le="0.95"}`:         0,
		`relay_client_speed_ratio_bucket{platform="ios",le="0.99"}`:         1,
		`relay_client_fps_bucket{platform="web_android",le="30"}`:           1,
		`relay_client_fps_bucket{platform="web_android",le="60"}`:           3,
		`relay_client_input_delay_ticks_bucket{le="4"}`:                     3,
		`relay_client_input_delay_ticks_bucket{le="6"}`:                     4,
	})
	checkExposition(t, renderMetrics(s))
}

func TestEarlyReportsAreRejected(t *testing.T) {
	// A player's side reports once a window of several seconds. More often than
	// that is not a faster game but somebody writing reports by hand, and each
	// report weighs in the figures as a window of its own: past the first, one
	// per interval is taken, and the rest are counted and dropped. A desync is
	// not a window and is not held to the interval.
	const every = time.Second
	s := &server{hub: NewHub(), reportEvery: every}
	addr, stop := serve(t, s)
	defer stop()
	player := dial(t, addr)
	player.sendJSON(t, hello{Action: "quick", Game: "tanks", Seed: 1, Platform: "windows"})
	player.welcome(t)

	windows := `relay_client_windows_total{platform="windows",verdict="smooth"}`
	early := `relay_client_reports_rejected_total{why="early"}`
	report := paceBody(pace{Speed: 100, Delay: 4, FPS: 60})

	player.sendText(t, report)
	eventually(t, func() bool { return metricValue(t, s, windows) == 1 })
	// The report was taken before this moment, which the wait below counts from.
	taken := time.Now()
	player.sendText(t, report)
	eventually(t, func() bool { return metricValue(t, s, early) == 1 })
	player.sendText(t, desyncBody)
	eventually(t, func() bool { return metricValue(t, s, `relay_desynced_matches_total{kind="quick"}`) == 1 })
	expectSeries(t, s, map[string]float64{
		windows: 1,
		early:   1,
		`relay_client_speed_ratio_count{platform="windows"}`:   1,
		`relay_client_fps_count{platform="windows"}`:           1,
		`relay_client_input_delay_ticks_count`:                 1,
		`relay_client_reports_rejected_total{why="malformed"}`: 0,
	})

	// The interval runs from the report that was taken, not from the one turned
	// away: once it has passed, the next report is taken again.
	time.Sleep(time.Until(taken.Add(every)))
	player.sendText(t, report)
	eventually(t, func() bool { return metricValue(t, s, windows) == 2 })
	expectSeries(t, s, map[string]float64{early: 1})
}

func TestMalformedReportIsRejectedWithoutClosing(t *testing.T) {
	// A message that is neither of the two shapes is dropped and counted, and
	// the player plays on: a client with a mistake in its reports is still a
	// player in a match, and cutting them off would end the game over a figure
	// that only feeds a dashboard.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, _ := seatPair(t, addr)

	bad := []string{
		`not json at all`,
		`{"report":{"speed":100,"waits":0,"delay":4,"fps":60},"desync":true}`,
		`{}`,
		`{"report":{"speed":95.5,"waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":95.0,"waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":1e2,"waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":"95","waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":null,"waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":100000000000000000000,"waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":95,"waits":0,"delay":4}}`,
		`{"report":{"speed":95,"waits":0,"delay":4,"fps":60,"ping":3}}`,
		`{"report":{"Speed":95,"waits":0,"delay":4,"fps":60}}`,
		`{"report":null}`,
		`{"report":[95,0,4,60]}`,
		`{"report":{"speed":95,"waits":0,"delay":4,"fps":60},"extra":1}`,
		`{"desync":false}`,
		`{"desync":"true"}`,
		`{"desync":true,"extra":1}`,
		`{"event":"joined","players":2}`,
		`{"desync":true} {"desync":true}`,
		`null`,
		`[]`,
		`95`,
	}
	for _, body := range bad {
		host.sendText(t, []byte(body))
	}
	malformed := `relay_client_reports_rejected_total{why="malformed"}`
	eventually(t, func() bool { return metricValue(t, s, malformed) == float64(len(bad)) })
	expectSeries(t, s, map[string]float64{
		`relay_client_reports_rejected_total{why="early"}`: 0,
		`relay_desynced_matches_total{kind="code"}`:        0,
		`relay_client_speed_ratio_count{platform="macos"}`: 0,
		`relay_client_input_delay_ticks_count`:             0,
		`relay_client_waits_total`:                         0,
		`relay_disconnects_total{cause="protocol"}`:        0,
	})

	// Still open, and still relaying both ways.
	packet := []byte{1, 0, 0, 0, 0, 31}
	host.send(t, packet)
	expectPacket(t, guest, packet)
	answer := []byte{2, 1, 0, 0, 0, 16}
	guest.send(t, answer)
	expectPacket(t, host, answer)

	// Spacing and the order of the fields are the writer's own business: the
	// same report laid out another way is taken.
	host.sendText(t, []byte("{ \"report\" : {\"fps\": 60,\n \"delay\": 4, \"waits\": 0, \"speed\": 100} }"))
	eventually(t, func() bool {
		return metricValue(t, s, `relay_client_windows_total{platform="macos",verdict="smooth"}`) == 1
	})
	expectSeries(t, s, map[string]float64{malformed: float64(len(bad))})
}

func TestADesyncIsCountedOncePerRoom(t *testing.T) {
	// When the two worlds part, both players' sides notice and each says so. It
	// is one broken match, not two, so the room counts it once however many say
	// it; and a side that says it again on the same connection is turned away
	// as early rather than let at the room's lock over and over.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, _ := seatPair(t, addr)
	desynced := func(kind string) string { return `relay_desynced_matches_total{kind="` + kind + `"}` }
	early := `relay_client_reports_rejected_total{why="early"}`

	// Each desync is followed by a packet the other side receives: by the time it
	// arrives, the server has read the desync ahead of it.
	host.sendText(t, desyncBody)
	first := []byte{1, 0, 0, 0, 0, 1}
	host.send(t, first)
	expectPacket(t, guest, first)
	guest.sendText(t, desyncBody)
	second := []byte{1, 1, 0, 0, 0, 1}
	guest.send(t, second)
	expectPacket(t, host, second)
	expectSeries(t, s, map[string]float64{desynced("code"): 1, desynced("quick"): 0, early: 0})

	host.sendText(t, desyncBody)
	third := []byte{1, 0, 0, 0, 0, 2}
	host.send(t, third)
	expectPacket(t, guest, third)
	expectSeries(t, s, map[string]float64{
		desynced("code"): 1,
		early:            1,
		// A desync is not a window: no pace figure moves.
		`relay_client_speed_ratio_count{platform="macos"}`: 0,
		`relay_client_speed_ratio_count{platform="web"}`:   0,
		`relay_client_input_delay_ticks_count`:             0,
	})

	// Another room's match is its own: a desync in a quick game is counted under
	// quick, and the room says only once that it was the first to hear.
	room, member, err := s.hub.QuickAs("tanks", 2, client{platform: "ios"})
	if err != nil {
		t.Fatalf("no quick room: %v", err)
	}
	var reports reportGate
	s.takeReport(&reports, member, room, desyncBody, time.Now())
	expectSeries(t, s, map[string]float64{desynced("code"): 1, desynced("quick"): 1})
	bare := newRoom("ABCDEF", "tanks", 3)
	if !bare.noteDesync() {
		t.Error("the first desync in a room was not noted as the first")
	}
	if bare.noteDesync() {
		t.Error("a second desync in the same room was noted as the first again")
	}
}

// lockedBuffer collects what the log writes, whichever goroutine writes it.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func TestReportsNeverReachTheLog(t *testing.T) {
	// The log is kept by whoever runs the server, for as long as they like, and a
	// report is whatever a stranger chose to write. Nothing of one is written
	// there: not a figure, not a word, not a rejected message as it was sent.
	// Not parallel: it takes over the package's log for its duration.
	captured := &lockedBuffer{}
	kept := log.Writer()
	log.SetOutput(captured)
	defer log.SetOutput(kept)

	s := &server{hub: NewHub(), reportEvery: time.Hour}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, _ := seatPair(t, addr)

	const marker = "Qz7markerXv"
	numbers := `{"report":{"speed":141421,"waits":271828,"delay":161803,"fps":314159}}`
	for _, body := range []string{
		numbers,
		numbers, // early
		`{"desync":true}`,
		`{"desync":true}`, // early
		`{"report":{"speed":"` + marker + `","waits":0,"delay":4,"fps":60}}`,
		marker,
	} {
		host.sendText(t, []byte(body))
	}
	packet := []byte{1, 0, 0, 0, 0, 31}
	host.send(t, packet)
	expectPacket(t, guest, packet)
	expectSeries(t, s, map[string]float64{
		`relay_client_windows_total{platform="macos",verdict="smooth"}`: 1,
		`relay_client_reports_rejected_total{why="early"}`:              2,
		`relay_client_reports_rejected_total{why="malformed"}`:          2,
		`relay_desynced_matches_total{kind="code"}`:                     1,
	})
	// Both leave, and every line their connections log on the way out is written
	// before the server lets go of the connections.
	host.conn.Close()
	guest.conn.Close()
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 0 })

	logged := captured.String()
	if !strings.Contains(logged, "joined") {
		t.Fatalf("the log was not captured, the test proves nothing: %q", logged)
	}
	// Matched as written: a report's words are lowercase, and a room code in the
	// log is uppercase, so a code cannot spell one of them by chance.
	for _, word := range []string{marker, "141421", "271828", "161803", "314159", "report", "desync", "speed", "waits", "fps"} {
		if strings.Contains(logged, word) {
			t.Errorf("the log carries %q from a report:\n%s", word, logged)
		}
	}
}
