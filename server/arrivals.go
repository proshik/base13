package main

// How evenly packets arrive from one member.
//
// The server is the impartial witness here: it sees both sides and can say
// whose stream is ragged without asking anyone. In lockstep what matters is
// not the average rate but the worst gap — that is what turns into a frozen
// frame on the partner's screen.

import "time"

// togetherWithin is how close packets arrive when they left together. A sender
// hands over one frame's packets back to back, and its frames are a sixtieth of
// a second apart; packets its network held are let go back to back as well.
const togetherWithin = 4 * time.Millisecond

// mostTogether bounds the count of packets that came together. Past a few dozen
// the answer is plain, and a stream sent back to back for good must not hold a
// window open for good.
const mostTogether = 64

type arrivals struct {
	packets int
	gaps    int
	last    time.Time
	worst   time.Duration
	// How many packets came together with the end of the worst gap, that one
	// included, and whether they may still be coming.
	together int
	counting bool
}

// note takes a packet's arrival. Every packet but a stream's very first ends a
// gap, and the gap is measured from the last packet whichever window that one
// fell in.
func (a *arrivals) note(now time.Time) {
	if !a.last.IsZero() {
		a.gaps++
		gap := now.Sub(a.last)
		switch {
		case gap > a.worst:
			a.worst = gap
			a.together = 1
			a.counting = true
		case a.counting && gap < togetherWithin && a.together < mostTogether:
			a.together++
		default:
			a.counting = false
		}
	}
	a.packets++
	a.last = now
}

func (a *arrivals) count() int { return a.packets }

func (a *arrivals) worstGap() time.Duration { return a.worst }

// atOnce is how many packets came together with the end of the worst gap. It
// tells the two causes of a stall apart. A machine that stood sent nothing
// meanwhile and catches up a few ticks a frame, so a handful come at once. A
// network that stood held what the sender went on sending and lets it all go
// together, so a stall's worth comes at once: a dozen for two hundred
// milliseconds.
func (a *arrivals) atOnce() int { return a.together }

// settling reports whether the packets that ended the worst gap may still be
// coming. A window is not closed on them: the count would be cut short, and a
// stall ending right on the window's end would always read as a machine's.
func (a *arrivals) settling() bool { return a.counting }

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
	a.together = 0
	a.counting = false
}
