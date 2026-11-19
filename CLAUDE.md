# Undertone

## Build and test

- Tasks live in `.mise.toml` (`mise tasks` lists them). Run `mise trust` once per new checkout or worktree.
- Tests: `mise run test` (pass-through: `mise run test -- --filter LinkParser`).
- Quick compile check: `swift build --product Undertone 2>&1 | grep -E "error|warning: " | grep -v Vendor`
- Install: `mise run install` builds, copies to `/Applications` and relaunches.

## Visual verification (required for every UI change)

A UI change is not done until it has been seen running. After `mise run install`, take screenshots of each state the change affects and show them to the reviewer.

- **Drive the app with its URL scheme**, via `/usr/bin/open "undertone://…"`. The full list is in `AppDelegate.handle(_:)`. Useful ones:
  - `undertone://mute`: a toggle. Mute before playing anything, and unmute when done.
  - `undertone://play?url=<percent-encoded URL>`
  - `undertone://open`: shows the panel.
  - `pause`, `next`, `seek?to=90`, `settings` and `close`.
- **Open the panel with `undertone://open`**, not by clicking the status item. A menu bar manager may hide the item.
- **Capture with peekaboo 4:** `peekaboo see --no-elements --mode screen --path /tmp/shot.png`. `peekaboo image` and `peekaboo list` were removed in v4.
- **Crop to the panel with `sips`**, for example `sips -c <height> <width> --cropOffset <y> <x> in.png --out out.png`.
  - The panel sits at the top right, under its status item.
  - Look at the full shot first to find it, since the position depends on the display.
- **Cover every state the change touches:** for example streaming, cached and playing from cache; light and dark mode; and with and without chapters.
