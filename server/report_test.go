package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"log"
	"os"
	"regexp"
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
// packet, with nothing ahead of it but the server's own pings: one goes out as
// soon as a player is seated, and it is not what these tests wait on.
func expectPacket(t *testing.T, c *wsClient, want []byte) {
	t.Helper()
	opcode, got := c.receiveFrame(t)
	for opcode == opPing {
		opcode, got = c.receiveFrame(t)
	}
	if opcode != opBinary || !bytes.Equal(got, want) {
		t.Fatalf("the next frame was kind %d carrying %q, expected the game packet %v", opcode, got, want)
	}
}

// expectQuiet checks that nothing but the server's own pings arrives for a
// client within a short wait.
func expectQuiet(t *testing.T, c *wsClient, why string) {
	t.Helper()
	until := time.Now().Add(300 * time.Millisecond)
	for {
		c.conn.SetReadDeadline(until)
		first, err := c.reader.Peek(1)
		if errors.Is(err, os.ErrDeadlineExceeded) {
			return
		}
		if err != nil {
			t.Fatalf("%s: the socket failed instead of staying quiet: %v", why, err)
		}
		if first[0]&0x0F != opPing {
			t.Fatalf("%s: a frame arrived", why)
		}
		c.receiveFrame(t)
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
		`relay_client_input_delay_ticks_bucket{le="5"}`:                  1,
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
	firstValues := seriesValues(t, first)
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
		if got, found := firstValues[series]; !found || got != 0 {
			t.Errorf("before any report %s is %v (found %v)", series, got, found)
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
		`relay_client_input_delay_ticks_bucket{le="5"}`:                     3,
		`relay_client_input_delay_ticks_bucket{le="6"}`:                     4,
	})
	checkExposition(t, renderMetrics(s))
}

func TestEarlyReportsAreRejected(t *testing.T) {
	// A player's side reports once a window of several seconds. More often than
	// that is not a faster game but somebody writing reports by hand, and each
	// report weighs in the figures as a window of its own. A connection may have
	// two taken at once, and past that allowance a report is counted and
	// dropped. A desync is not a window and is not held to the allowance.
	//
	// The interval here is an hour, so no runner is slow enough to earn a report
	// back mid-test. Where exactly the allowance refills is pinned by
	// TestThePaceAllowanceIsABucketOfTwo, with the clock in the test's hands.
	s := &server{hub: NewHub(), reportEvery: time.Hour}
	addr, stop := serve(t, s)
	defer stop()
	host, _, _ := seatPair(t, addr)

	windows := `relay_client_windows_total{platform="macos",verdict="smooth"}`
	early := `relay_client_reports_rejected_total{why="early"}`
	report := paceBody(pace{Speed: 100, Delay: 6, FPS: 60})

	host.sendText(t, report)
	host.sendText(t, report)
	eventually(t, func() bool { return metricValue(t, s, windows) == 2 })
	host.sendText(t, report)
	eventually(t, func() bool { return metricValue(t, s, early) == 1 })
	host.sendText(t, desyncBody)
	eventually(t, func() bool { return metricValue(t, s, `relay_desynced_matches_total{kind="code"}`) == 1 })
	expectSeries(t, s, map[string]float64{
		windows: 2,
		early:   1,
		`relay_client_speed_ratio_count{platform="macos"}`:     2,
		`relay_client_fps_count{platform="macos"}`:             2,
		`relay_client_input_delay_ticks_count`:                 2,
		`relay_client_reports_rejected_total{why="malformed"}`: 0,
	})
}

func TestThePaceAllowanceIsABucketOfTwo(t *testing.T) {
	// A connection's allowance holds two reports and earns one back every
	// interval. On a bad link a report held up on the way arrives close behind
	// the one before it, or just ahead of the next one sent on time; turning
	// either away would hide exactly the jitter these figures exist to show.
	// Over time the bound stays one report an interval.
	const every = 250 * time.Millisecond
	start := time.Unix(1_700_000_000, 0)
	var gate reportGate
	step := func(at time.Duration, want bool, what string) {
		t.Helper()
		if got := gate.allowPace(start.Add(at), every); got != want {
			t.Errorf("%s (at %v): taken %v, expected %v", what, at, got, want)
		}
	}
	step(0, true, "the first report on a connection")
	step(0, true, "a second at the same moment")
	step(0, false, "a third at the same moment")
	step(every-1, false, "a nanosecond short of an interval after them")
	step(every, true, "exactly an interval after them")
	step(every, false, "another at that same moment")

	// A report every five seconds against a limit of four, one of them two
	// seconds late: the late one and the next, on time, arrive three seconds
	// apart, and both are taken.
	var honest reportGate
	for _, at := range []time.Duration{0, 5, 12, 15, 20, 25} {
		if !honest.allowPace(start.Add(at*every/4), every) {
			t.Errorf("a report at %v, on a five-second cadence with one late, was turned away", at*every/4)
		}
	}

	// A flood gets its two, then one an interval: a hundred intervals of a
	// report every tenth of one take a hundred and two.
	var flood reportGate
	taken := 0
	for k := range 1001 {
		if flood.allowPace(start.Add(time.Duration(k)*every/10), every) {
			taken++
		}
	}
	if taken != paceBurst+100 {
		t.Errorf("a report every tenth of an interval for a hundred intervals: %d taken, expected %d",
			taken, paceBurst+100)
	}

	// Left at zero, the interval is four seconds, and a report the server reads
	// goes through the same allowance.
	if got := (&server{}).reportInterval(); got != 4*time.Second {
		t.Fatalf("a zero interval means %v, expected 4s", got)
	}
	s := &server{hub: NewHub()}
	room, _ := s.hub.Create("tanks", 1)
	member, _ := room.JoinAs(client{platform: "linux"})
	var reports reportGate
	report := paceBody(pace{Speed: 100, Delay: 6, FPS: 60})
	for _, at := range []time.Duration{0, 0, 0, 4*time.Second - 1, 4 * time.Second} {
		s.takeReport(&reports, member, room, report, start.Add(at))
	}
	expectSeries(t, s, map[string]float64{
		`relay_client_windows_total{platform="linux",verdict="smooth"}`: 3,
		`relay_client_reports_rejected_total{why="early"}`:              2,
	})
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
		`{"report":{"speed":95,"waits":0,"delay":4,"fps":59.94}}`,
		`{"report":{"speed":1.5e0,"waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":95,"waits":0,"delay":-0.5,"fps":60}}`,
		`{"report":{"speed":1e400,"waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":"95","waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":null,"waits":0,"delay":4,"fps":60}}`,
		`{"report":{"speed":true,"waits":0,"delay":4,"fps":60}}`,
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

	// Spacing, the order of the fields and a whole number written as a float are
	// the writer's own business: Godot writes its report this way, and it is taken.
	host.sendText(t, []byte("{ \"report\" : {\"fps\": 60.0,\n \"delay\": 6, \"waits\": 0, \"speed\": 100} }"))
	eventually(t, func() bool {
		return metricValue(t, s, `relay_client_windows_total{platform="macos",verdict="smooth"}`) == 1
	})
	expectSeries(t, s, map[string]float64{
		malformed: float64(len(bad)),
		`relay_client_fps_bucket{platform="macos",le="55"}`: 0,
		`relay_client_fps_bucket{platform="macos",le="60"}`: 1,
	})
}

func TestAWholeNumberIsTakenHoweverItIsWritten(t *testing.T) {
	// Godot writes every float with a point, even a whole one, and the frame rate
	// it measures is a float: 60.0 is sixty. A whole number is a figure however
	// it is spelled, and still held to its limits; a fraction is not a figure
	// and makes the report malformed.
	for _, c := range []struct {
		body string
		want pace
	}{
		{`{"report":{"speed":100,"waits":0,"delay":6,"fps":60}}`, pace{Speed: 100, Delay: 6, FPS: 60}},
		{`{"report":{"speed":95.0,"waits":2.0,"delay":6.0,"fps":60.0}}`, pace{Speed: 95, Waits: 2, Delay: 6, FPS: 60}},
		{`{"report":{"speed":1e2,"waits":0,"delay":6E0,"fps":6e1}}`, pace{Speed: 100, Delay: 6, FPS: 60}},
		{`{"report":{"speed":1.5e1,"waits":0,"delay":6,"fps":60}}`, pace{Speed: 15, Delay: 6, FPS: 60}},
		{`{"report":{"speed":-0.0,"waits":-3.0,"delay":6,"fps":60}}`, pace{Delay: 6, FPS: 60}},
		{`{"report":{"speed":1e20,"waits":100000000000000000000,"delay":1e9,"fps":1e300}}`,
			pace{Speed: 200, Waits: 300, Delay: 64, FPS: 1000}},
		{`{"report":{"speed":-1e20,"waits":0,"delay":6,"fps":60}}`, pace{Delay: 6, FPS: 60}},
	} {
		r := readReport([]byte(c.body))
		if r.kind != paceReport || r.pace != c.want {
			t.Errorf("%s read as kind %d %+v, expected a pace report %+v", c.body, r.kind, r.pace, c.want)
		}
	}
	for _, body := range []string{
		`{"report":{"speed":95.5,"waits":0,"delay":6,"fps":60}}`,
		`{"report":{"speed":100,"waits":0,"delay":6,"fps":59.94}}`,
		`{"report":{"speed":1.5e0,"waits":0,"delay":6,"fps":60}}`,
		`{"report":{"speed":100,"waits":0,"delay":6,"fps":1e-1}}`,
		`{"report":{"speed":1e400,"waits":0,"delay":6,"fps":60}}`,
	} {
		if r := readReport([]byte(body)); r.kind != malformedReport {
			t.Errorf("%s read as kind %d, expected malformed", body, r.kind)
		}
	}
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

	// Another room's match is its own: a desync in a quick game, once two
	// strangers met there, is counted under quick.
	room, member, err := s.hub.QuickAs("tanks", 2, client{platform: "ios"})
	if err != nil {
		t.Fatalf("no quick room: %v", err)
	}
	if paired, _, err := s.hub.QuickAs("tanks", 3, client{platform: "android"}); err != nil || paired != room {
		t.Fatalf("the second quick player was not seated with the first: %v", err)
	}
	var reports reportGate
	s.takeReport(&reports, member, room, desyncBody, time.Now())
	expectSeries(t, s, map[string]float64{desynced("code"): 1, desynced("quick"): 1})

	// And a room says only once that it was the first to hear.
	bare := newRoom("ABCDEF", "tanks", 3)
	bare.Join()
	bare.Join()
	if !bare.noteDesync() {
		t.Error("the first desync in a paired room was not noted as the first")
	}
	if bare.noteDesync() {
		t.Error("a second desync in the same room was noted as the first again")
	}
}

func TestADesyncBeforeAnyPairIsNotCounted(t *testing.T) {
	// Two worlds cannot part before there are two: a desync from a room that
	// never held a pair is not a broken match. Counted, a script that opens a
	// room, says desync and leaves, over and over, would grow the count without
	// bound and wake whoever is on call. Such a desync is neither counted nor
	// rejected: it is well formed and on time, it just describes no match. It
	// still uses up the connection's one desync, so repeating it is early.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()
	desynced := func(kind string) string { return `relay_desynced_matches_total{kind="` + kind + `"}` }
	early := `relay_client_reports_rejected_total{why="early"}`
	malformed := `relay_client_reports_rejected_total{why="malformed"}`

	// A message that is certainly malformed follows each desync: once it is
	// counted, the server has read the desync ahead of it.
	settled := func(c *wsClient, rejected float64) {
		t.Helper()
		c.sendText(t, []byte(`not a report`))
		eventually(t, func() bool { return metricValue(t, s, malformed) == rejected })
	}
	for i := range 3 {
		action := hello{Action: "create", Game: "tanks", Seed: 1}
		if i == 1 {
			action = hello{Action: "quick", Game: "tanks", Seed: 1}
		}
		solo := dial(t, addr)
		solo.sendJSON(t, action)
		solo.welcome(t)
		solo.sendText(t, desyncBody)
		settled(solo, float64(i+1))
		solo.conn.Close()
	}
	expectSeries(t, s, map[string]float64{desynced("code"): 0, desynced("quick"): 0, early: 0})

	// Alone in a room, a player says it twice: the second is early, and still
	// nothing is counted.
	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 1})
	code := host.welcome(t).Code
	host.sendText(t, desyncBody)
	host.sendText(t, desyncBody)
	settled(host, 4)
	expectSeries(t, s, map[string]float64{desynced("code"): 0, early: 1})

	// The room is left free to count a real one: once a partner has come, the
	// partner's desync is the match's.
	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code})
	guest.welcome(t)
	guest.sendText(t, desyncBody)
	eventually(t, func() bool { return metricValue(t, s, desynced("code")) == 1 })
	expectSeries(t, s, map[string]float64{desynced("quick"): 0, early: 1})

	bare := newRoom("ABCDEF", "tanks", 3)
	bare.Join()
	if bare.noteDesync() {
		t.Error("a room with a single player noted a desync")
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

// The delay a player reports is no longer a reading of the network. A client on
// the current build reports the same small number every window; one on an older
// build reported a number that climbed from five to sixteen as its link fell
// short. The histogram earns its keep only while the two land in different
// buckets — that is now the question it answers: which builds are in play.
func TestTheReportedDelayTellsTheBuildsApart(t *testing.T) {
	s := &server{hub: NewHub()}
	room, _ := s.hub.Create("code", 1)
	member, _ := room.JoinAs(client{platform: "web"})
	// Each report on a gate of its own, so the pace allowance turns none away.
	for _, p := range []pace{
		{Speed: 100, Delay: 2, FPS: 60},
		{Speed: 100, Delay: 2, FPS: 60},
		{Speed: 100, Delay: 5, FPS: 60},
		{Speed: 100, Delay: 8, FPS: 60},
	} {
		var reports reportGate
		s.takeReport(&reports, member, room, paceBody(p), time.Now())
	}
	expectSeries(t, s, map[string]float64{
		`relay_client_input_delay_ticks_bucket{le="2"}`: 2,
		`relay_client_input_delay_ticks_bucket{le="5"}`: 3,
		`relay_client_input_delay_ticks_bucket{le="8"}`: 4,
		`relay_client_input_delay_ticks_count`:          4,
		`relay_client_input_delay_ticks_sum`:            17,
	})
	checkExposition(t, renderMetrics(s))
}

func TestTheLogNamesASilentPartner(t *testing.T) {
	// The hang between two levels was read off packet counts: one slot sent
	// nothing for half a minute, the other sent bursts once a second. The window
	// line of the side still sending now says who has gone quiet, and the line
	// for a side leaving says how long it had been quiet.
	// Not parallel: it takes over the package's log for its duration.
	captured := &lockedBuffer{}
	kept := log.Writer()
	log.SetOutput(captured)
	defer log.SetOutput(kept)

	s := &server{hub: NewHub(), statsEvery: 50 * time.Millisecond}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, code := seatPair(t, addr)
	packet := []byte{1, 0, 0, 0, 0, 31}
	host.send(t, packet)
	expectPacket(t, guest, packet)
	// The guest sends on past the host's last packet for a few windows.
	named := regexp.MustCompile(`room ` + code + `, slot 1: [^\n]*slot 0 silent`)
	for deadline := time.Now().Add(2 * time.Second); !named.MatchString(captured.String()); {
		if time.Now().After(deadline) {
			t.Fatalf("no window line named the silent host: %q", captured.String())
		}
		time.Sleep(20 * time.Millisecond)
		guest.send(t, packet)
		expectPacket(t, host, packet)
	}
	host.conn.Close()
	// This room's line, not just any: a test before this one may still be
	// letting its players go, and its lines land here too.
	eventually(t, func() bool { return strings.Contains(captured.String(), "room "+code+": player 1 left") })
	if !regexp.MustCompile(`room ` + code + `: player 1 left, 1 remain, journal \d+ records, silent \d+m?s before`).MatchString(captured.String()) {
		t.Fatalf("the host leaving did not say how long they had been silent: %q", captured.String())
	}
}

func TestTheWindowLineSaysWhatCameAtOnceAfterTheWorstGap(t *testing.T) {
	// 2026-09-24: one player's stream stood for 100-460 ms nearly every window at
	// a normal packet count, and the log could not say whether their machine or
	// their network stood. The line now says how many packets came at once with
	// the end of the worst gap: a few for a machine catching up, many for a
	// network letting go of what it held.
	// Not parallel: it takes over the package's log for its duration.
	captured := &lockedBuffer{}
	kept := log.Writer()
	log.SetOutput(captured)
	defer log.SetOutput(kept)

	s := &server{hub: NewHub(), statsEvery: 50 * time.Millisecond}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, code := seatPair(t, addr)
	packet := []byte{1, 0, 0, 0, 0, 31}
	host.send(t, packet)
	expectPacket(t, guest, packet)
	// Past a window, nine packets in one write: what a network lets go of.
	time.Sleep(100 * time.Millisecond)
	var held []byte
	for i := 0; i < 9; i++ {
		held = append(held, clientFrame(opBinary, packet)...)
	}
	if _, err := host.conn.Write(held); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 9; i++ {
		expectPacket(t, guest, packet)
	}
	time.Sleep(20 * time.Millisecond)
	host.send(t, packet)
	expectPacket(t, guest, packet)
	eventually(t, func() bool { return strings.Contains(captured.String(), "room "+code+", slot 0: ") })
	if !regexp.MustCompile(`room ` + code + `, slot 0: \d+s, 1[01] packets, worst gap \d+ms, then 9 at once`).MatchString(captured.String()) {
		t.Fatalf("the window line does not say what came at once after the worst gap: %q", captured.String())
	}
}
