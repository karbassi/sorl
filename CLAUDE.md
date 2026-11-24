# Sorl

A macOS 15+ menu bar app (Liquid Glass on 26, popover material on 15) that plays the audio of YouTube and other yt-dlp sites. Formerly Undertone: `Sources/SorlCore/LegacyMigration.swift` moves an Undertone install's data on first launch. Brand rules (palette, glyphs, voice) live in `docs/brand/BRAND.md`.

## Repo

- `main` is the default branch. Each PR does one thing and merges with a merge commit.
- Releases are automatic: every PR merged into `main` gets a minor bump, a `CHANGELOG.md` section, a tag and a release (`auto-release.yml` → `release.yml`). Label the PR `major` or `patch` to change the bump, or `skip-release` to hold it for the next release. A hand-pushed `vX.Y.Z` tag still releases. `release.yml` builds `Sorl.zip` and attaches it to the GitHub release; the `sorl` cask lives in `karbassi/homebrew-tap`.
- The PR title becomes its line in `CHANGELOG.md` and the release notes, so write it as a user-facing change in plain English (e.g. "Play a link dropped on the menu bar icon").
- Label every PR when opening it: `patch` for a bug fix, no label (minor) for a new feature or visible change, `major` only when the maintainer asks, and `skip-release` for anything users can't see (CI, docs, CLAUDE.md, refactors, tests).
- Never edit `CHANGELOG.md` or push `v*` tags by hand; `auto-release.yml` owns both.

## Build and test

- Tasks live in `.mise.toml` (`mise tasks` lists them). Run `mise trust` once per new checkout or worktree.
- Tests: `mise run test` (pass-through: `mise run test -- --filter LinkParser`).
- Quick compile check: `swift build --product Sorl 2>&1 | grep -E "error|warning: " | grep -v Vendor`
- Install: `mise run install` builds, copies to `/Applications` and relaunches.

## Visual verification (required for every UI change)

A UI change is not done until it has been seen running. After `mise run install`, take screenshots of each state the change affects and show them to the reviewer.

- **Drive the app with its URL scheme**, via `/usr/bin/open "sorl://…"`. The full list is in `AppDelegate.handle(_:)`. Useful ones:
  - `sorl://mute`: a toggle. Mute before playing anything, and unmute when done.
  - `sorl://play?url=<percent-encoded URL>`
  - `sorl://open`: shows the panel.
  - `pause`, `next`, `seek?to=90`, `settings` and `close`.
- **Open the panel with `sorl://open`**, not by clicking the status item. A menu bar manager may hide the item.
- **Capture with peekaboo 4:** `peekaboo see --no-elements --mode screen --path /tmp/shot.png`. `peekaboo image` and `peekaboo list` were removed in v4.
- **Crop to the panel with `ffmpeg`**, for example `ffmpeg -y -i in.png -vf "crop=<width>:<height>:<x>:<y>" out.png`.
  - The panel sits at the top right, under its status item.
  - Look at the full shot first to find it, since the position depends on the display.
- **Cover every state the change touches:** for example streaming, cached and playing from cache; light and dark mode; and with and without chapters.
