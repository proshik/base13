# Project tasks.
#
# A thin index over tools/: the bodies live in the scripts, and without just
# they still run directly. The build gains no new dependency — CI calls the
# scripts itself, not through just.

# List the tasks
default:
    @just --list

# Every check: core boundaries, server neutrality, atlases, sounds, Go, GUT
test:
    ./tools/test.sh

# Build the game: all four platforms with no arguments, or name the ones you want
build *platforms:
    # just build Web
    # just build Windows Linux macOS
    ./tools/build.sh {{platforms}}

# Web build and the deployment image, verified by starting it
image:
    ./tools/image.sh

# Regenerate content from its text sources
assets:
    cd tools && python3 gen_sprites.py && python3 gen_sounds.py

# Run the game
run:
    godot --path game

# Bring the room server up on this machine
serve:
    cd server && go run .

# Core boundary check only — the fastest of them all
isolation:
    ./tools/check_core_isolation.sh
