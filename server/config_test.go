package main

import "testing"

// Configuration comes from the environment: the image is the same for every
// machine, and only the variables differ, not a rebuild.

func env(pairs map[string]string) func(string) string {
	return func(name string) string { return pairs[name] }
}

func TestDefaultsWhenNothingIsSet(t *testing.T) {
	got := settings(nil, env(nil))
	if got.Addr != defaultAddr {
		t.Fatalf("default address %q instead of %q", got.Addr, defaultAddr)
	}
	if got.Static != "" {
		t.Fatalf("with no folder given the server stays a relay, got %q", got.Static)
	}
}

func TestPortFromEnvironment(t *testing.T) {
	// PORT is the common convention: almost every hosting platform sets it.
	got := settings(nil, env(map[string]string{"PORT": "8123"}))
	if got.Addr != ":8123" {
		t.Fatalf("address %q instead of :8123", got.Addr)
	}
}

func TestAddrBeatsPort(t *testing.T) {
	// ADDR can do what PORT cannot: bind to a single interface.
	got := settings(nil, env(map[string]string{
		"PORT": "8123",
		"ADDR": "127.0.0.1:9000",
	}))
	if got.Addr != "127.0.0.1:9000" {
		t.Fatalf("address %q instead of 127.0.0.1:9000", got.Addr)
	}
}

func TestStaticFromEnvironment(t *testing.T) {
	got := settings(nil, env(map[string]string{"STATIC_DIR": "/web"}))
	if got.Static != "/web" {
		t.Fatalf("folder %q instead of /web", got.Static)
	}
}

func TestFlagsBeatEnvironment(t *testing.T) {
	// Variables define the ordinary run, a flag a one-off: bring up a second
	// copy on another port without touching the environment.
	given := map[string]string{"addr": "127.0.0.1:7000", "static": "./web"}
	got := settings(given, env(map[string]string{
		"ADDR":       "0.0.0.0:9000",
		"STATIC_DIR": "/web",
	}))
	if got.Addr != "127.0.0.1:7000" {
		t.Fatalf("address %q: a flag must beat a variable", got.Addr)
	}
	if got.Static != "./web" {
		t.Fatalf("folder %q: a flag must beat a variable", got.Static)
	}
}

func TestBarePortNumberIsAccepted(t *testing.T) {
	// A human writes "27014" meaning "listen on this port".
	got := settings(map[string]string{"addr": "27014"}, env(nil))
	if got.Addr != ":27014" {
		t.Fatalf("address %q instead of :27014", got.Addr)
	}
}

func TestRoomLimitComesFromTheEnvironment(t *testing.T) {
	// The ceiling is memory, and memory is the machine's: the image is the same
	// everywhere, so the number comes from the launch.
	if got := settings(nil, env(nil)); got.MaxRooms != defaultMaxRooms {
		t.Fatalf("default room limit %d instead of %d", got.MaxRooms, defaultMaxRooms)
	}
	if got := settings(nil, env(map[string]string{"MAX_ROOMS": "40"})); got.MaxRooms != 40 {
		t.Fatalf("room limit %d instead of 40", got.MaxRooms)
	}
	given := map[string]string{"max-rooms": "7"}
	if got := settings(given, env(map[string]string{"MAX_ROOMS": "40"})); got.MaxRooms != 7 {
		t.Fatalf("room limit %d: a flag must beat a variable", got.MaxRooms)
	}
	// Zero or garbage would mean "refuse everyone" — a typo, not a setting.
	if got := settings(nil, env(map[string]string{"MAX_ROOMS": "lots"})); got.MaxRooms != defaultMaxRooms {
		t.Fatalf("garbage in MAX_ROOMS gave a limit of %d", got.MaxRooms)
	}
}
