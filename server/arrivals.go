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

// mostHeldOpen is how long a window may wait for its burst once its time is up:
// long enough for mostTogether packets back to back, and a stream sent back to
// back without end does not hold it longer.
const mostHeldOpen = mostTogether * togetherWithin

type arrivals struct {
	packets int
	gaps    int
	last    time.Time
	worst   time.Duration
	// How many packets came together with the end of the worst gap, that one
	// included, and whether they may still be coming.
	together int
	counting bool
	// When the window, its time up, began to wait for the burst that ended its
	// worst gap; zero while it is not waiting.
	heldSince time.Time
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
// milliseconds. A client that stood a second for its partner also sends its
// recent input again in one go, so a gap that long ending in two dozen is that.
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
	a.heldSince = time.Time{}
}

// take notes a packet arriving at `now` in the window opened at `*window`, which
// lasts `every`. For each window the packet closes it calls `close` with the
// time the window ends; `close` reads the figures, and take then clears them
// and opens the next window.
//
// A window whose time is up closes on the next packet — unless that packet
// ended the window's worst gap. Then the window waits for the packets that came
// together with it, so the count is whole: a window that closed on the first of
// them read `then 1 at once` for any stall ending past its time. It waits only
// while they keep coming back to back, and mostHeldOpen at the longest. The
// first packet that does not come with them closes the window before it is
// noted, and opens the next one: the gap it ends may be another stall, with a
// burst of its own — a side standing for its partner sends its input again
// once a second — and counted here it would start the count over at one.
func (a *arrivals) take(now time.Time, window *time.Time, every time.Duration, close func(end time.Time)) {
	if !a.heldSince.IsZero() && (now.Sub(a.last) >= togetherWithin || now.Sub(a.heldSince) >= mostHeldOpen) {
		a.closeWindow(now, window, close)
	}
	a.note(now)
	if now.Sub(*window) < every || !a.heldSince.IsZero() {
		return
	}
	if a.settling() {
		a.heldSince = now
		return
	}
	a.closeWindow(now, window, close)
}

func (a *arrivals) closeWindow(now time.Time, window *time.Time, close func(end time.Time)) {
	close(now)
	a.forget()
	*window = now
}
