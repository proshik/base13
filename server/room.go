package main

// Rooms and relaying. The server does not know what bytes pass through it:
// it sees members, a room code and the order of packets. That is exactly why
// it suits any next game equally well.

import (
	"crypto/rand"
	"errors"
	"math/big"
	"sync"
	"time"
)

// The code alphabet: no zero, no letter O, no one, no letter I. The code gets
// read aloud over the phone — that is what settled the choice.
const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

const (
	codeLength   = 6
	roomCapacity = 2
	// An hour-long game is roughly a megabyte and a half of packets. Keeping
	// more is pointless: catching up from the middle is impossible anyway,
	// the whole journal is needed.
	maxJournal = 300000
	// Records are capped in bytes as well as in count. The count alone assumed
	// six-byte packets, but the server journals whatever it is handed, and a
	// count of large packets is gigabytes. Seven bytes a record leaves honest
	// play reaching the count first: its packets are six bytes and, once a
	// second, nine.
	maxJournalBytes = maxJournal * 7
	// How long a room stays alive while empty, waiting for someone to return.
	emptyRoomLifetime = 5 * time.Minute
)

// How many rooms one process holds by default. A room at its caps is about
// 4 MB, so this is about a gigabyte in the worst case. Past it a new room is
// refused with "busy" rather than the process being killed for memory, which
// would end every match on it at once.
const defaultMaxRooms = 250

var (
	errRoomFull     = errors.New("room is already full")
	errNoSuchRoom   = errors.New("no room with that code")
	errJournalAhead = errors.New("journal tail requested past its end")
	errServerBusy   = errors.New("the server holds as many rooms as it can")
)

// A short refusal marker alongside the human-readable text. The client draws
// its captions with its own atlas font, which knows only capital Latin letters
// and digits, so it cannot render an arbitrary explanation from the server —
// and picking one apart word by word would be the worst way to try.
func reasonCode(err error) string {
	switch err {
	case errRoomFull:
		return "full"
	case errNoSuchRoom:
		return "no_room"
	case errServerBusy:
		return "busy"
	}
	return "refused"
}

// outgoing is what goes out to a member. The frame kind travels with the
// data: a housekeeping message and a game packet share one queue, and the
// order between them must be preserved.
type outgoing struct {
	Text bool
	Data []byte
}

// Member is one occupant of a room. Sending goes through a channel rather
// than straight into the socket: a slow member must not hold up the rest.
type Member struct {
	Slot int
	Send chan outgoing
}

// journal holds the room's records back to back in a single buffer.
//
// Each record as its own slice cost 112 bytes for 6 useful ones: the slice
// header, the slot number and size rounding on allocation. A room at the cap
// took 32 MB, and a hundred long games took three gigabytes. Here a record
// costs its own bytes plus an offset and a slot number.
//
// The sender's slot is stored next to the data: without it a returning player
// could not catch up. Their own packets never came back to them, so their
// count of what was received does not include them — and that count is exactly
// how they mark how far they got.
type journal struct {
	buf    []byte
	starts []int32 // start of every record in buf, plus the end of the last
	slots  []uint8
}

func (j *journal) append(slot int, data []byte) {
	if len(j.starts) == 0 {
		j.starts = append(j.starts, 0)
	}
	j.buf = append(j.buf, data...)
	j.starts = append(j.starts, int32(len(j.buf)))
	j.slots = append(j.slots, uint8(slot))
}

func (j *journal) count() int {
	return len(j.slots)
}

// size reports how many bytes of records the journal holds.
func (j *journal) size() int {
	return len(j.buf)
}

// bytes reports how much memory the journal holds. The load measurement needs
// it: growth here is invisible in ordinary tests and only shows up in a long
// game.
func (j *journal) bytes() int {
	return cap(j.buf) + cap(j.starts)*4 + cap(j.slots)
}

// record returns record number i. The slice points into the shared buffer, so
// it must not be handed outside without a copy: the buffer grows and moves.
func (j *journal) record(i int) (int, []byte) {
	return int(j.slots[i]), j.buf[j.starts[i]:j.starts[i+1]]
}

type Room struct {
	Code string
	Game string
	Seed uint32
	// Matchmaking opens a public room, a code opens a private one. Nothing
	// else separates them: a room opened for one particular person must not
	// fall to a random passer-by, and that is the only difference.
	Public  bool
	mu      sync.Mutex
	members map[int]*Member
	journal journal
	emptyAt time.Time
}

func newRoom(code, game string, seed uint32) *Room {
	return &Room{
		Code:    code,
		Game:    game,
		Seed:    seed,
		members: map[int]*Member{},
	}
}

// available reports whether the room is fit for matchmaking. Called under the
// hub's lock, so it takes its own.
//
// An abandoned room is unfit even though a seat is free: its journal is not
// empty, and whoever is seated there would get a catch-up of somebody else's
// input — the world would drift from the very first tick, and it would look
// like a random desync.
func (r *Room) available() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.Public && len(r.members) > 0 && len(r.members) < roomCapacity
}

// Join seats a member in a free slot and returns it. The slot matters: the
// order of players depends on it, and that order must match on both sides.
func (r *Room) Join() (*Member, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for slot := 0; slot < roomCapacity; slot++ {
		if _, taken := r.members[slot]; taken {
			continue
		}
		member := &Member{Slot: slot, Send: make(chan outgoing, 256)}
		r.members[slot] = member
		r.emptyAt = time.Time{}
		return member, nil
	}
	return nil, errRoomFull
}

func (r *Room) Leave(member *Member) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if current, ok := r.members[member.Slot]; ok && current == member {
		delete(r.members, member.Slot)
		close(member.Send)
	}
	if len(r.members) == 0 {
		// Not removed at once: whoever dropped out must have time to return.
		r.emptyAt = time.Now()
	}
}

// Broadcast appends the packet to the journal and sends it to everyone except
// the sender: the client already has its own input, and echoing it back is
// wasted traffic and confusion.
func (r *Room) Broadcast(from *Member, data []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.journal.count() < maxJournal && r.journal.size()+len(data) <= maxJournalBytes {
		sender := -1
		if from != nil {
			sender = from.Slot
		}
		r.journal.append(sender, data)
	}
	for slot, member := range r.members {
		if from != nil && slot == from.Slot {
			continue
		}
		select {
		case member.Send <- outgoing{Data: data}:
		default:
			// The queue overflowed — this member is hopelessly behind. Cutting
			// their connection is more honest than slowing the game for
			// everyone else.
			close(member.Send)
			delete(r.members, slot)
		}
	}
}

// Notify sends a housekeeping message to everyone except the given member.
// It is how a side learns that the partner arrived or dropped out: it cannot
// see that itself, their connections are separate.
func (r *Room) Notify(except *Member, message []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for slot, member := range r.members {
		if except != nil && slot == except.Slot {
			continue
		}
		select {
		case member.Send <- outgoing{Text: true, Data: message}:
		default:
		}
	}
}

// JournalSince returns what a member in slot forSlot should have received,
// skipping the first `from` records. The world is computed from a seed and
// key presses, so catching up means replaying what was missed rather than
// restoring a state.
func (r *Room) JournalSince(from, forSlot int) ([][]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if from < 0 {
		return nil, errJournalAhead
	}
	tail := [][]byte{}
	counted := 0
	for i := 0; i < r.journal.count(); i++ {
		slot, data := r.journal.record(i)
		if slot == forSlot {
			continue
		}
		counted++
		if counted > from {
			// The copy is mandatory: the slice points into the shared buffer,
			// which grows and moves, while what is handed out goes to another
			// goroutine.
			packet := make([]byte, len(data))
			copy(packet, data)
			tail = append(tail, packet)
		}
	}
	if from > counted {
		return nil, errJournalAhead
	}
	return tail, nil
}

func (r *Room) JournalLength() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.journal.count()
}

// JournalBytes reports how much memory this room's journal holds.
func (r *Room) JournalBytes() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.journal.bytes()
}

func (r *Room) Occupants() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.members)
}

// Hub holds every room on the server.
type Hub struct {
	mu    sync.Mutex
	rooms map[string]*Room
	// Who is waiting for a partner, per game. Kept apart from the main map,
	// because otherwise matchmaking would walk every room on the server under
	// this very lock — the lock that also guards creation and lookup by code.
	// Unnoticeable at two hundred rooms; at ten thousand it is a stalled
	// server.
	waiting map[string]map[string]*Room
	// The most rooms at once; see defaultMaxRooms.
	limit int
	// What the server counts as it goes. Held by value, so a hub built bare
	// in a test counts from zero with nothing to set up.
	stats stats
}

func NewHub() *Hub {
	return &Hub{
		rooms:   map[string]*Room{},
		waiting: map[string]map[string]*Room{},
		limit:   defaultMaxRooms,
	}
}

// waitingCount reports how many rooms of this game are waiting for a partner.
// It is the property the queue exists for: only waiters are in it, nobody
// else.
func (h *Hub) waitingCount(game string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.waiting[game])
}

// forget drops a room from the waiting queue. Called with the lock held.
func (h *Hub) forget(room *Room) {
	if queue, ok := h.waiting[room.Game]; ok {
		delete(queue, room.Code)
		if len(queue) == 0 {
			delete(h.waiting, room.Game)
		}
	}
}

func (h *Hub) Create(game string, seed uint32) (*Room, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.create(game, seed)
}

// create opens a room. Called with the hub's lock already held: matchmaking
// needs to open a room without letting go of it.
func (h *Hub) create(game string, seed uint32) (*Room, error) {
	if len(h.rooms) >= h.limit {
		return nil, errServerBusy
	}
	for attempt := 0; attempt < 100; attempt++ {
		code, err := generateCode()
		if err != nil {
			return nil, err
		}
		if _, taken := h.rooms[code]; taken {
			continue
		}
		room := newRoom(code, game, seed)
		h.rooms[code] = room
		return room, nil
	}
	return nil, errors.New("could not find a free code")
}

// Quick seats a player with whoever is already waiting, and if nobody is,
// opens a room and leaves them waiting instead. Returns the room and the slot.
//
// Search and seating are indivisible: apart they race, and two people pressing
// the button in the same instant find the same room, with the second refused
// as "full" while a live partner sits there. Lock order is hub, then room —
// the same as in sweeping, or it would deadlock.
func (h *Hub) Quick(game string, seed uint32) (*Room, *Member, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	// The queue is small: only waiters are in it. Dropouts are cleaned out
	// right here, one per encounter — enough to keep the walk short, and it
	// spares us a back-pointer from room to hub.
	for code, room := range h.waiting[game] {
		if !room.available() {
			delete(h.waiting[game], code)
			continue
		}
		member, err := room.Join()
		if err != nil {
			// The seat was taken meanwhile — look further rather than refuse.
			delete(h.waiting[game], code)
			continue
		}
		if room.Occupants() >= roomCapacity {
			delete(h.waiting[game], code)
		}
		if len(h.waiting[game]) == 0 {
			delete(h.waiting, game)
		}
		return room, member, nil
	}

	room, err := h.create(game, seed)
	if err != nil {
		return nil, nil, err
	}
	room.Public = true
	member, err := room.Join()
	if err != nil {
		return nil, nil, err
	}
	if h.waiting[game] == nil {
		h.waiting[game] = map[string]*Room{}
	}
	h.waiting[game][room.Code] = room
	return room, member, nil
}

// Find looks up a room of the same game: rooms of different games never mix,
// even if their codes happen to collide.
func (h *Hub) Find(game, code string) (*Room, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	room, ok := h.rooms[code]
	if !ok || room.Game != game {
		return nil, errNoSuchRoom
	}
	return room, nil
}

// Sweep removes rooms that have stood empty longer than the allotted time.
func (h *Hub) Sweep(now time.Time) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	removed := 0
	for code, room := range h.rooms {
		room.mu.Lock()
		empty := len(room.members) == 0 && !room.emptyAt.IsZero() &&
			now.Sub(room.emptyAt) > emptyRoomLifetime
		room.mu.Unlock()
		if empty {
			delete(h.rooms, code)
			h.forget(room)
			removed++
		}
	}
	return removed
}

func (h *Hub) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.rooms)
}

func generateCode() (string, error) {
	out := make([]byte, codeLength)
	limit := big.NewInt(int64(len(codeAlphabet)))
	for i := range out {
		n, err := rand.Int(rand.Reader, limit)
		if err != nil {
			return "", err
		}
		out[i] = codeAlphabet[n.Int64()]
	}
	return string(out), nil
}
