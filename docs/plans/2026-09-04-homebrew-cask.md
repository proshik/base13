# BASE 13: installation through Homebrew — implementation plan

**Goal:** `brew install --cask proshik/tap/base13` installs the game and it launches on the first double-click — with no trip to System Settings.

**Architecture:** The cask lives in this repository as the source of truth (`Casks/base13.rb`) and is copied into the separate `proshik/homebrew-tap` repository by the release workflow, which rewrites two lines in it: `version` and `sha256`. The same arrangement is already used by `devdeck` in that tap, so the tap keeps one shape for both projects.

**Tech Stack:** Homebrew Cask DSL (Ruby), GitHub Actions, the existing `release.yml`.

**Spec:** none. This is a bounded packaging task on top of the finished release flow, not a new subsystem; the decisions that needed a design are recorded in the sections below.

**Not in this plan:** notarization by Apple (subproject 4 — it needs a paid account), casks for other games, a Homebrew formula for the room server, publishing to homebrew-cask core.

## Global Constraints

- The cask token is `base13`; the tap is `proshik/homebrew-tap`, addressed as `proshik/tap`.
- The macOS release asset is `base13-<version>-macos.zip` and holds `BASE 13.app`. Both names are fixed by `game/export_presets.cfg` and by the `Pack the desktop builds` step in `release.yml`; changing either breaks the cask.
- The build is **universal** (`binary_format/architecture="universal"`), so the cask carries no `arch` and no `depends_on arch:`.
- The app is ad-hoc signed (`codesign/codesign=1`) and **not notarized**. Everything below follows from that.
- `./tools/test.sh` must stay green: this plan touches no game code, but the check is the same one.
- A commit after every task. Messages in English: `feat:`, `test:`, `chore:`, `docs:`.

## Why a postflight, and not caveats

Homebrew marks every download it fetches with `com.apple.quarantine`. For an app that Apple has not notarized, that attribute is exactly what produces "Apple could not verify BASE 13 is free of malware" and sends the person into System Settings → Privacy & Security → Open Anyway.

So a cask without further measures buys nothing: the fuss is identical to downloading the zip from the Releases page by hand. It was that fuss that made brew worth doing at all.

Homebrew has no per-cask way to turn quarantine off — there is no `quarantine:` stanza, only the `--no-quarantine` flag, which the person would have to remember and type. What a cask *can* do is `postflight`, where `appdir` and `system_command` are both available. Removing the one attribute there costs one line and makes the install genuinely one command.

Two boundaries on this:

- `xattr -dr com.apple.quarantine` deletes exactly one attribute. **Not** `xattr -cr`, which clears every extended attribute — that is what returned `Operation not permitted` when we tried it by hand on macOS 15, and it can strip attributes that have nothing to do with Gatekeeper.
- On macOS 15 modifying an app inside `/Applications` can require App Management permission for the calling program. If the postflight turns out to fail on a real machine, the fallback is the `caveats` text from Task 1 step 4 — it says the truth and asks for one command. Task 2 is where this gets settled, on a real install, and not before.

None of this is a way around Gatekeeper for someone else's software: it is our own app, in our own tap, signed by us. Notarization in subproject 4 removes the need for the stanza entirely, and it comes out then.

## File structure

| File | Responsibility |
|------|----------------|
| `Casks/base13.rb` | The cask, source of truth. Copied to the tap on release |
| `.github/workflows/release.yml` | A step that rewrites `version`/`sha256` in the tap and pushes |
| `README.md` | The install line people actually read |

---

## Gate: two things only the repository owner can do

Neither can be done from here, and Task 1 is the only task that runs before them.

1. **Make `proshik/base13` public.** Homebrew downloads the asset unauthenticated; against a private repository every `brew install` gets a 404.
2. **Create a token for the tap and put it in the secrets.** A fine-grained PAT, `Contents: read and write` on `proshik/homebrew-tap` only, added to `proshik/base13` as the secret `TAP_TOKEN`. `GITHUB_TOKEN` cannot be used: it has no rights in another repository.

Task 3 is written so that a missing `TAP_TOKEN` skips the step with a message instead of failing the release.

---

### Task 1: The cask, checked against a published desktop release

**Files:**
- Create: `Casks/base13.rb`

**Interfaces:**
- Consumes: the release asset `base13-<version>-macos.zip` of a published desktop release
- Produces: `brew install --cask ./Casks/base13.rb` installs a launchable `BASE 13.app`.

This task needs no token and no public repository: a cask can be installed from a local path, and the asset URL of an existing release is what gets checked. Everything that can be found out before the gate is found out here.

There is no release to check it against today. `v0.1.0` and `v0.1.1` were deleted on 2026-09-13 together with the history they were cut from, before the repository went public. Cut a desktop release first — Actions → `release`, target `desktop` — and `<version>` below is its number.

- [ ] **Step 1: Take the checksum of the published asset**

```bash
gh release download v<version> --repo proshik/base13 \
  --pattern 'base13-*-macos.zip' --output /tmp/base13-macos.zip --clobber
shasum -a 256 /tmp/base13-macos.zip
```

Through `gh` rather than `curl`: while the repository is private, an anonymous download of the asset is a 404.

Expected: the same digest GitHub shows for that asset on the release page. A mismatch means the download broke; repeat it rather than writing down what came out.

- [ ] **Step 2: Write `Casks/base13.rb`**

```ruby
# Homebrew Cask for BASE 13.
#
# This file is the source of truth. The release workflow copies it into the
# separate tap repo `proshik/homebrew-tap` as `Casks/base13.rb`, rewriting the
# `version` and `sha256` lines on the way.
cask "base13" do
  version "<version>"
  sha256 "<the digest from step 1>"

  url "https://github.com/proshik/base13/releases/download/v#{version}/base13-#{version}-macos.zip"
  name "BASE 13"
  desc "Battle City remake with two-player co-op over the network"
  homepage "https://github.com/proshik/base13"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "BASE 13.app"

  # The build is ad-hoc signed but not notarized, and Homebrew quarantines
  # everything it downloads. Without this line the first launch goes through
  # System Settings -> Privacy & Security -> Open Anyway — exactly the fuss the
  # cask exists to remove. We delete the one attribute, not all of them:
  # xattr -cr strips attributes that have nothing to do with Gatekeeper.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/BASE 13.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Godot/app_userdata/BASE 13",
    "~/Library/Saved Application State/com.proshik.base13.savedState",
  ]
end
```

The high score lives in `user://base13.cfg`, which Godot puts under `app_userdata/BASE 13` — hence the `zap` path. `brew uninstall` leaves it alone, `brew uninstall --zap` removes it; that is the behaviour people expect from both.

- [ ] **Step 3: Audit and install from the local file**

```bash
brew audit --cask ./Casks/base13.rb
brew install --cask ./Casks/base13.rb
```

Expected: the audit is silent or reports only style notes, and the install puts `BASE 13.app` into `/Applications`.

- [ ] **Step 4: Check the thing this whole task is for**

```bash
xattr -p com.apple.quarantine "/Applications/BASE 13.app" 2>&1
open "/Applications/BASE 13.app"
```

Expected: `xattr` says `No such xattr` and the game opens at the splash screen with no dialog.

If instead the quarantine attribute is still there, or the postflight failed with `Operation not permitted`, then the postflight route is closed on this machine. Do not fight it: replace the `postflight` block with honest caveats and say so in the report —

```ruby
  caveats <<~EOS
    BASE 13 is not notarized: Apple has not checked it. Homebrew quarantines
    downloads, so macOS blocks the first launch. Clear it once:

      xattr -dr com.apple.quarantine "#{appdir}/BASE 13.app"

    Or open System Settings -> Privacy & Security, scroll to the message about
    the blocked application and press "Open Anyway". Once per version.
  EOS
```

— and carry that decision into Task 4's README wording.

- [ ] **Step 5: Check that uninstall is clean**

```bash
brew uninstall --cask base13
ls -d "/Applications/BASE 13.app" 2>&1
```

Expected: `No such file or directory`.

- [ ] **Step 6: Commit**

```bash
git add Casks/base13.rb
git commit -m "feat: Homebrew cask for the macOS build"
```

---

### Task 2: Publish the cask to the tap by hand, once

**Files:**
- Create (in `proshik/homebrew-tap`): `Casks/base13.rb`

**Interfaces:**
- Consumes: `Casks/base13.rb` from Task 1
- Produces: `brew install --cask proshik/tap/base13` works for anyone.

The first publication is by hand deliberately. Task 3 automates a path that has been walked once and is known to work; automating an unproven one only makes the failure harder to read.

**Runs after the gate:** the repository must already be public, otherwise the download 404s and nothing is proven.

- [ ] **Step 1: Copy the cask into the tap**

```bash
git clone git@github.com:proshik/homebrew-tap.git /tmp/tap
cp Casks/base13.rb /tmp/tap/Casks/base13.rb
cd /tmp/tap && git add Casks/base13.rb && git commit -m "base13 <version>" && git push
```

- [ ] **Step 2: Install the way a stranger would**

```bash
brew untap proshik/tap 2>/dev/null || true
brew tap proshik/tap
brew install --cask base13
open "/Applications/BASE 13.app"
```

Expected: the tap is picked up, the download comes from the release, the game opens with no dialog.

`brew install --cask base13` resolves through the tapped cask; the full `proshik/tap/base13` form works too and is what the README shows, because it is unambiguous when several taps are present.

- [ ] **Step 3: Check that the version is visible**

```bash
brew info --cask base13
```

Expected: the version of that release, and the `From:` line pointing at the tap.

- [ ] **Step 4: Nothing to commit here**

The change lives in the other repository. Report to the owner that the cask is published and installs.

---

### Task 3: Update the tap from the release workflow

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `dist/base13-<version>-macos.zip` from the `Pack the desktop builds` step; the secret `TAP_TOKEN`
- Produces: after a `desktop` or `both` release the tap carries the new `version` and `sha256`.

The step goes **last**, after the release has been created. The cask points at a release asset: publish the cask first and anyone who installs in that window gets a 404 on a tag that does not exist yet.

- [ ] **Step 1: Add the step to the end of `release.yml`**

After `Tag and create the release`:

```yaml
      # The cask points at a release asset, so this goes after the release exists:
      # published earlier, it would send people to a tag that is not there yet.
      - name: Update the Homebrew cask
        if: inputs.target != 'server'
        env:
          TAP_TOKEN: ${{ secrets.TAP_TOKEN }}
          VERSION: ${{ inputs.version }}
        run: |
          if [ -z "$TAP_TOKEN" ]; then
            echo "TAP_TOKEN is not set — the cask was not updated, the release is fine"
            exit 0
          fi
          sum=$(sha256sum "dist/base13-$VERSION-macos.zip" | cut -d' ' -f1)
          echo "sha256 $sum"
          git clone --depth 1 \
            "https://x-access-token:$TAP_TOKEN@github.com/proshik/homebrew-tap.git" tap
          sed -e "s|^  version \".*\"|  version \"$VERSION\"|" \
              -e "s|^  sha256 \".*\"|  sha256 \"$sum\"|" \
              Casks/base13.rb > tap/Casks/base13.rb
          grep -E '^  (version|sha256) ' tap/Casks/base13.rb
          cd tap
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add Casks/base13.rb
          git commit -m "base13 $VERSION"
          git push
```

The whole file is copied from this repository rather than patched in place in the tap: the source of truth is here, and an edit made straight in the tap would be silently overwritten on the next release — better that it is overwritten predictably.

`grep` after `sed` is not decoration: a `sed` that matched nothing exits successfully, and without the print the tap would quietly receive the old version.

- [ ] **Step 2: Check the workflow parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('release.yml OK')"
```

Expected: `release.yml OK`.

- [ ] **Step 3: Check the sed against the real file**

Without a runner, on the local copy:

```bash
VERSION=9.9.9 sum=deadbeef
sed -e "s|^  version \".*\"|  version \"$VERSION\"|" \
    -e "s|^  sha256 \".*\"|  sha256 \"$sum\"|" \
    Casks/base13.rb | grep -E '^  (version|sha256) '
```

Expected: exactly two lines, with `9.9.9` and `deadbeef`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat: release updates the Homebrew cask in the tap"
```

- [ ] **Step 5: Check it on a live release**

The next `desktop` release verifies the step for real. Ask before cutting one — a release is something people are handed. Afterwards:

```bash
brew update && brew info --cask base13
```

Expected: the new version.

---

### Task 4: The install line in the README

**Files:**
- Modify: `README.md`

The person reading the README should not have to work out where the build is and what to do about Gatekeeper. Under `## Builds`, before the paragraph about the unsigned build:

- [ ] **Step 1: Add the section**

````markdown
### Installing on macOS

```bash
brew install --cask proshik/tap/base13
```

The tap holds the cask; the build comes from the release attached to the tag. An
update arrives with `brew upgrade --cask base13`, and `brew uninstall --zap
--cask base13` removes the high score along with the application.
````

- [ ] **Step 2: Reword the paragraph about the unsigned build**

It currently sends everyone into System Settings. That stays true for a build downloaded by hand, and stops being true for a brew install — say exactly that, so neither half reads as a lie:

```markdown
The macOS build is signed "to itself" but not notarized: Apple has not checked
it, and the system will say so. Installed through brew there is nothing to do —
the cask clears the download attribute that triggers the check. Downloaded by
hand from the Releases page it opens like this — System Settings → Privacy &
Security → scroll down to the message about the blocked application → "Open
Anyway". Once per application. Right-click → "Open" no longer works for this
case on macOS 15 and newer. Notarization requires a paid Apple account — that is
subproject 4.
```

If Task 1 step 4 fell back to `caveats`, the first sentence changes to name the one command instead of promising there is nothing to do.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: installation through Homebrew"
```

---

### Task 5: Stamp the bundle version at export time

**Files:**
- Modify: `.github/workflows/release.yml`

**Separable from the rest of the plan.** Nothing above depends on it, and Homebrew takes the version from the cask, not from the bundle. It is here because it is the same release flow and it is two lines.

`game/export_presets.cfg` carries `application/short_version="0.1.0"` and `application/version="0.1.0"` hard-coded. They are not updated by anything, so every future build reports 0.1.0 in Get Info while brew reports the real number. The discrepancy is the kind that gets noticed in a bug report and wastes an evening.

- [ ] **Step 1: Add the step before `Build`**

```yaml
      # The version in the preset is stamped rather than kept up to date by hand:
      # a forgotten edit means the app reports one number and brew another, and
      # the difference surfaces in a bug report rather than here.
      - name: Stamp the version into the export preset
        if: inputs.target != 'server'
        run: |
          sed -i -e "s|^application/short_version=.*|application/short_version=\"${{ inputs.version }}\"|" \
                 -e "s|^application/version=.*|application/version=\"${{ inputs.version }}\"|" \
                 game/export_presets.cfg
          grep -n 'application/version\|application/short_version' game/export_presets.cfg
```

The edit is not committed: it belongs to the build, and the repository keeps whatever was last released by hand.

- [ ] **Step 2: Check the sed locally**

```bash
sed -e "s|^application/short_version=.*|application/short_version=\"9.9.9\"|" \
    -e "s|^application/version=.*|application/version=\"9.9.9\"|" \
    game/export_presets.cfg | grep -n 'application/version\|application/short_version'
```

Expected: every occurrence shows `9.9.9`. Note that the macOS preset is not the only one with these keys — check which presets the `grep` reports and confirm that stamping them all is what you want.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "chore: release stamps the version into the export preset"
```

---

## Readiness

1. `brew install --cask proshik/tap/base13` installs the game on a machine that has never seen it.
2. The first launch shows no Gatekeeper dialog — or, if the postflight route turned out to be closed, the caveats name exactly one command and the README says the same thing.
3. `brew uninstall --cask base13` removes the application, `--zap` also removes the high score.
4. A `desktop` release updates the cask in the tap by itself, and a release without `TAP_TOKEN` still succeeds.
5. `./tools/test.sh` green — this plan changes no game code, and that is worth confirming rather than assuming.

What this does **not** close: Apple has still not checked the application. Anyone who downloads the zip by hand goes through System Settings, and that is honest in the README. The real fix is notarization, and it lives in subproject 4 because it needs a paid account.
