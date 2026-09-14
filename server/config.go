package main

// Startup configuration.
//
// Read from the environment rather than from a file or baked into the build:
// the image is the same for every machine, and only the environment differs.
// Flags sit on top — handy for bringing up a second copy alongside without
// touching the environment.

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Deliberately not 8080: that one is taken on almost any working machine by a
// debug server or a port-forward, and the client would silently end up talking
// to somebody else's service. Connecting to the wrong place is worse than not
// connecting at all — the game just freezes with no explanation.
const defaultAddr = ":27014"

type config struct {
	Addr     string
	Static   string
	CertFile string
	KeyFile  string
	MaxRooms int
	// Empty disables the metrics listener outright — the common case, and the
	// default for anyone who has not asked for it.
	MetricsAddr string
	// Optional, and only from the environment: a flag would put it in the
	// process's own argument list, which "ps" shows to anyone on the machine.
	MetricsToken string
}

// secure reports whether to serve over TLS. Both halves or neither: a key
// without a certificate is a typo rather than a setting, and quietly coming up
// in the clear would do the opposite of what was asked.
func secure(c config) bool {
	return c.CertFile != "" && c.KeyFile != ""
}

// settings assembles the configuration: a flag beats an environment variable,
// a variable beats the default. `given` holds only the flags a human set
// explicitly; flag defaults must stay out, or they would always override the
// environment.
func settings(given map[string]string, env func(string) string) config {
	c := config{Addr: defaultAddr, MaxRooms: defaultMaxRooms}

	// PORT is the common convention across hosting platforms; ADDR can do what
	// PORT cannot: bind to a single interface.
	if port := env("PORT"); port != "" {
		c.Addr = normalizeAddr(port)
	}
	if addr := env("ADDR"); addr != "" {
		c.Addr = normalizeAddr(addr)
	}
	c.Static = env("STATIC_DIR")
	c.CertFile = env("TLS_CERT")
	c.KeyFile = env("TLS_KEY")
	// The ceiling is memory, and memory is the machine's, not the image's.
	if rooms := positive(env("MAX_ROOMS")); rooms > 0 {
		c.MaxRooms = rooms
	}
	if addr := env("METRICS_ADDR"); addr != "" {
		c.MetricsAddr = normalizeAddr(addr)
	}
	c.MetricsToken = env("METRICS_TOKEN")

	if addr, ok := given["addr"]; ok && addr != "" {
		c.Addr = normalizeAddr(addr)
	}
	if static, ok := given["static"]; ok {
		c.Static = static
	}
	if cert, ok := given["tls-cert"]; ok {
		c.CertFile = cert
	}
	if key, ok := given["tls-key"]; ok {
		c.KeyFile = key
	}
	if rooms := positive(given["max-rooms"]); rooms > 0 {
		c.MaxRooms = rooms
	}
	if addr, ok := given["metrics-addr"]; ok && addr != "" {
		c.MetricsAddr = normalizeAddr(addr)
	}
	return c
}

// metricsProblem reports why the metrics listener must not start, or nil when
// it may. Pure and cheap on purpose: main calls it before opening a socket,
// so a bad setting stops the process with a clear message instead of quietly
// listening somewhere unsafe — or, worse, exactly where the public server
// already does.
func metricsProblem(c config) error {
	if c.MetricsAddr == "" {
		return nil
	}
	_, metricsPort, err := net.SplitHostPort(normalizeAddr(c.MetricsAddr))
	if err != nil {
		return fmt.Errorf("metrics address %q: %w", c.MetricsAddr, err)
	}
	_, publicPort, err := net.SplitHostPort(normalizeAddr(c.Addr))
	if err != nil {
		return fmt.Errorf("public address %q: %w", c.Addr, err)
	}
	// Hosts are ignored on purpose: "127.0.0.1:27014" and ":27014" reach the
	// same socket on the machine that runs them, and a proxy dialing loopback
	// would land on metrics instead of the game.
	if metricsPort == publicPort {
		return fmt.Errorf("metrics port %s is the public port; metrics must listen elsewhere", metricsPort)
	}
	if c.MetricsToken != "" && len(c.MetricsToken) < 16 {
		return fmt.Errorf("metrics token is %d bytes, shorter than the 16 required", len(c.MetricsToken))
	}
	return nil
}

// normalizeAddr accepts "27014", ":27014" and "127.0.0.1:27014" alike:
// a human writes a bare number meaning "listen on this port".
func normalizeAddr(value string) string {
	if !strings.Contains(value, ":") {
		return ":" + value
	}
	return value
}

// positive reads a count. Zero, a negative or garbage reads as "not given": a
// room limit of zero would refuse everyone, which is a typo rather than a
// setting.
func positive(value string) int {
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || n <= 0 {
		return 0
	}
	return n
}
