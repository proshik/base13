package main

import (
	"bytes"
	"math"
	"os"
	"runtime/metrics"
	"slices"
	"strconv"
	"testing"
)

func TestStatParsingSurvivesSpacesInTheName(t *testing.T) {
	// The command name is field 2, in parentheses, and is whatever the process
	// named itself — spaces and even ")" are legal there. The only safe anchor
	// is the LAST ")" on the line; everything before it is not ours to split on
	// a space.
	line := "5417 (code helper (renderer)) S 1 5417 5417 0 -1 4194560 205 0 3 0 12 34 0 0 20 0 15 0 452605"
	utime, stime, ok := parseStat(line)
	if !ok {
		t.Fatal("parseStat did not accept a well-formed line")
	}
	if utime != 12 || stime != 34 {
		t.Errorf("utime=%d stime=%d, expected 12 and 34", utime, stime)
	}

	if _, _, ok := parseStat("nonsense with no closing paren"); ok {
		t.Error("a line with no ')' should not parse")
	}
	if _, _, ok := parseStat("1 (short) S 1 2"); ok {
		t.Error("a line with too few fields after the name should not parse")
	}
}

func TestStatmGivesResidentBytes(t *testing.T) {
	// size resident shared text lib data dt, in pages; the second field is
	// resident, and it is the caller's job to scale it by the page size.
	resident, ok := parseStatm("1000 250 100 5 0 300 0\n")
	if !ok || resident != 250 {
		t.Fatalf("resident=%d ok=%v, expected 250, true", resident, ok)
	}
	if _, ok := parseStatm("only-one-field"); ok {
		t.Error("a line with one field should not parse")
	}
}

func TestRuntimeFamiliesArePresent(t *testing.T) {
	// These come from runtime/metrics, not from /proc, so they render on every
	// platform the tests run on, macOS included.
	s := &server{hub: NewHub()}
	text := renderMetrics(s)
	checkExposition(t, text)

	if got := metricValue(t, s, "relay_goroutines"); got < 1 {
		t.Errorf("relay_goroutines is %v, expected at least this test's own goroutine", got)
	}
	if got := metricValue(t, s, "relay_runtime_memory_bytes"); got <= 0 {
		t.Errorf("relay_runtime_memory_bytes is %v, expected the runtime to have reserved something", got)
	}
	if got := metricValue(t, s, "relay_gc_cycles_total"); got < 0 {
		t.Errorf("relay_gc_cycles_total is %v, expected a non-negative count", got)
	}
	for _, series := range []string{
		"relay_heap_live_bytes",
		`relay_sched_latency_seconds_bucket{le="0.0001"}`,
		`relay_sched_latency_seconds_bucket{le="+Inf"}`,
		"relay_sched_latency_seconds_sum",
		"relay_sched_latency_seconds_count",
		`relay_gc_pause_seconds_bucket{le="0.0001"}`,
		`relay_gc_pause_seconds_bucket{le="+Inf"}`,
		"relay_gc_pause_seconds_sum",
		"relay_gc_pause_seconds_count",
	} {
		if _, found := seriesValue(text, series); !found {
			t.Errorf("missing series %s in:\n%s", series, text)
		}
	}
}

func TestProcessFamiliesOnlyWhereProcExists(t *testing.T) {
	// A fixture root stands in for /proc so the "present" half of this test
	// runs on macOS too; the "absent" half is a directory with nothing in it,
	// which is what /proc looks like there for real.
	dir := t.TempDir()
	if err := os.MkdirAll(dir+"/self/fd", 0o755); err != nil {
		t.Fatal(err)
	}
	stat := "1 (init) S 0 1 1 0 -1 4194560 0 0 0 0 25 15 0 0 20 0 1 0 100 0 0 18446744073709551615\n"
	if err := os.WriteFile(dir+"/self/stat", []byte(stat), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir+"/self/statm", []byte("100 40 10 5 0 50 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir+"/self/fd/0", nil, 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	e := newExposition(&out)
	writeProcessFamilies(e, dir)
	e.flush()
	text := out.String()
	checkExposition(t, text)

	if got, found := seriesValue(text, "relay_process_cpu_seconds_total"); !found || got != "0.4" {
		t.Errorf("relay_process_cpu_seconds_total is %q (found %v), expected \"0.4\" (25+15 ticks at 100/s)", got, found)
	}
	wantResident := strconv.FormatFloat(float64(40*os.Getpagesize()), 'f', -1, 64)
	if got, found := seriesValue(text, "relay_process_resident_memory_bytes"); !found || got != wantResident {
		t.Errorf("relay_process_resident_memory_bytes is %q (found %v), expected %q", got, found, wantResident)
	}
	if got, found := seriesValue(text, "relay_process_open_fds"); !found || got != "1" {
		t.Errorf("relay_process_open_fds is %q (found %v), expected \"1\"", got, found)
	}

	var absent bytes.Buffer
	ae := newExposition(&absent)
	writeProcessFamilies(ae, t.TempDir())
	ae.flush()
	if got := absent.String(); got != "" {
		t.Errorf("families rendered with no /proc under root: %s", got)
	}

	// And the real server, on whatever platform the test runs on, must not
	// break the render either way.
	s := &server{hub: NewHub()}
	checkExposition(t, renderMetrics(s))
}

func TestRebucketIsCumulativeAndKeepsTheTotal(t *testing.T) {
	// A synthetic histogram shaped like the real runtime/metrics ones: ±Inf at
	// the two extremes, and a middle bucket that straddles one of our own
	// bounds (0.02 lies inside (0.0003, 0.02] here, and so does our bound at
	// 0.01) — it must be counted at the next bound up, never at 0.01, or the
	// dashboard would understate how bad the stall was.
	h := &metrics.Float64Histogram{
		Counts:  []uint64{10, 20, 30},
		Buckets: []float64{math.Inf(-1), 0.0003, 0.02, math.Inf(1)},
	}
	bounds := []float64{0.0001, 0.0005, 0.01, 0.1}
	counts, total, sum := rebucket(h, bounds)

	wantCounts := []uint64{0, 10, 10, 30}
	if !slices.Equal(counts, wantCounts) {
		t.Errorf("counts = %v, expected %v", counts, wantCounts)
	}
	if total != 60 {
		t.Errorf("total = %d, expected 60", total)
	}
	if math.Abs(sum-0.806) > 1e-9 {
		t.Errorf("sum = %v, expected about 0.806", sum)
	}

	// Rendered, it must read exactly like any other histogram: cumulative
	// buckets, a +Inf bucket equal to _count, and both _sum and _count.
	var out bytes.Buffer
	e := newExposition(&out)
	e.histogramFromCumulative("relay_example_rebucketed_seconds", "An example.", bounds, counts, total, sum)
	e.flush()
	checkExposition(t, out.String())
}
