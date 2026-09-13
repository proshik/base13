#!/usr/bin/env bash
# Builds the deployment image: the web build plus the room server.
#
# Two steps together so the order need not be remembered: docker build cannot
# make the web build (Godot is deliberately kept out of the image), and without
# it the image is useless.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${TAG:-base13:latest}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed"
  exit 1
fi

# Through build.sh rather than a separate export: it runs the tests first, so
# the image cannot be built from a broken tree. Building an image by hand
# without checking anything used to be easy — and that is exactly how something
# broken ends up on a live server.
./tools/build.sh Web

echo "=== image ==="
docker build -t "$TAG" .

echo "=== check: the image comes up and answers ==="
# The port is given as a variable rather than a flag: that also exercises
# configuration coming from the environment — hosting platforms set PORT
# exactly this way.
name="base13-check-$$"
docker run -d --rm --name "$name" -e PORT=27014 -p 27099:27014 "$TAG" >/dev/null
trap 'docker stop "$name" >/dev/null 2>&1 || true' EXIT

for i in $(seq 1 40); do
  if curl -fsS --max-time 1 http://127.0.0.1:27099/health >/dev/null 2>&1; then
    echo "status: $(curl -fsS http://127.0.0.1:27099/health)"
    if curl -fsS --max-time 2 http://127.0.0.1:27099/ | grep -q "BASE 13"; then
      echo "the game page is served"
      if ! curl -fsS -o /dev/null -D - -H 'Accept-Encoding: gzip' \
          http://127.0.0.1:27099/index.wasm | grep -qi '^content-encoding: gzip'; then
        echo "ERROR: the engine is served uncompressed"
        exit 1
      fi
      echo "the engine is served compressed"
      echo
      echo "done: $TAG"
      echo "run it: docker run -p 27014:27014 $TAG"
      exit 0
    fi
    echo "ERROR: the server answers but does not serve the game page"
    exit 1
  fi
  sleep 0.25
done

echo "ERROR: the image came up but /health never answered"
docker logs "$name" 2>&1 | tail -20
exit 1
