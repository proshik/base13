# The deployment image: the room server together with the game's files.
#
# The web build is made by Godot, and Godot is deliberately not here. Godot inside
# docker build would be a second binding to the engine version, living apart from
# project.godot and silently drifting away from it. Building the game is the job of what
# already knows how to build it; the image packs up the result. tools/image.sh knows the
# order of the steps.

# The build stage runs on the machine doing the building and cross-compiles for
# the target. Left to itself, docker would emulate the whole toolchain instead,
# and the Go compiler dies under QEMU: building for amd64 from an Apple Silicon
# machine failed with a runtime crash inside the garbage collector. Go with CGO
# off cross-compiles natively, so there is nothing to emulate in the first place.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
# There is not a single dependency, so there is no layer for downloading them either.
COPY server/ ./
# Declared as late as it can be, just above the one step that reads it: a new
# version has to rebuild the binary and nothing before it. Unset, the image says
# "dev", the same as a build made outside Docker, so a hand-built image is never
# mistaken for a release.
ARG VERSION=dev
# No CGO — otherwise the binary would drag in libraries that scratch does not have,
# and cross-compilation would need a toolchain for every target.
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /relay .

# The game's files are the same bytes for every architecture, so this stage has no
# reason to be emulated either.
FROM --platform=$BUILDPLATFORM alpine:3 AS game
COPY build/web/ /web/
# Fail clearly: an image without the game would build silently and look healthy, while
# a person would see an empty page and go looking for the cause in the server.
RUN test -f /web/index.html || ( \
      echo "ERROR: there is no web build in build/web." && \
      echo "First: ./tools/build.sh   (or ./tools/image.sh, which does both steps)" && \
      exit 1 )
# The engine is forty megabytes and ten in gzip. Compressed once here rather than per
# visitor: the server hands the twin to a browser that accepts gzip, the original to
# anyone else.
RUN for f in /web/*.wasm /web/*.pck /web/*.js; do gzip -9 -c "$f" > "$f.gz"; done

# No system and no shell: the server starts no subprocesses and makes no outbound calls.
FROM scratch
COPY --from=build /relay /relay
COPY --from=game /web /web
# Settings come from environment variables rather than baked-in flags: the image is the
# same for any machine, and it is the launch that differs.
#
# The address is deliberately not set here. If it were, it would override the PORT the
# hosting platform supplies, and the image would listen somewhere other than where it
# was placed. The default lives in the program, not in the image; it can be overridden
# with either PORT or ADDR.
ENV STATIC_DIR="/web"
# Only the public port. The metrics port is left out on purpose: `docker run -P`
# publishes every exposed port on all of the host's interfaces, and metrics must
# be published by hand, onto loopback.
EXPOSE 27014
ENTRYPOINT ["/relay"]
