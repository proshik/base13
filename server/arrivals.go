package main

// How evenly packets arrive from one member.
//
// The server is the impartial witness here: it sees both sides and can say
// whose stream is ragged without asking anyone. In lockstep what matters is
// not the average rate but the worst gap — that is what turns into a frozen
// frame on the partner's screen.

import "time"

type arrivals struct {
	packets int
	gaps    int
	last    time.Time
	worst   time.Duration
}

// note takes a packet's arrival. Every packet but a stream's very first ends a
// gap, and the gap is measured from the last packet whichever window that one
// fell in.
func (a *arrivals) note(now time.Time) {
	if !a.last.IsZero() {
		a.gaps++
		if gap := now.Sub(a.last); gap > a.worst {
			a.worst = gap
		}
	}
	a.packets++
	a.last = now
}

func (a *arrivals) count() int { return a.packets }

func (a *arrivals) worstGap() time.Duration { return a.worst }

// measured reports whether the window holds a gap at all. Only a window holding
// nothing but a stream's first packet does not, and its worst gap of zero is
// no measurement: reported, it would pass for a perfect stream.
func (a *arrivals) measured() bool { return a.gaps > 0 }

// forget clears the window: a report speaks about the last few seconds,
// not about all time. The last arrival is kept. A window closes on a packet,
// so the gap into the next window's first packet began in this one, and a
// stall that ends there belongs to the window it ends in — cleared with the
// last arrival, it would not be measured anywhere.
func (a *arrivals) forget() {
	a.packets = 0
	a.gaps = 0
	a.worst = 0
}
