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
	last    time.Time
	worst   time.Duration
}

func (a *arrivals) note(now time.Time) {
	if a.packets > 0 {
		if gap := now.Sub(a.last); gap > a.worst {
			a.worst = gap
		}
	}
	a.packets++
	a.last = now
}

func (a *arrivals) count() int { return a.packets }

func (a *arrivals) worstGap() time.Duration { return a.worst }

// forget clears the window: a report speaks about the last few seconds,
// not about all time.
func (a *arrivals) forget() {
	a.packets = 0
	a.worst = 0
}
