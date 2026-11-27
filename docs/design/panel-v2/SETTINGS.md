# Settings in Panel v2: research and proposal

Research into how comparable menu bar apps handle Settings and Quit, and a proposal for Sorl. Status: proposal, awaiting the product owner's decisions on the open questions.

## Findings

| App / pattern | Entry point | Where settings open | Quit | Notes |
|---|---|---|---|---|
| Control Center modules | "… Settings" link at the bottom of a module | System Settings, a separate app | n/a | The module holds only live controls; configuration lives elsewhere. |
| Music MiniPlayer | Music › Settings ⌘, | Separate window | App menu | A regular app, not a menu bar accessory. |
| NepTunes | Icon menu | Separate preferences window | Icon menu | If the icon is hidden, relaunching opens preferences. |
| Bartender, Ice | Right-click or ⌥-click the icon | Separate window | Icon menu | Utilities with many settings. |
| Raycast | ⌘, (only while Raycast is showing), or the menu bar icon | Separate window | Menu bar icon | ⌘, works only while it's showing. |
| Fantastical | Gear at the bottom right of the mini window, or ⌘, | Separate window | ⌘Q | The gear opens an options menu. |
| Dropbox, Google Drive | Gear or avatar in the panel | Separate window | The same gear menu | The gear doubles as a menu holding Quit. |
| 1Password 8 | Menu bar item › Settings | The main app window | Icon menu | |
| Tailscale | Menu bar icon or app window | Inside the main window | ⌘Q asks: quit fully or stay in the menu bar | |
| Amphetamine, CleanShot X | Icon menu "Settings…" | Separate window | Icon menu | The classic pattern. |
| Itsycal | Gear under the calendar, ⌘, while showing, or right-click the icon | Separate window | Gear menu, ⌘Q, right-click | The closest analogue to Sorl. |

**Conventions**
- Apple's HIG puts Settings in the app menu with ⌘, and opens a settings window. It doesn't address menu bar extras.
- In an `.accessory` app, a SwiftUI `Settings` scene and `SettingsLink` are unreliable. Getting the window to the front needs activation-policy hacks, and `openSettings` failed on macOS 26.
- Sorl's panel also hides when it loses focus, so a separate window would close the panel anyway.

## Proposal: an in-panel Settings page

**Entry points**
- A gear in F1's hover footer, after volume.
- A gear at the top right of F5. First launch is when yt-dlp is most likely missing, and F5 has no footer.
- "Settings…  ⌘," in the status-item menu. Today it has only Open and Quit.
- `sorl://settings`, which already exists.

**Where it opens**
- The panel grows to the 560pt drawer height and swaps its content. Settings is not a fourth tab and not a separate window.
- The mini player stays pinned on top, so play/pause stays reachable.
- A "‹ Settings" header replaces the grabber and tabs, and the sections scroll.

**Getting back:** "‹" or Esc returns you to where you came from, either the player or the tab you were on.

**Quit**
- Pinned at the bottom of the Settings page, as "Quit Sorl".
- Also in the status-item menu and on ⌘Q.
- No power button on the player.

**⌘,:** handled in `PanelController.handleKey` while the panel is focused, the same way ⌘Q is caught today. Pressing it again closes Settings. There's no global hotkey.

**Tool problems**
- A missing, outdated or broken yt-dlp blocks playback, so it can't live only in Settings.
- Show the persistent banner (decision 11) under the player and on F5: "yt-dlp is out of date. Videos may not play.", then the `brew upgrade yt-dlp` command, Copy and Recheck.
- Add a small orange dot on the gear.
- Settings keeps the full diagnosis and the path override.
- Known snag: "Choose…" hides the panel, so after the file picker it must reopen on Settings.

## Layout (560pt; scroll area about 400pt)

```
┌──────────────────────────────────────────┐
│ [40] Brothers Vibe - Guy J       (▶)  ⏭ │ mini player, pinned
│      15:23 of 2:31:24                    │
├──────────────────────────────────────────┤
│ ‹  Settings                              │ header, pinned
├──────────────────────────────────────────┤
│ General                                  │
│ Open at login                      [◉ ]  │
│ Show the title in the menu bar     [ ◯]  │
│ (if needed) Approve in System Settings…  │
│                                          │
│ Updates                                  │
│ Check for updates automatically    [◉ ]  │
│ Check for updates            Check now   │
│ New versions come from GitHub. Sorl asks │
│ before installing one.                   │
│                                          │
│ iCloud                                   │
│ Sync Saved and shortcuts           [ ◯]  │
│ Keeps Saved and your shortcuts the same  │
│ on every Mac signed in to your iCloud    │
│ account. Turning it on merges this Mac's │
│ Saved with iCloud's.                     │
│                                          │
│ Keyboard shortcuts                       │
│ Play or pause                    ⌃⌥P     │
│ Next                             ⌃⌥→     │
│ Previous                         ⌃⌥←     │
│ Change speed                     ⌃⌥S     │
│ Show Sorl                   ⌃⌥Y     │
│ Media keys work without setup.           │
│                                          │
│ Downloads                                │
│ 340 MB of 2 GB         Delete downloads  │
│ Videos you play are kept so replays      │
│ start instantly and play offline.        │
│ → inline confirm: "Delete 340 MB?        │
│   Delete · Cancel" (can't be undone)     │
│                                          │
│ yt-dlp                                   │
│ ✓ yt-dlp 2026.10.22 · ready              │
│   /opt/homebrew/bin/yt-dlp   (gray mono) │
│   deno /opt/homebrew/bin/deno            │
│ Recheck · Choose… · Use default          │
├──────────────────────────────────────────┤
│ Sorl 0.4.0 (183)    Quit Sorl  │ pinned footer
└──────────────────────────────────────────┘
```

**Styling:** 32pt rows on white, with sentence-case section headers styled like the drawer's. Switches and shortcut recorders are aligned right, and links use the accent color.

**Updates:** Sparkle checks the appcast on the latest GitHub release once a day. When a check finds a newer version, the second row reads "Sorl 1.6.0 is available" and its button becomes "Install…", which opens Sparkle's window. In a build that can't update itself (no app bundle), the switch is disabled and the note reads "This copy of Sorl can't update itself. Install it from Homebrew or a release."

**iCloud note:** one switch, "Sync Saved and shortcuts", then a note that follows the sync status. The switch is disabled when this copy can't use iCloud. The layout shows the off state; the other notes are:
- Unavailable: "This copy of Sorl can't use iCloud. Install it from Homebrew or a release."
- Signed out: "Sign in to iCloud in System Settings to sync."
- Account changed: "Your iCloud account changed. Turning sync on again adds this Mac's Saved and shortcuts to the new account."
- Cloud data deleted: "Sorl's iCloud data was deleted. Turning sync on again uploads this Mac's Saved and shortcuts."
- Syncing: "Syncing…"
- Up to date: "Up to date" with a relative time.
- Errors: "You're offline. Sorl will sync when you're back.", "Your iCloud storage is full.", "Sign in to iCloud in System Settings to sync." or "Couldn't sync. Sorl will try again."

**Real settings**
- the 5 hotkeys
- Open at login
- iCloud sync (Saved and shortcuts)
- Show the title in the menu bar
- the yt-dlp path override

**Actions, not settings:** Delete downloads, Recheck, Choose… / Use default, and Approve in System Settings.

**Status only:** the cache size against the 2 GB cap, the yt-dlp and deno versions and paths, and the app version.

**Stays elsewhere:** speed, repeat, volume and the time toggle stay in the player. `idleUnloadSeconds` stays a hidden `defaults` key.

**Copy fixes:** the current code says "Next track", "Previous track", "Show track title" and "Tracks you play". Those become "Next", "Previous", "Show the title in the menu bar" and "Videos you play". "Cycle speed" becomes "Change speed". The section is named "Downloads" to match the "Downloaded · plays offline" glyph.

## Rejected

- **A separate Settings window:** it needs activation-policy hacks in a menu bar app, is flaky on macOS 26, and the panel closes when it loses focus anyway.
- **A fourth drawer tab:** Settings isn't content. It would crowd the tabs and be unreachable from F5.
- **A menu from the gear:** the design rules out menus in the panel, and shortcut recorders don't fit in a menu.
- **Swapping only the 304pt player:** the content doesn't fit.
- **Status-item menu only:** menu bar managers hide the icon, and there'd be no entry from the panel.
- **The power button on the player:** it puts a destructive action next to playback.
- **yt-dlp errors only in Settings:** playback would fail with no explanation.

## Decisions

1. **Gear on F1:** hover only, at the right end of the footer row after volume. When yt-dlp has a problem, a small orange dot shows at rest in the gear's spot. On F5 the gear is always visible, top right.
2. **Downloads limit:** a setting. "Keep up to" with a 1 / 2 / 5 / 10 GB segmented control, default 2 GB. Lowering it below current use removes the oldest downloads and says so in a toast.
3. **Quit:** no confirmation. The queue and position are saved.
4. **Page layout:** still a proposal; mocked as board S1 and in the flow for review. Sections are grouped cards (General, Keyboard shortcuts, Downloads). Downloads: usage bar with "Delete…" (inline confirm in the same row) and a "Keep up to" − 2 GB + stepper.
5. **yt-dlp has no section.** When it works, Settings says nothing; versions show on hover of the footer version. When it breaks, an orange card tops Settings ("Videos can't play right now", reason, the brew command with Copy, Check again) and the gear gets its dot. The path override becomes a hidden `defaults` key. This replaces the yt-dlp section in the layout above.
6. **yt-dlp and deno stay on Homebrew.** Not bundled or app-managed; error fixes show the brew command.

## Mock

- Board S1 in the design canvas; screen S1 in `flow.html` (gear on F1 or F5, or ⌘,).
- Working in the flow: switches, shortcut recording (click, type keys, Esc cancels), the limit picker, Delete downloads with inline confirm, Recheck/Choose…/Use default/Copy toasts, Quit toast, ‹ and Esc back.
- "Simulate: yt-dlp out of date" in the flow's action list shows the F1 dot and the Settings problem state.
- Screenshots: `screens/S1-Settings.png`, `screens/S1-Settings-problem.png`, `screens/F1b-Hover-gear.png`, `screens/F1-Resting-ytdlp-dot.png`.
- Not mocked yet: the persistent problem banner (decision 11), the Approve in System Settings row.

## Sources

https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
https://developer.apple.com/design/human-interface-guidelines/settings
https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items/
https://www.github.com/orchetect/SettingsAccess
https://mowglii.com/itsycal/help
https://manual.raycast.com/settings
https://flexibits.com/fantastical/help/shortcuts
https://help.dropbox.com/installs/desktop-application-overview
https://tailscale.com/blog/windowed-macos-ui-beta
https://iffy.freshdesk.com/support/solutions/articles/48000078454-amphetamine-101
https://www.macbartender.com/b3gettingstarted/bartender-preferences
