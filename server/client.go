package main

import (
	"fmt"
	"regexp"
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

// A game's name as the log may say it: a plain word, as every real client
// sends. The name is a stranger's, and written into a line as it came, a line
// break in it starts a line of its own — one that reads like the server's word
// about some other room. Quoting it would stop that and still leave hundreds of
// bytes of the stranger's text, lookalike words included, in every join line.
var plainWord = regexp.MustCompile(`^[a-z0-9_]{1,32}$`)

// gameLabel folds a game's name for the log: kept when it is a plain word, and
// other when it is anything else. The room keeps the name as it was sent; only
// the log folds it.
func gameLabel(sent string) string {
	if plainWord.MatchString(sent) {
		return sent
	}
	return "other"
}
