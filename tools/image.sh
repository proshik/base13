#!/usr/bin/env bash
# Builds the deployment image: the web build plus the room server.
#
# Two steps together so the order need not be remembered: docker build cannot
# make the web build (Godot is deliberately kept out of the image), and without
# it the image is useless.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${TAG:-base13:latest}"
# The version the image reports about itself. The server keeps only "dev" or
# N.N.N and reports anything else as "unknown", so a mistyped version is refused
# here, before minutes of tests and export, not by the check at the very end.
VERSION="${VERSION:-dev}"
version_shape='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
if [ "$VERSION" != "dev" ] && [[ ! "$VERSION" =~ $version_shape ]]; then
  echo "ERROR: VERSION \"$VERSION\" must be dev or look like N.N.N, for example 0.1.0"
  exit 1
fi

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
docker build --build-arg VERSION="$VERSION" -t "$TAG" .

echo "=== check: the image comes up and answers ==="
# The port is given as a variable rather than a flag: that also exercises
# configuration coming from the environment — hosting platforms set PORT
# exactly this way. Metrics get a listener of their own, on loopback only —
# the same shape a real deployment uses — and never on the public port.
name="base13-check-$$"
docker run -d --rm --name "$name" \
  -e PORT=27014 -e METRICS_ADDR=:27015 \
  -p 27099:27014 -p 127.0.0.1:27098:27015 \
  "$TAG" >/dev/null
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

      echo "=== check: the image carries its version ==="
      # The build argument travels through the Dockerfile into the linker, and
      # a slip anywhere on that path still builds: the image would simply call
      # itself "dev", and every release would look the same on a dashboard.
      if ! metrics="$(curl -fsS --max-time 2 http://127.0.0.1:27098/metrics)"; then
        echo "ERROR: the server is up but its metrics port does not answer"
        docker logs "$name" 2>&1 | tail -20
        exit 1
      fi
      build_info="$(printf '%s\n' "$metrics" | grep '^relay_build_info{' || true)"
      if [ -z "$build_info" ]; then
        echo "ERROR: the metrics port answers but has no relay_build_info line"
        docker logs "$name" 2>&1 | tail -20
        exit 1
      fi
      # The brace or comma before the name matters: a bare version= also
      # matches inside goversion=, and it would read the right label only for
      # as long as the labels happen to be written in their present order.
      got_version="$(printf '%s' "$build_info" | sed -n 's/.*[{,]version="\([^"]*\)".*/\1/p')"
      if [ "$got_version" != "$VERSION" ]; then
        echo "ERROR: the image reports version \"$got_version\" but was built as \"$VERSION\""
        exit 1
      fi
      echo "the image reports version $got_version"

      echo "=== check: metrics stay off the public port ==="
      # Exactly 404, not merely "not 200": a redirect or a password prompt
      # would still mean something on the public port claims /metrics.
      public_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
        http://127.0.0.1:27099/metrics || true)"
      if [ "$public_code" != "404" ]; then
        echo "ERROR: /metrics on the public port answered $public_code instead of 404"
        exit 1
      fi
      echo "the public port answers 404 for /metrics"

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
