package main

import (
	"fmt"
	"slices"
	"strings"
)

// Browser families and the systems under them that a hello from a browser may
// name. The client works them out of its user agent and sends only these words;
// the user agent itself never leaves it. Anything else sent is other, and
// nothing sent is unknown.
var (
	browsers = []string{"chrome", "safari", "firefox", "edge", "opera", "yandex", "samsung"}
	systems  = []string{"macos", "windows", "linux", "android", "ios", "chromeos"}
)

// familyLabel folds what a hello named into one of the known words.
func familyLabel(sent string, known []string) string {
	switch {
	case sent == "":
		return "unknown"
	case slices.Contains(known, sent):
		return sent
	}
	return "other"
}

// describe says who a seated player is, for the line that seats them: the
// release and the platform their hello named, and in a browser its family and
// system. Only folded words: what the client sent past the closed sets is other.
func (c client) describe(browser, os string) string {
	who := fmt.Sprintf("%s %s", versionLabel(c.version), platformLabel(c.platform))
	if !strings.HasPrefix(platformLabel(c.platform), "web") {
		return who
	}
	return fmt.Sprintf("%s (%s, %s)", who, familyLabel(browser, browsers), familyLabel(os, systems))
}
