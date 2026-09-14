package main

// The metrics listener never shares the public one: these tests exercise the
// handler on its own, and check the public routes never grow a /metrics of
// their own.

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
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
	s := &server{hub: NewHub()}
	handler := s.metricsHandler("")

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d instead of 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "text/plain; version=0.0.4; charset=utf-8" {
		t.Fatalf("content type %q", got)
	}
	if got := rec.Header().Get("Content-Length"); got != strconv.Itoa(rec.Body.Len()) {
		t.Fatalf("content length %q does not match the body's %d bytes", got, rec.Body.Len())
	}
	checkExposition(t, rec.Body.String())
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

// blockingWriter behaves like httptest.NewRecorder, except its first Write
// signals writing and then waits for release — standing in for a real
// client that has stopped reading its response.
type blockingWriter struct {
	*httptest.ResponseRecorder
	writing chan struct{}
	release chan struct{}
}

func (w *blockingWriter) Write(p []byte) (int, error) {
	close(w.writing)
	<-w.release
	return w.ResponseRecorder.Write(p)
}

// TestMetricsRenderLockIsReleasedBeforeTheNetworkWrite pins down the exact
// bug the review found: a slow reader must not hold metricsMu, or every other
// scrape queues behind it for up to WriteTimeout. A real TCP client that
// stops reading would prove the same thing, but only once its side of the
// connection fills the kernel's send buffer — a size and timing that vary by
// machine and are not something a test should depend on. Blocking inside
// Write itself reproduces the same shape deterministically: the first
// request is genuinely stuck in its network write when the second one is
// sent, so the second can only finish if the lock was already released.
func TestMetricsRenderLockIsReleasedBeforeTheNetworkWrite(t *testing.T) {
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
