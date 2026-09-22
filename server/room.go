package main

// Rooms and relaying. The server does not know what bytes pass through it:
// it sees members, a room code and the order of packets. That is exactly why
// it suits any next game equally well.

import (
	"crypto/rand"
	"errors"
	"math/big"
	"sync"
	"sync/atomic"
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
//
// At is when the room took a game packet to relay, from stamp, so the writer
// can tell how long it spent getting to the socket. A notice leaves it zero.
type outgoing struct {
	Text bool
	Data []byte
	At   time.Duration
}

// When the process started, as the moment every stamp counts from. Taken once
// and never written again.
var startTime = time.Now()

// stamp is the moment now, as time since the process started. Every queue holds
// 256 slots from the moment its member sits down, and a time.Time in each slot
// is 24 bytes where this is 8. startTime carries the monotonic clock, so a
// stamp never jumps with the wall clock. It is never zero either: zero is a
// slot nobody stamped.
func stamp() time.Duration {
	return max(time.Since(startTime), 1)
}

// Member is one occupant of a room. Sending goes through a channel rather
// than straight into the socket: a slow member must not hold up the rest.
type Member struct {
	Slot int
	Send chan outgoing
	// Both are written before the member goes into the room's map and never
	// after: a scrape reads them under the room's lock alone, and a write it
	// could not see coming would race it.
	client client
	stats  *stats
	// When the member last sent the game a packet, in Unix nanoseconds; zero
	// before the first. Written by the goroutine reading their connection and
	// read by the one reading their partner's, hence atomic.
	lastHeard atomic.Int64
}

// heard notes a game packet from the member.
func (m *Member) heard(at time.Time) { m.lastHeard.Store(at.UnixNano()) }

// quietFor is how long the member has sent the game nothing, or zero if they
// never sent anything.
func (m *Member) quietFor(now time.Time) time.Duration {
	at := m.lastHeard.Load()
	if at == 0 {
		return 0
	}
	return now.Sub(time.Unix(0, at))
}

// silence is a member who has sent the game nothing for a while.
type silence struct {
	slot int
	took time.Duration
}

// client is what a player's hello said about where they play from, already
// folded into labels. The strings a client sent are never kept: a member
// carries only what a scrape may render. The zero value is a client that said
// nothing, which renders as unknown.
type client struct {
	platform, version string
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
	//
	// Set before the room is in the hub's map and never after, so it is read
	// without the room's lock.
	Public  bool
	mu      sync.Mutex
	members map[int]*Member
	journal journal
	emptyAt time.Time
	// The hub's counts, set before the room is in the hub's map; nil in a room
	// built bare, which then counts nothing.
	stats *stats
	// When the room was opened. Like Public, never written once anyone else
	// can see the room.
	createdAt time.Time
	// The room's pair, under mu. paired is set the first time both seats fill
	// and stays set: a partner coming back after a drop is the same pair, not a
	// new one. pairedSince is when both seats last filled, and together adds up
	// every stretch they stayed full.
	paired      bool
	pairedSince time.Time
	together    time.Duration
	// Set the first time the journal turns a record away, under mu: past the
	// cap every packet is turned away, and the room is counted once, not once
	// per packet.
	journalCapped bool
	// Set the first time a player says the two worlds parted, under mu. Both
	// sides see the same moment and each says so, but it is one broken match.
	desynced bool
}

func newRoom(code, game string, seed uint32) *Room {
	return &Room{
		Code:      code,
		Game:      game,
		Seed:      seed,
		members:   map[int]*Member{},
		createdAt: time.Now(),
	}
}

// kind names the room for the metrics: quick for matchmaking's rooms, code for
// rooms opened to pass their code on.
func (r *Room) kind() string {
	if r.Public {
		return "quick"
	}
	return "code"
}

// state names where the room stands right now. Called under the room's lock.
// A single player is waiting only until the room's first pair: after that,
// they are waiting for a partner who was already there and dropped, which is
// a broken match rather than a quiet quick game.
func (r *Room) state() string {
	switch len(r.members) {
	case 0:
		return "empty"
	case roomCapacity:
		return "playing"
	}
	if r.paired {
		return "interrupted"
	}
	return "waiting"
}

// occupancyChanged keeps track of the room's pair. Called under the room's lock
// from every place a member comes or goes, with how many were seated before.
//
// The first time both seats fill is the pairing, counted with how long the room
// waited for it. Every time they stop being full, the stretch just ended is
// added to the time together: a player left alone until the partner comes back
// is playing with nobody, and a room standing empty even less so.
func (r *Room) occupancyChanged(before int) {
	after := len(r.members)
	switch {
	case before < roomCapacity && after == roomCapacity:
		now := time.Now()
		r.pairedSince = now
		if !r.paired {
			r.paired = true
			r.stats.roomPaired(r.kind(), now.Sub(r.createdAt))
		}
	case before == roomCapacity && after < roomCapacity:
		r.together += time.Since(r.pairedSince)
	}
}

// swept observes a room as the sweep removes it, under its lock. Only now is it certain
// that nobody is coming back: a room that ever held a pair reports how long it
// held one, and a room that never did reports how long it waited, up to the
// moment its last player gave up and left.
func (r *Room) swept() {
	if r.paired {
		r.stats.roomPlayed(r.kind(), r.together)
		return
	}
	r.stats.waitAbandoned(r.kind(), r.emptyAt.Sub(r.createdAt))
}

// noteDesync marks the room's match as desynced, and reports whether this call
// was the one that marked it: the room is counted once, by whoever says it
// first. A room that never held a pair had no match to part. Its desync is not
// noted and leaves the room unmarked, so a script that opens rooms only to say
// desync counts nothing, and a real one after a partner comes is still counted.
func (r *Room) noteDesync() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.paired || r.desynced {
		return false
	}
	r.desynced = true
	return true
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

// Join seats a member who said nothing about themselves.
func (r *Room) Join() (*Member, error) {
	return r.JoinAs(client{})
}

// JoinAs seats a member in a free slot and returns it. The slot matters: the
// order of players depends on it, and that order must match on both sides.
func (r *Room) JoinAs(c client) (*Member, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for slot := 0; slot < roomCapacity; slot++ {
		if _, taken := r.members[slot]; taken {
			continue
		}
		member := &Member{Slot: slot, Send: make(chan outgoing, 256), client: c, stats: r.stats}
		before := len(r.members)
		r.members[slot] = member
		r.emptyAt = time.Time{}
		r.occupancyChanged(before)
		return member, nil
	}
	return nil, errRoomFull
}

func (r *Room) Leave(member *Member) {
	r.mu.Lock()
	defer r.mu.Unlock()
	before := len(r.members)
	if current, ok := r.members[member.Slot]; ok && current == member {
		delete(r.members, member.Slot)
		close(member.Send)
	}
	r.occupancyChanged(before)
	if len(r.members) == 0 {
		// Not removed at once: whoever dropped out must have time to return.
		r.emptyAt = time.Now()
	}
}

// Silent lists the members other than self who have sent the game nothing for
// longer than `longer`, in slot order. One who never sent anything is not
// listed: a room that has just filled is not a room with a quiet side.
func (r *Room) Silent(self *Member, now time.Time, longer time.Duration) []silence {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []silence
	for slot := 0; slot < roomCapacity; slot++ {
		m, ok := r.members[slot]
		if !ok || m == self {
			continue
		}
		if took := m.quietFor(now); took > longer {
			out = append(out, silence{slot: slot, took: took})
		}
	}
	return out
}

// Broadcast appends the packet to the journal and sends it to everyone except
// the sender: the client already has its own input, and echoing it back is
// wasted traffic and confusion.
func (r *Room) Broadcast(from *Member, data []byte) {
	// One reading for every recipient, taken before the lock: a wait for the
	// room is the server's own delay as much as a slow socket is.
	at := stamp()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.journal.count() < maxJournal && r.journal.size()+len(data) <= maxJournalBytes {
		sender := -1
		if from != nil {
			sender = from.Slot
		}
		r.journal.append(sender, data)
	} else if !r.journalCapped {
		r.journalCapped = true
		r.stats.journalCapReached()
	}
	for slot, member := range r.members {
		if from != nil && slot == from.Slot {
			continue
		}
		select {
		case member.Send <- outgoing{Data: data, At: at}:
		default:
			// The queue overflowed — this member is hopelessly behind. Cutting
			// their connection is more honest than slowing the game for
			// everyone else.
			close(member.Send)
			before := len(r.members)
			delete(r.members, slot)
			r.occupancyChanged(before)
			r.stats.memberEvicted()
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
	// What the server counts as it goes, and the registry a scrape reads it
	// from. Every hub has its own, so a hub made in a test counts from zero.
	stats *stats
}

// NewHub is the only way a hub is made: a hub without its stats would have
// nowhere to count into.
func NewHub() *Hub {
	return &Hub{
		rooms:   map[string]*Room{},
		waiting: map[string]map[string]*Room{},
		limit:   defaultMaxRooms,
		stats:   newStats(),
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
	return h.create(game, seed, false)
}

// create opens a room. Called with the hub's lock already held: matchmaking
// needs to open a room without letting go of it.
//
// Whether the room is public is decided here, before the room is in the map, so
// nothing that finds the room ever sees it change. A scrape reads it without
// the room's lock, which is safe only for a field no one writes after that.
func (h *Hub) create(game string, seed uint32, public bool) (*Room, error) {
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
		room.Public = public
		room.stats = h.stats
		h.rooms[code] = room
		h.stats.roomCreated(room.kind())
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
	return h.QuickAs(game, seed, client{})
}

// QuickAs is Quick for a player whose hello said where they play from.
func (h *Hub) QuickAs(game string, seed uint32, c client) (*Room, *Member, error) {
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
		member, err := room.JoinAs(c)
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

	room, err := h.create(game, seed, true)
	if err != nil {
		return nil, nil, err
	}
	member, err := room.JoinAs(c)
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
//
// A room is observed as it goes, and only then. It leaves the map in the same
// pass, under the hub's lock, so no later sweep can find it and observe it
// twice; a room still standing may yet see its pair come back.
func (h *Hub) Sweep(now time.Time) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	removed := 0
	for code, room := range h.rooms {
		room.mu.Lock()
		empty := len(room.members) == 0 && !room.emptyAt.IsZero() &&
			now.Sub(room.emptyAt) > emptyRoomLifetime
		if empty {
			room.swept()
		}
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
