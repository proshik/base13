package main

// Process and Go runtime figures: signs of the machine, not of the game.
//
// "Now" figures in metrics.go are read at scrape time because a second copy
// invites drift; these are the same idea one layer down — CPU, memory, open
// descriptors and the scheduler's own bookkeeping are never counted as the
// server goes, only read when a scrape asks. That also keeps them off the
// hot path: nothing here takes a lock or runs anywhere but a scrape.

import (
	"math"
	"os"
	"runtime/metrics"
	"strconv"
	"strings"
)

// procRoot is where the real files live. A test points readers at a fixture
// directory instead, so the "present" half of the process tests runs on
// macOS too.
const procRoot = "/proc"

// clockTicksPerSecond is CLK_TCK, the unit /proc/self/stat counts CPU time
// in. Linux lets a kernel build change it, but every image this server runs
// in is built the ordinary way, where it is 100 — and there is no portable
// way to ask the kernel, short of calling into libc.
const clockTicksPerSecond = 100

// parseStat reads utime and stime, in clock ticks, from the text of
// /proc/self/stat. Field 2, the command name, is free text in parentheses
// and can itself contain spaces or even ")" — so the only safe anchor is the
// LAST ")" on the line. Everything after it is fixed-format, space-separated
// fields starting at field 3 (state); utime is field 14 and stime is field
// 15, which are the 12th and 13th fields after the name (1-indexed).
func parseStat(text string) (utimeTicks, stimeTicks uint64, ok bool) {
	i := strings.LastIndexByte(text, ')')
	if i < 0 {
		return 0, 0, false
	}
	fields := strings.Fields(text[i+1:])
	const utimeIndex, stimeIndex = 11, 12 // 0-indexed into fields, which starts at field 3
	if len(fields) <= stimeIndex {
		return 0, 0, false
	}
	utime, errU := strconv.ParseUint(fields[utimeIndex], 10, 64)
	stime, errS := strconv.ParseUint(fields[stimeIndex], 10, 64)
	if errU != nil || errS != nil {
		return 0, 0, false
	}
	return utime, stime, true
}

// parseStatm reads the resident field, in pages, from the text of
// /proc/self/statm: "size resident shared text lib data dt". Scaling by the
// page size is the caller's job — os.Getpagesize() is a syscall, not
// something a pure parser should reach for.
func parseStatm(text string) (residentPages uint64, ok bool) {
	fields := strings.Fields(text)
	if len(fields) < 2 {
		return 0, false
	}
	resident, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0, false
	}
	return resident, true
}

// readStat and its siblings below take a root so a test can point them at a
// fixture directory; the server itself always passes procRoot.

func readStat(root string) (utimeTicks, stimeTicks uint64, ok bool) {
	data, err := os.ReadFile(root + "/self/stat")
	if err != nil {
		return 0, 0, false
	}
	return parseStat(string(data))
}

func readStatm(root string) (residentPages uint64, ok bool) {
	data, err := os.ReadFile(root + "/self/statm")
	if err != nil {
		return 0, false
	}
	return parseStatm(string(data))
}

// countOpenFDs counts descriptors open right now by listing /proc/self/fd.
// Opening that directory borrows one descriptor for the length of the read
// and releases it before this returns — which is fine, since "open right
// now" is only ever true as of the moment of the scrape, and the read itself
// is part of that moment.
func countOpenFDs(root string) (int, bool) {
	entries, err := os.ReadDir(root + "/self/fd")
	if err != nil {
		return 0, false
	}
	return len(entries), true
}

// writeProcessFamilies renders relay_process_*. Their source is Linux's
// /proc, which is not there on a developer's Mac and would not be there in
// any container that does not mount it — so a missing file is not an error,
// it just means the family is left out of the render rather than guessed at.
// No process_max_fds: Go raises the soft descriptor limit to the hard one
// at startup, and the connection cap in server.go is hit long before a
// descriptor limit would be.
func writeProcessFamilies(e *exposition, root string) {
	if utimeTicks, stimeTicks, ok := readStat(root); ok {
		cpuSeconds := float64(utimeTicks+stimeTicks) / clockTicksPerSecond
		e.family("relay_process_cpu_seconds_total", "counter",
			"Total user and system CPU time spent, in seconds. Assumes 100 clock ticks per second (CLK_TCK), true of every Linux this image runs on.")
		e.sample("relay_process_cpu_seconds_total", nil, cpuSeconds)
	}
	if residentPages, ok := readStatm(root); ok {
		residentBytes := residentPages * uint64(os.Getpagesize())
		e.gauge("relay_process_resident_memory_bytes", "Resident set size, in bytes.", float64(residentBytes))
	}
	if n, ok := countOpenFDs(root); ok {
		e.gauge("relay_process_open_fds", "File descriptors open right now, this read among them.", float64(n))
	}
}

// schedLatencyBounds and gcPauseBounds are our own bucket edges for the two
// runtime histograms below — chosen for this dashboard, not inherited from
// the runtime, whose own edges are far finer and not something we can rely
// on staying the same across Go versions.
var (
	schedLatencyBounds = []float64{0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1}
	gcPauseBounds      = []float64{0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05}
)

// writeRuntimeMetrics renders relay_goroutines, relay_heap_live_bytes,
// relay_runtime_memory_bytes, relay_gc_cycles_total, relay_sched_latency_seconds
// and relay_gc_pause_seconds from runtime/metrics — unlike /proc, always
// present, on every platform these tests run on.
func writeRuntimeMetrics(e *exposition) {
	const (
		goroutines  = "/sched/goroutines:goroutines"
		heapLive    = "/gc/heap/live:bytes"
		runtimeMem  = "/memory/classes/total:bytes"
		gcCycles    = "/gc/cycles/total:gc-cycles"
		schedLatent = "/sched/latencies:seconds"
		gcPause     = "/sched/pauses/total/gc:seconds"
	)
	names := []string{goroutines, heapLive, runtimeMem, gcCycles, schedLatent, gcPause}
	samples := make([]metrics.Sample, len(names))
	for i, n := range names {
		samples[i].Name = n
	}
	metrics.Read(samples)

	for i, sample := range samples {
		switch sample.Value.Kind() {
		case metrics.KindBad:
			// Not supported by the toolchain that built this binary; skip
			// rather than guess at a value that was never read.
			continue
		case metrics.KindUint64:
			v := float64(sample.Value.Uint64())
			switch names[i] {
			case goroutines:
				e.gauge("relay_goroutines", "Goroutines alive right now.", v)
			case heapLive:
				e.gauge("relay_heap_live_bytes", "Live heap bytes as of the last garbage collection.", v)
			case runtimeMem:
				e.gauge("relay_runtime_memory_bytes", "Memory the Go runtime has reserved for everything: heap, stacks, metadata.", v)
			case gcCycles:
				e.counter("relay_gc_cycles_total", "Garbage collections completed since the process started.", sample.Value.Uint64())
			}
		case metrics.KindFloat64Histogram:
			switch names[i] {
			case schedLatent:
				writeRebucketed(e, "relay_sched_latency_seconds",
					"How long a goroutine waited runnable before it actually ran, rebucketed onto our own bounds from the runtime's own histogram; a growing tail means the process is not getting the CPU it asked for. _sum is an estimate from bucket midpoints.",
					sample.Value.Float64Histogram(), schedLatencyBounds)
			case gcPause:
				writeRebucketed(e, "relay_gc_pause_seconds",
					"Stop-the-world time the garbage collector charged the whole process, rebucketed onto our own bounds from the runtime's own histogram. _sum is an estimate from bucket midpoints.",
					sample.Value.Float64Histogram(), gcPauseBounds)
			}
		}
	}
}

func writeRebucketed(e *exposition, name, help string, h *metrics.Float64Histogram, bounds []float64) {
	counts, total, sum := rebucket(h, bounds)
	e.histogramFromCumulative(name, help, bounds, counts, total, sum)
}

// rebucket maps a runtime/metrics histogram — whose bucket edges are the
// runtime's own and not ours to choose, and finer than anything a dashboard
// needs — onto our own ascending bounds. The result is already cumulative,
// the shape the exposition format wants: counts[i] is how many observations
// landed at bounds[i] or below, and total is the +Inf bucket.
//
// A runtime bucket is placed at the smallest of our bounds whose upper edge
// is greater than or equal to its own upper edge; one that straddles a bound
// — its own range spans past it — is deferred to the next bound up instead
// of being credited to the bound it straddles. That can only push an
// observation to a higher reported latency than it truly was, never hide a
// slow one as a fast one.
//
// The runtime histogram does not carry a sum, so this estimates one: each
// bucket contributes its count times its midpoint. The extreme buckets have
// an infinite edge with no midpoint, so they use their one finite edge
// instead — an underestimate for the top bucket, but the alternative is no
// number at all.
func rebucket(h *metrics.Float64Histogram, bounds []float64) (counts []uint64, total uint64, sum float64) {
	counts = make([]uint64, len(bounds))
	for i, count := range h.Counts {
		lower, upper := h.Buckets[i], h.Buckets[i+1]
		total += count
		sum += float64(count) * midpoint(lower, upper)
		for b, bound := range bounds {
			if upper <= bound {
				counts[b] += count
				break
			}
		}
	}
	for i := 1; i < len(counts); i++ {
		counts[i] += counts[i-1]
	}
	return counts, total, sum
}

// midpoint estimates one runtime bucket's typical value for the sum
// estimate in rebucket. An infinite edge has no mean to split, so the
// finite edge stands in for it.
func midpoint(lower, upper float64) float64 {
	switch {
	case math.IsInf(lower, -1):
		return upper
	case math.IsInf(upper, 1):
		return lower
	default:
		return (lower + upper) / 2
	}
}
