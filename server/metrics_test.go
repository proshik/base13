package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"math"
	"net/http"
	"net/http/httptest"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// A render is checked the way Prometheus reads it, not against a string we
// happen to expect: a malformed line is never an error the server sees — the
// scrape fails on the other side, and the dashboard quietly goes blank.

// renderMetrics returns what a scrape of s would receive.
func renderMetrics(s *server) string {
	var out bytes.Buffer
	s.writeMetrics(&out)
	return out.String()
}

// metricValue finds one exact series in a fresh render and returns its value.
// The series is written as it is rendered: a bare name such as
// relay_connections, or a name with its labels sorted by label name, `le`
// last, such as relay_refusals_total{reason="full"}.
func metricValue(t *testing.T, s *server, series string) float64 {
	t.Helper()
	text := renderMetrics(s)
	raw, found := seriesValue(text, series)
	if !found {
		t.Fatalf("no series %s in the render:\n%s", series, text)
	}
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		t.Fatalf("series %s has a value that is not a number: %q", series, raw)
	}
	return value
}

// seriesValue returns the raw value of one exact series in a render.
func seriesValue(text, series string) (string, bool) {
	for _, line := range strings.Split(text, "\n") {
		if value, found := strings.CutPrefix(line, series+" "); found {
			return value, true
		}
	}
	return "", false
}

// familyNames returns every family's name, in the order it appears. A TYPE
// line opens a family exactly once, so this also serves as a structural
// fingerprint of a render: two renders with the same families in the same
// order agree on shape even when live figures inside them do not agree on
// value.
func familyNames(text string) []string {
	var names []string
	for _, line := range strings.Split(text, "\n") {
		if rest, ok := strings.CutPrefix(line, "# TYPE "); ok {
			name, _, _ := strings.Cut(rest, " ")
			names = append(names, name)
		}
	}
	return names
}

// eventually waits for something the server does on its own goroutines: a
// connection is counted after the handshake is answered, not before it.
func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("the condition did not come true within two seconds")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// checkExposition fails the test on anything in a render that Prometheus would
// refuse or misread. Any test may hand it any render.
func checkExposition(t *testing.T, text string) {
	t.Helper()
	for _, problem := range expositionProblems(text) {
		t.Error(problem)
	}
}

var (
	expositionMetricName = regexp.MustCompile(`^[a-zA-Z_:][a-zA-Z0-9_:]*$`)
	expositionLabelName  = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)
	// Only what the server's closed sets are made of. A room code is
	// uppercase, so it cannot pass as a label value even by accident.
	expositionLabelValue = regexp.MustCompile(`^[a-z0-9_.]+$`)
)

type parsedSample struct {
	name   string
	labels []label
	value  float64
}

// parseSample reads one sample line: a name, labels in braces with the
// format's three escapes, a space and a value. The server never writes a
// timestamp, so one is refused.
func parseSample(line string) (parsedSample, error) {
	var sample parsedSample
	end := strings.IndexAny(line, "{ ")
	if end < 0 {
		return sample, errors.New("no value")
	}
	sample.name, line = line[:end], line[end:]
	if !expositionMetricName.MatchString(sample.name) {
		return sample, fmt.Errorf("bad metric name %q", sample.name)
	}
	if line[0] == '{' {
		line = line[1:]
		for !strings.HasPrefix(line, "}") {
			name, rest, found := strings.Cut(line, "=")
			if !found || !strings.HasPrefix(rest, `"`) {
				return sample, errors.New("a label without a quoted value")
			}
			var value strings.Builder
			closed := false
			i := 1
			for ; i < len(rest); i++ {
				c := rest[i]
				if c == '"' {
					closed = true
					break
				}
				if c != '\\' {
					value.WriteByte(c)
					continue
				}
				if i+1 == len(rest) {
					return sample, errors.New("an escape at the end of the line")
				}
				i++
				switch rest[i] {
				case '\\':
					value.WriteByte('\\')
				case '"':
					value.WriteByte('"')
				case 'n':
					value.WriteByte('\n')
				default:
					return sample, fmt.Errorf("unknown escape \\%c", rest[i])
				}
			}
			if !closed {
				return sample, errors.New("a label value is never closed")
			}
			sample.labels = append(sample.labels, label{name, value.String()})
			line = rest[i+1:]
			if strings.HasPrefix(line, ",") {
				line = line[1:]
				if strings.HasPrefix(line, "}") {
					return sample, errors.New("a trailing comma in labels")
				}
			} else if !strings.HasPrefix(line, "}") {
				return sample, errors.New("labels are not separated by commas")
			}
		}
		line = line[1:]
	}
	raw, found := strings.CutPrefix(line, " ")
	if !found || raw == "" || strings.Contains(raw, " ") {
		return sample, errors.New("not exactly one value after the name")
	}
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return sample, fmt.Errorf("value %q is not a number", raw)
	}
	sample.value = value
	return sample, nil
}

// seriesKey names a series with its labels in a fixed order, so that the same
// series written with its labels in another order is still recognized.
func seriesKey(name string, labels []label) string {
	sorted := slices.Clone(labels)
	slices.SortFunc(sorted, func(a, b label) int { return strings.Compare(a.name, b.name) })
	parts := make([]string, len(sorted))
	for i, l := range sorted {
		parts[i] = l.name + "=" + strconv.Quote(l.value)
	}
	return name + "{" + strings.Join(parts, ",") + "}"
}

// expositionProblems lists everything wrong with a render. Kept apart from
// checkExposition so the checker itself can be shown to catch what it claims.
func expositionProblems(text string) []string {
	var problems []string
	fail := func(format string, args ...any) {
		problems = append(problems, fmt.Sprintf(format, args...))
	}
	if !strings.HasSuffix(text, "\n") {
		fail("the render does not end in a newline")
	}

	type histogramSeries struct {
		bounds, counts   []float64
		count            float64
		hasSum, hasCount bool
	}
	var (
		kinds      = map[string]string{}
		helped     = map[string]bool{}
		sampled    = map[string]bool{}
		finished   = map[string]bool{}
		seen       = map[string]bool{}
		histograms = map[string]*histogramSeries{}
		families   []string
		order      []string
		current    string
	)
	// Every line of a family comes together: HELP, TYPE, then its samples.
	enter := func(n int, family string) {
		if family == current {
			return
		}
		if finished[family] {
			fail("line %d: %s continues after another family began", n, family)
		}
		if current != "" {
			finished[current] = true
		}
		current = family
	}

	for i, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		n := i + 1
		switch {
		case line == "":
			fail("line %d is empty", n)

		case strings.HasPrefix(line, "# HELP "):
			name, _, _ := strings.Cut(line[len("# HELP "):], " ")
			enter(n, name)
			if helped[name] {
				fail("line %d: a second HELP for %s", n, name)
			}
			if sampled[name] {
				fail("line %d: HELP for %s comes after its samples", n, name)
			}
			helped[name] = true

		case strings.HasPrefix(line, "# TYPE "):
			name, kind, _ := strings.Cut(line[len("# TYPE "):], " ")
			if !expositionMetricName.MatchString(name) {
				fail("line %d: bad family name %q", n, name)
			}
			enter(n, name)
			if _, twice := kinds[name]; twice {
				fail("line %d: %s is declared twice", n, name)
				continue
			}
			if !helped[name] {
				fail("line %d: %s has no HELP before its TYPE", n, name)
			}
			switch kind {
			case "counter":
				if !strings.HasSuffix(name, "_total") {
					fail("line %d: counter %s does not end in _total", n, name)
				}
			case "gauge", "histogram":
				if strings.HasSuffix(name, "_total") {
					fail("line %d: %s %s ends in _total, which promises a counter", n, kind, name)
				}
			default:
				fail("line %d: %s has type %q, which the server never renders", n, name, kind)
			}
			kinds[name] = kind
			families = append(families, name)

		case strings.HasPrefix(line, "#"):
			fail("line %d: a comment that is neither HELP nor TYPE", n)

		default:
			sample, err := parseSample(line)
			if err != nil {
				fail("line %d: %v: %q", n, err, line)
				continue
			}
			family, suffix := sample.name, ""
			for _, s := range []string{"_bucket", "_sum", "_count"} {
				if base, ok := strings.CutSuffix(sample.name, s); ok && kinds[base] == "histogram" {
					family, suffix = base, s
					break
				}
			}
			enter(n, family)
			kind, typed := kinds[family]
			if !typed {
				fail("line %d: %s has no TYPE before it", n, sample.name)
				continue
			}
			sampled[family] = true

			names := map[string]bool{}
			var rest []label
			le, hasLe := "", false
			for _, l := range sample.labels {
				if !expositionLabelName.MatchString(l.name) || strings.HasPrefix(l.name, "__") {
					fail("line %d: bad label name %q", n, l.name)
				}
				if names[l.name] {
					fail("line %d: label %s given twice", n, l.name)
				}
				names[l.name] = true
				if l.name == "le" {
					le, hasLe = l.value, true
					if suffix != "_bucket" {
						fail("line %d: le on %s, which is not a histogram bucket", n, sample.name)
					}
					if l.value == "+Inf" {
						continue
					}
				} else {
					rest = append(rest, l)
				}
				if !expositionLabelValue.MatchString(l.value) {
					fail("line %d: label %s=%q is outside [a-z0-9_.]", n, l.name, l.value)
				}
			}

			key := seriesKey(sample.name, sample.labels)
			if seen[key] {
				fail("line %d: series %s is rendered twice", n, key)
			}
			seen[key] = true

			if kind == "counter" && !(sample.value >= 0) {
				fail("line %d: counter %s is %v", n, key, sample.value)
			}
			if kind != "histogram" {
				continue
			}
			if suffix == "" {
				fail("line %d: histogram %s has a sample that is not a bucket, sum or count", n, family)
				continue
			}
			id := seriesKey(family, rest)
			h := histograms[id]
			if h == nil {
				h = &histogramSeries{}
				histograms[id] = h
				order = append(order, id)
			}
			switch suffix {
			case "_bucket":
				if !hasLe {
					fail("line %d: a bucket of %s without le", n, id)
					continue
				}
				bound, err := strconv.ParseFloat(le, 64)
				if err != nil {
					fail("line %d: le %q is not a number", n, le)
					continue
				}
				h.bounds = append(h.bounds, bound)
				h.counts = append(h.counts, sample.value)
			case "_sum":
				h.hasSum = true
			case "_count":
				h.count, h.hasCount = sample.value, true
			}
		}
	}

	for _, family := range families {
		if !sampled[family] {
			fail("%s is declared but has no samples", family)
		}
	}
	for _, id := range order {
		h := histograms[id]
		if !h.hasSum {
			fail("%s has no _sum", id)
		}
		if !h.hasCount {
			fail("%s has no _count", id)
		}
		if len(h.bounds) == 0 {
			fail("%s has no buckets", id)
			continue
		}
		for i := 1; i < len(h.bounds); i++ {
			if !(h.bounds[i] > h.bounds[i-1]) {
				fail("%s: bucket bounds are not ascending: %v", id, h.bounds)
				break
			}
		}
		for i := 1; i < len(h.counts); i++ {
			if h.counts[i] < h.counts[i-1] {
				fail("%s: buckets are not cumulative: %v", id, h.counts)
				break
			}
		}
		last := len(h.bounds) - 1
		if !math.IsInf(h.bounds[last], 1) {
			fail("%s has no +Inf bucket as its last", id)
		} else if h.hasCount && h.counts[last] != h.count {
			fail("%s: the +Inf bucket holds %v but _count is %v", id, h.counts[last], h.count)
		}
	}
	return problems
}

func TestExpositionIsWellFormed(t *testing.T) {
	// Prometheus refuses a whole scrape for one bad line, so every render must
	// hold the format — and no label may carry anything but the server's own
	// closed values.
	s := &server{hub: NewHub()}
	rendered := renderMetrics(s)
	checkExposition(t, rendered)
	// Since process.go, a render is no longer byte-identical from one scrape
	// to the next: the scheduler and the garbage collector do not pause for a
	// scrape, so relay_goroutines, the runtime memory figures and the two
	// rebucketed histograms are free to move even though nothing the server
	// itself tracks has changed. What must still hold: the same families in
	// the same order — nothing appears or disappears between two scrapes of
	// an idle server — and the server's own numbers, as opposed to the
	// machine's, stay exactly put.
	again := renderMetrics(s)
	checkExposition(t, again)
	if before, after := familyNames(rendered), familyNames(again); !slices.Equal(before, after) {
		t.Errorf("families differ between two renders:\n%v\n---\n%v", before, after)
	}
	for _, series := range []string{
		"relay_connections", "relay_connections_limit", "relay_rooms_limit",
		"relay_start_time_seconds",
		`relay_build_info{goversion="` + goVersionLabel(runtime.Version()) + `",version="dev"}`,
	} {
		first, foundFirst := seriesValue(rendered, series)
		second, foundSecond := seriesValue(again, series)
		if !foundFirst || !foundSecond || first != second {
			t.Errorf("%s moved between two renders of the same state: %q (found %v), then %q (found %v)",
				series, first, foundFirst, second, foundSecond)
		}
	}

	// The server renders no histogram yet, so one is built here: the histogram
	// path has to be seen working before a real family relies on it.
	shape := durationBuckets(0.01, 0.1, 1)
	pairs := labelSet{
		{"kind", []string{"code", "quick"}},
		{"outcome", []string{"paired", "abandoned"}},
	}
	var opened atomic.Uint64
	var outcomes counterVec
	var wait histogram
	var waits histogramVec
	opened.Add(3)
	outcomes.inc(pairs, "quick", "abandoned")
	outcomes.add(pairs, 4, "code", "paired")
	wait.observeDuration(shape, 50*time.Millisecond)
	waits.at(pairs, "code", "paired").observeDuration(shape, 2*time.Second)
	waits.at(pairs, "quick", "abandoned").observeDuration(shape, 5*time.Millisecond)
	waits.at(pairs, "quick", "nobody").observeDuration(shape, time.Second)

	var out bytes.Buffer
	e := newExposition(&out)
	e.counter("relay_example_opened_total", "An example counter.", opened.Load())
	e.counterVec("relay_example_outcomes_total", "An example counter vector.", pairs, &outcomes)
	e.gauge("relay_example_now", "An example gauge.", 2)
	e.histogram("relay_example_wait_seconds", "An example histogram.", shape, &wait)
	e.histogramVec("relay_example_waits_seconds", "An example histogram vector.", pairs, shape, &waits)
	e.flush()
	built := out.String()
	checkExposition(t, built)

	for _, c := range []struct {
		series string
		want   string
	}{
		{`relay_example_opened_total`, "3"},
		{`relay_example_outcomes_total{kind="quick",outcome="abandoned"}`, "1"},
		{`relay_example_outcomes_total{kind="code",outcome="paired"}`, "4"},
		{`relay_example_outcomes_total{kind="code",outcome="abandoned"}`, "0"},
		{`relay_example_now`, "2"},
		{`relay_example_wait_seconds_bucket{le="0.01"}`, "0"},
		{`relay_example_wait_seconds_bucket{le="0.1"}`, "1"},
		{`relay_example_wait_seconds_bucket{le="+Inf"}`, "1"},
		{`relay_example_wait_seconds_sum`, "0.05"},
		{`relay_example_waits_seconds_bucket{kind="code",outcome="paired",le="1"}`, "0"},
		{`relay_example_waits_seconds_bucket{kind="code",outcome="paired",le="+Inf"}`, "1"},
		{`relay_example_waits_seconds_sum{kind="code",outcome="paired"}`, "2"},
		{`relay_example_waits_seconds_count{kind="quick",outcome="abandoned"}`, "1"},
		// A value outside the closed set is not counted anywhere.
		{`relay_example_waits_seconds_count{kind="quick",outcome="paired"}`, "0"},
	} {
		if got, found := seriesValue(built, c.series); !found || got != c.want {
			t.Errorf("%s is %q (found %v), expected %q", c.series, got, found, c.want)
		}
	}

	// And the checker catches what it claims to: a checker that never refuses
	// anything proves nothing about the renders it passes.
	const head = "# HELP relay_a A.\n# TYPE relay_a gauge\n"
	const histogramHead = "# HELP relay_h H.\n# TYPE relay_h histogram\n"
	for _, bad := range []struct{ why, text, mention string }{
		{"a sample before its TYPE", "# HELP relay_a A.\nrelay_a 1\n# TYPE relay_a gauge\n", "no TYPE"},
		{"a family without HELP", "# TYPE relay_a gauge\nrelay_a 1\n", "no HELP"},
		{"a family declared twice", head + "relay_a 1\n# HELP relay_b B.\n# TYPE relay_b gauge\nrelay_b 1\n# TYPE relay_a gauge\n", "declared twice"},
		{"a family split in two", head + "relay_a{k=\"x\"} 1\n# HELP relay_b B.\n# TYPE relay_b gauge\nrelay_b 1\nrelay_a{k=\"y\"} 1\n", "continues"},
		{"a series rendered twice", head + "relay_a{k=\"x\",j=\"y\"} 1\nrelay_a{j=\"y\",k=\"x\"} 2\n", "rendered twice"},
		{"a counter without _total", "# HELP relay_a A.\n# TYPE relay_a counter\nrelay_a 1\n", "_total"},
		{"a room code in a label", head + "relay_a{code=\"K7QX2M\"} 1\n", "outside"},
		{"a label that is not a closed value", head + "relay_a{game=\"my game\"} 1\n", "outside"},
		{"buckets that shrink", histogramHead + "relay_h_bucket{le=\"0.1\"} 2\nrelay_h_bucket{le=\"+Inf\"} 1\nrelay_h_sum 1\nrelay_h_count 1\n", "cumulative"},
		{"+Inf apart from _count", histogramHead + "relay_h_bucket{le=\"0.1\"} 1\nrelay_h_bucket{le=\"+Inf\"} 2\nrelay_h_sum 1\nrelay_h_count 3\n", "_count is"},
		{"a histogram without _sum", histogramHead + "relay_h_bucket{le=\"+Inf\"} 1\nrelay_h_count 1\n", "no _sum"},
		{"a histogram without +Inf", histogramHead + "relay_h_bucket{le=\"0.1\"} 1\nrelay_h_sum 1\nrelay_h_count 1\n", "+Inf"},
		{"a timestamp", head + "relay_a 1 1700000000000\n", "one value"},
		{"no final newline", head + "relay_a 1", "newline"},
	} {
		problems := expositionProblems(bad.text)
		if !strings.Contains(strings.Join(problems, "\n"), bad.mention) {
			t.Errorf("the checker let %s through (problems: %q)", bad.why, problems)
		}
	}
}

func TestExpositionReportsConnectionsAndLimits(t *testing.T) {
	// Connections and the limits they run into are read at the moment of the
	// scrape, not counted as they happen: a count kept alongside can drift from
	// the truth, the server's own map of connections cannot.
	s := &server{hub: NewHub(), maxConns: 7}
	s.hub.limit = 3
	addr, stop := serve(t, s)
	defer stop()

	if got := metricValue(t, s, "relay_connections_limit"); got != 7 {
		t.Errorf("connections limit %v, expected 7", got)
	}
	if got := metricValue(t, s, "relay_rooms_limit"); got != 3 {
		t.Errorf("rooms limit %v, expected 3", got)
	}
	if got := metricValue(t, s, "relay_connections"); got != 0 {
		t.Errorf("%v connections before anyone connected", got)
	}

	first := dial(t, addr)
	second := dial(t, addr)
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 2 })
	first.conn.Close()
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 1 })
	second.conn.Close()
	eventually(t, func() bool { return metricValue(t, s, "relay_connections") == 0 })

	info := `relay_build_info{goversion="` + goVersionLabel(runtime.Version()) + `",version="dev"}`
	if got := metricValue(t, s, info); got != 1 {
		t.Errorf("%s is %v, expected 1", info, got)
	}
	// The start is the process's own, taken once: a restart shows as a jump,
	// and a scrape must not read as one.
	started := metricValue(t, s, "relay_start_time_seconds")
	if started <= 0 || started > float64(time.Now().Unix()+1) {
		t.Errorf("start time %v is not a moment in the past", started)
	}
	if again := metricValue(t, s, "relay_start_time_seconds"); again != started {
		t.Errorf("start time moved between scrapes: %v, then %v", started, again)
	}
}

func TestBuildVersionIsSanitized(t *testing.T) {
	// The version is stamped at build time from whatever the release was given,
	// and it becomes a label. A "v0.5.0" typed by hand, or a value with a quote
	// in it, must not reach the render as it was typed.
	defer func(kept string) { version = kept }(version)
	for _, c := range []struct{ stamped, want string }{
		{"dev", "dev"},
		{"0.5.0", "0.5.0"},
		{"123.45.6", "123.45.6"},
		{"v0.5.0", "unknown"},
		{"0.5", "unknown"},
		{"0.5.0-rc1", "unknown"},
		{"1234.0.0", "unknown"},
		{"0.5.0\n", "unknown"},
		{`0.5.0"} 1`, "unknown"},
		{"", "unknown"},
	} {
		version = c.stamped
		if got := buildVersion(); got != c.want {
			t.Errorf("version stamped as %q renders as %q, expected %q", c.stamped, got, c.want)
		}
	}

	version = `0.5.0"} 1`
	s := &server{hub: NewHub()}
	text := renderMetrics(s)
	checkExposition(t, text)
	if !strings.Contains(text, `version="unknown"`) {
		t.Errorf("a stamped version with a quote reached the render:\n%s", text)
	}

	// The Go version is a label too. A release toolchain names itself plainly;
	// an experiment or a development build adds words the label cannot carry.
	for _, c := range []struct{ reported, want string }{
		{"go1.26.4", "go1.26.4"},
		{"go1.27rc1", "go1.27rc1"},
		{"go1.26.4 X:jsonv2", "go1.26.4"},
		{"devel go1.27-4d1c2a Tue Sep 1 10:00:00 2026 +0000", "unknown"},
		{"", "unknown"},
	} {
		if got := goVersionLabel(c.reported); got != c.want {
			t.Errorf("Go reported as %q renders as %q, expected %q", c.reported, got, c.want)
		}
	}
}

func TestHistogramLandsValuesOnTheirBounds(t *testing.T) {
	// A bucket's bound is inclusive. Compared carelessly in floating point, a
	// share of exactly 95% lands above the 0.95 bucket — the very line the
	// smooth verdict is drawn at.
	durations := durationBuckets(0.0005, 0.01, 0.25)
	shares := scaledBuckets(100, 0.95, 1.01)
	counts := countBuckets(3, 4)
	var slow, pace, delay histogram
	for _, d := range []time.Duration{
		500 * time.Microsecond, 10 * time.Millisecond, 10*time.Millisecond + 1,
		200 * time.Millisecond, 3 * time.Second,
	} {
		slow.observeDuration(durations, d)
	}
	for _, percent := range []uint64{95, 96, 101, 102} {
		pace.observe(shares, percent)
	}
	delay.observe(counts, 3)
	delay.observe(counts, 5)

	var out bytes.Buffer
	e := newExposition(&out)
	e.histogram("relay_example_slow_seconds", "Durations.", durations, &slow)
	e.histogram("relay_example_pace_ratio", "Shares.", shares, &pace)
	e.histogram("relay_example_delay_ticks", "Counts.", counts, &delay)
	e.flush()
	text := out.String()
	checkExposition(t, text)

	for _, c := range []struct{ series, want string }{
		{`relay_example_slow_seconds_bucket{le="0.0005"}`, "1"},
		{`relay_example_slow_seconds_bucket{le="0.01"}`, "2"},
		{`relay_example_slow_seconds_bucket{le="0.25"}`, "4"},
		{`relay_example_slow_seconds_bucket{le="+Inf"}`, "5"},
		{`relay_example_slow_seconds_sum`, "3.220500001"},
		{`relay_example_slow_seconds_count`, "5"},
		{`relay_example_pace_ratio_bucket{le="0.95"}`, "1"},
		{`relay_example_pace_ratio_bucket{le="1.01"}`, "3"},
		{`relay_example_pace_ratio_bucket{le="+Inf"}`, "4"},
		{`relay_example_pace_ratio_sum`, "3.94"},
		{`relay_example_delay_ticks_bucket{le="3"}`, "1"},
		{`relay_example_delay_ticks_bucket{le="4"}`, "1"},
		{`relay_example_delay_ticks_bucket{le="+Inf"}`, "2"},
		{`relay_example_delay_ticks_sum`, "8"},
	} {
		if got, found := seriesValue(text, c.series); !found || got != c.want {
			t.Errorf("%s is %q (found %v), expected %q", c.series, got, found, c.want)
		}
	}
}

func TestLabelValuesAndHelpAreEscaped(t *testing.T) {
	// Every label the server renders comes from a closed set, so none of these
	// characters can reach one today. The writer escapes anyway: the day a set
	// grows a value with a quote in it, one broken line would blank the whole
	// scrape, not just its own series.
	var out bytes.Buffer
	e := newExposition(&out)
	e.family("relay_example_escaped", "gauge", "a back\\slash\nand a new line")
	e.sample("relay_example_escaped", []label{{"quoted", "a\"b\\c\nd"}}, 1)
	e.flush()
	want := "# HELP relay_example_escaped a back\\\\slash\\nand a new line\n" +
		"# TYPE relay_example_escaped gauge\n" +
		"relay_example_escaped{quoted=\"a\\\"b\\\\c\\nd\"} 1\n"
	if got := out.String(); got != want {
		t.Fatalf("escaped render:\n%s\nexpected:\n%s", got, want)
	}
	lines := strings.Split(want, "\n")
	sample, err := parseSample(lines[2])
	if err != nil || len(sample.labels) != 1 || sample.labels[0].value != "a\"b\\c\nd" {
		t.Errorf("the escaped value did not read back: %+v, %v", sample, err)
	}
}

func TestHistogramCountMatchesBucketsUnderConcurrentObservations(t *testing.T) {
	// Observations never take a lock, so a scrape races them. Whatever it
	// catches must still be one consistent histogram: a +Inf bucket that
	// disagrees with _count, or a bucket smaller than the one before it, makes
	// every quantile over that scrape a lie.
	shape := durationBuckets(0.001, 0.01, 0.1)
	var h histogram
	const writers = 8
	var stop atomic.Bool
	observed := make([]uint64, writers)
	summed := make([]uint64, writers)
	var wg sync.WaitGroup
	for w := range writers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; !stop.Load(); i++ {
				d := time.Duration(i%500) * 250 * time.Microsecond
				h.observeDuration(shape, d)
				observed[w]++
				summed[w] += uint64(d)
			}
		}()
	}

	for n := 0; n < 300; n++ {
		var out bytes.Buffer
		e := newExposition(&out)
		e.histogram("relay_example_race_seconds", "Observed while rendered.", shape, &h)
		e.flush()
		if problems := expositionProblems(out.String()); len(problems) > 0 {
			stop.Store(true)
			wg.Wait()
			t.Fatalf("render %d under concurrent observations: %s\n%s",
				n, strings.Join(problems, "; "), out.String())
		}
	}
	stop.Store(true)
	wg.Wait()

	var total, sum uint64
	for w := range writers {
		total += observed[w]
		sum += summed[w]
	}
	var out bytes.Buffer
	e := newExposition(&out)
	e.histogram("relay_example_race_seconds", "Observed while rendered.", shape, &h)
	e.flush()
	text := out.String()
	checkExposition(t, text)
	if got, _ := seriesValue(text, "relay_example_race_seconds_count"); got != strconv.FormatUint(total, 10) {
		t.Errorf("_count is %s after %d observations", got, total)
	}
	wantSum := strconv.FormatFloat(float64(sum)/1e9, 'f', -1, 64)
	if got, _ := seriesValue(text, "relay_example_race_seconds_sum"); got != wantSum {
		t.Errorf("_sum is %s, expected %s", got, wantSum)
	}
}

// Every platform label the server may render, in the order it renders them.
var testPlatforms = []string{
	"web", "web_android", "web_ios", "macos", "windows", "linux", "android", "ios", "unknown", "other",
}

func TestPlatformAndVersionLabelsAreClosed(t *testing.T) {
	// Both come from the client's hello, as the client typed them. A label
	// value is a series, so a stranger who could pick the values could grow the
	// render without bound; whatever is sent, only a closed set comes out.
	for _, c := range []struct{ sent, want string }{
		{"web", "web"},
		{"web_android", "web_android"},
		{"web_ios", "web_ios"},
		{"macos", "macos"},
		{"windows", "windows"},
		{"linux", "linux"},
		{"android", "android"},
		{"ios", "ios"},
		{"", "unknown"},
		{"unknown", "unknown"},
		{"other", "other"},
		{"Macos", "other"},
		{"UNKNOWN", "other"},
		{"macos ", "other"},
		{" web", "other"},
		{"web\n", "other"},
		{"playstation", "other"},
		{`ios"} 1`, "other"},
	} {
		got := platformLabel(c.sent)
		if got != c.want {
			t.Errorf("platform sent as %q is labelled %q, expected %q", c.sent, got, c.want)
		}
		if !slices.Contains(testPlatforms, got) {
			t.Errorf("platform sent as %q is labelled %q, outside the closed set", c.sent, got)
		}
		// A member keeps only the label, and the label goes through the same
		// function again when it is counted: labelling a label changes nothing.
		if again := platformLabel(got); again != got {
			t.Errorf("platform label %q labelled again became %q", got, again)
		}
	}

	for _, c := range []struct{ sent, want string }{
		{"0.5.0", "0.5.0"},
		{"0.0.0", "0.0.0"},
		{"123.45.6", "123.45.6"},
		{"", "unknown"},
		{"unknown", "unknown"},
		{"other", "other"},
		{"Unknown", "other"},
		{"dev", "other"},
		{"v0.5.0", "other"},
		{"0.5", "other"},
		{"0.5.0.1", "other"},
		{"0.5.0-rc1", "other"},
		{"1234.0.0", "other"},
		{"0.5.0\n", "other"},
		{" 0.5.0", "other"},
		{`0.5.0"} 1`, "other"},
		// Digits of another script are digits to Unicode but not to a label.
		{"١.٢.٣", "other"},
	} {
		got := versionLabel(c.sent)
		if got != c.want {
			t.Errorf("version sent as %q is labelled %q, expected %q", c.sent, got, c.want)
		}
		if !expositionLabelValue.MatchString(got) {
			t.Errorf("version sent as %q is labelled %q, which no label may carry", c.sent, got)
		}
		if again := versionLabel(got); again != got {
			t.Errorf("version label %q labelled again became %q", got, again)
		}
	}

	// And what a seated member keeps is the label, never what was sent: the
	// strings end with the hello.
	s := &server{hub: NewHub()}
	for _, c := range []struct {
		platform, version string
		want              client
	}{
		{"ios", "0.5.0", client{platform: "ios", version: "0.5.0"}},
		{"PlayStation 5", "v0.5.0 beta", client{platform: "other", version: "other"}},
		{"", "", client{platform: "unknown", version: "unknown"}},
	} {
		far, conn := pipeConn(t)
		body, _ := json.Marshal(hello{Action: "create", Game: "tanks", Platform: c.platform, Version: c.version})
		go func() {
			far.Write(clientFrame(opBinary, body))
			io.Copy(io.Discard, far)
		}()
		_, member, err := s.greet(conn, httptest.NewRequest(http.MethodGet, "/ws", nil))
		far.Close()
		if err != nil {
			t.Fatalf("a hello naming %q and %q was not seated: %v", c.platform, c.version, err)
		}
		if member.client != c.want {
			t.Errorf("a hello naming %q and %q left the member with %+v, expected %+v",
				c.platform, c.version, member.client, c.want)
		}
	}
}

// familySamples returns every sample of one family in a render, by the value
// of the one label it is split by, keeping the order they were rendered in.
func familySamples(t *testing.T, text, family, labelName string) ([]string, map[string]float64) {
	t.Helper()
	var order []string
	values := map[string]float64{}
	for _, line := range strings.Split(text, "\n") {
		if !strings.HasPrefix(line, family+"{") {
			continue
		}
		sample, err := parseSample(line)
		if err != nil || len(sample.labels) != 1 || sample.labels[0].name != labelName {
			t.Fatalf("an unexpected sample of %s: %q (%v)", family, line, err)
		}
		order = append(order, sample.labels[0].value)
		values[sample.labels[0].value] = sample.value
	}
	return order, values
}

func TestLiveVersionsAreFoldedPastTen(t *testing.T) {
	// Versions are not a closed set: every release is a new one. Kept in a
	// table as they arrive, a script sending made-up versions could fill it;
	// counted at the scrape from whoever is seated right now, the ten most
	// common get a series each and everything past them is other.
	s := &server{hub: NewHub()}
	type seat struct {
		room   *Room
		member *Member
	}
	var seats []seat
	sit := func(c client, times int) {
		t.Helper()
		for range times {
			room, member, err := s.hub.QuickAs("tanks", 1, c)
			if err != nil {
				t.Fatalf("a player was not seated: %v", err)
			}
			seats = append(seats, seat{room, member})
		}
	}
	sit(client{platform: "web", version: "2.0.0"}, 4)
	sit(client{platform: "macos", version: "1.9.0"}, 3)
	sit(client{platform: "web", version: "1.8.0"}, 2)
	// Nine versions tied at one player each, broken by the version as a string:
	// 1.0.10 comes before 1.0.2, and 1.0.7 and 1.0.8 are the two left over.
	for _, v := range []string{"1.0.8", "1.0.7", "1.0.6", "1.0.5", "1.0.4", "1.0.3", "1.0.2", "1.0.10", "1.0.1"} {
		sit(client{platform: "ios", version: v}, 1)
	}
	sit(client{platform: "linux", version: versionLabel("dev")}, 1)
	sit(client{platform: "web", version: "unknown"}, 1)
	sit(client{}, 1)

	text := renderMetrics(s)
	checkExposition(t, text)
	order, got := familySamples(t, text, "relay_players_by_version", "version")
	want := map[string]float64{
		"2.0.0": 4, "1.9.0": 3, "1.8.0": 2,
		"1.0.1": 1, "1.0.10": 1, "1.0.2": 1, "1.0.3": 1, "1.0.4": 1, "1.0.5": 1, "1.0.6": 1,
		// 1.0.7 and 1.0.8 past the tenth, and the member whose version was not one.
		"other":   3,
		"unknown": 2,
	}
	if !maps.Equal(got, want) {
		t.Errorf("live versions rendered as %v, expected %v", got, want)
	}
	wantOrder := []string{"2.0.0", "1.9.0", "1.8.0", "1.0.1", "1.0.10", "1.0.2", "1.0.3", "1.0.4", "1.0.5", "1.0.6", "other", "unknown"}
	if !slices.Equal(order, wantOrder) {
		t.Errorf("live versions rendered in the order %v, expected %v", order, wantOrder)
	}
	// The hub's rooms are a map, walked in a different order every time; the
	// render must not follow it.
	for range 20 {
		again, _ := familySamples(t, renderMetrics(s), "relay_players_by_version", "version")
		if !slices.Equal(again, order) {
			t.Fatalf("a second render of the same players came out in the order %v, then %v", order, again)
		}
	}
	if players := metricValue(t, s, `relay_players{platform="ios"}`); players != 9 {
		t.Errorf("relay_players{platform=\"ios\"} is %v, expected 9", players)
	}

	// Nothing is kept between scrapes: a version whose players left is gone,
	// and unknown and other stay, at zero.
	for _, seat := range seats {
		seat.room.Leave(seat.member)
	}
	order, got = familySamples(t, renderMetrics(s), "relay_players_by_version", "version")
	if want := map[string]float64{"other": 0, "unknown": 0}; !maps.Equal(got, want) || len(order) != 2 {
		t.Errorf("with nobody seated, live versions rendered as %v (%v), expected %v", got, order, want)
	}
	sit(client{platform: "web", version: "0.5.0"}, 1)
	_, got = familySamples(t, renderMetrics(s), "relay_players_by_version", "version")
	if want := map[string]float64{"0.5.0": 1, "other": 0, "unknown": 0}; !maps.Equal(got, want) {
		t.Errorf("one player seated after everyone left rendered as %v, expected %v", got, want)
	}
}

func TestScrapingWhilePlayersComeAndGo(t *testing.T) {
	// A scrape copies the list of rooms under the hub's lock, lets go of it, and
	// then reads each room's members under that room's lock alone. What a member
	// said about itself must therefore be written before the member is in the
	// room: written after, even under the hub's lock, it is read unguarded by a
	// scrape that took its list a moment earlier. A scraper that follows one room
	// at a time stands in for that moment, and every way a player sits down —
	// matchmaking, a hello, a plain join — is walked past it again and again: a
	// late write is a few instructions wide, and the race detector only sees the
	// time it lands between two of the scraper's reads.
	s := &server{hub: NewHub()}
	var watched atomic.Pointer[Room]
	var stop atomic.Bool
	scraped := make(chan struct{})
	go func() {
		defer close(scraped)
		for !stop.Load() {
			if room := watched.Load(); room != nil {
				livePlayers([]*Room{room})
			}
		}
	}()
	request := httptest.NewRequest(http.MethodGet, "/ws", nil)
	for i := range 300 {
		waiting, waiter, err := s.hub.QuickAs("tanks", uint32(i), client{platform: "web", version: "0.5.0"})
		if err != nil {
			t.Fatalf("no waiting room: %v", err)
		}
		watched.Store(waiting)

		_, partner, err := s.hub.QuickAs("tanks", uint32(i), client{platform: "ios", version: "0.4.0"})
		if err != nil || partner.Slot != 1 {
			t.Fatalf("matchmaking did not seat the partner with the waiter: %v", err)
		}
		waiting.Leave(partner)

		// A hello has the narrowest window of the three — greet locks the room
		// again straight after seating — so it is walked past more often.
		body, _ := json.Marshal(hello{Action: "join", Game: "tanks", Code: waiting.Code, Platform: "android", Version: "0.4.0"})
		for range 4 {
			far, conn := pipeConn(t)
			go func() {
				far.Write(clientFrame(opBinary, body))
				io.Copy(io.Discard, far)
			}()
			_, greeted, err := s.greet(conn, request)
			if err != nil {
				t.Fatalf("the hello was not seated: %v", err)
			}
			waiting.Leave(greeted)
			far.Close()
		}

		member, err := waiting.JoinAs(client{platform: "linux", version: "0.3.0"})
		if err != nil {
			t.Fatalf("not seated: %v", err)
		}
		waiting.Leave(member)
		waiting.Leave(waiter)
		s.hub.Sweep(time.Now().Add(emptyRoomLifetime + time.Minute))
	}
	stop.Store(true)
	<-scraped

	// And whole scrapes, while players meet, leave and have their rooms swept,
	// stay well formed.
	stop.Store(false)
	var wg sync.WaitGroup
	for w := range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c := client{platform: testPlatforms[w], version: "0." + strconv.Itoa(w) + ".0"}
			for !stop.Load() {
				if room, member, err := s.hub.QuickAs("tanks", uint32(w), c); err == nil {
					room.Leave(member)
				}
				s.hub.Sweep(time.Now().Add(emptyRoomLifetime + time.Minute))
			}
		}()
	}
	for range 200 {
		if problems := expositionProblems(renderMetrics(s)); len(problems) > 0 {
			stop.Store(true)
			wg.Wait()
			t.Fatalf("a render while players came and went: %s", strings.Join(problems, "; "))
		}
	}
	stop.Store(true)
	wg.Wait()
}

func TestExpositionNeverCarriesCodesOrSeeds(t *testing.T) {
	// A room's code is the way into it, and the seed and the game name belong to
	// the players. None of them may leave the server through a scrape, not even
	// on a machine where only the owner reads the metrics: dashboards get shared.
	const seed = 3735928559
	const game = "zqprivatematch"
	s := &server{hub: NewHub()}
	addr, stop := serve(t, s)
	defer stop()

	host := dial(t, addr)
	host.sendJSON(t, hello{Action: "create", Game: game, Seed: seed, Platform: "web", Version: "0.5.0"})
	code := host.welcome(t).Code
	guest := dial(t, addr)
	guest.sendJSON(t, hello{Action: "join", Game: game, Code: code, Platform: "macos", Version: "0.5.0"})
	if answer := guest.welcome(t); !answer.OK {
		t.Fatalf("the guest was refused: %+v", answer)
	}
	waiter := dial(t, addr)
	waiter.sendJSON(t, hello{Action: "quick", Game: game, Seed: seed, Platform: "ios", Version: "0.4.0"})
	quickCode := waiter.welcome(t).Code
	eventually(t, func() bool {
		return metricValue(t, s, `relay_seatings_total{action="quick",platform="ios"}`) == 1
	})

	text := renderMetrics(s)
	checkExposition(t, text)
	for _, secret := range []string{code, quickCode, game} {
		if strings.Contains(text, secret) {
			t.Errorf("%q, a room's code or its game, is in the render:\n%s", secret, text)
		}
	}
	// The seed's digits may turn up by chance in a memory figure, so they are
	// looked for only where a room's own number could have been put: in a label,
	// or as a value.
	digits := strconv.FormatUint(seed, 10)
	lowered := []string{strings.ToLower(code), strings.ToLower(quickCode)}
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		sample, err := parseSample(line)
		if err != nil {
			t.Fatalf("an unreadable line: %q (%v)", line, err)
		}
		if sample.value == seed {
			t.Errorf("a series carries the seed as its value: %q", line)
		}
		for _, l := range sample.labels {
			if strings.Contains(l.value, digits) || slices.Contains(lowered, l.value) {
				t.Errorf("a label carries a room's seed or code: %q", line)
			}
		}
	}
}

// expectSeries checks several exact series in one render, in a steady order so
// that two failing runs report the same way.
func expectSeries(t *testing.T, s *server, want map[string]float64) {
	t.Helper()
	text := renderMetrics(s)
	for _, series := range slices.Sorted(maps.Keys(want)) {
		raw, found := seriesValue(text, series)
		if !found {
			t.Errorf("no series %s in the render", series)
			continue
		}
		if got, err := strconv.ParseFloat(raw, 64); err != nil || got != want[series] {
			t.Errorf("%s is %s, expected %v", series, raw, want[series])
		}
	}
}

// expectBetween checks a series that holds a measured time: at least low,
// and less than high.
func expectBetween(t *testing.T, s *server, series string, low, high float64) {
	t.Helper()
	if got := metricValue(t, s, series); got < low || got >= high {
		t.Errorf("%s is %v, expected at least %v and less than %v", series, got, low, high)
	}
}

func TestRoomsAreReportedByState(t *testing.T) {
	// Where every room stands right now, read from the rooms themselves at the
	// scrape. The matchmaking queue cannot say it: a waiter who gave up stays
	// in the queue until the next quick player walks past, and counted from it
	// they would still be waiting.
	s := &server{hub: NewHub()}
	kinds := []string{"code", "quick"}
	states := []string{"waiting", "playing", "interrupted", "empty"}
	rooms := func(kind, state string) string {
		return `relay_rooms{kind="` + kind + `",state="` + state + `"}`
	}

	// Every room and product series from the very first scrape, at zero.
	first := renderMetrics(s)
	checkExposition(t, first)
	zero := []string{"relay_journal_capped_total"}
	for _, kind := range kinds {
		for _, state := range states {
			zero = append(zero, rooms(kind, state))
		}
		zero = append(zero,
			`relay_rooms_created_total{kind="`+kind+`"}`,
			`relay_pairings_total{kind="`+kind+`"}`,
			`relay_played_seconds_count{kind="`+kind+`"}`,
			`relay_pairing_wait_seconds_count{kind="`+kind+`",outcome="paired"}`,
			`relay_pairing_wait_seconds_count{kind="`+kind+`",outcome="abandoned"}`,
		)
	}
	for _, series := range zero {
		if got, found := seriesValue(first, series); !found || got != "0" {
			t.Errorf("before any room was opened %s is %q (found %v)", series, got, found)
		}
	}

	// A different number of rooms in every state, so that no two series can be
	// mistaken for each other.
	waiting, _ := s.hub.Create("tanks", 1)
	waiting.Join()
	for range 2 {
		room, _ := s.hub.Create("tanks", 1)
		room.Join()
		room.Join()
	}
	// Interrupted: a partner dropped out three times over, and once the pair
	// both left and one came back. Either way someone is waiting for a partner
	// they already had.
	for range 3 {
		room, _ := s.hub.Create("tanks", 1)
		room.Join()
		guest, _ := room.Join()
		room.Leave(guest)
	}
	{
		room, _ := s.hub.Create("tanks", 1)
		host, _ := room.Join()
		guest, _ := room.Join()
		room.Leave(guest)
		room.Leave(host)
		room.Join()
	}
	// Empty: opened and nobody seated yet, a host who left before anyone came,
	// and a pair who both left.
	s.hub.Create("tanks", 1)
	for range 2 {
		room, _ := s.hub.Create("tanks", 1)
		host, _ := room.Join()
		room.Leave(host)
	}
	{
		room, _ := s.hub.Create("tanks", 1)
		host, _ := room.Join()
		guest, _ := room.Join()
		room.Leave(guest)
		room.Leave(host)
	}

	// Quick rooms, each game on its own so that nobody gets matched by accident.
	game := 0
	quick := func() (*Room, *Member) {
		game++
		room, member, err := s.hub.Quick("quick"+strconv.Itoa(game), 1)
		if err != nil {
			t.Fatalf("no quick room: %v", err)
		}
		return room, member
	}
	for range 4 {
		quick()
	}
	for range 3 {
		room, _ := quick()
		s.hub.Quick(room.Game, 2)
	}
	for range 2 {
		room, _ := quick()
		_, partner, _ := s.hub.Quick(room.Game, 2)
		room.Leave(partner)
	}
	gaveUp, waiter := quick()
	gaveUp.Leave(waiter)
	if queued := s.hub.waitingCount(gaveUp.Game); queued != 1 {
		t.Fatalf("the queue holds %d rooms of a waiter who gave up; the test needs it to still hold one", queued)
	}

	want := map[string]float64{
		rooms("code", "waiting"): 1, rooms("code", "playing"): 2, rooms("code", "interrupted"): 4, rooms("code", "empty"): 4,
		rooms("quick", "waiting"): 4, rooms("quick", "playing"): 3, rooms("quick", "interrupted"): 2, rooms("quick", "empty"): 1,
	}
	expectSeries(t, s, want)
	checkExposition(t, renderMetrics(s))

	// A waiter who is found moves from waiting to playing, and the room of the
	// one who gave up is gone once swept.
	waitingRoom, _ := quick()
	want[rooms("quick", "waiting")]++
	expectSeries(t, s, want)
	s.hub.Quick(waitingRoom.Game, 2)
	want[rooms("quick", "waiting")]--
	want[rooms("quick", "playing")]++
	expectSeries(t, s, want)
}

func TestJournalBytesAreSummedAcrossRooms(t *testing.T) {
	// The memory every journal holds, read from the rooms at the scrape: the
	// same figure the load measurement reads, summed over every room there is,
	// so a dashboard can set it against the caps.
	s := &server{hub: NewHub()}
	expectSeries(t, s, map[string]float64{"relay_journal_bytes": 0})

	busy, _ := s.hub.Create("tanks", 1)
	quiet, _ := s.hub.Create("tanks", 2)
	s.hub.Create("tanks", 3) // opened, and nothing in its journal yet
	host, _ := busy.Join()
	for i := range 1000 {
		busy.Broadcast(host, []byte{1, byte(i), byte(i >> 8), 0, 0, 31})
	}
	for range 10 {
		quiet.Broadcast(nil, []byte{2, 0, 0, 0, 0, 31, 0, 0, 9})
	}
	busyBytes, quietBytes := busy.JournalBytes(), quiet.JournalBytes()
	if busyBytes == 0 || quietBytes == 0 || busyBytes == quietBytes {
		t.Fatalf("the test needs two different journals that hold something, got %d and %d", busyBytes, quietBytes)
	}
	expectSeries(t, s, map[string]float64{"relay_journal_bytes": float64(busyBytes + quietBytes)})
	checkExposition(t, renderMetrics(s))
}
