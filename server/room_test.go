package main

import (
	"bytes"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCodeAvoidsLookalikeCharacters(t *testing.T) {
	// The code is read aloud over the phone: zero and O, one and I are
	// indistinguishable.
	for i := 0; i < 200; i++ {
		code, err := generateCode()
		if err != nil {
			t.Fatalf("code was not generated: %v", err)
		}
		if len(code) != codeLength {
			t.Fatalf("code length %d, expected %d", len(code), codeLength)
		}
		if strings.ContainsAny(code, "0O1I") {
			t.Fatalf("code %q contains characters that sound alike", code)
		}
	}
}

func TestCodesDoNotRepeat(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 500; i++ {
		code, _ := generateCode()
		if seen[code] {
			t.Fatalf("code %q came up twice in five hundred tries", code)
		}
		seen[code] = true
	}
}

func TestRoomTakesTwoAndRefusesThird(t *testing.T) {
	room := newRoom("ABCDEF", "tanks", 42)
	first, err := room.Join()
	if err != nil {
		t.Fatalf("the first one was not seated: %v", err)
	}
	second, err := room.Join()
	if err != nil {
		t.Fatalf("the second one was not seated: %v", err)
	}
	if first.Slot == second.Slot {
		t.Fatal("member slots must differ: the order of players depends on them")
	}
	if _, err := room.Join(); err != errRoomFull {
		t.Fatalf("a third must not be let in, got: %v", err)
	}
}

func TestLeavingFreesTheSlotForTheSamePlayer(t *testing.T) {
	// Whoever dropped out returns to their own slot; otherwise the order of
	// players in the game changes and the worlds diverge.
	room := newRoom("ABCDEF", "tanks", 42)
	first, _ := room.Join()
	second, _ := room.Join()
	room.Leave(first)
	back, err := room.Join()
	if err != nil {
		t.Fatalf("returning failed: %v", err)
	}
	if back.Slot != first.Slot {
		t.Fatalf("returned to slot %d instead of %d", back.Slot, first.Slot)
	}
	_ = second
}

func TestPacketReachesTheOtherAndNotTheSender(t *testing.T) {
	room := newRoom("ABCDEF", "tanks", 42)
	sender, _ := room.Join()
	receiver, _ := room.Join()

	payload := []byte{1, 2, 3}
	room.Broadcast(sender, payload)

	select {
	case got := <-receiver.Send:
		if got.Text || !bytes.Equal(got.Data, payload) {
			t.Fatalf("the wrong thing arrived: %+v", got)
		}
	default:
		t.Fatal("the packet never reached the second member")
	}
	select {
	case <-sender.Send:
		t.Fatal("the sender must not get their own packet back")
	default:
	}
}

func TestJournalKeepsOrderAndGivesTheTail(t *testing.T) {
	room := newRoom("ABCDEF", "tanks", 42)
	sender, _ := room.Join()
	for i := 0; i < 5; i++ {
		room.Broadcast(sender, []byte{byte(i)})
	}
	if room.JournalLength() != 5 {
		t.Fatalf("the journal holds %d records instead of five", room.JournalLength())
	}
	tail, err := room.JournalSince(2, 1)
	if err != nil {
		t.Fatalf("the tail was not returned: %v", err)
	}
	if len(tail) != 3 || tail[0][0] != 2 || tail[2][0] != 4 {
		t.Fatalf("the journal tail is wrong: %v", tail)
	}
}

func TestJournalRefusesImpossibleRequests(t *testing.T) {
	room := newRoom("ABCDEF", "tanks", 42)
	if _, err := room.JournalSince(1, 1); err != errJournalAhead {
		t.Fatal("a request past the end of the journal must be refused")
	}
	if _, err := room.JournalSince(-1, 1); err != errJournalAhead {
		t.Fatal("a negative index must be refused")
	}
	if tail, err := room.JournalSince(0, 1); err != nil || len(tail) != 0 {
		t.Fatal("an empty journal from zero is an empty tail, not an error")
	}
}

func TestJournalIsBounded(t *testing.T) {
	// A game runs for hours; the journal must not grow without bound.
	room := newRoom("ABCDEF", "tanks", 42)
	sender, _ := room.Join()
	for i := 0; i < maxJournal+50; i++ {
		room.Broadcast(sender, []byte{1})
	}
	if room.JournalLength() > maxJournal {
		t.Fatalf("the journal grew to %d records", room.JournalLength())
	}
}

func TestJournalIsBoundedInBytesToo(t *testing.T) {
	// The server relays whatever it is handed. A cap on the record count alone
	// lets large packets pile up without limit in one room.
	room := newRoom("ABCDEF", "tanks", 1)
	big := bytes.Repeat([]byte{7}, maxMessageSize)
	for i := 0; i < 2*maxJournalBytes/maxMessageSize; i++ {
		room.Broadcast(nil, big)
	}
	if got := room.journal.size(); got > maxJournalBytes {
		t.Fatalf("the journal holds %d bytes, the cap is %d", got, maxJournalBytes)
	}
}

func TestTheByteCapLeavesRoomForAFullHonestMatch(t *testing.T) {
	// Game packets are six bytes and, once a second, nine. If the byte cap bit
	// before the count cap, a long honest match would lose its catch-up.
	if maxJournal*7 > maxJournalBytes {
		t.Fatalf("%d records of seven bytes do not fit in %d", maxJournal, maxJournalBytes)
	}
}

func TestBroadcastCopiesThePacket(t *testing.T) {
	// The caller reuses its read buffer; the journal must keep its own copy.
	room := newRoom("ABCDEF", "tanks", 42)
	sender, _ := room.Join()
	buffer := []byte{7}
	room.Broadcast(sender, buffer)
	buffer[0] = 99
	tail, _ := room.JournalSince(0, 1)
	if tail[0][0] != 7 {
		t.Fatal("the journal holds a reference to somebody else's buffer and rots with it")
	}
}

func TestHubRefusesRoomsPastItsLimit(t *testing.T) {
	// Past the cap a new room is refused rather than the process being killed
	// for memory — which would end every match on it at once.
	hub := NewHub()
	hub.limit = 2
	hub.Create("tanks", 1)
	hub.Create("tanks", 2)
	if _, err := hub.Create("tanks", 3); err != errServerBusy {
		t.Fatalf("a room past the limit was not refused: %v", err)
	}
	if reasonCode(errServerBusy) != "busy" {
		t.Fatalf("refusal marker %q instead of busy", reasonCode(errServerBusy))
	}
}

func TestAFullServerStillSeatsWhoeverIsWaiting(t *testing.T) {
	// Seating someone in a waiting room opens nothing new, so the cap must not
	// stop it: the waiter would otherwise wait forever beside a free seat.
	hub := NewHub()
	hub.limit = 1
	if _, _, err := hub.Quick("tanks", 1); err != nil {
		t.Fatalf("the waiter was not seated: %v", err)
	}
	if _, _, err := hub.Quick("tanks", 2); err != nil {
		t.Fatalf("the partner was refused though a seat was free: %v", err)
	}
	if _, _, err := hub.Quick("tanks", 3); err != errServerBusy {
		t.Fatalf("a third quick player needs a new room, which is past the limit: %v", err)
	}
}

func TestRoomsOfDifferentGamesDoNotMix(t *testing.T) {
	hub := NewHub()
	room, _ := hub.Create("tanks", 1)
	if _, err := hub.Find("chess", room.Code); err != errNoSuchRoom {
		t.Fatal("a code of one game must not open a room of another")
	}
	if _, err := hub.Find("tanks", room.Code); err != nil {
		t.Fatalf("a game must find its own room: %v", err)
	}
}

func TestUnknownCodeIsRefused(t *testing.T) {
	hub := NewHub()
	if _, err := hub.Find("tanks", "ZZZZZZ"); err != errNoSuchRoom {
		t.Fatalf("a nonexistent code must be refused, got: %v", err)
	}
}

func TestEmptyRoomIsSweptButNotImmediately(t *testing.T) {
	hub := NewHub()
	room, _ := hub.Create("tanks", 1)
	member, _ := room.Join()
	room.Leave(member)

	if hub.Sweep(time.Now()); hub.Count() != 1 {
		t.Fatal("the room was swept at once — whoever dropped out has nowhere to return")
	}
	if hub.Sweep(time.Now().Add(emptyRoomLifetime + time.Minute)); hub.Count() != 0 {
		t.Fatal("an empty room must be swept once its time is up")
	}
}

func TestOccupiedRoomSurvivesSweeping(t *testing.T) {
	hub := NewHub()
	room, _ := hub.Create("tanks", 1)
	room.Join()
	hub.Sweep(time.Now().Add(24 * time.Hour))
	if hub.Count() != 1 {
		t.Fatal("a room with a player in it must not be swept")
	}
}

func TestJournalDoesNotReturnPlayerHisOwnPackets(t *testing.T) {
	// A returning player counts what they received — and they only ever
	// received somebody else's. Hand them their own input back and the count
	// drifts, and the world with it.
	room := newRoom("ABCDEF", "tanks", 42)
	first, _ := room.Join()
	second, _ := room.Join()

	room.Broadcast(first, []byte{10})
	room.Broadcast(second, []byte{20})
	room.Broadcast(first, []byte{11})

	tail, err := room.JournalSince(0, 1)
	if err != nil {
		t.Fatalf("the tail was not returned: %v", err)
	}
	if len(tail) != 2 || tail[0][0] != 10 || tail[1][0] != 11 {
		t.Fatalf("the second must get only the other side's packets, got: %v", tail)
	}

	// They saw the first of them — exactly the second must be sent after.
	tail, _ = room.JournalSince(1, 1)
	if len(tail) != 1 || tail[0][0] != 11 {
		t.Fatalf("the catch-up tail is wrong: %v", tail)
	}

	// And the first is owed only the second one's packet.
	tail, _ = room.JournalSince(0, 0)
	if len(tail) != 1 || tail[0][0] != 20 {
		t.Fatalf("the first got the wrong thing: %v", tail)
	}
}

func TestNoticeGoesToTheOtherSideOnly(t *testing.T) {
	room := newRoom("ABCDEF", "tanks", 42)
	first, _ := room.Join()
	second, _ := room.Join()
	room.Notify(second, []byte(`{"event":"joined"}`))

	select {
	case got := <-first.Send:
		if !got.Text {
			t.Fatal("a housekeeping message must be a text frame")
		}
	default:
		t.Fatal("the partner never learned about the arrival")
	}
	select {
	case <-second.Send:
		t.Fatal("nobody should be told about their own arrival")
	default:
	}
}

func TestQuickPairsTwoWaitingPlayers(t *testing.T) {
	hub := NewHub()
	first, firstMember, err := hub.Quick("tanks", 555)
	if err != nil {
		t.Fatalf("the first one did not start waiting: %v", err)
	}
	if firstMember.Slot != 0 {
		t.Fatalf("whoever waits first takes the first slot, got %d", firstMember.Slot)
	}

	second, secondMember, err := hub.Quick("tanks", 999)
	if err != nil {
		t.Fatalf("the second one was not matched: %v", err)
	}
	if second != first {
		t.Fatal("two people pressing the button must end up in one room")
	}
	if secondMember.Slot != 1 {
		t.Fatalf("the matched one takes the second slot, got %d", secondMember.Slot)
	}
	// The seed is set by whoever started waiting: every level's seed is derived
	// from it, and the second must receive that one, not their own.
	if second.Seed != 555 {
		t.Fatalf("room seed %d instead of 555", second.Seed)
	}
}

func TestQuickStartsAFreshRoomWhenNobodyWaits(t *testing.T) {
	hub := NewHub()
	room, member, err := hub.Quick("tanks", 1)
	if err != nil {
		t.Fatalf("the room was not opened: %v", err)
	}
	if len(room.Code) != codeLength {
		t.Fatalf("a public room has a code too: %q", room.Code)
	}
	if member.Slot != 0 || room.Occupants() != 1 {
		t.Fatalf("a lone player must wait alone: slot %d, occupied %d",
			member.Slot, room.Occupants())
	}
}

func TestQuickDoesNotOfferARoomItsWaiterHasLeft(t *testing.T) {
	// An abandoned room's journal is not empty: it holds input sent before the
	// break. Seating the next player there would give them a catch-up of
	// somebody else's input — the world would drift from the very first tick,
	// and it would look like a random desync.
	hub := NewHub()
	abandoned, waiter, _ := hub.Quick("tanks", 7)
	abandoned.Broadcast(waiter, []byte{1, 2, 3})
	abandoned.Leave(waiter)

	fresh, _, err := hub.Quick("tanks", 8)
	if err != nil {
		t.Fatalf("matchmaking did not work out: %v", err)
	}
	if fresh == abandoned {
		t.Fatal("an abandoned room must not be offered: its journal is not empty")
	}
}

func TestQuickIgnoresPrivateRooms(t *testing.T) {
	// A room opened by code for one particular person must not fall to a
	// random passer-by: its code was dictated to somebody.
	hub := NewHub()
	private, _ := hub.Create("tanks", 42)
	private.Join()

	public, _, err := hub.Quick("tanks", 43)
	if err != nil {
		t.Fatalf("matchmaking did not work out: %v", err)
	}
	if public == private {
		t.Fatal("matchmaking took a private room")
	}
}

func TestQuickKeepsGamesApart(t *testing.T) {
	hub := NewHub()
	tanks, _, _ := hub.Quick("tanks", 1)
	chess, _, err := hub.Quick("chess", 2)
	if err != nil {
		t.Fatalf("matchmaking for the second game did not work out: %v", err)
	}
	if chess == tanks {
		t.Fatal("matchmaking paired players of different games")
	}
}

func TestQuickFillsRoomsBeforeStartingNewOnes(t *testing.T) {
	// Otherwise waiters pile up: each opens their own room and nobody ever
	// meets anybody.
	hub := NewHub()
	hub.Quick("tanks", 1)
	hub.Quick("tanks", 2)
	if hub.Count() != 1 {
		t.Fatalf("two must fit in one room, rooms %d", hub.Count())
	}
	third, _, _ := hub.Quick("tanks", 3)
	if hub.Count() != 2 {
		t.Fatalf("the third needs a room of their own, rooms %d", hub.Count())
	}
	if third.Occupants() != 1 {
		t.Fatal("the third must wait alone")
	}
}

func TestQuickUnderRaceGivesEveryoneADistinctSeat(t *testing.T) {
	// Two press the button in the same instant. Separate search and seating
	// would hand them one slot, and one would be refused as "full" with a live
	// partner sitting there.
	hub := NewHub()
	const players = 40
	seats := make(chan string, players)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < players; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			<-start
			room, member, err := hub.Quick("tanks", uint32(n))
			if err != nil {
				seats <- "error: " + err.Error()
				return
			}
			seats <- room.Code + ":" + strconv.Itoa(member.Slot)
		}(i)
	}
	close(start)
	wg.Wait()
	close(seats)

	taken := map[string]bool{}
	for seat := range seats {
		if strings.HasPrefix(seat, "error") {
			t.Fatalf("matchmaking refused while waiters were live: %s", seat)
		}
		if taken[seat] {
			t.Fatalf("two were seated in one slot: %s", seat)
		}
		taken[seat] = true
	}
	if len(taken) != players {
		t.Fatalf("slots handed out %d, players %d", len(taken), players)
	}
}

func TestJournalStoresPacketsCompactly(t *testing.T) {
	// Each record as its own slice cost 112 bytes for 6 useful ones: the slice
	// header, the slot number and size rounding on allocation. A room at the
	// journal cap took 32 MB, and a hundred long games ate three gigabytes.
	room := newRoom("ABCDEF", "tanks", 42)
	sender, _ := room.Join()
	room.Join()

	const packets = 20000
	for i := 0; i < packets; i++ {
		room.Broadcast(sender, []byte{1, byte(i), byte(i >> 8), 0, 0, 31})
	}

	perPacket := float64(room.JournalBytes()) / packets
	if perPacket > 16 {
		t.Fatalf("a 6-byte packet costs %.1f bytes of storage", perPacket)
	}
}

func TestCompactJournalGivesBackExactlyWhatWentIn(t *testing.T) {
	// Storage may be as compact as it likes; what comes back must be identical.
	room := newRoom("ABCDEF", "tanks", 42)
	first, _ := room.Join()
	second, _ := room.Join()

	room.Broadcast(first, []byte{1, 0, 0, 0, 0, 31})
	room.Broadcast(second, []byte{1, 1, 0, 0, 0, 16})
	room.Broadcast(first, []byte{3, 0, 0, 0, 60, 9, 9, 9, 9}) // a hash is longer than an input
	room.Broadcast(first, []byte{1, 2, 0, 0, 0, 4})

	tail, err := room.JournalSince(0, 1)
	if err != nil {
		t.Fatalf("the tail was not returned: %v", err)
	}
	want := [][]byte{
		{1, 0, 0, 0, 0, 31},
		{3, 0, 0, 0, 60, 9, 9, 9, 9},
		{1, 2, 0, 0, 0, 4},
	}
	if len(tail) != len(want) {
		t.Fatalf("records %d instead of %d: %v", len(tail), len(want), tail)
	}
	for i := range want {
		if !bytes.Equal(tail[i], want[i]) {
			t.Fatalf("record %d: %v instead of %v", i, tail[i], want[i])
		}
	}
}

func TestWaitingIndexHoldsOnlyRoomsThatActuallyWait(t *testing.T) {
	// Matchmaking must not walk every room on the server: that is O(n) under
	// the shared lock, which also guards creation and lookup by code.
	// Unnoticeable at two hundred rooms; at ten thousand it is a stalled
	// server.
	hub := NewHub()

	// A hundred and fifty occupied games: they have no business in the waiting
	// queue.
	for i := 0; i < 150; i++ {
		hub.Quick("tanks", uint32(i))
		hub.Quick("tanks", uint32(i))
	}
	if got := hub.waitingCount("tanks"); got != 0 {
		t.Fatalf("%d rooms in the queue while nobody is waiting", got)
	}

	// One waiter means exactly one entry.
	hub.Quick("tanks", 1)
	if got := hub.waitingCount("tanks"); got != 1 {
		t.Fatalf("%d rooms in the queue instead of one", got)
	}

	// The second arrived — the queue is empty again.
	hub.Quick("tanks", 2)
	if got := hub.waitingCount("tanks"); got != 0 {
		t.Fatalf("%d rooms left in the queue after matchmaking", got)
	}
}

func TestAbandonedRoomLeavesTheWaitingIndex(t *testing.T) {
	hub := NewHub()
	room, waiter, _ := hub.Quick("tanks", 1)
	room.Broadcast(waiter, []byte{1, 2, 3})
	room.Leave(waiter)

	// Matchmaking skips an abandoned room and never comes back to it.
	hub.Quick("tanks", 2)
	if got := hub.waitingCount("tanks"); got != 1 {
		t.Fatalf("%d rooms in the queue: the abandoned one was not dropped, or the new one was not added", got)
	}
}

func TestSweptRoomsLeaveTheWaitingIndex(t *testing.T) {
	hub := NewHub()
	room, waiter, _ := hub.Quick("tanks", 1)
	room.Leave(waiter)
	hub.Sweep(time.Now().Add(emptyRoomLifetime + time.Minute))
	if got := hub.waitingCount("tanks"); got != 0 {
		t.Fatalf("a swept room stayed in the queue: %d", got)
	}
}
