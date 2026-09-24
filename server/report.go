package main

// A player's own report on how its game runs.
//
// The server measures the network by itself: the round trip to a player, the
// gaps in a player's stream. A game can also run slow because of the machine,
// though, and only the player's side sees that: how long a window of ticks
// took, how often it stopped to wait for the partner's input, at what input
// delay and at what frame rate. So the client reports these once a window, and
// the server counts what it is told, and writes it to its log beside its own
// window line: a complaint is then read from one log, by the room's code.
//
// None of it is taken on trust. A report is whatever a stranger chose to write.
// It is read into a fixed shape or dropped, every figure is held to what a real
// window can be, and over time a connection is heard no more than once an
// interval. Nothing from a report is relayed or journaled, and the log gets
// only what the server read: whole numbers within their bounds, in the server's
// own words. A forged report can still skew the figures within those bounds,
// and that is the price of hearing from the player's side at all.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// A player's side reports once every three hundred ticks, which is five seconds
// at full speed. The interval leaves room for a window that ran somewhat fast
// while catching up, and none for a stream of reports.
const defaultReportEvery = 4 * time.Second

// How many pace reports a connection may have taken at once. The allowance
// refills by one every interval. Two, not one: on a bad link a report held up
// on the way arrives close to the next one sent on time, and that link's
// arrival jitter is exactly what these figures are for. Over time the bound is
// still one report an interval.
const paceBurst = 2

// pace is one window of a player's game, as its own side measured it.
type pace struct {
	Speed int `json:"speed"` // ticks computed, in percent of sixty a second
	Waits int `json:"waits"` // times the game stopped for the partner's input
	Delay int `json:"delay"` // the input delay, in ticks
	FPS   int `json:"fps"`   // frames drawn a second
	// The rest of the client's own line, which only the current shape carries,
	// and whether this report carried it. Only for the log: no family counts it.
	detail paceDetail
	full   bool
}

// paceDetail is the rest of a window as the client's own line prints it.
type paceDetail struct {
	Frozen          int // stands too long to be the network: a frame loop standing still
	FrozenLongestMS int
	StopsLongestMS  int
	Rollbacks       int // times a guess was wrong and the game stepped back
	Deepest         int // how far back the deepest one went, in ticks
	ResimMS         int // what stepping back cost the machine
	Skips           int // ticks let go to fall back into step
	Lead            int // how far ahead of the partner the side ran, in ticks
	PartnerLead     int // the same, as the partner last said it
	LongestFrameMS  int
}

// reportKind is what a text message from a player turned out to be.
type reportKind int

const (
	malformedReport reportKind = iota
	paceReport
	desyncReport
	noteReport
)

// report is a text message from a player, as the server read it.
type report struct {
	kind reportKind
	pace pace
	tick int // the tick a desync was seen on, or -1 when it was not said
	note note
}

// A figure of a pace report: its key and where it goes. The first four are
// every client's, the rest only the current shape's.
type figure struct {
	name string
	into func(*pace) *int
}

var paceFigures = []figure{
	{"speed", func(p *pace) *int { return &p.Speed }},
	{"waits", func(p *pace) *int { return &p.Waits }},
	{"delay", func(p *pace) *int { return &p.Delay }},
	{"fps", func(p *pace) *int { return &p.FPS }},
}

var detailFigures = []figure{
	{"frozen", func(p *pace) *int { return &p.detail.Frozen }},
	{"frozen_longest_ms", func(p *pace) *int { return &p.detail.FrozenLongestMS }},
	{"stops_longest_ms", func(p *pace) *int { return &p.detail.StopsLongestMS }},
	{"rollbacks", func(p *pace) *int { return &p.detail.Rollbacks }},
	{"deepest", func(p *pace) *int { return &p.detail.Deepest }},
	{"resim_ms", func(p *pace) *int { return &p.detail.ResimMS }},
	{"skips", func(p *pace) *int { return &p.detail.Skips }},
	{"lead", func(p *pace) *int { return &p.detail.Lead }},
	{"partner_lead", func(p *pace) *int { return &p.detail.PartnerLead }},
	{"longest_frame_ms", func(p *pace) *int { return &p.detail.LongestFrameMS }},
}

// readReport reads a text message as one of the reports a player may send.
// The shapes are exact:
//
//	{"report":{"speed":95,"waits":0,"delay":6,"fps":60}}
//	{"report":{"speed":95,"waits":0,"delay":6,"fps":60,"frozen":0,...}}
//	{"desync":true}
//	{"desync":1260}
//	{"note":{"what":"hidden"}}
//
// A pace report has either the four figures every client sends or those and
// the ten of the current shape, nothing between. A desync says the tick it was
// seen on, or on an older build only that it happened. A note is one of the
// shapes in notes.go. A client sends the current shapes only to a server whose
// welcome announced notes.
//
// Everything else is malformed: a key in another case, a key too many or too
// few, a number that is not whole, a string, a null. Keys are compared exactly,
// not through a struct, because the standard decoder folds case and fills a
// missing or null field with zero, and a zero here would count as a real
// window. Spacing, key order and how a whole number is spelled are up to the
// writer. What comes back is already clamped.
func readReport(data []byte) report {
	malformed := report{kind: malformedReport}
	var message map[string]json.RawMessage
	if json.Unmarshal(data, &message) != nil || len(message) != 1 {
		return malformed
	}
	if raw, found := message["desync"]; found {
		if string(bytes.TrimSpace(raw)) == "true" {
			return report{kind: desyncReport, tick: -1}
		}
		tick, ok := wholeNumber(raw)
		if !ok || tick < 0 {
			return malformed
		}
		return report{kind: desyncReport, tick: min(tick, maxNoteFigure)}
	}
	if raw, found := message["note"]; found {
		n, ok := readNote(raw)
		if !ok {
			return malformed
		}
		return report{kind: noteReport, note: n}
	}
	raw, found := message["report"]
	if !found {
		return malformed
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return malformed
	}
	var p pace
	figures := paceFigures
	switch len(fields) {
	case len(paceFigures):
	case len(paceFigures) + len(detailFigures):
		figures = append(append([]figure{}, paceFigures...), detailFigures...)
		p.full = true
	default:
		return malformed
	}
	for _, f := range figures {
		n, ok := wholeNumber(fields[f.name])
		if !ok {
			return malformed
		}
		*f.into(&p) = n
	}
	return report{kind: paceReport, pace: clamp(p)}
}

// wholeNumber reads one JSON value as a whole number, however it is spelled:
// 60, 60.0 or 6e1. Godot writes every float with a point even when it is whole,
// and the frame rate it measures is a float. A fraction is not a figure, and
// neither is a string, a null, a number past what a double holds, or a missing
// key, which reads as empty. The message already parsed as JSON, so the text
// is a single JSON value, and every JSON number is one strconv reads.
func wholeNumber(raw json.RawMessage) (int, bool) {
	f, err := strconv.ParseFloat(string(bytes.TrimSpace(raw)), 64)
	if err != nil || f != math.Trunc(f) {
		return 0, false
	}
	// Held within a billion either way before it becomes an int. Converting a
	// double past what an int holds gives no defined value, and every figure's
	// own limit, applied by clamp, lies far inside this.
	return int(min(max(f, -1e9), 1e9)), true
}

// clamp holds each figure to what a real window can be. Speed stops at twice
// full speed. Waits stop at three hundred, one for every tick of a window.
// Delay stops at sixty-four ticks, over a second and far past anything the game
// raises it to. The frame rate stops past any display. Below, nothing is
// negative. Without this, one report of a billion waits would outweigh every
// honest window in a histogram's sum.
//
// The rest of the current shape feeds no family, only the log, and is held the
// same way so that no figure there runs past seven digits: counts of the
// window's ticks stop at three hundred, a duration at an hour, rollbacks at
// ten thousand, a lead at a thousand ticks either way.
func clamp(p pace) pace {
	const hour = 3_600_000
	d := p.detail
	return pace{
		Speed: min(max(p.Speed, 0), 200),
		Waits: min(max(p.Waits, 0), 300),
		Delay: min(max(p.Delay, 0), 64),
		FPS:   min(max(p.FPS, 0), 1000),
		detail: paceDetail{
			Frozen:          min(max(d.Frozen, 0), 300),
			FrozenLongestMS: min(max(d.FrozenLongestMS, 0), hour),
			StopsLongestMS:  min(max(d.StopsLongestMS, 0), hour),
			Rollbacks:       min(max(d.Rollbacks, 0), 10_000),
			Deepest:         min(max(d.Deepest, 0), 300),
			ResimMS:         min(max(d.ResimMS, 0), hour),
			Skips:           min(max(d.Skips, 0), 300),
			Lead:            min(max(d.Lead, -1000), 1000),
			PartnerLead:     min(max(d.PartnerLead, -1000), 1000),
			LongestFrameMS:  min(max(d.LongestFrameMS, 0), hour),
		},
		full: p.full,
	}
}

// line is a window as the log says it, in the words of the client's own line.
// Waits are the client's stops. A report of the older shape says what it has.
func (p pace) line() string {
	if !p.full {
		return fmt.Sprintf("speed %d%%, stops %d, %d fps, delay %d", p.Speed, p.Waits, p.FPS, p.Delay)
	}
	d := p.detail
	return fmt.Sprintf("speed %d%%, stops %d (longest %d ms), frozen %d (longest %d ms), "+
		"rollbacks %d (deepest %d), resim %d ms, skips %d, lead %d against %d, longest frame %d ms, "+
		"%d fps, delay %d",
		p.Speed, p.Waits, d.StopsLongestMS, d.Frozen, d.FrozenLongestMS,
		d.Rollbacks, d.Deepest, d.ResimMS, d.Skips, d.Lead, d.PartnerLead, d.LongestFrameMS,
		p.FPS, p.Delay)
}

// verdict names what a window was lost to. It is the same rule a person reads
// the client's own log line by. At 95% of full speed or more the window was
// smooth. Below that, a window that waited for the partner's input lost its
// time to the network, and one that never waited lost it to the machine.
func verdict(speed, waits int) string {
	switch {
	case speed >= 95:
		return "smooth"
	case waits > 0:
		return "network"
	}
	return "machine"
}

// reportGate is what one connection's reports have had taken so far. It lives
// on the goroutine that reads the connection and nowhere else.
type reportGate struct {
	pace     allowance
	notes    allowance
	desynced bool // whether this connection has already reported a desync
}

// allowance is a bucket of credit kept as time rather than as a count: an
// interval of credit is one message. seen is when the credit was last brought
// up to date, and zero until the first message, when a connection starts with
// a full allowance.
type allowance struct {
	credit time.Duration
	seen   time.Time
}

// allow reports whether a message arriving now fits the allowance, and spends
// it if it does. Time since the last message earns credit, up to burst
// intervals of it, and a message taken spends one interval. A message turned
// away spends nothing but still brings the credit up to date, so turning one
// away never costs the next. The clock is a parameter so a test can hold it.
func (a *allowance) allow(now time.Time, every time.Duration, burst int) bool {
	full := time.Duration(burst) * every
	if a.seen.IsZero() {
		a.credit = full
	} else {
		// Bounded before it is added, so a connection quiet for years cannot
		// overflow the sum, and a clock that stepped back earns nothing.
		a.credit = min(a.credit+min(max(now.Sub(a.seen), 0), full), full)
	}
	a.seen = now
	if a.credit < every {
		return false
	}
	a.credit -= every
	return true
}

// allowPace reports whether a pace report arriving now fits the connection's
// allowance of paceBurst, and spends it if it does.
func (g *reportGate) allowPace(now time.Time, every time.Duration) bool {
	return g.pace.allow(now, every, paceBurst)
}

// takeReport counts one text message a seated player sent after the hello, and
// writes what it took to the log, one line a message.
//
// A connection may have two pace reports taken at once, and earns one back
// every interval. A report past that allowance is rejected as early. Notes have
// an allowance of their own, noteBurst at once and one back every note
// interval. A desync is not a window, so no allowance applies, but a
// connection reports a desync only once: a repeat is also rejected as early,
// so a client that keeps repeating it cannot keep taking the room's lock.
//
// A desync counts once a room, whichever side reports it first, and only in a
// room that has held a pair: before a partner came there was no match to part.
// A desync from a room that never paired is neither counted nor rejected, since
// it is well formed and on time. It still uses up the connection's one desync.
//
// A line carries only what readReport made of the message: its figures
// clamped, its words the server's own. A rejection is a count, not a line: it
// is exactly what a stranger may send as often as they like.
func (s *server) takeReport(gate *reportGate, member *Member, room *Room, data []byte, now time.Time) {
	counted := s.hub.stats
	r := readReport(data)
	said := ""
	switch r.kind {
	case desyncReport:
		if gate.desynced {
			counted.reportRejected("early")
			return
		}
		gate.desynced = true
		if room.noteDesync() {
			counted.matchDesynced(room.kind())
		}
		said = "worlds parted"
		if r.tick >= 0 {
			said += fmt.Sprintf(" at tick %d", r.tick)
		}
	case paceReport:
		if !gate.allowPace(now, s.reportInterval()) {
			counted.reportRejected("early")
			return
		}
		counted.paced(member.client.platform, r.pace)
		said = r.pace.line()
	case noteReport:
		if !gate.notes.allow(now, s.noteInterval(), noteBurst) {
			counted.reportRejected("early")
			return
		}
		said = r.note.line()
	default:
		counted.reportRejected("malformed")
		return
	}
	log.Printf("room %s, slot %d client: %s", room.Code, member.Slot, said)
}

// clientReports is what players' reports add up to.
type clientReports struct {
	speed    histogramVec // over platformLabels
	windows  counterVec   // over windowLabels
	delay    prometheus.Histogram
	waits    prometheus.Counter
	fps      histogramVec // over platformLabels
	desynced counterVec   // over roomKindLabels
	rejected counterVec   // over rejectionLabels
}

// A window by the platform the player's hello named and by what it was lost
// to, if anything.
var windowLabels = labelSet{
	{"platform", platforms},
	{"verdict", []string{"smooth", "network", "machine"}},
}

// Why a report was dropped: it came sooner than allowed, or it was none of the
// shapes readReport takes.
var rejectionLabels = labelSet{{"why", []string{"early", "malformed"}}}

// A window's speed as a share of full speed. Half speed is a game that is
// plainly broken. The smooth line is at 0.95. The last two bounds sit just
// below and just above full speed, so a game keeping pace gets a bucket of its
// own. A report's whole percent over a hundred is the same double as the
// bound's own literal, so 95 and 99 land exactly on their bounds.
var speedBuckets = []float64{0.5, 0.75, 0.9, 0.95, 0.99, 1.01}

// Input delay in ticks. It used to be a reading of the network: a client raised
// it from five to sixteen as its link fell short, and the spread was the point.
// A client on the current build holds it at a small constant instead and absorbs
// a ragged link another way, so every window it sends lands at the bottom.
//
// The lowest bound is therefore what the histogram is now for: below it are
// clients on the current build, above it clients on an older one, still raising
// the delay as they always did. The upper bounds are kept so that those older
// clients stay as legible as before.
//
// A whole population on the current build reads under two rather than at two:
// a value sitting on a bucket's upper bound is interpolated across that bucket,
// and the lowest bucket runs from zero. The shape is what to read, not the digit.
var inputDelayBuckets = []float64{2, 5, 6, 8, 10, 12, 14, 16}

// Frames a second, from a slide show to a fast display. 55 and 60 sit close
// together so that a display that just misses sixty is told apart from one
// that keeps it.
var fpsBuckets = []float64{15, 30, 45, 55, 60, 120}

// newClientReports builds the families players' reports are counted into.
func newClientReports(f families) clientReports {
	return clientReports{
		speed: f.histogramVec("relay_client_speed_ratio",
			"How fast a player's game ran over a window of ticks, as a share of full speed, as the player's side "+
				"reported it, by the platform their hello named. Self-reported and clamped to 0..2; "+
				"only network games played through this server report.",
			platformLabels, speedBuckets),
		windows: f.counterVec("relay_client_windows_total",
			"Windows of ticks players reported, by platform and by what the window was lost to: "+
				"smooth at 95% of full speed or more; below that network if the game waited for the partner's input, "+
				"machine if it never did.",
			windowLabels),
		delay: f.histogram("relay_client_input_delay_ticks",
			"The input delay a player's game ran at, in ticks, observed once for every reported window. "+
				"Clients on the current build hold it at a small constant and pile into the lowest bucket; "+
				"older ones raised it from five to sixteen as their link fell short, so the spread above the "+
				"lowest bound is what those clients are still about. "+
				"Self-reported and clamped to 0..64.",
			inputDelayBuckets),
		waits: f.counter("relay_client_waits_total",
			"Times players' games stopped to wait for the partner's input, summed over reported windows; "+
				"each window clamped to 300."),
		fps: f.histogramVec("relay_client_fps",
			"Frames a second a player's side drew over a reported window, by the platform their hello named. "+
				"Self-reported and clamped to 0..1000.",
			platformLabels, fpsBuckets),
		desynced: f.counterVec("relay_desynced_matches_total",
			"Rooms whose two players' worlds parted, as a player reported it; counted once a room, "+
				"however many of its players report it, and only in a room that has held a pair.",
			roomKindLabels),
		rejected: f.counterVec("relay_client_reports_rejected_total",
			"Reports and notes from players that were dropped: early when a connection had used up "+
				"its allowance (for reports two at once, then one an interval; for notes ten at once, "+
				"then one every two seconds) or reported a desync twice; "+
				"malformed when it was none of the shapes the server reads.",
			rejectionLabels),
	}
}

// paced counts one pace report that was taken. Its figures are already
// clamped.
func (s *stats) paced(platform string, p pace) {
	if s == nil {
		return
	}
	platform = platformLabel(platform)
	r := &s.reports
	r.speed.observe(float64(p.Speed)/100, platform)
	r.windows.inc(platform, verdict(p.Speed, p.Waits))
	r.delay.Observe(float64(p.Delay))
	r.waits.Add(float64(p.Waits))
	r.fps.observe(float64(p.FPS), platform)
}

// matchDesynced counts one room whose two worlds parted, under its kind.
func (s *stats) matchDesynced(kind string) {
	if s == nil {
		return
	}
	s.reports.desynced.inc(kind)
}

// reportRejected counts one dropped report, under a reason from
// rejectionLabels.
func (s *stats) reportRejected(why string) {
	if s == nil {
		return
	}
	s.reports.rejected.inc(why)
}
