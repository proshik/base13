package main

import (
	"bytes"
	"encoding/json"
	"log"
	"regexp"
	"strings"
	"testing"
	"time"
)

// 2026-09-24: a complaint that the game lagged was read off one player's
// browser console, kept only because the tab was still open, and the other
// side was never seen at all. The server's log had packets and gaps and nothing
// of what each side itself saw. Now a player's own figures, its events and who
// it is reach the server's log, so one log read by the room's code tells the
// story — still held to what a stranger may write there.

// captureLog takes over the package's log until the test ends. Tests that use
// it are not parallel.
func captureLog(t *testing.T) *lockedBuffer {
	t.Helper()
	captured := &lockedBuffer{}
	kept := log.Writer()
	log.SetOutput(captured)
	t.Cleanup(func() { log.SetOutput(kept) })
	return captured
}

// fullPaceBody is a pace report of the current shape, every figure the
// client's own line prints.
func fullPaceBody(figures map[string]int) []byte {
	body, _ := json.Marshal(map[string]map[string]int{"report": figures})
	return body
}

func fullFigures() map[string]int {
	return map[string]int{
		"speed": 97, "waits": 2, "delay": 2, "fps": 60,
		"frozen": 1, "frozen_longest_ms": 2400, "stops_longest_ms": 120,
		"rollbacks": 40, "deepest": 9, "resim_ms": 12, "skips": 3,
		"lead": 4, "partner_lead": -1, "longest_frame_ms": 250,
	}
}

func noteBody(what string, figures map[string]int) []byte {
	note := map[string]any{"what": what}
	for name, n := range figures {
		note[name] = n
	}
	body, _ := json.Marshal(map[string]any{"note": note})
	return body
}

// waitForLine waits until the log carries a line matching the pattern.
func waitForLine(t *testing.T, captured *lockedBuffer, pattern string) {
	t.Helper()
	re := regexp.MustCompile(pattern)
	deadline := time.Now().Add(2 * time.Second)
	for !re.MatchString(captured.String()) {
		if time.Now().After(deadline) {
			t.Fatalf("no line matches %q in:\n%s", pattern, captured.String())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestWelcomeAnnouncesNotes(t *testing.T) {
	// A server from before notes reads the current report shape as malformed and
	// a note as nothing it knows. So a client sends them only to a server whose
	// welcome says it takes them, and a refusal says nothing of the kind.
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()
	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 1})
	if raw := host.receiveText(t); !bytes.Contains(raw, []byte(`"notes":true`)) {
		t.Errorf("the welcome does not announce notes: %s", raw)
	}
	refused := dial(t, addr)
	refused.sendJSON(t, hello{Action: "join", Game: "tanks", Code: "ZZZZZZ"})
	if raw := refused.receiveText(t); bytes.Contains(raw, []byte("notes")) {
		t.Errorf("a refusal announces notes: %s", raw)
	}
}

func TestAReportOfTheCurrentShapeIsRead(t *testing.T) {
	// The four figures every client sends, and beside them the rest of the
	// client's own line. The four are counted exactly as before; the rest is
	// only for the log.
	r := readReport(fullPaceBody(fullFigures()))
	if r.kind != paceReport {
		t.Fatalf("the current shape read as kind %d", r.kind)
	}
	want := pace{Speed: 97, Waits: 2, Delay: 2, FPS: 60, full: true, detail: paceDetail{
		Frozen: 1, FrozenLongestMS: 2400, StopsLongestMS: 120, Rollbacks: 40, Deepest: 9,
		ResimMS: 12, Skips: 3, Lead: 4, PartnerLead: -1, LongestFrameMS: 250,
	}}
	if r.pace != want {
		t.Errorf("read as %+v, expected %+v", r.pace, want)
	}

	// Either shape whole, or nothing: a figure too many or too few is not a
	// third shape.
	for _, drop := range []string{"frozen", "longest_frame_ms", "speed"} {
		figures := fullFigures()
		delete(figures, drop)
		if r := readReport(fullPaceBody(figures)); r.kind != malformedReport {
			t.Errorf("a report without %q read as kind %d", drop, r.kind)
		}
	}
	figures := fullFigures()
	figures["ping"] = 3
	if r := readReport(fullPaceBody(figures)); r.kind != malformedReport {
		t.Errorf("a report with a figure too many read as kind %d", r.kind)
	}
	// Four of the old ones and one new is neither shape either.
	if r := readReport([]byte(`{"report":{"speed":95,"waits":0,"delay":4,"fps":60,"frozen":1}}`)); r.kind != malformedReport {
		t.Errorf("the old shape with one new figure read as kind %d", r.kind)
	}
	// A fraction anywhere spoils the whole report, a new figure included.
	body := strings.Replace(string(fullPaceBody(fullFigures())), `"resim_ms":12`, `"resim_ms":12.5`, 1)
	if r := readReport([]byte(body)); r.kind != malformedReport {
		t.Errorf("a fractional resim read as kind %d", r.kind)
	}
}

func TestTheNewFiguresAreClamped(t *testing.T) {
	// They feed no histogram, but they are written to a log kept for as long as
	// whoever runs the server likes: a figure is held to what a window can be,
	// and at most seven digits long whatever was sent.
	huge := map[string]int{}
	tiny := map[string]int{}
	for name := range fullFigures() {
		huge[name] = 1_000_000_000
		tiny[name] = -1_000_000_000
	}
	high := readReport(fullPaceBody(huge)).pace
	if high.detail != (paceDetail{
		Frozen: 300, FrozenLongestMS: 3_600_000, StopsLongestMS: 3_600_000, Rollbacks: 10_000,
		Deepest: 300, ResimMS: 3_600_000, Skips: 300, Lead: 1000, PartnerLead: 1000, LongestFrameMS: 3_600_000,
	}) {
		t.Errorf("a billion everywhere clamped to %+v", high.detail)
	}
	low := readReport(fullPaceBody(tiny)).pace
	if low.detail != (paceDetail{Lead: -1000, PartnerLead: -1000}) {
		t.Errorf("minus a billion everywhere clamped to %+v", low.detail)
	}
}

func TestEachTakenReportIsOneLineOfTheLog(t *testing.T) {
	// One line a report, beside the window line, reading like the client's own:
	// the complaint is then read from the server's log alone. A report of the
	// older shape still says what it has. A report turned away as early says
	// nothing, and one that is malformed says nothing either.
	captured := captureLog(t)
	s := &server{hub: NewHub(), reportEvery: time.Hour}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, code := seatPair(t, addr)

	host.sendText(t, fullPaceBody(fullFigures()))
	waitForLine(t, captured, `room `+code+`, slot 0 client: speed 97%, stops 2 \(longest 120 ms\), frozen 1 \(longest 2400 ms\), `+
		`rollbacks 40 \(deepest 9\), resim 12 ms, skips 3, lead 4 against -1, longest frame 250 ms, 60 fps, delay 2\n`)

	guest.sendText(t, paceBody(pace{Speed: 88, Waits: 4, Delay: 8, FPS: 59}))
	waitForLine(t, captured, `room `+code+`, slot 1 client: speed 88%, stops 4, 59 fps, delay 8\n`)

	host.sendText(t, fullPaceBody(fullFigures()))
	host.sendText(t, fullPaceBody(fullFigures())) // past the allowance of two
	host.sendText(t, []byte(`{"report":{"speed":95,"waits":0,"delay":4,"fps":60,"frozen":1}}`))
	eventually(t, func() bool {
		return metricValue(t, s, `relay_client_reports_rejected_total{why="early"}`) == 1 &&
			metricValue(t, s, `relay_client_reports_rejected_total{why="malformed"}`) == 1
	})
	if got := strings.Count(captured.String(), "slot 0 client: speed"); got != 2 {
		t.Errorf("%d lines for the host's reports, expected the two taken:\n%s", got, captured.String())
	}
	// The current shape counts in the families exactly as the older one does.
	expectSeries(t, s, map[string]float64{
		`relay_client_windows_total{platform="macos",verdict="smooth"}`: 2,
		`relay_client_waits_total`:                                      8,
	})
}

func TestADesyncSaysItsTick(t *testing.T) {
	// A side that sees the worlds part says on which tick, to a server that
	// takes notes; one on an older build says only that they parted. Either is
	// one line, and counted once a room as before.
	captured := captureLog(t)
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, code := seatPair(t, addr)
	host.sendText(t, []byte(`{"desync":1260}`))
	waitForLine(t, captured, `room `+code+`, slot 0 client: worlds parted at tick 1260\n`)
	guest.sendText(t, desyncBody)
	waitForLine(t, captured, `room `+code+`, slot 1 client: worlds parted\n`)
	expectSeries(t, s, map[string]float64{`relay_desynced_matches_total{kind="code"}`: 1})

	for _, body := range []string{`{"desync":-1}`, `{"desync":1.5}`, `{"desync":"60"}`, `{"desync":null}`} {
		if r := readReport([]byte(body)); r.kind != malformedReport {
			t.Errorf("%s read as kind %d", body, r.kind)
		}
	}
	if r := readReport([]byte(`{"desync":60.0}`)); r.kind != desyncReport || r.tick != 60 {
		t.Errorf("a whole tick written as a float read as %+v", r)
	}
}

func TestEveryNoteIsOneLine(t *testing.T) {
	// The client's own event lines, told to the server: a stage beginning,
	// ending and done — which ends a hang between two stages — input sent again
	// and why, and a tab or a window going out of sight or focus, which tells a
	// player looking elsewhere from a network falling short. The server knows a
	// closed set of them and writes each in words of its own.
	captured := captureLog(t)
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()
	host, _, code := seatPair(t, addr)
	for _, c := range []struct {
		what    string
		figures map[string]int
		line    string
	}{
		{"stage_begins", map[string]int{"stage": 3}, "stage 3 begins"},
		{"stage_ends", map[string]int{"stage": 3, "tick": 4210, "ended": 4120, "seen": 4131},
			"stage 3 ends on tick 4210: ended in 4120, seen at 4131"},
		{"stage_done", map[string]int{"stage": 3, "tick": 4210}, "stage 3 done on tick 4210"},
		{"stood", map[string]int{"stage": 4, "tick": 17, "ms": 1003, "confirmed": 4, "from": 0, "through": 19},
			"stage 4: tick 17 stood 1003 ms, confirmed through 4, input sent again for 0..19"},
		{"horizon", map[string]int{"stage": 4, "tick": 5000, "ms": 1010, "confirmed": 4990, "from": 4976, "through": 5002},
			"stage 4: standing at the horizon 5000 for 1010 ms, confirmed through 4990, input sent again for 4976..5002"},
		{"link_back", map[string]int{"stage": 4, "from": 300, "through": 330},
			"stage 4: link back, input sent again for 300..330"},
		{"hidden", nil, "tab hidden"},
		{"visible", nil, "tab visible"},
		{"blur", nil, "window lost focus"},
		{"focus", nil, "window has focus"},
	} {
		host.sendText(t, noteBody(c.what, c.figures))
		waitForLine(t, captured, `room `+code+`, slot 0 client: `+regexp.QuoteMeta(c.line)+`\n`)
	}
	expectSeries(t, s, map[string]float64{
		`relay_client_reports_rejected_total{why="malformed"}`: 0,
		`relay_client_reports_rejected_total{why="early"}`:     0,
	})
}

func TestANoteIsOneOfTheKnownShapesOrNothing(t *testing.T) {
	// A note is a word from a closed set and whole numbers, exactly the ones
	// that word takes. Nothing a stranger writes reaches the log as it was
	// written: not an unknown word, not a string in a figure's place.
	for _, body := range []string{
		`{"note":{"what":"stage_begins"}}`,
		`{"note":{"what":"stage_begins","stage":3,"tick":1}}`,
		`{"note":{"what":"stage_begins","stage":"3"}}`,
		`{"note":{"what":"stage_begins","stage":3.5}}`,
		`{"note":{"what":"Stage_begins","stage":3}}`,
		`{"note":{"what":"rm -rf","stage":3}}`,
		`{"note":{"what":3}}`,
		`{"note":{"stage":3}}`,
		`{"note":{"what":"hidden","why":"x"}}`,
		`{"note":"hidden"}`,
		`{"note":{"what":"hidden"},"extra":1}`,
		`{"note":null}`,
	} {
		if r := readReport([]byte(body)); r.kind != malformedReport {
			t.Errorf("%s read as kind %d", body, r.kind)
		}
	}
	r := readReport([]byte(`{"note":{"stage":1e12,"what":"stage_begins"}}`))
	if r.kind != noteReport || r.note.figures[0] != 10_000_000 {
		t.Errorf("a stage of a trillion read as %+v, expected one clamped to ten million", r)
	}
}

func TestNotesHaveAnAllowanceOfTheirOwn(t *testing.T) {
	// A few notes come at once — a stage ends, is done and the next begins; a
	// tab goes out of sight and the window loses focus — so a burst of ten is
	// taken, and after it one every two seconds. Notes do not spend the pace
	// allowance, nor pace reports the notes'.
	start := time.Unix(1_700_000_000, 0)
	s := &server{hub: NewHub(), reportEvery: time.Hour}
	room, _ := s.hub.Create("tanks", 1)
	member, _ := room.JoinAs(client{platform: "web"})
	var gate reportGate
	for range noteBurst + 3 {
		s.takeReport(&gate, member, room, noteBody("hidden", nil), start)
	}
	s.takeReport(&gate, member, room, paceBody(pace{Speed: 100, Delay: 2, FPS: 60}), start)
	s.takeReport(&gate, member, room, noteBody("hidden", nil), start.Add(defaultNoteEvery-1))
	s.takeReport(&gate, member, room, noteBody("visible", nil), start.Add(defaultNoteEvery))
	expectSeries(t, s, map[string]float64{
		`relay_client_windows_total{platform="web",verdict="smooth"}`: 1,
		`relay_client_reports_rejected_total{why="early"}`:            4,
	})
}

func TestTheLogCarriesNothingAsAStrangerWroteIt(t *testing.T) {
	// The log now carries a player's figures and events, and only as the server
	// read them: whole numbers held to their bounds, words from its own closed
	// sets. A report turned away, early or malformed, leaves no trace there.
	captured := captureLog(t)
	s := &server{hub: NewHub(), reportEvery: time.Hour}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, _ := seatPair(t, addr)

	const marker = "Qz7markerXv"
	numbers := `{"report":{"speed":141421,"waits":271828,"delay":161803,"fps":314159}}`
	for _, body := range []string{
		numbers,
		numbers,
		numbers, // early
		`{"desync":true}`,
		`{"desync":true}`, // early
		`{"report":{"speed":"` + marker + `","waits":0,"delay":4,"fps":60}}`,
		`{"note":{"what":"` + marker + `"}}`,
		`{"note":{"what":"hidden","` + marker + `":1}}`,
		`{"desync":577215}`, // a second desync: early
		marker,
	} {
		host.sendText(t, []byte(body))
	}
	packet := []byte{1, 0, 0, 0, 0, 31}
	host.send(t, packet)
	expectPacket(t, guest, packet)
	host.conn.Close()
	guest.conn.Close()
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 0 })

	logged := captured.String()
	if !strings.Contains(logged, "speed 200%, stops 300, 1000 fps, delay 64") {
		t.Fatalf("the clamped figures never reached the log, the test proves nothing:\n%s", logged)
	}
	for _, word := range []string{marker, "141421", "271828", "161803", "314159", "577215"} {
		if strings.Contains(logged, word) {
			t.Errorf("the log carries %q as a stranger wrote it:\n%s", word, logged)
		}
	}
}

func TestTheJoinLineSaysWhoCame(t *testing.T) {
	// Which release, from where, and for the browser a family and a system —
	// never the whole user agent, and never what was sent past the closed sets.
	captured := captureLog(t)
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()
	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: "tanks", Seed: 1, Platform: "web", Version: "0.6.5",
		Browser: "chrome", OS: "macos"})
	code := host.welcome(t).Code
	waitForLine(t, captured, `room `+code+` \(private, game tanks\): player 1 joined, 1 in room, client 0\.6\.5 web \(chrome, macos\)\n`)

	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code, Platform: "web", Version: "Mozilla/5.0 (X11)",
		Browser: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit", OS: strings.Repeat("x", 300)})
	guest.welcome(t)
	waitForLine(t, captured, `player 2 joined, 2 in room, client other web \(other, other\)\n`)
	host.receiveText(t)

	// A desktop names no browser; an older client names nothing at all.
	host.send(t, []byte{1, 0, 0, 0, 0, 31})
	guest.receive(t)
	guest.conn.Close()
	eventually(t, func() bool { return strings.Contains(captured.String(), "player 2 left") })
	back := dial(t, addr)
	back.sendJSON(t, hello{Action: "join", Game: "tanks", Code: code, Since: 1})
	back.welcome(t)
	waitForLine(t, captured, `player 2 returned, sending 0 records, 2 in room, client unknown unknown\n`)

	for _, c := range []struct{ platform, version, browser, os, want string }{
		{"macos", "0.6.5", "", "", "0.6.5 macos"},
		{"web_ios", "0.6.5", "safari", "ios", "0.6.5 web_ios (safari, ios)"},
		{"web", "0.6.5", "", "", "0.6.5 web (unknown, unknown)"},
		{"web", "0.6.5", "chrome", "", "0.6.5 web (chrome, unknown)"},
		{"linux", "0.6.5", "chrome", "linux", "0.6.5 linux"},
	} {
		who := client{platform: platformLabel(c.platform), version: versionLabel(c.version)}
		if got := who.describe(c.browser, c.os); got != c.want {
			t.Errorf("%+v described as %q, expected %q", c, got, c.want)
		}
	}
}

func TestTheWindowLineSaysTheLastRoundTrip(t *testing.T) {
	// The server pings every twenty seconds and a window is five, so a window
	// holds one round trip at most: its line says the last one measured, and
	// nothing before the first.
	captured := captureLog(t)
	s := &server{hub: NewHub(), statsEvery: 50 * time.Millisecond, pingEvery: 30 * time.Millisecond}
	addr, stop := serve(t, s)
	defer stop()
	host, guest, _ := seatPair(t, addr)
	packet := []byte{1, 0, 0, 0, 0, 31}
	// Only the guest answers pings, so only the guest's line has a round trip
	// to say; the host's, whose pings go unanswered, says none.
	deadline := time.Now().Add(3 * time.Second)
	for !regexp.MustCompile(`slot 1: [^\n]*, rtt \d+(\.\d+)?[mµn]?s\n`).MatchString(captured.String()) {
		if time.Now().After(deadline) {
			t.Fatalf("no window line said a round trip:\n%s", captured.String())
		}
		guest.send(t, packet)
		for {
			if opcode, _ := host.receiveFrame(t); opcode == opBinary {
				break
			}
		}
		host.send(t, packet)
		for {
			opcode, payload := guest.receiveFrame(t)
			if opcode == opPing {
				guest.conn.Write(clientFrame(opPong, payload))
				continue
			}
			if opcode == opBinary {
				break
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if regexp.MustCompile(`slot 0: [^\n]*rtt`).MatchString(captured.String()) {
		t.Errorf("a side that never answered a ping was given a round trip:\n%s", captured.String())
	}
}
