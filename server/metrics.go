package main

// Metrics for Prometheus, through Prometheus's own client library.
//
// What happens — a refusal, a pairing, a packet — is counted as it happens, in
// stats, which the hub holds. What is only true right now — how many
// connections are open, what the limits are — is read at the moment of the
// scrape instead, by stateCollector, so there is no second copy of it to
// drift. The Go runtime's figures and the process's own come from the
// library's standard collectors, under the names any Go dashboard already
// knows.
//
// Every label comes from a closed set the server defines. Nothing a client
// sends reaches a label as it was sent: each distinct label value is a new
// series, and a stranger who could pick the values could grow the scrape, and
// the memory of whatever scrapes it, without bound.

import (
	"cmp"
	"fmt"
	"maps"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Stamped at build time with -ldflags "-X main.version=0.5.0". A build without
// the stamp is a developer's own.
var version = "dev"

// The shape of a release version, the only kind of version a label may carry.
var releaseVersion = regexp.MustCompile(`^\d{1,3}\.\d{1,3}\.\d{1,3}$`)

// buildVersion is the version as a label may carry it. The stamp comes from
// whatever the release was given, and a "v0.5.0" typed by hand, or anything
// with a quote in it, would otherwise reach every scrape as it was typed.
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

// stats is everything the server counts as it goes, and the registry a scrape
// reads it from. Only NewHub makes one. Rooms and members that count something
// hold a pointer to their hub's, and a nil pointer counts nothing: every
// method that records begins with `if s == nil { return }`, so a room built
// bare works too.
//
// A registry of its own rather than the library's default one: a hub is its
// own world, so a test's hub counts from zero, and nothing that happens to
// register itself globally can reach a scrape.
//
// A new family is a field here, made in newStats through families. Recording
// takes no lock of the server's — it runs on the paths that relay packets —
// and the library's counters and histograms are atomic underneath.
type stats struct {
	registry *prometheus.Registry

	opened      prometheus.Counter
	refusals    counterVec // over refusalLabels
	disconnects counterVec // over disconnectLabels
	seatings    counterVec // over seatingLabels

	roomsCreated counterVec   // over roomKindLabels
	pairings     counterVec   // over roomKindLabels
	pairingWaits histogramVec // over pairingWaitLabels
	played       histogramVec // over roomKindLabels
	capped       prometheus.Counter

	// The three a relayed packet pays for are single series, held directly:
	// one packet costs atomic additions and nothing else.
	packets     prometheus.Counter
	packetBytes prometheus.Counter
	forwards    prometheus.Histogram
	evicted     prometheus.Counter
	rtt         histogramVec // over platformLabels
	worstGaps   prometheus.Histogram

	reports clientReports // see report.go

	responses     counterVec   // over httpResponseLabels
	responseTimes histogramVec // over httpRouteLabels
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
// longer than that. In seconds, like every duration here.
var pairingWaitBuckets = []float64{1, 2, 5, 10, 20, 30, 60, 120, 300, 600}

// Time together from half a minute, a pair that met and parted at once, to two
// hours, a long evening's match.
var playedBuckets = []float64{30, 60, 120, 300, 600, 1200, 1800, 3600, 7200}

// A round trip to a player, from ten milliseconds, a neighbour on the same
// network, to over a second and a half, a link no lockstep game survives.
var rttBuckets = []float64{0.01, 0.025, 0.05, 0.1, 0.2, 0.4, 0.8, 1.6}

// The worst gap in a player's stream over a window, from three frames at sixty
// a second, a hitch few notice, to a stall long enough to read as a dropped link.
var worstGapBuckets = []float64{0.05, 0.1, 0.25, 0.5, 1, 2.5}

// The server's own delay, from half a millisecond, a relay with nothing in its
// way, to a second, a socket that barely takes anything.
var forwardBuckets = []float64{0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1}

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
var httpResponseBuckets = []float64{0.1, 0.5, 1, 2.5, 5, 10, 30, 60}

// How many versions get a series of their own among the players seated right
// now. Past it they are other: releases pile up over the years, and a script
// could make up as many as it likes.
const maxVersionSeries = 10

// newStats builds every family the server counts into, on a registry of its
// own, together with the Go runtime's and the process's standard figures and
// the build it runs as.
func newStats() *stats {
	registry := prometheus.NewRegistry()
	// The scheduler's latencies show a process short of CPU, and the collector's
	// pauses a process stopping itself; both come from runtime/metrics, read
	// only when a scrape asks.
	registry.MustRegister(
		collectors.NewGoCollector(collectors.WithGoCollectorRuntimeMetrics(
			collectors.MetricsScheduler, collectors.MetricsGC)),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	build := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "relay_build_info",
		Help: "The version the server was built as and the Go it was built with; always 1.",
		ConstLabels: prometheus.Labels{
			"version":   buildVersion(),
			"goversion": goVersionLabel(runtime.Version()),
		},
	})
	build.Set(1)
	registry.MustRegister(build)

	f := families{registry}
	return &stats{
		registry: registry,

		opened: f.counter("relay_connections_opened_total",
			"WebSocket connections accepted, counted at the upgrade, refused ones among them."),
		refusals: f.counterVec("relay_refusals_total",
			"Connections refused, by the reason they were refused for.",
			refusalLabels),
		disconnects: f.counterVec("relay_disconnects_total",
			"Connections of seated players that ended, by how they ended.",
			disconnectLabels),
		seatings: f.counterVec("relay_seatings_total",
			"Players seated in a room, by how they came in and the platform their hello named; "+
				"return is coming back by code after a drop.",
			seatingLabels),

		roomsCreated: f.counterVec("relay_rooms_created_total",
			"Rooms opened, by kind: code for a room opened to pass its code on, quick for the quick game's.",
			roomKindLabels),
		pairings: f.counterVec("relay_pairings_total",
			"Rooms whose two seats filled for the first time; a partner coming back is not another pairing.",
			roomKindLabels),
		pairingWaits: f.histogramVec("relay_pairing_wait_seconds",
			"How long a room waited for its first partner: paired when one came, observed then; "+
				"abandoned when none ever did, up to the moment the room emptied, observed when it is swept.",
			pairingWaitLabels, pairingWaitBuckets),
		played: f.histogramVec("relay_played_seconds",
			"How long a room held two players, counting only the time both seats were full, "+
				"observed when the room is swept.",
			roomKindLabels, playedBuckets),
		capped: f.counter("relay_journal_capped_total",
			"Rooms whose journal reached its cap and stopped taking records; "+
				"a player who drops after that cannot catch up."),

		packets: f.counter("relay_packets_total", "Game packets read from players and relayed."),
		packetBytes: f.counter("relay_packet_bytes_total",
			"Bytes of the game packets read from players and relayed."),
		forwards: f.histogram("relay_forward_seconds",
			"How long a game packet took from being relayed to being in the partner's socket: "+
				"the server's own delay, and a partner's socket slow to take it.",
			forwardBuckets),
		evicted: f.counter("relay_members_evicted_total",
			"Members a room dropped because their queue overflowed: they fell too far behind to catch up live."),
		rtt: f.histogramVec("relay_rtt_seconds",
			"The round trip to a player, measured by the server's own pings as the player answers them, "+
				"by the platform their hello named: the network both ways, plus the time the player's side takes "+
				"to answer (up to a frame on native builds) and the server's own wait to write the ping; "+
				"observed about every twenty seconds per player.",
			platformLabels, rttBuckets),
		worstGaps: f.histogram("relay_packet_gap_worst_seconds",
			"The longest a player's stream of packets went quiet in each window, observed once a window per player: "+
				"jitter on the way to the server, and pauses in the game too.",
			worstGapBuckets),

		reports: newClientReports(f),

		responses: f.counterVec("relay_http_responses_total",
			"Responses for the game's files, counted as each one finished: page for the page itself, "+
				"wasm for the engine, other for the rest; by status class, and by whether the gzipped twin went out. "+
				"A download the player abandons counts under the status it began with. "+
				"Zero on a server that serves no game files.",
			httpResponseLabels),
		responseTimes: f.histogramVec("relay_http_response_seconds",
			"How long a response for the game's files took, from the server starting on the request to the last byte "+
				"handed to the connection, by route: for wasm, how long a player waits for the engine to download. "+
				"A download the player abandons is observed as far as it went.",
			httpRouteLabels, httpResponseBuckets),
	}
}

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

// seconds is a duration as a histogram of durations observes it. The monotonic
// clock never runs backwards, but a duration built by subtraction can; it
// counts as zero rather than as a negative time pulling the sum down.
func seconds(d time.Duration) float64 {
	return max(d, 0).Seconds()
}

// connectionOpened counts one WebSocket upgrade, whatever becomes of it after.
func (s *stats) connectionOpened() {
	if s == nil {
		return
	}
	s.opened.Inc()
}

// refused counts one refusal under a reason from refusalLabels.
func (s *stats) refused(reason string) {
	if s == nil {
		return
	}
	s.refusals.inc(reason)
}

// disconnected counts one seated connection ending, under a cause from
// disconnectLabels.
func (s *stats) disconnected(cause string) {
	if s == nil {
		return
	}
	s.disconnects.inc(cause)
}

// seated counts one player sitting down, under an action from seatingLabels
// and the platform their hello named.
func (s *stats) seated(action, platform string) {
	if s == nil {
		return
	}
	s.seatings.inc(action, platformLabel(platform))
}

// roomCreated counts one room opened, under its kind.
func (s *stats) roomCreated(kind string) {
	if s == nil {
		return
	}
	s.roomsCreated.inc(kind)
}

// roomPaired counts a room's first pair, and how long the player already there
// waited for it.
func (s *stats) roomPaired(kind string, waited time.Duration) {
	if s == nil {
		return
	}
	s.pairings.inc(kind)
	s.pairingWaits.observe(seconds(waited), kind, "paired")
}

// waitAbandoned observes how long a room waited for a partner who never came.
func (s *stats) waitAbandoned(kind string, waited time.Duration) {
	if s == nil {
		return
	}
	s.pairingWaits.observe(seconds(waited), kind, "abandoned")
}

// roomPlayed observes how long a room that is gone held two players.
func (s *stats) roomPlayed(kind string, together time.Duration) {
	if s == nil {
		return
	}
	s.played.observe(seconds(together), kind)
}

// journalCapReached counts one room whose journal stopped taking records.
func (s *stats) journalCapReached() {
	if s == nil {
		return
	}
	s.capped.Inc()
}

// relayed counts one game packet read from a player and handed to the room, and
// its size.
func (s *stats) relayed(size int) {
	if s == nil {
		return
	}
	s.packets.Inc()
	s.packetBytes.Add(float64(size))
}

// memberEvicted counts one member the room dropped for falling behind.
func (s *stats) memberEvicted() {
	if s == nil {
		return
	}
	s.evicted.Inc()
}

// observeRTT observes one round trip to a player, under the platform their hello
// named.
func (s *stats) observeRTT(platform string, took time.Duration) {
	if s == nil {
		return
	}
	s.rtt.observe(seconds(took), platformLabel(platform))
}

// observeWorstGap observes the longest a player's stream went quiet over one
// window.
func (s *stats) observeWorstGap(gap time.Duration) {
	if s == nil {
		return
	}
	s.worstGaps.Observe(seconds(gap))
}

// observeForward observes how long a game packet took from being relayed to
// being in the partner's socket.
func (s *stats) observeForward(took time.Duration) {
	if s == nil {
		return
	}
	s.forwards.Observe(seconds(took))
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
	s.responses.inc(route, statusClass(status), encoding)
	s.responseTimes.observe(seconds(took), route)
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

// metricsGatherers is everything a scrape reads: what the hub counted as it
// went, with the runtime's and the process's figures beside it, and what is
// true of the server at the moment of the scrape. The second registry is made
// here because a server is built as a bare literal, with nothing to make it
// in; a handler is made once, and so is its registry.
func (s *server) metricsGatherers() prometheus.Gatherers {
	now := prometheus.NewRegistry()
	now.MustRegister(stateCollector{s})
	return prometheus.Gatherers{s.hub.stats.registry, now}
}

// stateCollector reads, at the moment of a scrape, what is only true at that
// moment: connections, limits, rooms by state, who is seated and the memory
// their journals hold.
type stateCollector struct {
	s *server
}

var (
	connectionsDesc = prometheus.NewDesc("relay_connections",
		"Connections open right now, in a room or still saying hello.", nil, nil)
	connectionsLimitDesc = prometheus.NewDesc("relay_connections_limit",
		"The most connections held at once; zero means no cap.", nil, nil)
	roomsDesc = prometheus.NewDesc("relay_rooms",
		"Rooms held right now, by kind and by state: waiting for a first partner, playing, "+
			"interrupted when a partner the room already had is gone, or empty.",
		roomStateLabels.names(), nil)
	roomsLimitDesc = prometheus.NewDesc("relay_rooms_limit",
		"The most rooms held at once.", nil, nil)
	playersDesc = prometheus.NewDesc("relay_players",
		"Players seated in a room right now, by the platform their hello named.",
		platformLabels.names(), nil)
	playersByVersionDesc = prometheus.NewDesc("relay_players_by_version",
		"Players seated in a room right now, by the version their hello named: the "+
			strconv.Itoa(maxVersionSeries)+" most common, "+
			"other for the rest and for anything that is not a release version, unknown for none.",
		[]string{"version"}, nil)
	journalBytesDesc = prometheus.NewDesc("relay_journal_bytes",
		"Memory the journals of every room hold right now, in bytes.", nil, nil)
)

func (stateCollector) Describe(descs chan<- *prometheus.Desc) {
	for _, desc := range []*prometheus.Desc{
		connectionsDesc, connectionsLimitDesc, roomsDesc, roomsLimitDesc,
		playersDesc, playersByVersionDesc, journalBytesDesc,
	} {
		descs <- desc
	}
}

// Collect reads the server's state and hands it over. Each lock is held only
// to copy what it guards, and never two at once: holding one while taking the
// other would be a new lock order for the whole server to keep. The hub's gives
// up its list of rooms, and each room is then locked on its own. None is held
// while a figure is handed over, since the registry on the other end of the
// channel may take its time.
func (c stateCollector) Collect(metrics chan<- prometheus.Metric) {
	s := c.s
	s.mu.Lock()
	connections := len(s.conns)
	s.mu.Unlock()
	s.hub.mu.Lock()
	roomsLimit := s.hub.limit
	rooms := slices.Collect(maps.Values(s.hub.rooms))
	s.hub.mu.Unlock()
	live := livePlayers(rooms)

	gauge := func(desc *prometheus.Desc, value int, labels ...string) {
		metrics <- prometheus.MustNewConstMetric(desc, prometheus.GaugeValue, float64(value), labels...)
	}
	gauge(connectionsDesc, connections)
	gauge(connectionsLimitDesc, s.maxConns)
	roomStateLabels.each(func(values []string) {
		gauge(roomsDesc, live.rooms[keyOf(values)], values...)
	})
	gauge(roomsLimitDesc, roomsLimit)
	for _, platform := range platforms {
		gauge(playersDesc, live.byPlatform[platform], platform)
	}
	for _, v := range foldVersions(live.byVersion) {
		gauge(playersByVersionDesc, v.players, v.version)
	}
	gauge(journalBytesDesc, live.journalBytes)
}

// liveFigures is what the rooms held at one moment.
type liveFigures struct {
	byPlatform   map[string]int    // players, by platform label
	byVersion    map[string]int    // players, by version label
	rooms        map[seriesKey]int // rooms, by kind and state
	journalBytes int
}

// livePlayers counts whoever is seated right now, by platform and by version
// label, the rooms they sit in, by kind and state, and the memory every room's
// journal holds. One walk gives all of it, so a room's players and its state
// come from the same moment. It takes each room's lock in turn and never the
// hub's: the caller copies the rooms out from under that, so a scrape does not
// hold up everyone sitting down for as long as it takes to walk every room.
func livePlayers(rooms []*Room) liveFigures {
	counted := liveFigures{byPlatform: map[string]int{}, byVersion: map[string]int{}, rooms: map[seriesKey]int{}}
	for _, room := range rooms {
		room.mu.Lock()
		counted.rooms[seriesKey{room.kind(), room.state()}]++
		counted.journalBytes += room.journal.bytes()
		for _, member := range room.members {
			counted.byPlatform[platformLabel(member.client.platform)]++
			counted.byVersion[versionLabel(member.client.version)]++
		}
		room.mu.Unlock()
	}
	return counted
}

// versionCount is one version's series among the live players.
type versionCount struct {
	version string
	players int
}

// foldVersions picks the series a scrape carries for live versions: the most
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

// dimension is one label and every value it may take.
type dimension struct {
	name   string
	values []string
}

// labelSet is a closed set of label combinations: every dimension of a family
// and every value of each, in the order a series' values are given.
//
// Declared once, at package scope, next to the family it belongs to, and never
// written.
type labelSet []dimension

// names is the label names, in order.
func (set labelSet) names() []string {
	names := make([]string, len(set))
	for i, d := range set {
		names[i] = d.name
	}
	return names
}

// each calls visit with every combination of values, one per dimension in
// order. The slice is visit's own to keep.
func (set labelSet) each(visit func(values []string)) {
	values := make([]string, len(set))
	var walk func(d int)
	walk = func(d int) {
		if d == len(set) {
			visit(slices.Clone(values))
			return
		}
		for _, v := range set[d].values {
			values[d] = v
			walk(d + 1)
		}
	}
	walk(0)
}

// A family is split by at most this many labels. The key of a series is then a
// fixed array, which a map hashes as it is, without a string built for every
// count.
const maxDimensions = 3

// seriesKey names one series of a family by its label values, in order.
type seriesKey [maxDimensions]string

// keyOf is the key for a series' values. There are never more of them than a
// key holds: a family is refused more dimensions as it is built, and a count
// with a different number of values than its family's counts nowhere.
func keyOf(values []string) seriesKey {
	var key seriesKey
	copy(key[:], values)
	return key
}

// families builds the server's own metric families onto one registry.
//
// A family split by labels gets every series of its closed set as it is
// built. Every series is then there from the first scrape, at zero — a series
// that appears only once first counted breaks rate() over the moment it
// appears — and recording never adds one.
type families struct {
	registry *prometheus.Registry
}

func (f families) counter(name, help string) prometheus.Counter {
	c := prometheus.NewCounter(prometheus.CounterOpts{Name: name, Help: help})
	f.registry.MustRegister(c)
	return c
}

func (f families) histogram(name, help string, buckets []float64) prometheus.Histogram {
	h := prometheus.NewHistogram(prometheus.HistogramOpts{Name: name, Help: help, Buckets: buckets})
	f.registry.MustRegister(h)
	return h
}

func (f families) counterVec(name, help string, set labelSet) counterVec {
	vec := prometheus.NewCounterVec(prometheus.CounterOpts{Name: name, Help: help}, closedNames(name, set))
	f.registry.MustRegister(vec)
	counters := counterVec{dimensions: len(set), series: map[seriesKey]prometheus.Counter{}}
	set.each(func(values []string) {
		counters.series[keyOf(values)] = vec.WithLabelValues(values...)
	})
	return counters
}

func (f families) histogramVec(name, help string, set labelSet, buckets []float64) histogramVec {
	vec := prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: name, Help: help, Buckets: buckets},
		closedNames(name, set))
	f.registry.MustRegister(vec)
	histograms := histogramVec{dimensions: len(set), series: map[seriesKey]prometheus.Observer{}}
	set.each(func(values []string) {
		histograms.series[keyOf(values)] = vec.WithLabelValues(values...)
	})
	return histograms
}

// closedNames is the label names of a family that a key can hold. A family
// split by more labels is a mistake in a declaration, not in anything a client
// sent, so it stops the process as it starts.
func closedNames(name string, set labelSet) []string {
	if len(set) == 0 || len(set) > maxDimensions {
		panic(fmt.Sprintf("%s: a family is split by 1 to %d labels, not %d", name, maxDimensions, len(set)))
	}
	return set.names()
}

// counterVec is a counter per combination of a closed label set.
//
// The library's own vector makes a series for whatever values it is handed, so
// a value outside the set would be a series nobody declared. The counters
// made with the family are kept here instead, in a map nothing writes once it
// is built, and a value outside the set counts nowhere.
type counterVec struct {
	dimensions int
	series     map[seriesKey]prometheus.Counter
}

// inc counts one under the given values, one per dimension in order.
func (v counterVec) inc(values ...string) {
	if len(values) != v.dimensions {
		return
	}
	if c, found := v.series[keyOf(values)]; found {
		c.Inc()
	}
}

// histogramVec is a histogram per combination of a closed label set, kept the
// way counterVec keeps its counters.
type histogramVec struct {
	dimensions int
	series     map[seriesKey]prometheus.Observer
}

// observe records one value under the given values, one per dimension in order.
func (v histogramVec) observe(value float64, values ...string) {
	if len(values) != v.dimensions {
		return
	}
	if h, found := v.series[keyOf(values)]; found {
		h.Observe(value)
	}
}
