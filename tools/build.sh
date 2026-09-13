#!/usr/bin/env bash
# Game builds. Output lands in build/.
#
# By default everything is built; name what you need instead:
#   ./tools/build.sh                      all four
#   ./tools/build.sh Web                  browser only
#   ./tools/build.sh Windows Linux macOS  desktop only
#
# The split is not cosmetic: the desktop builds are three exports with a texture
# reimport, while the backend needs one web build. Releasing the server often,
# there is no reason to pay for all of it every time.
#
# Tests run first, and deliberately: there is no point shipping something
# broken, and catching a break after the builds are handed out costs more than
# catching it before.
set -euo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

PRESETS=("$@")
if [ ${#PRESETS[@]} -eq 0 ]; then
  PRESETS=(Windows Linux macOS Web)
fi

./tools/test.sh

# No associative arrays here, deliberately: they need bash 4, and the stock
# bash on macOS is 3.2 — the script would fail on its own machine.
dir_of() {
  case "$1" in
    Windows) echo windows ;;
    Linux)   echo linux ;;
    macOS)   echo macos ;;
    Web)     echo web ;;
    *) echo "unknown platform: $1" >&2; exit 1 ;;
  esac
}

pack_of() {
  case "$1" in
    Windows) echo "build/windows/base13.exe" ;;
    Linux)   echo "build/linux/base13.x86_64" ;;
    macOS)   echo "build/macos/BASE 13.app/Contents/Resources/BASE 13.pck" ;;
    Web)     echo "build/web/index.pck" ;;
  esac
}

# Only what is being built gets cleaned: otherwise building one platform would
# wipe its neighbour's output, and a release would ship without half of it.
for preset in "${PRESETS[@]}"; do
  rm -rf "build/$(dir_of "$preset")"
  mkdir -p "build/$(dir_of "$preset")"
done

for preset in "${PRESETS[@]}"; do
  echo "=== $preset ==="
  "$GODOT" --headless --path game --export-release "$preset"
done

echo "=== what came out ==="
find build -type f -size +0 -exec ls -lh {} \;

# Levels are plain text, not Godot resources: the export packs them only via
# include_filter. The filter was once forgotten, and the builds shipped without
# a single level. Every pack is checked for all thirty-five.
# Paths inside a pack carry no res:// prefix.
echo "=== levels in the packs ==="
packs=()
for preset in "${PRESETS[@]}"; do
  if [ "$preset" = "macOS" ]; then
    unzip -q -o build/macos/base13.zip -d build/macos
  fi
  packs+=("$(pack_of "$preset")")
done
for pack in "${packs[@]}"; do
  count=$(strings "$pack" | grep -cE '^levels/[0-9]{2}[.]lvl' || true)
  if [ "$count" -lt 35 ]; then
    echo "ERROR: $pack holds $count levels, expected 35"
    exit 1
  fi
  echo "$pack: $count levels"
done

# The room server ships as its own file alongside the builds. For another
# machine it is built the same way: GOOS and GOARCH pick the target.
if command -v go >/dev/null 2>&1; then
  echo "=== room server ==="
  (cd server && GOTOOLCHAIN=local go build -o ../build/relay .)
  ls -lh build/relay
  echo "for Linux: cd server && GOOS=linux GOARCH=amd64 go build -o ../build/relay-linux ."
else
  echo "Go is not installed — the room server was not built"
fi
