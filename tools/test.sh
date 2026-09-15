#!/usr/bin/env bash
set -euo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

./tools/check_core_isolation.sh
(cd tools && python3 gen_sprites.py --check)
(cd tools && python3 gen_sounds.py --check)

# The relay server: its own tests, in the same run. A local toolchain — the
# build must not fetch a compiler from somebody else's servers. The modules are
# fetched once, checked against go.sum, and come from the module cache after.
if command -v go >/dev/null 2>&1; then
  ./tools/check_server_neutral.sh
  # go.mod and go.sum are used exactly as committed. Allowed to fix themselves
  # here, an untidy or half-committed pair would pass on every push, because
  # the fix lands in a checkout that is thrown away, and fail for the first time
  # in the release's image build, which reads them as they are. -mod=readonly
  # is spelled out so a GOFLAGS from the environment cannot loosen it.
  (cd server && GOTOOLCHAIN=local go mod tidy -diff) || {
    echo "server/go.mod or go.sum is not tidy: run go mod tidy in server/ and commit both"
    exit 1
  }
  (cd server && GOTOOLCHAIN=local go test -mod=readonly -timeout 90s ./...)
  # The client tests need the binary: they stand a real server up and talk to
  # it for real. Otherwise the client-server seam would go unchecked — each
  # side green, and together they do not work.
  (cd server && GOTOOLCHAIN=local go build -mod=readonly -o ../.build/relay .)
else
  echo "Go is not installed — server tests skipped"
  rm -f .build/relay
fi

"$GODOT" --headless --path game --import >/dev/null 2>&1 || true
"$GODOT" --headless --path game -s addons/gut/gut_cmdln.gd \
  -gdir=res://tests -ginclude_subdirs -gexit
