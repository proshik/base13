#!/usr/bin/env bash
# The server knows nothing about the game's rules — that is its main property,
# not an accident: it is exactly why the same server will suit the next game.
# A property holds only while it is checked, or one day somebody adds "and here
# a tank fired" and takes away the thing this was built for.
#
# Tests do not count: there the game is named on purpose.
set -euo pipefail
cd "$(dirname "$0")/.."

# Words that name this game's content. The server may know about rooms,
# members, slots and bytes; a tank or a level it must not.
WORDS='tank|bullet|projectile|level|eagle|base13'
FOUND=0

for file in server/*.go; do
  case "$file" in *_test.go) continue;; esac
  if grep -inE "$WORDS" "$file"; then
    echo "^^^ $file knows more about the game than it should"
    FOUND=1
  fi
done

if [ "$FOUND" -ne 0 ]; then
  echo
  echo "The server must see only rooms, members and bytes."
  exit 1
fi
echo "server knows nothing about the game: clean"
