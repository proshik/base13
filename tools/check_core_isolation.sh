#!/usr/bin/env bash
# Checks that core/ does not depend on the engine and uses no floats.
set -uo pipefail

fail=0

engine=$(grep -rnE '(^|[^A-Za-z_])(Input|Time|Engine|OS|ResourceLoader|FileAccess|SceneTree|Node2D|Node)[.(]|(^|[^A-Za-z_])(randi|randf|randomize|preload|load)[[:space:]]*\(|^extends[[:space:]]+(Node|Resource)' game/core/ 2>/dev/null)
if [ -n "$engine" ]; then
  echo "ERROR: core/ reaches into the engine:"
  echo "$engine"
  fail=1
fi

floats=$(grep -rnE ':[[:space:]]*float\b|->[[:space:]]*float\b|(^|[^A-Za-z_])float[[:space:]]*\(' game/core/ 2>/dev/null)
if [ -n "$floats" ]; then
  echo "ERROR: core/ uses float:"
  echo "$floats"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "core/ isolation: OK"
fi
exit $fail
