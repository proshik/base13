package main

import (
	"encoding/json"
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

	"github.com/prometheus/client_golang/prometheus/testutil"
	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"
)

// A scrape is checked the way Prometheus reads it: taken through the real
// handler and read by Prometheus's own parser, not matched against a string we
// happen to expect. A malformed line is never an error the server sees — the
// scrape fails on the other side, and the dashboard quietly goes blank.

// renderMetrics returns what a scrape of s receives: the body the metrics
// handler writes for a scraper that asks for no format in particular, which is
// the text format.
func renderMetrics(s *server) string {
	recorder := httptest.NewRecorder()
	s.metricsHandler("").ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	return recorder.Body.String()
}

// sample is one line of a scrape: a counter or a gauge is one, a histogram is
// one per bucket plus its _sum and _count.
type sample struct {
	name   string           // with _bucket, _sum or _count where the line has it
	series string           // the name and labels, written the way the tests write a series
	labels []*dto.LabelPair // le and quantile among them, where the line has one
	value  float64
}

// parseScrape reads a scrape with Prometheus's own text parser and lays every
// family out as the lines it came from. A series written as the tests write it
// is a bare name such as relay_connections, or a name with its labels sorted by
// label name and le or quantile last, such as
// relay_pairing_wait_seconds_bucket{kind="code",outcome="paired",le="10"}.
//
// The parser takes a series written twice without complaint, and a scrape
// carrying one is ambiguous to whatever reads it, so that is refused here.
func parseScrape(text string) ([]sample, error) {
	parser := expfmt.NewTextParser(model.LegacyValidation)
	families, err := parser.TextToMetricFamilies(strings.NewReader(text))
	if err != nil {
		return nil, fmt.Errorf("prometheus cannot parse the scrape: %w", err)
	}
	var samples []sample
	seen := map[string]bool{}
	add := func(name string, labels []*dto.LabelPair, bound *dto.LabelPair, value float64) error {
		sorted := slices.Clone(labels)
		slices.SortFunc(sorted, func(a, b *dto.LabelPair) int { return strings.Compare(a.GetName(), b.GetName()) })
		if bound != nil {
			sorted = append(sorted, bound)
		}
		parts := make([]string, len(sorted))
		for i, l := range sorted {
			parts[i] = l.GetName() + `="` + l.GetValue() + `"`
		}
		series := name
		if len(parts) > 0 {
			series += "{" + strings.Join(parts, ",") + "}"
		}
		if seen[series] {
			return fmt.Errorf("series %s is in the scrape twice", series)
		}
		seen[series] = true
		samples = append(samples, sample{name: name, series: series, labels: sorted, value: value})
		return nil
	}
	pair := func(name string, value float64) *dto.LabelPair {
		text := "+Inf"
		if !math.IsInf(value, 1) {
			text = strconv.FormatFloat(value, 'f', -1, 64)
		}
		return &dto.LabelPair{Name: &name, Value: &text}
	}

	for _, name := range slices.Sorted(maps.Keys(families)) {
		family := families[name]
		for _, m := range family.GetMetric() {
			var errs []error
			switch family.GetType() {
			case dto.MetricType_COUNTER:
				errs = append(errs, add(name, m.GetLabel(), nil, m.GetCounter().GetValue()))
			case dto.MetricType_GAUGE:
				errs = append(errs, add(name, m.GetLabel(), nil, m.GetGauge().GetValue()))
			case dto.MetricType_UNTYPED:
				errs = append(errs, add(name, m.GetLabel(), nil, m.GetUntyped().GetValue()))
			case dto.MetricType_SUMMARY:
				summary := m.GetSummary()
				for _, q := range summary.GetQuantile() {
					errs = append(errs, add(name, m.GetLabel(), pair("quantile", q.GetQuantile()), q.GetValue()))
				}
				errs = append(errs,
					add(name+"_sum", m.GetLabel(), nil, summary.GetSampleSum()),
					add(name+"_count", m.GetLabel(), nil, float64(summary.GetSampleCount())))
			case dto.MetricType_HISTOGRAM:
				histogram := m.GetHistogram()
				count := float64(histogram.GetSampleCount()) + histogram.GetSampleCountFloat()
				infinite := false
				for _, b := range histogram.GetBucket() {
					infinite = infinite || math.IsInf(b.GetUpperBound(), 1)
					cumulative := float64(b.GetCumulativeCount()) + b.GetCumulativeCountFloat()
					errs = append(errs, add(name+"_bucket", m.GetLabel(), pair("le", b.GetUpperBound()), cumulative))
				}
				if !infinite {
					errs = append(errs, add(name+"_bucket", m.GetLabel(), pair("le", math.Inf(1)), count))
				}
				errs = append(errs,
					add(name+"_sum", m.GetLabel(), nil, histogram.GetSampleSum()),
					add(name+"_count", m.GetLabel(), nil, count))
			default:
				return nil, fmt.Errorf("%s has type %s, which the server never exposes", name, family.GetType())
			}
			for _, err := range errs {
				if err != nil {
					return nil, err
				}
			}
		}
	}
	return samples, nil
}

// seriesValues is every series of a scrape by the way the tests write one. A
// scrape Prometheus would refuse fails the test.
func seriesValues(t *testing.T, text string) map[string]float64 {
	t.Helper()
	samples, err := parseScrape(text)
	if err != nil {
		t.Fatalf("%v\n%s", err, text)
	}
	values := make(map[string]float64, len(samples))
	for _, s := range samples {
		values[s.series] = s.value
	}
	return values
}

// metricValue finds one exact series in a fresh scrape and returns its value.
func metricValue(t *testing.T, s *server, series string) float64 {
	t.Helper()
	text := renderMetrics(s)
	value, found := seriesValues(t, text)[series]
	if !found {
		t.Fatalf("no series %s in the scrape:\n%s", series, text)
	}
	return value
}

// familyNames returns the name of every family in a scrape, sorted by name as
// parseScrape lays them out. The order a scrape writes them in is the client
// library's, not the server's, so two of these lists compare the sets of
// families: two scrapes with the same families agree on shape even when the
// live figures inside them do not agree on value.
func familyNames(t *testing.T, text string) []string {
	t.Helper()
	samples, err := parseScrape(text)
	if err != nil {
		t.Fatalf("%v\n%s", err, text)
	}
	var names []string
	for _, s := range samples {
		family := s.name
		for _, suffix := range []string{"_bucket", "_sum", "_count"} {
			family = strings.TrimSuffix(family, suffix)
		}
		if len(names) == 0 || names[len(names)-1] != family {
			names = append(names, family)
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

// Only what the server's closed sets are made of. A room code is uppercase, so
// it cannot pass as a label value even by accident.
var expositionLabelValue = regexp.MustCompile(`^[a-z0-9_.]+$`)

// expositionProblem says what is wrong with a scrape, if anything: a scrape
// Prometheus would refuse, or a label value of the server's own outside the
// closed sets' characters. Only relay_ families are held to that: the
// standard collectors' labels are the client library's, and go_info names the
// toolchain as it reports itself, spaces and all on an experimental one. le
// and quantile are exempt too: they are bounds the library writes, and +Inf
// is one of them.
func expositionProblem(text string) error {
	samples, err := parseScrape(text)
	if err != nil {
		return err
	}
	for _, s := range samples {
		if !strings.HasPrefix(s.name, "relay_") {
			continue
		}
		for _, l := range s.labels {
			if l.GetName() == "le" || l.GetName() == "quantile" {
				continue
			}
			if !expositionLabelValue.MatchString(l.GetValue()) {
				return fmt.Errorf("%s: label %s=%q is outside [a-z0-9_.]", s.series, l.GetName(), l.GetValue())
			}
		}
	}
	return nil
}

// checkExposition fails the test on anything in a scrape that Prometheus would
// refuse or misread, or that no label of the server's may carry. Any test may
// hand it any scrape.
func checkExposition(t *testing.T, text string) {
	t.Helper()
	if err := expositionProblem(text); err != nil {
		t.Errorf("%v\n%s", err, text)
	}
}

func TestExpositionIsWellFormed(t *testing.T) {
	// Prometheus refuses a whole scrape for one bad line, so every scrape must
	// hold the format — and no label may carry anything but the server's own
	// closed values.
	s := &server{hub: NewHub()}
	// The client library's own linter, over each registry a scrape reads: the
	// hub's, with the standard collectors on it, and the one holding what is
	// read at the moment of the scrape.
	for i, registry := range s.metricsGatherers() {
		problems, err := testutil.GatherAndLint(registry)
		if err != nil {
			t.Fatalf("registry %d could not be gathered: %v", i, err)
		}
		for _, problem := range problems {
			t.Errorf("registry %d: %s: %s", i, problem.Metric, problem.Text)
		}
	}
	rendered := renderMetrics(s)
	checkExposition(t, rendered)
	// A scrape is not the same bytes from one to the next: the scheduler and the
	// garbage collector do not pause for it, so the runtime's and the process's
	// figures are free to move even though nothing the server itself tracks has
	// changed. What must still hold: the same families — nothing appears or
	// disappears between two scrapes of an idle server — and the server's own
	// numbers, as opposed to the machine's, stay exactly put.
	again := renderMetrics(s)
	checkExposition(t, again)
	if before, after := familyNames(t, rendered), familyNames(t, again); !slices.Equal(before, after) {
		t.Errorf("families differ between two scrapes:\n%v\n---\n%v", before, after)
	}
	first, second := seriesValues(t, rendered), seriesValues(t, again)
	for _, series := range []string{
		"relay_connections", "relay_connections_limit", "relay_rooms_limit",
		`relay_build_info{goversion="` + goVersionLabel(runtime.Version()) + `",version="dev"}`,
	} {
		before, foundBefore := first[series]
		after, foundAfter := second[series]
		if !foundBefore || !foundAfter || before != after {
			t.Errorf("%s moved between two scrapes of the same state: %v (found %v), then %v (found %v)",
				series, before, foundBefore, after, foundAfter)
		}
	}

	// And the checker catches what it claims to: a checker that never refuses
	// anything proves nothing about the scrapes it passes.
	const head = "# HELP relay_a A.\n# TYPE relay_a gauge\n"
	for _, bad := range []struct{ why, text, mention string }{
		{"a line Prometheus cannot read", head + "relay_a{k=\"x\" 1\n", "cannot parse"},
		{"a family declared twice", head + "relay_a 1\n# HELP relay_b B.\n# TYPE relay_b gauge\nrelay_b 1\n# TYPE relay_a gauge\n", "cannot parse"},
		{"a series written twice", head + "relay_a{k=\"x\",j=\"y\"} 1\nrelay_a{j=\"y\",k=\"x\"} 2\n", "twice"},
		{"a room code in a label", head + "relay_a{code=\"K7QX2M\"} 1\n", "outside"},
		{"a label that is not a closed value", head + "relay_a{game=\"my game\"} 1\n", "outside"},
	} {
		if err := expositionProblem(bad.text); err == nil || !strings.Contains(err.Error(), bad.mention) {
			t.Errorf("the checker let %s through (problem: %v)", bad.why, err)
		}
	}
	// And it leaves the library's own labels to the library: an experimental
	// toolchain names itself with a space.
	library := "# HELP go_info Go.\n# TYPE go_info gauge\ngo_info{version=\"go1.27 X:jsonv2\"} 1\n"
	if err := expositionProblem(library); err != nil {
		t.Errorf("the checker refused a label of the client library's own: %v", err)
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
	// The start is the process's own, taken from the system: a restart shows
	// as a jump, and a scrape must not read as one.
	started := metricValue(t, s, "process_start_time_seconds")
	if started <= 0 || started > float64(time.Now().Unix()+1) {
		t.Errorf("start time %v is not a moment in the past", started)
	}
	if again := metricValue(t, s, "process_start_time_seconds"); again != started {
		t.Errorf("start time moved between scrapes: %v, then %v", started, again)
	}
}

func TestAValueOutsideAClosedSetCountsNowhere(t *testing.T) {
	// The client library's vectors make a new series for any value they are
	// handed. Every value the server counts under is folded into its closed set
	// long before, but a slip that let one through must not become a series
	// nobody declared: it counts nowhere, and the family keeps its shape.
	s := &server{hub: NewHub()}
	before := seriesValues(t, renderMetrics(s))
	s.hub.stats.refused("made_up")
	s.hub.stats.refusals.inc("full", "extra")
	s.hub.stats.pairingWaits.observe(1, "quick", "nobody")
	s.hub.stats.responded("favicon", http.StatusOK, false, time.Second)
	after := seriesValues(t, renderMetrics(s))
	for series, value := range after {
		if !strings.HasPrefix(series, "relay_") || strings.HasPrefix(series, "relay_build_info") {
			continue
		}
		if was, found := before[series]; !found || was != value {
			t.Errorf("%s went from %v (found %v) to %v on values outside its set", series, was, found, value)
		}
	}
	for series := range before {
		if _, found := after[series]; !found {
			t.Errorf("%s is gone from the scrape", series)
		}
	}
}

func TestStandardRuntimeAndProcessFiguresArePresent(t *testing.T) {
	// The machine's side comes from the client library's standard collectors,
	// under the names every Go dashboard reads. The runtime's figures are there
	// on every platform; the process's open descriptors come from /proc, and
	// Linux is where the image runs.
	s := &server{hub: NewHub()}
	values := seriesValues(t, renderMetrics(s))
	want := []string{
		"go_goroutines", "go_threads", "go_sched_latencies_seconds_count", "go_gc_pauses_seconds_count",
		"process_cpu_seconds_total", "process_start_time_seconds",
	}
	if runtime.GOOS == "linux" {
		want = append(want, "process_open_fds", "process_resident_memory_bytes")
	}
	for _, series := range want {
		if _, found := values[series]; !found {
			t.Errorf("no %s in the scrape on %s", series, runtime.GOOS)
		}
	}
	if got := values["go_goroutines"]; got < 1 {
		t.Errorf("go_goroutines is %v, expected at least this test's own goroutine", got)
	}
	if runtime.GOOS == "linux" && values["process_open_fds"] < 1 {
		t.Errorf("process_open_fds is %v, expected at least the descriptors the test runs with", values["process_open_fds"])
	}
	// The figures the server once worked out itself are gone for good: two
	// names for one number would split every dashboard between them.
	for series := range values {
		for _, gone := range []string{
			"relay_goroutines", "relay_heap_live_bytes", "relay_runtime_memory_bytes", "relay_gc_cycles_total",
			"relay_sched_latency_seconds", "relay_gc_pause_seconds", "relay_process_", "relay_start_time_seconds",
		} {
			if strings.HasPrefix(series, gone) {
				t.Errorf("%s is still in the scrape", series)
			}
		}
	}
}

func TestBuildVersionIsSanitized(t *testing.T) {
	// The version is stamped at build time from whatever the release was given,
	// and it becomes a label. A "v0.5.0" typed by hand, or a value with a quote
	// in it, must not reach the scrape as it was typed.
	// Not parallel: it rewrites the package's version for its duration.
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
			t.Errorf("version stamped as %q is labelled %q, expected %q", c.stamped, got, c.want)
		}
	}

	version = `0.5.0"} 1`
	s := &server{hub: NewHub()}
	text := renderMetrics(s)
	checkExposition(t, text)
	info := `relay_build_info{goversion="` + goVersionLabel(runtime.Version()) + `",version="unknown"}`
	if got, found := seriesValues(t, text)[info]; !found || got != 1 {
		t.Errorf("a stamped version with a quote reached the scrape; %s is %v (found %v):\n%s", info, got, found, text)
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
			t.Errorf("Go reported as %q is labelled %q, expected %q", c.reported, got, c.want)
		}
	}
}

// Every platform label the server may expose.
var testPlatforms = []string{
	"web", "web_android", "web_ios", "macos", "windows", "linux", "android", "ios", "unknown", "other",
}

func TestPlatformAndVersionLabelsAreClosed(t *testing.T) {
	// Both come from the client's hello, as the client typed them. A label
	// value is a series, so a stranger who could pick the values could grow the
	// scrape without bound; whatever is sent, only a closed set comes out.
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

// familySamples returns every sample of one family in a scrape, by the value of
// the one label it is split by, in the order the scrape carries them.
func familySamples(t *testing.T, text, family, labelName string) ([]string, map[string]float64) {
	t.Helper()
	samples, err := parseScrape(text)
	if err != nil {
		t.Fatalf("%v\n%s", err, text)
	}
	var order []string
	values := map[string]float64{}
	for _, s := range samples {
		if s.name != family {
			continue
		}
		if len(s.labels) != 1 || s.labels[0].GetName() != labelName {
			t.Fatalf("an unexpected sample of %s: %s", family, s.series)
		}
		order = append(order, s.labels[0].GetValue())
		values[s.labels[0].GetValue()] = s.value
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
		t.Errorf("live versions exposed as %v, expected %v", got, want)
	}
	// Which versions get a series is the server's choice; the order they are
	// written in is the client library's, which sorts a family's series by
	// their labels.
	wantOrder := []string{"1.0.1", "1.0.10", "1.0.2", "1.0.3", "1.0.4", "1.0.5", "1.0.6", "1.8.0", "1.9.0", "2.0.0", "other", "unknown"}
	if !slices.Equal(order, wantOrder) {
		t.Errorf("live versions exposed in the order %v, expected %v", order, wantOrder)
	}
	// The hub's rooms are a map, walked in a different order every time; the
	// scrape must not follow it.
	for range 20 {
		again, _ := familySamples(t, renderMetrics(s), "relay_players_by_version", "version")
		if !slices.Equal(again, order) {
			t.Fatalf("a second scrape of the same players came out as %v, then %v", order, again)
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
		t.Errorf("with nobody seated, live versions exposed as %v (%v), expected %v", got, order, want)
	}
	sit(client{platform: "web", version: "0.5.0"}, 1)
	_, got = familySamples(t, renderMetrics(s), "relay_players_by_version", "version")
	if want := map[string]float64{"0.5.0": 1, "other": 0, "unknown": 0}; !maps.Equal(got, want) {
		t.Errorf("one player seated after everyone left exposed as %v, expected %v", got, want)
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
		if err := expositionProblem(renderMetrics(s)); err != nil {
			stop.Store(true)
			wg.Wait()
			t.Fatalf("a scrape while players came and went: %v", err)
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
			t.Errorf("%q, a room's code or its game, is in the scrape:\n%s", secret, text)
		}
	}
	// The seed's digits may turn up by chance in a memory figure, so they are
	// looked for only where a room's own number could have been put: in a label,
	// or as a value.
	digits := strconv.FormatUint(seed, 10)
	lowered := []string{strings.ToLower(code), strings.ToLower(quickCode)}
	samples, err := parseScrape(text)
	if err != nil {
		t.Fatalf("%v\n%s", err, text)
	}
	for _, sample := range samples {
		if sample.value == seed {
			t.Errorf("a series carries the seed as its value: %s", sample.series)
		}
		for _, l := range sample.labels {
			if strings.Contains(l.GetValue(), digits) || slices.Contains(lowered, l.GetValue()) {
				t.Errorf("a label carries a room's seed or code: %s", sample.series)
			}
		}
	}
}

// sameFigure compares two figures a scrape carries. A sum of several
// observations is added up in floating point, in whatever order they came, so
// 0.95 + 0.8 + 0.8 may miss 2.55 by the last bit; counts and bounds compare
// exactly all the same.
func sameFigure(got, want float64) bool {
	return got == want || math.Abs(got-want) <= 1e-9*math.Max(math.Abs(got), math.Abs(want))
}

// expectSeries checks several exact series in one scrape, in a steady order so
// that two failing runs report the same way.
func expectSeries(t *testing.T, s *server, want map[string]float64) {
	t.Helper()
	values := seriesValues(t, renderMetrics(s))
	for _, series := range slices.Sorted(maps.Keys(want)) {
		got, found := values[series]
		if !found {
			t.Errorf("no series %s in the scrape", series)
			continue
		}
		if !sameFigure(got, want[series]) {
			t.Errorf("%s is %v, expected %v", series, got, want[series])
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
	firstValues := seriesValues(t, first)
	for _, series := range zero {
		if got, found := firstValues[series]; !found || got != 0 {
			t.Errorf("before any room was opened %s is %v (found %v)", series, got, found)
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
