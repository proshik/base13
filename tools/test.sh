#!/usr/bin/env bash
set -euo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

./tools/check_core_isolation.sh
(cd tools && python3 gen_sprites.py --check)
(cd tools && python3 gen_sounds.py --check)

# The relay server: its own tests, in the same run. A local toolchain and no
# network — the build must not depend on somebody else's servers.
if command -v go >/dev/null 2>&1; then
  ./tools/check_server_neutral.sh
  (cd server && GOTOOLCHAIN=local GOFLAGS=-mod=mod go test -timeout 90s ./...)
  # The client tests need the binary: they stand a real server up and talk to
  # it for real. Otherwise the client-server seam would go unchecked — each
  # side green, and together they do not work.
  (cd server && GOTOOLCHAIN=local go build -o ../.build/relay .)
else
  echo "Go is not installed — server tests skipped"
  rm -f .build/relay
fi

"$GODOT" --headless --path game --import >/dev/null 2>&1 || true
"$GODOT" --headless --path game -s addons/gut/gut_cmdln.gd \
  -gdir=res://tests -ginclude_subdirs -gexit
