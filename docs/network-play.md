# Network play

How a two-player match over the network runs, how to read its figures, and how to test
it on two machines. The ways to meet a partner are in the
[README](../README.md#two-players); the server side is in [room-server.md](room-server.md).

## How a match runs

The game does not wait for the partner's keys. It guesses them — whatever the partner
held last — and when the real ones arrive and differ, it steps back a few ticks and
computes them again within one frame. Your own tank answers two ticks after the press.
The game stands only when the partner has been silent for longer than 200 ms: a hidden
tab, a dropped link, or a path too long for guessing to cover.

## Reading the `[net]` lines

If the game stutters, look at the `[net]` lines — they appear every five seconds in the
terminal, and in the browser in the developer console. `L` puts the same figures on
screen:

```
[net] 300 ticks in 5000 ms (norm 5000), speed 100%, stops 0 (longest 0 ms), frozen 0 (longest 0 ms), rollbacks 8 (deepest 8), resim 3 ms, skips 1, lead 9 against 6, longest frame 18 ms
```

- `stops` — times the game stood past those 200 ms for a moment, up to 150 ms: a path a
  little too long for guessing. These are the waits the server hears.
- `frozen` — stands longer than that: the partner's hidden tab, a dropped link. Shown
  here, not sent to the server as waits.
- `rollbacks` and `deepest` — how often a guess was wrong and how far back it had to go.
  On a path of about 110 ms to the server expect around eight ticks at the deepest.
- `resim` — what stepping back cost this machine over the five seconds.
- `skips` and `lead` — a side that got ahead of its partner lets one tick in twenty go
  until the two are level. When the partner is back from a stand, the lead the stand left
  is let go at once instead, before the picture moves again.
- `longest frame` — the longest this machine took over one frame. Far past a tick, the
  machine stood still: nothing was sent meanwhile, and the partner's screen saw the same
  gap a network would have made.

`frozen` means the partner went quiet; `stops` that keep coming mean the network. A speed
noticeably below a hundred with neither and a large `resim` means the machine cannot keep
up.

## A direct connection on the local network

A direct connection (`LAN HOST` / `LAN JOIN`) does without the server, but on macOS 15
and newer the system asks for local network permission on the first connection. Without
it the game will not find the partner, even though the port is open and the machines are
on the same Wi-Fi. The permission is granted in System Settings → Privacy & Security →
Local Network, and it is needed **on both machines**. Through a room there is no such
fuss at all.

## Testing on two laptops

The server comes up on one of them, and both clients go to it.

On laptop A:

```bash
ipconfig getifaddr en0        # your address, for example 192.168.1.20
cd server && go run . -addr=:27014
godot --path game             # in another window; the server is local, nothing to find
```

On laptop B:

```bash
curl http://192.168.1.20:27014/health  # first make sure the server is visible
godot --path game -- --relay=ws://192.168.1.20:27014/ws
```

Then: A picks `CREATE ROOM` and reads out the code, B picks `JOIN ROOM` and enters it.

If `curl` does not answer, the game is not the problem: either the machines are on
different networks, or `-addr=:27014` was replaced with `127.0.0.1`. If `curl` answers
but the game says `NO CONNECTION` with an address on screen, macOS did not let the
application onto the local network; the permission is in System Settings → Privacy &
Security → Local Network.

None of this fuss will be there once the server moves to a real machine on the internet:
then both sides dial out, and the local network has nothing to do with it.

