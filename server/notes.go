package main

// A player's own events, for the log.
//
// A window line says how a player's stream went; it cannot say what the player
// saw. A hang between two stages was read off one browser console that
// happened to stay open, and a tab gone out of sight looked exactly like a
// network falling short. So the client names its events to the server — a
// stage beginning, ending, done; input sent again, and why; a tab or a window
// going out of sight or focus — and the server writes each as one line.
//
// The server does not interpret them: it knows a closed set of words, the whole
// numbers each word takes, and how to say each in the log. A stage is only a
// number the client counts by. Nothing from a note reaches the log as a
// stranger wrote it: the word is one of the server's own, and every figure is a
// whole number held within maxNoteFigure.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"
)

// A few notes come together — a stage ends, is done and the next begins; a tab
// goes out of sight and its window loses focus, then both come back — so a
// connection may have ten taken at once, and earns one back every two seconds.
// An honest client sends a handful a minute; a flood writes at most thirty
// lines a minute for its connection.
const (
	noteBurst        = 10
	defaultNoteEvery = 2 * time.Second
)

// Every figure a note carries is a tick, a stage or a duration in
// milliseconds, and none of them honestly reaches ten million: that is
// forty-six hours of ticks. Held there, a figure is at most eight characters.
const maxNoteFigure = 10_000_000

// A note shape: the figures its word takes, in the order its line says them.
type noteShape struct {
	figures []string
	line    string
}

// The closed set. Looked up by the word, never walked, so its order is no
// one's business.
var noteShapes = map[string]noteShape{
	"stage_begins": {[]string{"stage"}, "stage %d begins"},
	"stage_ends": {[]string{"stage", "tick", "ended", "seen"},
		"stage %d ends on tick %d: ended in %d, seen at %d"},
	"stage_done": {[]string{"stage", "tick"}, "stage %d done on tick %d"},
	"stood": {[]string{"stage", "tick", "ms", "confirmed", "from", "through"},
		"stage %d: tick %d stood %d ms, confirmed through %d, input sent again for %d..%d"},
	"horizon": {[]string{"stage", "tick", "ms", "confirmed", "from", "through"},
		"stage %d: standing at the horizon %d for %d ms, confirmed through %d, input sent again for %d..%d"},
	"link_back": {[]string{"stage", "from", "through"}, "stage %d: link back, input sent again for %d..%d"},
	"hidden":    {nil, "tab hidden"},
	"visible":   {nil, "tab visible"},
	"blur":      {nil, "window lost focus"},
	"focus":     {nil, "window has focus"},
}

// note is one event as the server read it: a shape from the closed set and its
// figures, in the shape's order.
type note struct {
	shape   noteShape
	figures []int
}

// readNote reads the inside of {"note":{...}}: the word under "what", and
// exactly the figures that word takes, each a whole number. Anything else is
// not a note.
func readNote(raw json.RawMessage) (note, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return note{}, false
	}
	var what string
	quoted := bytes.TrimSpace(fields["what"])
	if len(quoted) == 0 || quoted[0] != '"' || json.Unmarshal(quoted, &what) != nil {
		return note{}, false
	}
	shape, known := noteShapes[what]
	if !known || len(fields) != len(shape.figures)+1 {
		return note{}, false
	}
	n := note{shape: shape, figures: make([]int, len(shape.figures))}
	for i, name := range shape.figures {
		value, ok := wholeNumber(fields[name])
		if !ok {
			return note{}, false
		}
		n.figures[i] = min(max(value, -maxNoteFigure), maxNoteFigure)
	}
	return n, true
}

// line is the note in the server's words.
func (n note) line() string {
	args := make([]any, len(n.figures))
	for i, figure := range n.figures {
		args[i] = figure
	}
	return fmt.Sprintf(n.shape.line, args...)
}

func (s *server) noteInterval() time.Duration {
	if s.noteEvery > 0 {
		return s.noteEvery
	}
	return defaultNoteEvery
}
