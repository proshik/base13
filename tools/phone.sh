#!/usr/bin/env bash
# The web build on a phone on the same Wi-Fi. A browser starts the game only from
# a secure origin — https, or localhost, which a phone is not — so the room server
# serves the build itself over TLS, with a certificate mkcert makes for this Mac's
# address. Nothing leaves the local network.
#
#   just phone            # serve what is in build/web, building it if missing
#   just phone --build    # build the web version again first
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8443}"

for tool in mkcert go; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is missing: brew install $tool"
    exit 1
  fi
done

ip="${PHONE_IP:-}"
if [ -z "$ip" ]; then
  ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
fi
if [ -z "$ip" ]; then
  echo "no Wi-Fi address found: set PHONE_IP=192.168.x.y"
  exit 1
fi

if [ "${1:-}" = "--build" ] || [ ! -f build/web/index.html ]; then
  ./tools/build.sh Web
fi

mkdir -p .build/phone
# Without JAVA_HOME: with it set, mkcert also checks Java's trust store and dies on
# a keytool with no keystore — before it writes the certificate we asked for.
if ! out="$(env -u JAVA_HOME mkcert -cert-file .build/phone/cert.pem \
    -key-file .build/phone/key.pem "$ip" localhost 127.0.0.1 2>&1)"; then
  echo "$out"
  exit 1
fi
(cd server && GOTOOLCHAIN=local go build -mod=readonly -o ../.build/relay .)

echo
echo "On the phone:  https://$ip:$PORT/"
echo "Speed check:   https://$ip:$PORT/?selftest"
echo
echo "First time only, so the phone trusts the certificate:"
echo "  1. AirDrop $(mkcert -CAROOT)/rootCA.pem to the iPhone"
echo "  2. Settings > General > VPN & Device Management: install the profile"
echo "  3. Settings > General > About > Certificate Trust Settings: turn it on"
echo
exec .build/relay -addr "$PORT" -static build/web \
  -tls-cert .build/phone/cert.pem -tls-key .build/phone/key.pem
