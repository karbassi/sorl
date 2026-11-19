# Panel v2: flow and state audit

An independent review of the README, the PNGs, `flow.html` and the current code, run before building. It lists every state, the gaps, the open decisions and the inconsistencies. Decisions made from it go into `README.md`; this file stays as the record.

**Validated:** a second, independent pass checked all 132 items against the code, PNGs, flow and README.
- 119 are valid, 12 partly valid, 1 can't be verified (B29, which is runtime behaviour), and 0 invalid.
- The partly valid items are corrected in place below and marked *(corrected)*.
- Section E adds issues the first pass missed.
- All 12 blockers stand.

**Line references:**
- `PE` means `Sources/Undertone/Player/PlayerEngine.swift`.
- `PC` means `Sources/Undertone/PanelController.swift`.
- `flow.html` numbers are file lines.

## A. State inventory

| # | State | Status |
|---|---|---|
| 1 | Nothing playing, first launch (Recent empty) | Missing. F5 always shows 2 recent rows. |
| 2 | Nothing playing, with history | Designed (F5) |
| 3 | Nothing playing, needing Saved or the full Recent list | Missing. F5 has no drawer or tabs. |
| 4 | Player at rest, playing | Designed (F1) |
| 5 | Player at rest, paused | Partial. Only the glyph swaps. |
| 6 | Player on hover or keyboard focus | Designed (F1b) |
| 7 | Player with no chapters | Partial (flow only) |
| 8 | Player for a live stream | Missing |
| 9 | After a video ends (repeat off, queue empty) | Missing |
| 10 | After Stop | Missing. There's no Stop control either. |
| 11 | Resolving a link (spinner or Cancel) | Missing |
| 12 | Buffering | Missing |
| 13 | Resolve or playback error | Missing |
| 14 | Notices (skipped an unavailable video, no Mix) | Missing |
| 15 | yt-dlp missing, outdated or broken | Missing |
| 16 | Relaunch with a restored queue or mid-video | Missing |
| 17 | ⌘V prompt, video | Designed (F6) |
| 18 | ⌘V prompt, playlist or Mix | Missing |
| 19 | ⌘V prompt while loading, or metadata unknown | Missing |
| 20 | ⌘V with junk, unsupported or unavailable links | Missing |
| 21 | ⌘V over the drawer, or on F5 | Partial (flow only): the paste map plays on F5 and adds in the drawer, with no PNG *(corrected)* |
| 22 | Up next, chapters and a queue | Designed (F2) |
| 23 | Up next, chapters and no queue | Missing |
| 24 | Up next from a playlist | Designed (G1) |
| 25 | Row hover | Designed (G2) |
| 26 | Row keyboard focus | Partial |
| 27 | Row being dragged | Partial (flow only) |
| 28 | Played expanded | Partial (flow only) |
| 29 | Link added | Designed (G3) |
| 30 | Paste field focused via + | Partial (flow only) |
| 31 | Paste field error | Missing |
| 32 | Row still resolving | Missing |
| 33 | Row unavailable or failed | Missing |
| 34 | After Clear | Designed (G4) |
| 35 | Playing, nothing queued | Designed (G5) |
| 36 | Long list, top and scrolled | Designed (G9) |
| 37 | Mix still loading in the queue | Missing |
| 38 | Saved | Designed (G7) |
| 39 | Saved, empty | Missing |
| 40 | Saved, current item marked | Missing |
| 41 | Recent | Designed (G8) |
| 42 | Recent, empty or after Clear | Missing |
| 43 | Toast with Undo | Designed |
| 44 | Toast stacking or replacement | Missing |
| 45 | Up next bar with nothing next | Partial (flow only): the bar prints "Nothing" *(corrected)* |
| 46 | Settings entry point | Missing |
| 47 | Dark Mode | Missing |
| 48 | Increase Contrast, Reduce Transparency | Missing |
| 49 | Short screen | Missing |
| 50 | Offline, with cached and uncached rows | Missing |
| 51 | Cache states (not cacheable, 0% delay, cached mid-stream, playing from file) | Partial |

## B. Gaps

### Blockers

1. **Next and Previous mean different things in different places.** F1 says "chapter", the mini player's ⏭ is always the next video, and in code a queue disables chapter-skip (PE:686). Media keys and hotkeys inherit whichever model is chosen.
2. **"Play now" for a playlist or Mix has no defined effect on Up next.** This covers F6, Saved and Recent rows, F5 and `undertone://play`.
3. **Clicking a Saved or Recent row has undefined side effects.** Unknown: whether the current item goes to Played, whether the queue is kept, and whether clicking mid-queue moves the rows above it into Played.
4. **Errors, notices, resolving and yt-dlp status have no place to appear** inside the fixed heights. A toast that disappears after 3.5s can't hold "brew upgrade yt-dlp" plus Copy and Recheck.
5. **No Stop, Settings or Quit control.** Also unknown: whether Stop empties the persisted queue, and what shows after it.
6. **F5 is a dead end.** With nothing playing you can't reach Saved or the full Recent list.
7. **Repeat has three states in code (off, all, one) and a binary toggle in the design.** This also makes G5's copy wrong when repeat is on.
8. **The row model lacks the data the design draws.** *(corrected)*
   - Queue entries already have `duration` (PlaylistEntry:7). The thumbnail can be derived from the video id (Track:69).
   - Saved and Recent store no kind, duration or "N videos", so they can't draw their trailing text without re-resolving.
   - Duplicate videos break SwiftUI `ForEach` identity, because `PlaylistEntry.id` is the video id.
   - Saved and Recent do *not* key on the raw URL for YouTube. They store the canonical `watch?v=` URL (MediaLink:60–67, PE:284, PE:382). Only non-YouTube links keep their raw URL.
9. **Relaunch is undefined:** what shows before yt-dlp runs, and what Play does on a restored item.
10. **⌘V per screen is inconsistent.** The README and flow disagree. The code only forwards ⌘V to a focused text field (selector at PC:453, forwarded at PC:462).
11. **F6 can't show a title and length instantly.** `warm()` resolves only YouTube videos, after about 700ms plus yt-dlp. F6 needs loading, unknown and failed states.
12. **The visual-check rule can't reach the new states.** No `undertone://` routes exist for tabs, F6, adding to the queue, Clear or toasts.

### Should

13. **Toasts only hold one Undo at a time.**
    - A second toast replaces the first, and the first Undo is lost.
    - Unknown: whether closing the panel, switching tabs or opening F6 dismisses a toast.
    - Unknown: whether ⌘Z works as Undo.
    - With VoiceOver, toasts need a longer timeout and to be announced.
14. **The panel can hide mid-drag or with a toast showing** (a click outside, a Space change). Unknown: whether the drag commits or cancels, and whether the Undo survives.
15. **The queue's source label goes stale.** "From SOUND ISLAND sets" stays after mixed adds, Clear then add, and removing every SOUND ISLAND row.
16. **The Played section is unspecified:** its row style, replaying a row, removing a row, a cap, whether it persists, whether Clear affects it, and whether Previous walks back into it.
17. **Queue and chapter boundaries:** Next on the last item, Previous on the first, and the 3-second restart rule.
18. **The state after the last video ends is undesigned.**
19. **Offline:**
    - In code, an uncached next item stops the queue with a network error.
    - Unknown: whether uncached rows dim.
    - F6 needs the network to resolve a link.
20. **A Mix or playlist still loading:** loading rows, the 500-entry cap (silent today), 0 entries, and the fallback notices.
21. **Cache states are incomplete:** not cacheable, the first-20-seconds delay, over 500MB, a failed download, a full disk, and a cached file deleted in Settings.
22. **Saving:** *(corrected)* the code can already save a playlist or Mix ("Save This Playlist/Mix", URLBar:136–140, PE:307), and the star saves the video heard inside a Mix (PE:281–286). v2 has no control for saving a playlist, so that is a regression. Unsaving the current item in G7 is still unknown.
23. **Recent:**
    - While a playlist plays, Recent records the playlist URL, but G8 shows individual videos.
    - Resuming a playlist from Recent restarts at video 1.
    - The date-group boundaries are undefined.
24. **Empty states:** first-run Saved, Recent and F5 copy.
25. **Keyboard:**
    - Plain ↑/↓ change volume today, which conflicts with moving between rows.
    - Esc must close things in order: F6, then the drawer, then the panel.
    - Undefined: Space on a focused row, the tab order, and tab-switching shortcuts.
    - *(corrected)* Showing hover controls on keyboard focus is already in the README, so it's not a gap.
26. **VoiceOver and colour:** *(corrected)*
    - Row labels and actions are already required by the README.
    - Chapter changes and toasts still need announcements.
    - The cache glyph's two states differ only by colour, which fails colour-blind sighted users. Its aria-labels differ, so VoiceOver is fine.
27. **Dark Mode, Increase Contrast and Reduce Transparency are undesigned.** The tokens are opaque light hex values, while the code uses Liquid Glass.
28. **Short screens:** `maxContentHeight` can drop to 160pt, below even the 304pt player. Unknown: which pinned areas shrink first.
29. **A status item hidden by a menu-bar manager** may misplace the panel for the hotkey and for `undertone://open`. *(Can't verify statically; test at runtime.)*
30. **The first click while the app is inactive.** *(corrected)* The hover fallback is already in the README; only the first-click behaviour is open.
31. **Live streams:** no duration, no position saving, no caching. An upcoming live event is classified as unavailable.
32. **Sleep, wake and AirPods disconnecting:** there's no handling in code and no "resuming" state.
33. **Play next order:** whether several Play next items stack first-in-first-out or last-in-first-out.
34. **Duplicates:** pasting what's already playing or already queued.
35. **Links with a timestamp:** a saved position beats `t=`. Should F6 say "from 1:30"?
36. **Private, deleted or age-restricted links:** errors in F6 and the paste field.

### Nice

37. Long titles squash the mini player's play button. Also RTL titles, and which text truncates first.
38. The accessibility text-size setting against fixed heights.
39. Videos over about 8.5 hours are never cached, so the glyph's "saved for next time" is false for them.
40. Reduce Motion for the drag lift, the row reflow and toasts.
41. Recent's size limit and pruning are never communicated.
42. Make clear that "no right-click menus" excludes the status item's own menu.

## C. Open decisions (with the auditor's recommendation)

1. **What F1's ⏮/⏭ do:** chapters first, then the next video once the chapters run out. Media keys do the same. The label becomes "Next" when a video has no chapters.
2. **Play now with a playlist or Mix:** it replaces Up next, with an Undo toast ("Replaced 21 in up next · Undo").
3. **Clicking a row mid-queue:** the rows above stay queued.
4. **Play now from Saved or Recent:** the current item goes to Played and the queue is kept. Playlists follow decision 2.
5. **Stop:**
   - A Stop button in the F1b footer.
   - Stop keeps Up next and shows F5 with an "Up next (21)" entry.
   - The media Stop key calls `stop()`.
6. **Settings and Quit:** a gear in the F1b footer, plus the status-item menu.
7. **Repeat:** keep off, all and one; the glyph shows "1" for repeat one.
8. **Speed:** global, with 5 steps (1×, 1.25×, 1.5×, 2×, 0.75×).
9. **⌘V:** in the drawer it adds to the end, with "Play next instead". On F5 it plays now. On Saved or Recent it switches to Up next and adds. Everywhere else it shows F6.
10. **Duplicates:** allowed, using a unique id per queue entry. Pasting what's already playing shows "Already playing".
11. **Errors:** the yt-dlp banner and persistent errors go in an inline row pinned under the player. Transient notices are toasts.
12. **Relaunch:** F1 comes back paused at the saved position. *(corrected)* Most metadata already persists in StreamCache and the AudioCache sidecars (AudioCache:14–17), so a new snapshot is only needed for the queue. Videos under 10 minutes save no position and come back at 0:00.
13. **Finished in Recent:** keep a finished flag. Resuming a finished item restarts it.
14. **The star while a playlist plays:** it saves the video. A "Save playlist" control goes in the Up next header.
15. **F1's title:** the video title. The current chapter becomes the subtitle.

## D. Inconsistencies

1. **Transport:** the labels and behaviour differ between F1, the mini player, the flow and the code.
2. **Repeat:** a tri-state in code, binary in the design.
3. **Speed:** *(corrected)* the preference type exists as the README says, but the code has only 1×, 1.5× and 2×, while the design has 5 steps.
4. **Recent:** *(corrected)*
   - G8 shows 9 items, which fits the code's cap of 10. The real question is how far back history should reach.
   - Positions are saved only for videos of 10 minutes or more.
5. **Finished items:** the position is forgotten when a video ends, so G8's gray bar has no data behind it.
6. **Recent stores the playlist URL,** not each video.
7. **Clear Recent:** immediate in code, with no Undo. The flow's Undo does nothing.
8. **Played and counts:**
   - F2 has no Played section and says "· 21"; G1 has one and says "· 21 left".
   - G3's count mixes sources under one label.
9. **Chapters:** "Chapter 3 of 14" is hardcoded, while only 4 rows are shown. Chapter-list overflow is unspecified.
10. **Title vs chapter:** F1's title reads like a chapter, and the chapter name has no slot in F1.
11. **The current item:** it is unmarked in G7, the star is unfilled even though the item is saved, and G3 uses the current-item colours for the newly added row.
12. **G4 copy** *(corrected)*: the PNG adds "Add a link, or pick something from Saved.", which the README lacks. G5's copy matches the README, but G5 lacks a Played section.
13. **G5 says playback stops** while the flow has repeat on.
14. **⌘V:** the README and the flow's paste map disagree.
15. **One gray ↓ glyph, two meanings:** "streaming" in the player, "downloaded" in rows.
16. **Cache copy:** the design has 2 states, the code has 4 plus non-cacheable cases.
17. **Settings has no per-item cache delete.**
18. **Panel surface:** the design uses opaque colours; the code uses Liquid Glass.
19. **Heights:** fixed in the README, but `PanelRoot` sizes to its content.
20. **The queue-wipe bug is broader than the README says:** playlist open, `stop()` and `shutdown()` all clear the queue.
21. **The star and the URL scheme save the video only,** yet G7 lists playlists. *(corrected)* The code can save a playlist through the Saved menu, which v2 removes.
22. **No mute state is designed,** though mute exists in code and in the URL scheme.
23. **The media Stop key pauses** instead of stopping.
24. **Clipboard prefill on open:** unknown whether v2 keeps it.

## E. Missed by the first pass (found during validation)

1. **Code bug: the Mix fallback keeps a stale queue (PE:356–369).**
   - When the Mix listing fails, or there's no Mix, `resolveAndPlay` runs without clearing the old `queue`.
   - Next, Previous and the "N / M" label then act on the previous playlist.
   - No Recent entry is recorded.
   - "Save This Mix" saves under the old queue's title.
2. **F1 and F2 disagree on what's next.** F1's Up next bar says "Target Demographic - Atmosphere", while F2's first queue row in the same state is "Sunday sessions vol. 4".
3. **The current item has two names:** "Brothers Vibe - Guy J" (F1, G8) and "no vocals deep house mix" (G7, F5).
4. **G7 shows + and × on the current item,** against the README's rule that the current item has no hover controls.
5. **F5's rows break the row rule:** their trailing text is "15:23" and "Mix", not a duration or "N videos".
6. **Another no-op Undo:** the flow's `addq` Undo does nothing.
7. **Played appears from nowhere:** F2 has no Played section, but its Clear leads to G4, which shows "Played (2)".
8. **⏭ with nothing next:** G4 and G5 show an active ⏭ in the mini player with nothing queued.
9. **Missing cache state:** a stream resolved within about 15 minutes of its URL expiring is never cached (PE:196).
10. **v2 drops features the code has.** These are regressions, not just gaps:
    - "Resume at…" labels in the current menus (AppSettings:76, URLBar:90)
    - Save playlist
    - the gear and Quit buttons
11. **The README's bug reference is imprecise:** `open(_ link:)` starts at PE:322, but `queue = nil` is at PE:336.
