# Gumball — dev handoff

Short-lived notes for **Cursor / Claude / Xcode** so the next session doesn't guess. Commit updates when you switch tools or land a chunk of work.

## Current state (v0.9)

- macOS 15+ SwiftUI app, `LSUIElement`, arm64; Xcode project `Gumball/Gumball.xcodeproj`
- `NowPlayingWatcher` → bundled `mediaremote-adapter` (`bin/` + `build/MediaRemoteAdapter.framework`)
- `ScrobbleStateMachine` (wall-clock play time, scrobble eligibility, idle close rules)
- `ScrobbleQueue` (SQLite) under `~/Library/Application Support/Gumball/gumball.sqlite3`
- `ScrobbleFlushService` → `track.scrobble` POST (batches ≤50), retry 11/16, re-auth on code 9
- Last.fm: desktop auth, session key + username in **UserDefaults** (`lastfm.sessionKey`, `lastfm.username`); API key/secret via **env** only
- `ScrobbleSourceFilter`: browser + Spotify gated; duration ≤ 10 min (browsers) / 22 min (Spotify) = eligible; longer → `artist.getInfo` playcount ≥ 1 000
- `LastFMLoveService`: `track.getInfo` on every track switch → heart state; `track.love` / `track.unlove` from heart overlay on album art
- Menu bar popover: artwork + heart overlay (bottom-right, Last.fm red `#D51007`), full-width metadata links (no underline), playback controls, auth badge, pending count
- Options window: two tabs (`Options`, `Track History`); `Options` exposes menu background opacity plus a pinned popover debug window toggle via `@AppStorage`

## Secrets / where things live

- `LASTFM_API_KEY`, `LASTFM_SHARED_SECRET`: Xcode scheme **Environment Variables** (not in source)
- Session key + username: **UserDefaults** keys `lastfm.sessionKey`, `lastfm.username`
- Scrobble DB: `~/Library/Application Support/Gumball/gumball.sqlite3`

## Next (suggested)

- [ ] Prefs UI / per-app scrobble filter
- [ ] v0.2: metadata correction
- [ ] Move `DebugQueueView` window out of debug once stable

## Notes & gotchas

- If build breaks after switching IDEs, check `project.pbxproj` for duplicate UUIDs and `OTHER_LDFLAGS` for `-lsqlite3`.
- Vendored adapter is large; future cleanup may gitignore `build/` — coordinate before stripping.
- `ScrobbleSourceFilter` has per-source duration thresholds (`shortTrackCutoff` dict); Spotify is 22 min, browsers 10 min.
- `track.getInfo` requires `username` param for `userloved` to be populated; falls back to `nil` (heart greyed) if username not yet cached.

## Recent changes (log here)

- 2026-04-25 — v0.1 MVP: scrobble pipeline, Last.fm auth, debug queue window, menu bar status
- 2026-04-25 — Menu bar redesign: album artwork, playback controls, Last.fm badge + profile link, username persistence
- 2026-04-25 — Split `DebugQueueView.swift` → `MenuBarView.swift` + `DebugQueueView.swift`
- 2026-04-25 — Replace Keychain with UserDefaults for session key + username (eliminates launch auth prompts)
- 2026-04-25 — `ScrobbleSourceFilter`: browser/Spotify source gating with duration threshold + `artist.getInfo` validity check for long tracks
- 2026-04-25 — `LastFMLoveService` + heart overlay on album art (`track.getInfo` on track switch, `track.love`/`track.unlove` on tap)
- 2026-04-25 — UI polish: full-width metadata links, no underline on hover, heart at Last.fm red `#D51007`
- 2026-04-26 — Replaced Track History menu action with tabbed Options window; added background opacity slider for slit-scan menu background
- 2026-04-26 — Experimental menu background now horizontally carousel-scrolls album art before blur + Metal slit-scan shader
- 2026-04-26 — Added pinned popover debug window toggle; renders menu content in a normal window because `MenuBarExtra` dismissal is system-controlled
- 2026-04-26 — Pinned popover debug window uses SwiftUI Liquid Glass (`glassEffect`) with regular material fallback
- 2026-04-26 — Options exposes slit-scan background carousel speed: Slow 30s, Medium 20s, Fast 8s
- 2026-04-26 — Options exposes album-art background style: Blur, Slit-scan, or None
- 2026-04-26 — Album-art background crossfades from previous artwork on track changes instead of cutting
- 2026-04-26 — Background carousel scroll pauses while playback is paused and resumes from the same offset
- 2026-04-26 — Throttled background carousel redraws to 12 FPS and disables timeline updates while paused to reduce CPU
- 2026-04-26 — Moved background infinite scroll into Metal shaders with `fmod` looped sampling; SwiftUI now passes only a scalar offset
- 2026-04-26 — Split background shader order to scroll first, slit-scan second; pause scroll ticks when popover view disappears
- 2026-04-26 — Reordered background blur after fmod scroll pass to avoid looping blurred source edges as vignette seams
- 2026-04-26 — Background CPU pass: 8 FPS scroll ticks, Static speed option, Core Image pre-blur cache
- 2026-04-26 — Inset fmod-wrapped Metal sample coordinates by 0.5px to avoid edge seam artifacts in slit-scan
- 2026-04-26 — Background speed FPS now scales by setting: Slow 8 FPS, Medium 12 FPS, Fast 20 FPS; Options warns about resource use
- 2026-04-26 — Restored slit-scan as a separate Metal pass after scrollSample for morphing strips
- 2026-04-26 — Added 2px seam feather in Metal scrollSample to blend fmod wrap boundary before slit-scan
- 2026-04-26 — Increased Metal scrollSample seam feather to 16px for softer carousel wrap overlap
- 2026-04-26 — Seam feather now auto-disables when scroll speed is Static (duration 0)
- 2026-04-26 — Menu polish: stronger subtle album-art shadow; Options/Quit collapsed to trailing icon-only actions
- 2026-04-26 — Icon-only Options/Quit actions now match menu hover treatment with rounded highlight and foreground lift
- 2026-04-27 — v0.9: AOTY Liquid Glass chip, RYM/AOTY equal-width chips with hairline stroke, Sources/Debug → Sources/UI rename
- 2026-04-27 — Light mode: adaptive sat/contrast shader values, inner glow overlay (screen blend, light-mode only), hardcoded opacity 0.38L/0.55D
- 2026-04-27 — Last.fm badge isTemplate=true for adaptive color; "CONNECTED" small-caps label; Last.fm profile link moved to bottom action row
- 2026-04-27 — Layout: 16pt uniform inset, authStatusRow aligned to metadata leading edge, play/pause enlarged (22pt, 90% opacity)
- 2026-04-27 — Seamless scroll fix: sweep 2×width per cycle to complete full mirror period; maxSampleOffset doubled
- 2026-04-27 — sameImage uses tiffRepresentation to prevent double crossfade on play/pause events
- 2026-04-27 — Single-pass Metal shaders (scrollAndSlitScan, scrollAndColorAdjust) replace two-pass chain; FPS reduced: Slow 4, Med 8, Fast 15
