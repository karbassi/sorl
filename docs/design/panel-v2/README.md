# Panel v2 design

The redesigned menu bar panel: a calm player that reveals controls on hover, and a drawer with three tabs (Up next, Saved, Recent). This folder is the source of truth for building it in SwiftUI.

## What's here

- `flow.html`: a clickable, offline copy of the whole flow. Open it in a browser. It keeps playback state, so the star, chapters, queue rows, speed, repeat, the scrubber, the time toggle, + and × buttons, Undo and drag to reorder all behave as designed.
- `screens/*.png`: every screen at 2x. The filenames match the screen codes below.
- Live versions (owner-only links): the flow at https://claude.ai/artifact/RN4vZzV8WDs2AwBpg2avBm and the design canvas with every board at https://claude.ai/artifact/PNiaNmjwcELLvKeXZSNfD6

When the PNGs and `flow.html` disagree with this document, this document wins. When this document is silent, match `flow.html`.

## Screens

| Code | Screen | File |
| --- | --- | --- |
| F5 | Nothing playing. The first screen people see. | `screens/F5-nothing-playing.png` |
| F1 | Player at rest | `screens/F1-player-rest.png` |
| F1b | Player on hover or keyboard focus | `screens/F1b-player-hover.png` |
| F6 | ⌘V on the player: what should this link do? | `screens/F6-paste-prompt.png` |
| F2 | Drawer, Up next, video with chapters | `screens/F2-upnext-chapters.png` |
| G1 | Drawer, Up next from a playlist (no chapters) | `screens/G1-upnext-playlist.png` |
| G2 | Up next with one row hovered (grip + ×) | `screens/G2-row-hover.png` |
| G3 | Right after pasting a link into Up next | `screens/G3-link-added.png` |
| G4 | After Clear | `screens/G4-cleared.png` |
| G5 | Playing, nothing queued | `screens/G5-nothing-next.png` |
| G7 | Saved tab | `screens/G7-saved.png` |
| G8 | Recent tab | `screens/G8-recent.png` |
| G9 | Long Up next, at the top and scrolled | `screens/G9-long-list.png`, `screens/G9-long-list-scrolled.png` |
| G6 | Play now on a playlist or Mix replaced Up next (toast with Undo) | `screens/G6-play-now-replaced.png` |
| F7 | Problem banner under the player, mini player and on F5 | `screens/F1-banner-ytdlp.png`, `screens/G1-banner-failed.png`, `screens/F5-banner-ytdlp.png` |
| F7 | Problem banner board (F1 with the banner) | `screens/F1-banner-ytdlp.png` |
| S1 | Settings, and with a yt-dlp problem | `screens/S1-Settings.png`, `screens/S1-Settings-problem.png` |

**Status:** the decisions below are applied to the screens, `flow.html` and this spec (as of the F7/S1 pass). Where anything still disagrees, the Decisions section wins.

## Decisions

These were settled during design review. Don't reopen them without asking.

- **One home per job.** Playback controls live in the player. What's coming lives in the drawer. Cache status is a glyph by the time plus the faint band behind the scrubber. Deleting cached files lives in Settings.
- **Up next is an editable queue.** A pasted playlist or Mix is copied into it. Clear empties what's coming only, and what's playing keeps going. Clear always offers Undo.
- **No Stop button.** Pause covers it, and Quit ends playback. The media Stop key pauses. F5 (Nothing playing) appears only on first launch and after the last item finishes.
- **The queue survives relaunch.** On relaunch, F1 comes back paused at the saved position with Up next intact. Videos under 10 minutes save no position and come back at 0:00.
- **⌘V depends on where you are:**
  - Player (F1): shows the F6 prompt (Play now on Return, Play next, Add to end, Cancel on Esc).
  - Up next: adds to the end, and the toast offers "Play next instead".
  - Saved or Recent: switches to Up next and adds to the end.
  - F5: plays now.
- **The paste field in the drawer is one step:** paste and it's added to the end. The toast offers "Play next instead".
- **⏮ and ⏭ (the buttons, media keys and hotkeys) step through chapters first.** After the last chapter, ⏭ plays the next video. When a video has no chapters, the buttons are labelled Previous and Next and skip videos. The mini player's ⏭ follows the same rule.
- **Play now with a playlist or Mix replaces Up next,** with the toast "Replaced 21 in up next · Undo". This applies to F6, a Saved or Recent row, F5 and `sorl://play`. Play next and Add to end cover merging.
- **Clicking a row mid-queue** plays only that row. The rows above it stay queued.
- **Playing a video from Saved or Recent** moves the interrupted video to Played and keeps Up next as it is.
- **Duplicates are allowed in the queue,** so each entry needs its own id. Pasting the video that's already playing shows the toast "Already playing".
- **Repeat has three modes.** Clicking cycles off, then repeat all, then repeat one. Repeat one shows the `repeat.1` glyph, and the rest mark shows whichever mode is on.
- **Speed is global**, from 0.75× to 2× in 0.25 steps. Clicking the pill steps up (1, 1.25, 1.5, 1.75, 2, 0.75, 1). Option-click or scrolling on the pill steps down. Double-click resets it to 1×.
- **Errors:**
  - Problems that need action (yt-dlp missing or outdated, playback failed) get a slim banner row pinned under the player or the mini player (F7): 36pt, orange "!", one short line, one action ("Fix…" opens Settings; "Try again" retries). On F1 it sits above the Up next bar and the player grows 44pt while it shows; in the drawer it sits under the mini player and the list gives up the space; on F5 it tops the panel. While the banner shows, the gear's orange dot is hidden (the banner already says it).
  - One-off notices (a skipped unavailable video, no Mix found) are toasts.
- **Recent tracks finished items.** A finished item shows a full gray bar, and clicking it restarts it from 0:00.
- **The star means Saved,** and it always saves the video playing, even inside a playlist. It fills blue, and the toast says "Added to Saved · Undo". A "Save playlist" button in the Up next header saves the playlist or Mix (today's feature, kept).
- **F1's title is the video title.** The current chapter is the subtitle.
- **Settings lives in the panel (proposal, mocked as S1).** Reached by a hover-only gear on F1 (orange dot at rest if yt-dlp has a problem), an always-visible gear on F5, ⌘, and the status-item menu. The panel grows to 560 with the mini player pinned; ‹ or Esc goes back. The downloads limit is a setting (1 / 2 / 5 / 10 GB, default 2). "Quit Sorl" sits in its footer and quits without asking. Full spec in [SETTINGS.md](SETTINGS.md).
- **Neutral copy.** People play podcasts and any YouTube video, not only music. Say "video", never song or track. Say Mix only when the item really is a YouTube Mix.
- **No right-click menus.** Every row action is a visible hover control (and an accessibility action).
- **Fixed heights.** Player 304pt. With the drawer open, 560pt, or less if the screen is short (`maxContentHeight` in `PanelController`). Every tab uses the same height. Lists scroll inside. The panel never resizes per item or per tab.
- **The player is calm at rest.** It shows artwork, title, subtitle, the scrubber, the time and previous, play/pause and next. The rest fades in on hover or keyboard focus without moving anything.

## Interaction spec

### Player (F1, F1b)

- **At rest:** artwork 64pt, title, subtitle, scrubber (no knob), elapsed and remaining time, previous chapter, play/pause (52pt), next chapter, and the Up next bar.
- **On hover or focus,** by opacity only so the layout never shifts:
  - the star
  - −15s and +15s
  - the scrubber knob
  - the footer: speed pill, repeat button (off, all, one), volume, and the Settings gear
  - the + on the Up next bar
- **Rest marks:** at rest, any non-default setting shows as a small blue mark next to the time: the repeat glyph if repeat is on (with a small 1 for repeat one), the speed if it isn't 1×. They hide on hover, because the footer shows the real controls.
- **Time toggle:** clicking the remaining time switches between −time left and total time. The choice is remembered across videos and relaunches.
- **Cache glyph** by the time: "Streaming · 77% saved for next time", or "Downloaded · plays offline" (blue) when fully cached.
- **Speed pill:** click steps up through 1×, 1.25×, 1.5×, 1.75×, 2×, 0.75×, then 1×. Option-click steps down. Double-click resets to 1×. Tinted when not 1×.
- **Repeat button:** click cycles off, repeat all, repeat one (`repeat.1` glyph). The tooltip names the mode.
- **Subtitle:** the current chapter when the video has chapters, otherwise the playlist or source.
- **⏮ ⏭ labels:** "Previous chapter" / "Next chapter" when the video has chapters, "Previous" / "Next" when it doesn't. The mini player's ⏭ follows the same rule.
- **Up next bar:** a grabber with "Up next" and the next title. Clicking it opens the drawer.
- **The + on the bar** opens the drawer with the paste field focused. Its placeholder reads "Paste a link, then press Return".

### Drawer chrome (every tab)

- **Pinned top:** mini player (40pt artwork, title, "15:23 of 2:31:24", 36pt play/pause, next), then the grabber (click to close), then the segmented tabs, then the section header.
- **Pinned bottom on Up next:** the paste field ("Paste a link to add it", ⌘V hint).
- **The list scrolls between them.** A 36pt white fade sits at the bottom edge. A 28pt fade at the top edge appears once you scroll.
- **Toasts** are dark, sit just above the bottom pin, and carry at most one action (Undo, or Play next instead).

### One row component, used by every list

- **Layout:** a 32pt thumbnail (7pt radius), a one-line title, and on the right the trailing text.
- **Trailing text:** a duration for videos, "N videos" for playlists and Mixes, or "Now playing" for the current item.
- **Download glyph:** an 11pt glyph, gray, appears before the trailing text when the item is fully downloaded. Its tooltip is "Downloaded, plays offline".
- **Recent only:** a 3pt progress bar along the bottom of the thumbnail. It is blue for the position, and a full gray bar when finished; clicking a finished row plays it from 0:00.
- **Current item:** the title and trailing text are blue (#0a4fae) on a light blue row (#eaf2fd), and there's no hover controls.
- **Hover or focus:** the row gets a gray background (#f2f2f5), and the hover controls replace the trailing text in place. The row height never changes.
  - **Up next:** an × removes the row. A drag grip also appears over the thumbnail (45% black, white dots).
  - **Saved and Recent:** a + (blue) adds to the end of up next, and an × (gray) removes the row from Saved or Recent.
- **Clicks:**
  - **Click a row:** in Up next, it plays now; in Saved, it plays now; in Recent, it resumes at the saved position.
  - **+ on a playlist or Mix:** adds all of its videos ("Added 24 videos from SOUND ISLAND sets to up next · Undo").
  - **Every remove** shows a toast with Undo.
- **Reorder (Up next only):** drag the grip. Rows make room live, and the dragged row lifts with a shadow. Holding it near the list's edge scrolls the list. The keyboard way is Option+↑/↓, and focus stays on the row. The toast reads "X plays next" when it lands first, otherwise "Moved to 3 of 5".

### Up next tab (F2, G1, G3–G5, G9)

- **With chapters (F2):**
  - "In this video · chapter 3 of 14", then chapter rows. Each chapter row is a timestamp column (40pt) plus the chapter name.
  - The current chapter is highlighted.
  - Chapter names are their own, never the video title.
  - Clicking a chapter seeks there.
  - A divider follows, then "Then, from SOUND ISLAND sets · 21" + Save playlist + Clear (the header text truncates before the buttons do), then the queue.
- **Without chapters (G1):** "From SOUND ISLAND sets · 21 left" + Save playlist (shows "Saved" when it already is; click toggles, toast with Undo) + Clear, a collapsed "Played (2)" disclosure, then the queue.
- **Clear (G4):** "Nothing up next. What's playing now keeps going." plus the toast "Cleared 21 from up next · Undo".
- **Nothing queued (G5):** "Nothing up next. Playback stops when this video ends. Add a link below, or pick something from Saved."
- **Playing a queue row** moves the current video into Played. It also drops the chapters section if the new video has none, and updates every count.

### Saved tab (G7)

- **Header:** "Click to play. + adds to up next."
- **Contents:** one flat list mixing videos, playlists and Mixes.
- **Hover:** + and ×.

### Recent tab (G8)

- **Header:** "Click to resume. + adds to up next." with Clear (and Undo) on the right.
- **Groups:** Today, Yesterday, Earlier this week, Last week.
- **Rows:** thumbnail progress bars. The playing item says "Now playing".
- **Hover:** + and ×.

### F5 Nothing playing

- **Paste field:** "Paste a video, playlist or Mix link" with a Play button, then "Or press ⌘V anywhere in the panel."
- **Below it:** "Pick up where you left off", with two recent rows.

## Tokens (light mode as designed)

| Token | Value |
| --- | --- |
| Panel background | #f6f6f8 |
| Drawer surface | #ffffff, 16pt top radius, top shadow |
| Accent | #0a64d8 (current text #0a4fae, current row #eaf2fd) |
| Text | #1d1d1f, secondary #6e6e73, tertiary #8e8e93 |
| Hover row | #f2f2f5 |
| Segmented control track | #ebebef |
| Toast | #1d1d1f with #6cb0ff action |
| Radii | panel 22, drawer 16, rows 8, thumbnails 7 (40pt art 8, 64pt art 12) |
| Type | system font. Titles 13 semibold (player 14), rows 13, meta 11 with tabular numbers |

Dark mode was not designed. Derive it from system colors and check it with screenshots.

## SwiftUI component map

Build these as small views in `Sources/Sorl/Views/`, sharing styling through one `PanelStyle` (tokens above).

| Component | Used in | Notes |
| --- | --- | --- |
| `PanelStyle` | everywhere | colors, radii, fonts, row metrics |
| `HoverReveal` modifier | F1 | `.onHover` + `@FocusState` → opacity, with no fade under Reduce Motion. The panel is a non-activating `NSPanel`; if `.onHover` misses while the app is inactive, back it with an `NSTrackingArea` using `.activeAlways`. |
| `PlayerView` | F1 | composes the five below |
| `NowPlayingHeader` | F1 | artwork, title, subtitle, `SaveButton` (star) |
| `Scrubber` | F1 | track, cache band, knob (revealed on hover), elapsed, `RemainingTimeToggle`, `CacheGlyph`, `RestMarks` |
| `TransportControls` | F1 | previous/next chapter, ±15 (revealed), play/pause |
| `PlaybackFooter` | F1 | `SpeedPill`, `RepeatToggle`, volume (all revealed) |
| `UpNextBar` | F1 | grabber, next title, + (revealed) |
| `PastePrompt` | F6 | overlay card; Return, Esc |
| `MiniPlayerHeader` | drawer | 40pt artwork, title, time, play/pause, next |
| `DrawerTabs` | drawer | segmented control, Up next / Saved / Recent |
| `SectionHeader` | all tabs | bold label · count, trailing text button (Clear) |
| `ScrollingList` | all tabs | `ScrollView` + top and bottom edge fades; top fade keyed to scroll offset |
| `ListRow` | all tabs | the one row component; configured by `trailing` (duration, count, now playing), `downloaded`, `progress`, `isCurrent`, `hoverActions` ([.remove], [.add, .remove]), `reorderable` |
| `ChapterRow` | F2 | timestamp + name, current highlight |
| `PlayedDisclosure` | Up next | collapsed "Played (n)" |
| `InlineAddField` | Up next | pinned paste field |
| `EmptyListMessage` | G4, G5 | title + one line |
| `Toast` + `ToastCenter` | drawer, player | one at a time, auto-dismiss, one action |
| `UpNextTab`, `SavedTab`, `RecentTab` | drawer | compose the pieces above |

Each row needs `accessibilityActions` that mirror its hover controls (Remove, Add to up next, Move up, Move down), so nothing depends on a mouse.

## Model work the UI needs

The core types live in `Sources/SorlCore/`. Today `PlayQueue` is a read-only snapshot that only lives in memory. It holds at most 500 entries, and a Mix is capped at 50.

- **Mutable queue:** append, insert next, remove, move, and clear with undo. It is persisted so it survives relaunch.
- **Saved** (`SavedLinks`): add and remove with undo. The star toggles membership for the current item.
- **Recent** (`RecentLinks` + `PlaybackPositions`): position, finished, and date grouping. Add remove and clear with undo.
- **Preferences:** speed and repeat already exist (`PlaybackSpeed`, `RepeatMode`). Add "show total time".
- **Bug to fix:** `PlayerEngine.open(_ link: MediaLink)` (around `PlayerEngine.swift:322`) sets `queue = nil` before resolving, which wipes Up next when a new link opens.

## Suggested build order

Each step is its own PR targeting `personal`. Each UI step is verified per `CLAUDE.md` (screenshots via `sorl://` URLs and peekaboo).

1. `PanelStyle`, `ListRow`, `Toast`, `ScrollingList` (with a preview harness).
2. Drawer shell: `MiniPlayerHeader`, `DrawerTabs`, fixed height, `SectionHeader`.
3. Mutable, persisted queue + Up next tab (remove, reorder, clear + undo, paste field), plus the `open()` queue-wipe fix.
4. Saved and Recent tabs (+ / ×, resume, groups).
5. Player rest/hover (`HoverReveal`, rest marks, time toggle, `UpNextBar` +).
6. ⌘V paste prompt.
