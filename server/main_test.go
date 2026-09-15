package main

// The metrics listener never shares the public one: these tests exercise the
// handler on its own, and check the public routes never grow a /metrics of
// their own.

import (
	"compress/gzip"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/common/expfmt"
)

func TestMetricsHandlerAnswersOnlyGetMetrics(t *testing.T) {
	s := &server{hub: NewHub()}
	handler := s.metricsHandler("")

	for _, path := range []string{"/", "/debug/pprof/", "/health"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("GET %s: got %d instead of 404", path, rec.Code)
		}
	}

	req := httptest.NewRequest(http.MethodPost, "/metrics", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /metrics: got %d instead of 405", rec.Code)
	}
	if got := rec.Header().Get("Allow"); got != http.MethodGet {
		t.Fatalf("Allow header %q instead of GET", got)
	}
}

func TestMetricsTokenIsRequiredWhenSet(t *testing.T) {
	s := &server{hub: NewHub()}
	handler := s.metricsHandler("0123456789abcdef0123")

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no token: got %d instead of 401", rec.Code)
	}
	if got := rec.Header().Get("WWW-Authenticate"); got != "Bearer" {
		t.Fatalf("WWW-Authenticate %q instead of Bearer", got)
	}

	req = httptest.NewRequest(http.MethodGet, "/metrics", nil)
	req.Header.Set("Authorization", "Bearer wrong-token-entirely-x")
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong token: got %d instead of 401", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/metrics", nil)
	req.Header.Set("Authorization", "Bearer 0123456789abcdef0123")
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("correct token: got %d instead of 200", rec.Code)
	}
}

func TestMetricsContentTypeIsPrometheusText(t *testing.T) {
	// The type is whatever the client library negotiates, and the parameters
	// it adds are its own business; what matters is that a scraper asking for
	// nothing in particular is told it has the text format, and that the body
	// is exactly that as Prometheus reads it.
	s := &server{hub: NewHub()}
	handler := s.metricsHandler("")

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d instead of 200", rec.Code)
	}
	if format := expfmt.ResponseFormat(rec.Header()); format.FormatType() != expfmt.TypeTextPlain {
		t.Fatalf("content type %q is not Prometheus's text format", rec.Header().Get("Content-Type"))
	}
	checkExposition(t, rec.Body.String())

	// A scraper that accepts gzip, as Prometheus does, gets the same scrape
	// packed.
	req = httptest.NewRequest(http.MethodGet, "/metrics", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("a scraper accepting gzip got %d with encoding %q", rec.Code, rec.Header().Get("Content-Encoding"))
	}
	unpacked, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatalf("the packed scrape is not gzip: %v", err)
	}
	body, err := io.ReadAll(unpacked)
	if err != nil {
		t.Fatalf("the packed scrape does not unpack: %v", err)
	}
	checkExposition(t, string(body))
}

func TestMetricsAreNotServedOnThePublicPort(t *testing.T) {
	// A relay with no game files: routes("").
	relay := &server{hub: NewHub()}
	addr, stop := serve(t, relay)
	defer stop()
	assertPublicPortHasNoMetrics(t, addr)

	// A relay that also serves the game files: routes(dir). The file server
	// would answer 404 for /metrics on its own — this still checks it, since
	// a later change to the file server's fallback could paper over the gap.
	addr, stop = startServerWithStatic(t, writeStatic(t))
	defer stop()
	assertPublicPortHasNoMetrics(t, addr)
}

func assertPublicPortHasNoMetrics(t *testing.T, addr string) {
	t.Helper()
	resp, err := http.Get("http://" + addr + "/metrics")
	if err != nil {
		t.Fatalf("GET /metrics on the public port: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("the public port answered /metrics with %d instead of 404", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("reading the body: %v", err)
	}
	if strings.Contains(string(body), "relay_build_info") {
		t.Fatal("the public port's 404 body carries the exposition")
	}
}

// blockingWriter behaves like httptest.NewRecorder, except its writes
// signal writing and then wait for release — standing in for a real client
// that has stopped reading its response.
type blockingWriter struct {
	*httptest.ResponseRecorder
	started sync.Once
	writing chan struct{}
	release chan struct{}
}

func (w *blockingWriter) Write(p []byte) (int, error) {
	w.started.Do(func() { close(w.writing) })
	<-w.release
	return w.ResponseRecorder.Write(p)
}

// TestASlowScrapeReaderHoldsUpNoOtherScrape pins down what a review once
// found: a scrape stuck writing to a reader that stopped reading must hold
// nothing another scrape needs, or every other scrape queues behind it for up
// to WriteTimeout. A real TCP client that stops reading would prove the same
// thing, but only once its side of the connection fills the kernel's send
// buffer — a size and timing that vary by machine and are not something a
// test should depend on. Blocking inside Write itself reproduces the same
// shape deterministically: the first request is genuinely stuck in its
// network write when the second one is sent, so the second can only finish if
// the first holds nothing it waits for.
func TestASlowScrapeReaderHoldsUpNoOtherScrape(t *testing.T) {
	s := &server{hub: NewHub()}
	handler := s.metricsHandler("")

	writing := make(chan struct{})
	release := make(chan struct{})
	stuck := &blockingWriter{ResponseRecorder: httptest.NewRecorder(), writing: writing, release: release}

	firstDone := make(chan struct{})
	go func() {
		handler.ServeHTTP(stuck, httptest.NewRequest(http.MethodGet, "/metrics", nil))
		close(firstDone)
	}()

	select {
	case <-writing:
	case <-time.After(2 * time.Second):
		t.Fatal("the first scrape never reached its network write")
	}

	second := make(chan struct{})
	go func() {
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/metrics", nil))
		close(second)
	}()

	select {
	case <-second:
	case <-time.After(2 * time.Second):
		t.Fatal("a second scrape waited for the first one's stuck network write")
	}

	close(release)
	select {
	case <-firstDone:
	case <-time.After(2 * time.Second):
		t.Fatal("the first scrape did not finish after its write was released")
	}
}

// brokenCollector stands in for a collector that fails as it is gathered: a
// standard one clashing with a name after a Go upgrade, say. Its error names a
// series the way the client library's own errors do, labels and all.
type brokenCollector struct{}

var brokenDesc = prometheus.NewDesc("relay_example_broken", "A collector that fails.", []string{"platform"}, nil)

const brokenMarker = "zqbrokenmarker"

func (brokenCollector) Describe(descs chan<- *prometheus.Desc) { descs <- brokenDesc }

func (brokenCollector) Collect(metrics chan<- prometheus.Metric) {
	metrics <- prometheus.NewInvalidMetric(brokenDesc, errors.New(brokenMarker+` label:{name:"platform" value:"web_ios"}`))
}

func TestABrokenCollectorDoesNotBlankTheScrape(t *testing.T) {
	// One collector failing is one family missing, not a dashboard gone blank:
	// everything else that was gathered still goes out. Why it failed is not
	// sent to the scraper, and the log hears only that something was left out —
	// the library's message names series with their labels, and the log is kept
	// by whoever runs the server for as long as they like.
	// Not parallel: it takes over the package's log for its duration.
	captured := &lockedBuffer{}
	kept := log.Writer()
	log.SetOutput(captured)
	defer log.SetOutput(kept)

	s := &server{hub: NewHub(), maxConns: 7}
	s.hub.stats.registry.MustRegister(brokenCollector{})
	s.hub.stats.relayed(6)
	rec := httptest.NewRecorder()
	s.metricsHandler("").ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("a scrape with one broken collector was answered %d:\n%s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	checkExposition(t, body)
	values := seriesValues(t, body)
	for series, want := range map[string]float64{
		"relay_connections_limit":  7,
		"relay_packet_bytes_total": 6,
	} {
		if got, found := values[series]; !found || got != want {
			t.Errorf("%s is %v (found %v) beside a broken collector, expected %v", series, got, found, want)
		}
	}
	if _, found := values["go_goroutines"]; !found {
		t.Error("the standard figures are gone beside a broken collector")
	}
	if strings.Contains(body, brokenMarker) || strings.Contains(body, "relay_example_broken") {
		t.Errorf("the scrape carries the broken collector's family or its error:\n%s", body)
	}

	logged := captured.String()
	if !strings.Contains(logged, "metrics") {
		t.Errorf("nothing in the log says a scrape left something out: %q", logged)
	}
	if strings.Contains(logged, brokenMarker) || strings.Contains(logged, "web_ios") {
		t.Errorf("the log carries the library's error, labels and all: %q", logged)
	}
}

func TestAFloodOfScrapesIsTurnedAway(t *testing.T) {
	// Every scrape gathers everything afresh, so a flood of them would each
	// pay for a whole gather at once. Past four at a time the rest are turned
	// away at the door. A room held locked keeps the gathers that got in from
	// finishing, so exactly as many as the limit are still waiting when the
	// others have been answered, whatever order they arrived in.
	s := &server{hub: NewHub()}
	room, err := s.hub.Create("tanks", 1)
	if err != nil {
		t.Fatalf("no room: %v", err)
	}
	handler := s.metricsHandler("")

	room.mu.Lock()
	const scrapes = 8
	codes := make(chan int, scrapes)
	for range scrapes {
		go func() {
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
			codes <- rec.Code
		}()
	}
	for range scrapes - 4 {
		select {
		case code := <-codes:
			if code != http.StatusServiceUnavailable {
				room.mu.Unlock()
				t.Fatalf("a scrape past the four in flight was answered %d instead of 503", code)
			}
		case <-time.After(2 * time.Second):
			room.mu.Unlock()
			t.Fatal("the scrapes past the four in flight were not turned away")
		}
	}
	room.mu.Unlock()
	for range 4 {
		select {
		case code := <-codes:
			if code != http.StatusOK {
				t.Fatalf("a scrape that got in was answered %d once the room was free", code)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("the scrapes in flight never finished")
		}
	}
}

func TestBoundPortsCollide(t *testing.T) {
	// Same port, different hosts: still the same socket on this machine.
	loopback := &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 27014}
	everyInterface := &net.TCPAddr{IP: net.ParseIP("0.0.0.0"), Port: 27014}
	if !boundPortsCollide(loopback, everyInterface) {
		t.Fatal("the same port on different hosts was not flagged as a collision")
	}

	distinct := &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 27115}
	if boundPortsCollide(loopback, distinct) {
		t.Fatal("two distinct ports were flagged as a collision")
	}

	// A non-TCP address never collides: there is nothing to compare a port
	// against.
	if boundPortsCollide(loopback, &net.UnixAddr{Name: "/tmp/x"}) {
		t.Fatal("a non-TCP address was flagged as a collision")
	}
}
