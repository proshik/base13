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
	"fmt"
	"io"
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
type stats struct{}

// writeMetrics renders the server's whole state. Families come in a fixed
// order, so two scrapes of the same state are the same bytes.
func (s *server) writeMetrics(w io.Writer) {
	// Each lock is held only to copy a number, and never two at once: holding
	// one while taking the other would be a new lock order for the whole server
	// to keep.
	s.mu.Lock()
	connections := len(s.conns)
	s.mu.Unlock()
	s.hub.mu.Lock()
	roomsLimit := s.hub.limit
	s.hub.mu.Unlock()

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
	e.gauge("relay_rooms_limit", "The most rooms held at once.", float64(roomsLimit))

	writeRuntimeMetrics(e)
	writeProcessFamilies(e, procRoot)
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
