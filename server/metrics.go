package main

// Metrics in Prometheus's text format.
//
// Written by hand, the way the WebSocket layer is: the format is a line of
// text per series, and a client library would be the server's first
// dependency. What happens — a refusal, a pairing, a packet — is counted as it
// happens, in stats, which the hub holds. What is only true right now — how
// many connections are open, what the limits are — is read at the moment of
// the scrape instead, so there is no second copy of it to drift.
//
// Every label comes from a closed set the server defines. Nothing a client
// sends reaches a label as it was sent: each distinct label value is a new
// series, and a stranger who could pick the values could grow the render, and
// the memory of whatever scrapes it, without bound.

import (
	"bufio"
	"cmp"
	"fmt"
	"io"
	"maps"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// Stamped at build time with -ldflags "-X main.version=0.5.0". A build without
// the stamp is a developer's own.
var version = "dev"

// When the process started. Taken once and never written again: a restart
// shows on a dashboard as this jumping, and nothing else may move it.
var startTime = time.Now()

// The shape of a release version, the only kind of version a label may carry.
var releaseVersion = regexp.MustCompile(`^\d{1,3}\.\d{1,3}\.\d{1,3}$`)

// buildVersion is the version as a label may carry it. The stamp comes from
// whatever the release was given, and a "v0.5.0" typed by hand, or anything
// with a quote in it, would otherwise reach every render as it was typed.
func buildVersion() string {
	if version == "dev" || releaseVersion.MatchString(version) {
		return version
	}
	return "unknown"
}

var goRelease = regexp.MustCompile(`^go[0-9a-z.]+$`)

// goVersionLabel is the Go toolchain's name as a label may carry it. A release
// names itself plainly, "go1.26.4"; an experiment appends " X:name" and a
// development build starts with "devel", and neither fits a closed label.
func goVersionLabel(reported string) string {
	name, _, _ := strings.Cut(reported, " ")
	if goRelease.MatchString(name) {
		return name
	}
	return "unknown"
}

// stats is everything the server counts as it goes. The hub holds it by value,
// so a hub built bare in a test counts from zero with nothing to set up. Rooms
// and members that count something hold a pointer to the hub's, and a nil
// pointer counts nothing: every method that records begins with
// `if s == nil { return }`, so a room built bare works too.
//
// A new counter is an atomic.Uint64 field; a counter over a closed label set
// is a counterVec; a histogram is a histogram, or a histogramVec over a label
// set. Recording takes no lock — it runs on the paths that relay packets — and
// writeMetrics renders each field in its place.
type stats struct {
	opened      atomic.Uint64
	refusals    counterVec // over refusalLabels
	disconnects counterVec // over disconnectLabels
	seatings    counterVec // over seatingLabels

	roomsCreated counterVec   // over roomKindLabels
	pairings     counterVec   // over roomKindLabels
	pairingWaits histogramVec // over pairingWaitLabels, pairingWaitBuckets
	played       histogramVec // over roomKindLabels, playedBuckets
	capped       atomic.Uint64

	packets     atomic.Uint64
	packetBytes atomic.Uint64
	evicted     atomic.Uint64
	rtt         histogramVec // over platformLabels, rttBuckets
	worstGaps   histogram    // over worstGapBuckets
	forwards    histogram    // over forwardBuckets

	reports clientReports // see report.go

	responses     counterVec   // over httpResponseLabels
	responseTimes histogramVec // over httpRouteLabels, httpResponseBuckets
}

// Why a connection was refused. Both limits reach the client as the same
// "busy", which is all it needs to show; whoever runs the server needs to know
// which limit it was, because raising the wrong one fixes nothing.
var refusalLabels = labelSet{{"reason", []string{
	"rooms_limit", "connections_limit", "full", "no_room", "bad_hello", "other",
}}}

// How a seated player's connection ended: they said goodbye, went silent past
// the read deadline, dropped without a word, were cut off by our own side, or
// broke the protocol.
var disconnectLabels = labelSet{{"cause", []string{
	"goodbye", "idle", "lost", "cut", "protocol",
}}}

// Every platform a hello may name, and the two folds for the rest: a client
// that names none is unknown, and anything else it names is other.
var platforms = []string{
	"web", "web_android", "web_ios", "macos", "windows", "linux", "android", "ios", "unknown", "other",
}

var platformLabels = labelSet{{"platform", platforms}}

// How a player sat down: opening a room, joining one by its code, the quick
// game, or coming back by code after a drop.
var seatingLabels = labelSet{
	{"action", []string{"create", "join", "quick", "return"}},
	{"platform", platforms},
}

// A room is opened by code for one particular partner, or by the quick game for
// whoever comes next. The two are judged apart: a code was passed on to someone
// who is expected, while the quick game waits on strangers.
var roomKinds = []string{"code", "quick"}

var roomKindLabels = labelSet{{"kind", roomKinds}}

// Where a room stands: one player waiting for a partner not yet met, two
// playing, one left alone by a partner the room already had, or nobody.
var roomStateLabels = labelSet{
	{"kind", roomKinds},
	{"state", []string{"waiting", "playing", "interrupted", "empty"}},
}

// How a wait for a partner ended: the partner came, or the room was swept with
// nobody having come.
var pairingWaitLabels = labelSet{
	{"kind", roomKinds},
	{"outcome", []string{"paired", "abandoned"}},
}

// Waits from a second to ten minutes: few people look at a waiting screen for
// longer than that.
var pairingWaitBuckets = durationBuckets(1, 2, 5, 10, 20, 30, 60, 120, 300, 600)

// Time together from half a minute, a pair that met and parted at once, to two
// hours, a long evening's match.
var playedBuckets = durationBuckets(30, 60, 120, 300, 600, 1200, 1800, 3600, 7200)

// A round trip to a player, from ten milliseconds, a neighbour on the same
// network, to over a second and a half, a link no lockstep game survives.
var rttBuckets = durationBuckets(0.01, 0.025, 0.05, 0.1, 0.2, 0.4, 0.8, 1.6)

// The worst gap in a player's stream over a window, from three frames at sixty
// a second, a hitch few notice, to a stall long enough to read as a dropped link.
var worstGapBuckets = durationBuckets(0.05, 0.1, 0.25, 0.5, 1, 2.5)

// The server's own delay, from half a millisecond, a relay with nothing in its
// way, to a second, a socket that barely takes anything.
var forwardBuckets = durationBuckets(0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1)

// What a response for the game's files was to a player: the page they open,
// the engine they wait on, or one of the small files around them.
var httpRoutes = []string{"page", "wasm", "other"}

var httpRouteLabels = labelSet{{"route", httpRoutes}}

// A response by route, by the class of its status, and by whether the gzipped
// twin went out. The class is enough to tell a download from a cached engine or
// a missing file, and a status code of its own per series would multiply them
// for nothing.
var httpResponseLabels = labelSet{
	{"route", httpRoutes},
	{"class", []string{"2xx", "3xx", "4xx", "5xx"}},
	{"encoding", []string{"gzip", "identity"}},
}

// A response from a tenth of a second, a page or a cached engine, to a minute,
// an engine downloaded over a slow mobile link.
var httpResponseBuckets = durationBuckets(0.1, 0.5, 1, 2.5, 5, 10, 30, 60)

// How many versions get a series of their own among the players seated right
// now. Past it they are other: releases pile up over the years, and a script
// could make up as many as it likes.
const maxVersionSeries = 10

// platformLabel folds whatever a hello named as its platform into the closed
// set. A label passed through it again comes back unchanged, so a member that
// keeps only the label can be counted through it too.
func platformLabel(sent string) string {
	switch {
	case sent == "":
		return "unknown"
	case slices.Contains(platforms, sent):
		return sent
	}
	return "other"
}

// versionLabel folds whatever a hello named as its version: a release version
// is kept, since the set of those is folded again at the scrape, none is
// unknown, and anything else is other. Like platformLabel, it leaves a label
// as it is.
func versionLabel(sent string) string {
	switch {
	case sent == "":
		return "unknown"
	case sent == "unknown" || releaseVersion.MatchString(sent):
		return sent
	}
	return "other"
}

// connectionOpened counts one WebSocket upgrade, whatever becomes of it after.
func (s *stats) connectionOpened() {
	if s == nil {
		return
	}
	s.opened.Add(1)
}

// refused counts one refusal under a reason from refusalLabels.
func (s *stats) refused(reason string) {
	if s == nil {
		return
	}
	s.refusals.inc(refusalLabels, reason)
}

// disconnected counts one seated connection ending, under a cause from
// disconnectLabels.
func (s *stats) disconnected(cause string) {
	if s == nil {
		return
	}
	s.disconnects.inc(disconnectLabels, cause)
}

// seated counts one player sitting down, under an action from seatingLabels
// and the platform their hello named.
func (s *stats) seated(action, platform string) {
	if s == nil {
		return
	}
	s.seatings.inc(seatingLabels, action, platformLabel(platform))
}

// roomCreated counts one room opened, under its kind.
func (s *stats) roomCreated(kind string) {
	if s == nil {
		return
	}
	s.roomsCreated.inc(roomKindLabels, kind)
}

// roomPaired counts a room's first pair, and how long the player already there
// waited for it.
func (s *stats) roomPaired(kind string, waited time.Duration) {
	if s == nil {
		return
	}
	s.pairings.inc(roomKindLabels, kind)
	s.pairingWaits.at(pairingWaitLabels, kind, "paired").observeDuration(pairingWaitBuckets, waited)
}

// waitAbandoned observes how long a room waited for a partner who never came.
func (s *stats) waitAbandoned(kind string, waited time.Duration) {
	if s == nil {
		return
	}
	s.pairingWaits.at(pairingWaitLabels, kind, "abandoned").observeDuration(pairingWaitBuckets, waited)
}

// roomPlayed observes how long a room that is gone held two players.
func (s *stats) roomPlayed(kind string, together time.Duration) {
	if s == nil {
		return
	}
	s.played.at(roomKindLabels, kind).observeDuration(playedBuckets, together)
}

// journalCapReached counts one room whose journal stopped taking records.
func (s *stats) journalCapReached() {
	if s == nil {
		return
	}
	s.capped.Add(1)
}

// relayed counts one game packet read from a player and handed to the room, and
// its size.
func (s *stats) relayed(size int) {
	if s == nil {
		return
	}
	s.packets.Add(1)
	s.packetBytes.Add(uint64(size))
}

// memberEvicted counts one member the room dropped for falling behind.
func (s *stats) memberEvicted() {
	if s == nil {
		return
	}
	s.evicted.Add(1)
}

// observeRTT observes one round trip to a player, under the platform their hello
// named.
func (s *stats) observeRTT(platform string, took time.Duration) {
	if s == nil {
		return
	}
	s.rtt.at(platformLabels, platformLabel(platform)).observeDuration(rttBuckets, took)
}

// observeWorstGap observes the longest a player's stream went quiet over one
// window.
func (s *stats) observeWorstGap(gap time.Duration) {
	if s == nil {
		return
	}
	s.worstGaps.observeDuration(worstGapBuckets, gap)
}

// observeForward observes how long a game packet took from being relayed to
// being in the partner's socket.
func (s *stats) observeForward(took time.Duration) {
	if s == nil {
		return
	}
	s.forwards.observeDuration(forwardBuckets, took)
}

// responded counts one response for the game's files, under its route, the
// class of its status and whether it went out gzipped, and observes how long it
// took.
func (s *stats) responded(route string, status int, gzip bool, took time.Duration) {
	if s == nil {
		return
	}
	encoding := "identity"
	if gzip {
		encoding = "gzip"
	}
	s.responses.inc(httpResponseLabels, route, statusClass(status), encoding)
	s.responseTimes.at(httpRouteLabels, route).observeDuration(httpResponseBuckets, took)
}

// statusClass folds a status into its class. Below 300 counts as a success:
// nothing behind the wrapper sends an interim 1xx status. From 500 up is a
// failure, however far up.
func statusClass(status int) string {
	switch {
	case status < 300:
		return "2xx"
	case status < 400:
		return "3xx"
	case status < 500:
		return "4xx"
	}
	return "5xx"
}

// livePlayers counts whoever is seated right now, by platform and by version
// label, the rooms they sit in, by kind and state, and the memory every room's
// journal holds. One walk gives all of it, so a room's players and its state
// come from the same moment. It takes each room's lock in turn and never the
// hub's: the caller copies the rooms out from under that, so a scrape does not
// hold up everyone sitting down for as long as it takes to walk every room.
func livePlayers(rooms []*Room) (byPlatform []float64, byVersion map[string]int, byState []float64, journalBytes int) {
	byPlatform = make([]float64, platformLabels.size())
	byVersion = map[string]int{}
	byState = make([]float64, roomStateLabels.size())
	for _, room := range rooms {
		room.mu.Lock()
		if i := roomStateLabels.index(room.kind(), room.state()); i >= 0 {
			byState[i]++
		}
		journalBytes += room.journal.bytes()
		for _, member := range room.members {
			if i := platformLabels.index(platformLabel(member.client.platform)); i >= 0 {
				byPlatform[i]++
			}
			byVersion[versionLabel(member.client.version)]++
		}
		room.mu.Unlock()
	}
	return byPlatform, byVersion, byState, journalBytes
}

// versionCount is one version's series among the live players.
type versionCount struct {
	version string
	players int
}

// foldVersions picks the series a scrape renders for live versions: the most
// common release versions, most players first and ties in string order so two
// scrapes of the same players agree, at most maxVersionSeries of them; then
// other, which takes every version past those as well as players already
// labelled other; then unknown. Other and unknown are always there, at zero
// too, so a panel over them never has a gap.
func foldVersions(byVersion map[string]int) []versionCount {
	ranked := make([]versionCount, 0, len(byVersion))
	for version, players := range byVersion {
		if version != "unknown" && version != "other" {
			ranked = append(ranked, versionCount{version, players})
		}
	}
	slices.SortFunc(ranked, func(a, b versionCount) int {
		if a.players != b.players {
			return cmp.Compare(b.players, a.players)
		}
		return strings.Compare(a.version, b.version)
	})
	other := byVersion["other"]
	for _, past := range ranked[min(len(ranked), maxVersionSeries):] {
		other += past.players
	}
	ranked = ranked[:min(len(ranked), maxVersionSeries)]
	return append(ranked, versionCount{"other", other}, versionCount{"unknown", byVersion["unknown"]})
}

// writeMetrics renders the server's whole state. Families come in a fixed
// order, so two scrapes of the same state are the same bytes.
func (s *server) writeMetrics(w io.Writer) {
	// Each lock is held only to copy what it guards, and never two at once:
	// holding one while taking the other would be a new lock order for the whole
	// server to keep. The hub's gives up its list of rooms, and each room is then
	// locked on its own.
	s.mu.Lock()
	connections := len(s.conns)
	s.mu.Unlock()
	s.hub.mu.Lock()
	roomsLimit := s.hub.limit
	rooms := slices.Collect(maps.Values(s.hub.rooms))
	s.hub.mu.Unlock()
	byPlatform, byVersion, byState, journalBytes := livePlayers(rooms)

	e := newExposition(w)
	defer e.flush()

	e.family("relay_build_info", "gauge", "The version the server was built as and the Go it was built with; always 1.")
	e.sample("relay_build_info", []label{
		{"version", buildVersion()},
		{"goversion", goVersionLabel(runtime.Version())},
	}, 1)
	e.gauge("relay_start_time_seconds", "When the process started, in seconds since the Unix epoch.",
		float64(startTime.UnixNano())/1e9)

	e.gauge("relay_connections", "Connections open right now, in a room or still saying hello.", float64(connections))
	e.gauge("relay_connections_limit", "The most connections held at once; zero means no cap.", float64(s.maxConns))
	e.family("relay_rooms", "gauge",
		"Rooms held right now, by kind and by state: waiting for a first partner, playing, "+
			"interrupted when a partner the room already had is gone, or empty.")
	for i := range roomStateLabels.size() {
		e.sample("relay_rooms", roomStateLabels.labels(i), byState[i])
	}
	e.gauge("relay_rooms_limit", "The most rooms held at once.", float64(roomsLimit))
	e.family("relay_players", "gauge", "Players seated in a room right now, by the platform their hello named.")
	for i := range platformLabels.size() {
		e.sample("relay_players", platformLabels.labels(i), byPlatform[i])
	}
	e.family("relay_players_by_version", "gauge",
		"Players seated in a room right now, by the version their hello named: the "+
			strconv.Itoa(maxVersionSeries)+" most common, "+
			"other for the rest and for anything that is not a release version, unknown for none.")
	for _, v := range foldVersions(byVersion) {
		e.sample("relay_players_by_version", []label{{"version", v.version}}, float64(v.players))
	}
	e.gauge("relay_journal_bytes",
		"Memory the journals of every room hold right now, in bytes.",
		float64(journalBytes))

	writeRuntimeMetrics(e)
	writeProcessFamilies(e, procRoot)

	// Counted as they happen, so read without any lock: every field is atomic.
	counted := &s.hub.stats
	e.counter("relay_connections_opened_total",
		"WebSocket connections accepted, counted at the upgrade, refused ones among them.",
		counted.opened.Load())
	e.counterVec("relay_refusals_total",
		"Connections refused, by the reason they were refused for.",
		refusalLabels, &counted.refusals)
	e.counterVec("relay_disconnects_total",
		"Connections of seated players that ended, by how they ended.",
		disconnectLabels, &counted.disconnects)
	e.counterVec("relay_seatings_total",
		"Players seated in a room, by how they came in and the platform their hello named; "+
			"return is coming back by code after a drop.",
		seatingLabels, &counted.seatings)
	e.counterVec("relay_rooms_created_total",
		"Rooms opened, by kind: code for a room opened to pass its code on, quick for the quick game's.",
		roomKindLabels, &counted.roomsCreated)
	e.counterVec("relay_pairings_total",
		"Rooms whose two seats filled for the first time; a partner coming back is not another pairing.",
		roomKindLabels, &counted.pairings)
	e.histogramVec("relay_pairing_wait_seconds",
		"How long a room waited for its first partner: paired when one came, observed then; "+
			"abandoned when none ever did, up to the moment the room emptied, observed when it is swept.",
		pairingWaitLabels, pairingWaitBuckets, &counted.pairingWaits)
	e.histogramVec("relay_played_seconds",
		"How long a room held two players, counting only the time both seats were full, "+
			"observed when the room is swept.",
		roomKindLabels, playedBuckets, &counted.played)
	e.counter("relay_journal_capped_total",
		"Rooms whose journal reached its cap and stopped taking records; "+
			"a player who drops after that cannot catch up.",
		counted.capped.Load())
	e.histogramVec("relay_rtt_seconds",
		"The round trip to a player, measured by the server's own pings as the player answers them, "+
			"by the platform their hello named: the network both ways, plus the time the player's side takes "+
			"to answer (up to a frame on native builds) and the server's own wait to write the ping; "+
			"observed about every twenty seconds per player.",
		platformLabels, rttBuckets, &counted.rtt)
	e.histogram("relay_packet_gap_worst_seconds",
		"The longest a player's stream of packets went quiet in each window, observed once a window per player: "+
			"jitter on the way to the server, and pauses in the game too.",
		worstGapBuckets, &counted.worstGaps)
	e.histogram("relay_forward_seconds",
		"How long a game packet took from being relayed to being in the partner's socket: "+
			"the server's own delay, and a partner's socket slow to take it.",
		forwardBuckets, &counted.forwards)
	e.counter("relay_members_evicted_total",
		"Members a room dropped because their queue overflowed: they fell too far behind to catch up live.",
		counted.evicted.Load())
	e.counter("relay_packets_total", "Game packets read from players and relayed.", counted.packets.Load())
	e.counter("relay_packet_bytes_total", "Bytes of the game packets read from players and relayed.",
		counted.packetBytes.Load())
	writeReportFamilies(e, &counted.reports)
	e.counterVec("relay_http_responses_total",
		"Responses for the game's files, counted as each one finished: page for the page itself, "+
			"wasm for the engine, other for the rest; by status class, and by whether the gzipped twin went out. "+
			"A download the player abandons counts under the status it began with. "+
			"Zero on a server that serves no game files.",
		httpResponseLabels, &counted.responses)
	e.histogramVec("relay_http_response_seconds",
		"How long a response for the game's files took, from the server starting on the request to the last byte "+
			"handed to the connection, by route: for wasm, how long a player waits for the engine to download. "+
			"A download the player abandons is observed as far as it went.",
		httpRouteLabels, httpResponseBuckets, &counted.responseTimes)
}

// How much a single vector or histogram can hold. The storage is a fixed array
// so that it works from its zero value, with nothing to allocate; a family
// needing more is refused when it is rendered, which every test that looks at
// it does.
const (
	maxCounterSeries   = 64
	maxHistogramSeries = 16
	maxBounds          = 15
)

// label is one name and value on a series.
type label struct {
	name, value string
}

// dimension is one label and every value it may take.
type dimension struct {
	name   string
	values []string
}

// labelSet is a closed set of label combinations: every dimension of a family
// and every value of each. A vector keeps one series per combination, in the
// order the dimensions are given, and renders all of them from zero — a series
// that appears only once first seen breaks rate() over the moment it appears.
//
// Declared once, at package scope, next to the family it belongs to, and never
// written.
type labelSet []dimension

func (set labelSet) size() int {
	n := 1
	for _, d := range set {
		n *= len(d.values)
	}
	return n
}

// index finds the series for the given values, one per dimension in order, or
// -1 when any of them is outside its set. Nothing outside the set is counted.
func (set labelSet) index(values ...string) int {
	if len(values) != len(set) {
		return -1
	}
	i := 0
	for d, dim := range set {
		j := slices.Index(dim.values, values[d])
		if j < 0 {
			return -1
		}
		i = i*len(dim.values) + j
	}
	return i
}

// labels names series i: the reverse of index.
func (set labelSet) labels(i int) []label {
	out := make([]label, len(set))
	for d := len(set) - 1; d >= 0; d-- {
		n := len(set[d].values)
		out[d] = label{set[d].name, set[d].values[i%n]}
		i /= n
	}
	return out
}

// counterVec is a counter per combination of a closed label set.
type counterVec struct {
	counts [maxCounterSeries]atomic.Uint64
}

func (v *counterVec) inc(set labelSet, values ...string) {
	v.add(set, 1, values...)
}

func (v *counterVec) add(set labelSet, n uint64, values ...string) {
	if i := set.index(values...); i >= 0 && i < len(v.counts) {
		v.counts[i].Add(n)
	}
}

// buckets is the shape of a histogram family: the upper bound of each bucket,
// in the unit the family is rendered in, and how many recorded units make one
// of those. Declared once, at package scope, and never written: every
// histogram of the family shares it and none carries a copy.
//
// Values are recorded as whole units so that the sum is an atomic integer.
// Bounds are compared by dividing the recorded value by per rather than
// multiplying the bound by it: a division by a whole number rounds to the same
// double the bound's own literal does, so a value exactly on a bound lands in
// that bucket.
type buckets struct {
	bounds []float64 // ascending; +Inf is implied after the last
	per    uint64
}

// durationBuckets shapes a family of durations: recorded in nanoseconds,
// rendered in seconds. Record into it with observeDuration.
func durationBuckets(bounds ...float64) buckets {
	return scaledBuckets(uint64(time.Second), bounds...)
}

// countBuckets shapes a family of whole numbers rendered as they are: ticks,
// frames per second.
func countBuckets(bounds ...float64) buckets {
	return scaledBuckets(1, bounds...)
}

// scaledBuckets shapes a family whose recorded units are a fraction of the
// rendered one: a percentage recorded as a whole number and rendered as a
// share is per = 100.
//
// A malformed shape is a mistake in a declaration, not in anything a client
// sent, so it stops the process as it starts rather than rendering nonsense.
func scaledBuckets(per uint64, bounds ...float64) buckets {
	ascending := len(bounds) > 0
	for i := 1; i < len(bounds); i++ {
		ascending = ascending && bounds[i] > bounds[i-1]
	}
	if per == 0 || !ascending || len(bounds) > maxBounds {
		panic(fmt.Sprintf("histogram buckets need 1 to %d ascending bounds and a unit, got %v per %d",
			maxBounds, bounds, per))
	}
	return buckets{bounds: bounds, per: per}
}

// histogram counts observations into buckets without a lock.
//
// Each bucket counts only its own observations, not those below it: one
// observation is then one atomic increment, and there is no moment at which a
// scrape could catch some buckets bumped and others not. The cumulative
// counts are added up at render time, and _count is their total — so the
// +Inf bucket equals _count in every scrape, however many observations race
// it.
type histogram struct {
	counts [maxBounds + 1]atomic.Uint64 // the last one is past every bound
	sum    atomic.Uint64                // in recorded units, see buckets
}

// observe records one value, in the recorded units of the family's buckets.
// A nil histogram — a value outside a vector's label set — records nothing.
func (h *histogram) observe(b buckets, recorded uint64) {
	if h == nil {
		return
	}
	value := float64(recorded) / float64(b.per)
	i := 0
	for i < len(b.bounds) && i < maxBounds && value > b.bounds[i] {
		i++
	}
	h.counts[i].Add(1)
	h.sum.Add(recorded)
}

// observeDuration records a duration into a family shaped by
// durationBuckets. The monotonic clock never runs backwards, but a duration
// built by subtraction can; it counts as zero rather than as centuries.
func (h *histogram) observeDuration(b buckets, d time.Duration) {
	h.observe(b, uint64(max(d, 0)))
}

// histogramVec is a histogram per combination of a closed label set.
type histogramVec struct {
	series [maxHistogramSeries]histogram
}

// at returns the histogram for the given values, or nil — which records
// nothing — when any of them is outside the set.
func (v *histogramVec) at(set labelSet, values ...string) *histogram {
	i := set.index(values...)
	if i < 0 || i >= len(v.series) {
		return nil
	}
	return &v.series[i]
}

// exposition writes families in the text format, one call per family.
type exposition struct {
	w *bufio.Writer
}

func newExposition(w io.Writer) *exposition {
	return &exposition{w: bufio.NewWriter(w)}
}

// flush hands what was written to the underlying writer.
func (e *exposition) flush() {
	e.w.Flush()
}

var (
	helpEscaper  = strings.NewReplacer(`\`, `\\`, "\n", `\n`)
	labelEscaper = strings.NewReplacer(`\`, `\\`, "\n", `\n`, `"`, `\"`)
)

// family opens a family: its description and its type. Every sample of the
// family must follow before the next one opens.
func (e *exposition) family(name, kind, help string) {
	e.w.WriteString("# HELP " + name + " " + helpEscaper.Replace(help) + "\n")
	e.w.WriteString("# TYPE " + name + " " + kind + "\n")
}

// sample writes one series. Labels are sorted by name, so the same series
// always reads the same way.
func (e *exposition) sample(name string, labels []label, value float64) {
	sorted := slices.Clone(labels)
	slices.SortFunc(sorted, func(a, b label) int { return strings.Compare(a.name, b.name) })
	e.line(name, sorted, value)
}

// line writes one series with its labels in exactly the order given.
func (e *exposition) line(name string, labels []label, value float64) {
	e.w.WriteString(name)
	if len(labels) > 0 {
		e.w.WriteByte('{')
		for i, l := range labels {
			if i > 0 {
				e.w.WriteByte(',')
			}
			e.w.WriteString(l.name + `="` + labelEscaper.Replace(l.value) + `"`)
		}
		e.w.WriteByte('}')
	}
	e.w.WriteString(" " + formatValue(value) + "\n")
}

// formatValue writes a number in full, never in exponent form: easier on a
// human reading a scrape by eye, and "+Inf" comes out as the format spells it.
func formatValue(v float64) string {
	return strconv.FormatFloat(v, 'f', -1, 64)
}

func (e *exposition) gauge(name, help string, value float64) {
	e.family(name, "gauge", help)
	e.sample(name, nil, value)
}

func (e *exposition) counter(name, help string, value uint64) {
	e.family(name, "counter", help)
	e.sample(name, nil, float64(value))
}

func (e *exposition) counterVec(name, help string, set labelSet, v *counterVec) {
	if set.size() > len(v.counts) {
		panic(fmt.Sprintf("%s: %d series is more than a counter vector holds", name, set.size()))
	}
	e.family(name, "counter", help)
	for i := 0; i < set.size(); i++ {
		e.sample(name, set.labels(i), float64(v.counts[i].Load()))
	}
}

func (e *exposition) histogram(name, help string, b buckets, h *histogram) {
	e.family(name, "histogram", help)
	e.histogramSeries(name, nil, b, h)
}

func (e *exposition) histogramVec(name, help string, set labelSet, b buckets, v *histogramVec) {
	if set.size() > len(v.series) {
		panic(fmt.Sprintf("%s: %d series is more than a histogram vector holds", name, set.size()))
	}
	e.family(name, "histogram", help)
	for i := 0; i < set.size(); i++ {
		e.histogramSeries(name, set.labels(i), b, &v.series[i])
	}
}

// histogramSeries writes one histogram's buckets, sum and count. Each bucket is
// read exactly once and the cumulative counts are built from those reads, so
// the render is consistent with itself even while observations race it.
func (e *exposition) histogramSeries(name string, labels []label, b buckets, h *histogram) {
	sorted := slices.Clone(labels)
	slices.SortFunc(sorted, func(a, b label) int { return strings.Compare(a.name, b.name) })
	var cumulative uint64
	for i := 0; i <= len(b.bounds); i++ {
		cumulative += h.counts[i].Load()
		le := "+Inf"
		if i < len(b.bounds) {
			le = formatValue(b.bounds[i])
		}
		// le goes last, after the family's own labels.
		e.line(name+"_bucket", append(slices.Clip(sorted), label{"le", le}), float64(cumulative))
	}
	e.line(name+"_sum", sorted, float64(h.sum.Load())/float64(b.per))
	e.line(name+"_count", sorted, float64(cumulative))
}

// histogramFromCumulative writes a histogram whose bucket counts were made
// cumulative elsewhere — process.go rebuckets runtime/metrics onto our own
// bounds, which are not backed by a *histogram's lock-free counters — through
// the same per-line format every other histogram uses, so a scrape cannot
// tell the two apart. There is deliberately one rendering path for the text
// format: this is the smallest possible second entry point into it, not a
// second format.
func (e *exposition) histogramFromCumulative(name, help string, bounds []float64, counts []uint64, total uint64, sum float64) {
	e.family(name, "histogram", help)
	for i, bound := range bounds {
		e.line(name+"_bucket", []label{{"le", formatValue(bound)}}, float64(counts[i]))
	}
	e.line(name+"_bucket", []label{{"le", "+Inf"}}, float64(total))
	e.line(name+"_sum", nil, sum)
	e.line(name+"_count", nil, float64(total))
}
