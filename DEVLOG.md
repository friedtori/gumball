# Gumball — dev handoff

Short-lived notes for **Cursor / Claude / Xcode** so the next session doesn't guess. Commit updates when you switch tools or land a chunk of work.

## Current state (v0.5)

- macOS 15+ SwiftUI app, `LSUIElement`, arm64; Xcode project `Gumball/Gumball.xcodeproj`
- `NowPlayingWatcher` → bundled `mediaremote-adapter` (`bin/` + `build/MediaRemoteAdapter.framework`)
- `ScrobbleStateMachine` (wall-clock play time, scrobble eligibility, idle close rules)
- `ScrobbleQueue` (SQLite) under `~/Library/Application Support/Gumball/gumball.sqlite3`
- `ScrobbleFlushService` → `track.scrobble` POST (batches ≤50), retry 11/16, re-auth on code 9
- Last.fm: desktop auth, session key + username in **UserDefaults** (`lastfm.sessionKey`, `lastfm.username`); API key/secret via **env** only
- `ScrobbleSourceFilter`: browser + Spotify gated; duration ≤ 10 min (browsers) / 22 min (Spotify) = eligible; longer → `artist.getInfo` playcount ≥ 1 000
- `LastFMLoveService`: `track.getInfo` on every track switch → heart state; `track.love` / `track.unlove` from heart overlay on album art
- Menu bar popover: artwork + heart overlay (bottom-right, Last.fm red `#D51007`), full-width metadata links (no underline), playback controls, auth badge, pending count

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
