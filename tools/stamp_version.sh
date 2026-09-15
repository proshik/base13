#!/usr/bin/env bash
# Stamps the game's own release version into game/project.godot, replacing the
# "0.0.0" that every other build honestly reports.
#
# Run by the release workflow, right before build.sh, once the version input
# has already been checked to look like N.N.N. ClientInfo reads this same
# value back out through ProjectSettings and puts it in the hello, so a
# released build's metrics carry the version it actually is.
#
# Invoked as `tools/stamp_version.sh VERSION` from the repository root, same
# as every other script here.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: tools/stamp_version.sh VERSION" >&2
  exit 1
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "ERROR: version \"$VERSION\" must look like N.N.N, for example 0.1.0" >&2
  exit 1
fi

PROJECT_FILE="game/project.godot"
if [ ! -f "$PROJECT_FILE" ]; then
  echo "ERROR: $PROJECT_FILE not found (run this from the repository root)" >&2
  exit 1
fi

# The "|| true" matters: grep -c exits 1 when nothing matched, and count=0 is
# exactly the case that must fall through to the error below, not abort here
# under set -e with no message at all.
count=$(grep -c '^config/version="[^"]*"$' "$PROJECT_FILE" || true)
if [ "$count" -ne 1 ]; then
  echo "ERROR: expected exactly one config/version line in $PROJECT_FILE, found $count" >&2
  exit 1
fi

# Written to a temp file and moved into place rather than edited in place:
# macOS's BSD sed wants "-i ''" and GNU sed wants "-i" alone, and there is no
# single spelling that satisfies both.
tmp=$(mktemp "${PROJECT_FILE}.XXXXXX")
sed "s/^config\\/version=\"[^\"]*\"\$/config\\/version=\"$VERSION\"/" "$PROJECT_FILE" > "$tmp"
mv "$tmp" "$PROJECT_FILE"

echo "stamped $PROJECT_FILE with version $VERSION"
