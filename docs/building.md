# Building, checks and releases

How to build and test the game, run it from the source, make builds for every platform
and cut a release.

## Build and run

You need [Godot 4.7.2](https://godotengine.org/download/archive/).

```bash
export GODOT=/Applications/Godot.app/Contents/MacOS/Godot
"$GODOT" --path game -e                    # open the project in the editor
"$GODOT" --path game --headless --quit     # check that the project imports
```

Tests — together with the architectural boundary checks and the atlas verification:

```bash
./tools/test.sh
```

The first run on a machine downloads the server's Go modules, checked against
`server/go.sum`; after that they come from the module cache.

Sprites are rebuilt from their text sources:

```bash
cd tools && python3 gen_sprites.py
```

## Running the game

From the repository root (the `godot` symlink comes with `brew install --cask godot`;
the Godot project itself lives in `game/`):

| Command | What it does |
|---|---|
| `just run` or `godot --path game` | Run the game |
| `godot --path game -e` | Open the project in the Godot editor |
| `godot --path <path to game/>` | Run from any other folder |

A built application no longer needs Godot: `open "build/macos/BASE 13.app"` after
`./tools/build.sh`, or drag it into Applications.

## Builds

```bash
./tools/build.sh
```

Puts builds for Windows, macOS and Linux into `build/`. You need the Godot 4.7.2 export
templates — installed through `Editor → Manage Export Templates`, or by unpacking the
official `.tpz` into `~/Library/Application Support/Godot/export_templates/`.

The presets live in `export_presets.cfg` and are kept in the repository: without them
the build is not reproducible. They hold no secrets for desktop; when Android arrives,
the keystore passwords will live in environment variables, not in this file.

The macOS build is signed "to itself" but not notarized: Apple has not checked it, and
the system will say so. This is how you open it — System Settings → Privacy & Security →
scroll down to the message about the blocked application → "Open Anyway". Once per
application. Right-click → "Open" no longer works for this case on macOS 15 and newer.
Notarization requires a paid Apple account — that is subproject 4.

The web build lands in `build/web/` and works from any static host — threads are off, so
the host needs no special headers:

```bash
cd build/web && python3 -m http.server 8137
```

Open `http://localhost:8137/`. The address with `?selftest` runs the reference scenario
and prints the world hash on screen: it must match the desktop one, otherwise
cross-platform co-op is impossible. The same on desktop — `godot --path game -- --selftest`.

## The web build on a phone

The browser runs the game only from a secure origin, so a phone on the same Wi-Fi needs
https with a certificate it trusts:

```bash
just phone            # serve build/web over https on this Mac's Wi-Fi address, port 8443
just phone --build    # build the web version again first
```

The script prints the address to open and, for the first time only, how to install the
mkcert root certificate on the iPhone. Type the address with `https://` in full: Safari
opens an address with a port and no scheme over http, and the TLS server's reply is
downloaded as `document.txt`.

## Checks and publishing

Every push to any branch runs `./tools/test.sh` — the same run as locally: core
isolation, server neutrality, atlas and sound verification against the manifests, the Go
tests and all the GUT tests.

The image is **not** built on push. Publishing from every branch would fill up the
registry, and the package budget is zero with a hard stop: run out of space and a real
release will not go out either.

### Release

Cut by hand from `master`: Actions tab → "release" workflow → Run workflow. Two fields:
the version number without `v`, and what exactly to release.

| What | What happens | Why separate |
|---|---|---|
| `server` | Web build, image into the registry, image checked by running it | Ships often; makes no desktop exports |
| `desktop` | Builds for Windows, macOS, Linux, a `vX.Y.Z` tag, a release with attachments | Three exports with texture rebuilds — slow and expensive |
| `both` | Both of the above | |

Desktop builds are expensive and the backend has to be updated often — hence the split.
Only the desktop release places a git tag: that is what people download, while a server
version may go out more than once.

By hand rather than automatically, because a release is something you hand to someone,
and a human should decide when it is ready. A run from anything but `master`, or a
repeat of a version already taken, is rejected by the workflow itself.

```bash
docker pull ghcr.io/proshik/base13:0.1.0
docker run -p 27014:27014 ghcr.io/proshik/base13:0.1.0
```

| Image tag | When |
|---|---|
| `X.Y.Z` | a server release with that number |
| `latest` | the last one released |
| `sha-<commit>` | always — it shows exactly what is running on the server |

To build the same thing by hand:

```bash
just --list                   # every task in the project
just build                    # all four platforms
just build Web                # for the browser only
just build Windows Linux macOS
just image                    # web build and image
```

`just` is an index, not a dependency. The task bodies live in `tools/*.sh`, they are
called directly without it, and CI calls exactly those:

```bash
./tools/build.sh Web
./tools/image.sh
```

Godot and the export templates live in the run's cache: the templates weigh a gigabyte,
and downloading them every time takes longer than everything else put together.
