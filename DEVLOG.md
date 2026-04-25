# Gumball — dev handoff

Short-lived notes for **Cursor / Claude / Xcode** so the next session doesn’t guess. Commit updates when you switch tools or land a chunk of work.

## Current state

- macOS 15+ SwiftUI app, `LSUIElement`, arm64; Xcode project `Gumball/Gumball.xcodeproj`
- `NowPlayingWatcher` → bundled `mediaremote-adapter` (`bin/` + `build/MediaRemoteAdapter.framework`)
- `ScrobbleStateMachine` (wall-clock play time, scrobble eligibility, idle close rules)
- `ScrobbleQueue` (SQLite) under `~/Library/Application Support/Gumball/gumball.sqlite3`
- `ScrobbleFlushService` → `track.scrobble` POST (batches of ≤50), retry 11/16, re-auth 9, periodic + post-enqueue flush
- Last.fm: desktop auth (token + browser + `auth.getSession`), session key in **Keychain**; API key/secret via **env** only
- **No** menu bar UI yet (empty Settings for lifecycle)

## Secrets / where things live

- `LASTFM_API_KEY`, `LASTFM_SHARED_SECRET`: Xcode scheme **Environment Variables** (not in source)
- Session key: Keychain service `com.gumball.Gumball.lastfm`, account `sessionKey`
- Scrobble DB: Application Support `Gumball/gumball.sqlite3`

## Next (suggested)

- [ ] `track.updateNowPlaying` (optional best-effort per spec)
- [ ] Menu bar: status item, current track, auth state, log tail
- [ ] Optional: per-app scrobble filter, prefs UI

## Notes & gotchas

- If build breaks after switching IDEs, check `project.pbxproj` for duplicate UUIDs, target membership, and `OTHER_LDFLAGS` for `-lsqlite3` if `SQLite3` is used.
- Vendored adapter is large; future cleanup may gitignore `build/` and document a rebuild step—coordinate before stripping.

## Recent changes (log here)

- 2026-04-25 — `track.scrobble` + `ScrobbleFlushService` (env creds, Keychain session, queue drain / retries / idle-close enqueue to DB)
- 2026-04-25 — Temp debug: **Menu bar “Gumball”** + **Window “Scrobble queue (debug)”** (`QueueDebugBridge` + `fetchRecentForDebug`), auto-refresh ~3s
- 2026-04-25 — Menu bar now shows current track, Last.fm auth state, and pending queue count via `AppStatusBridge`
- 2026-04-25 — Fix Now Playing stale `Paused` state: adapter uses `stream --no-diff --no-artwork`; watcher also merges diff payloads if re-enabled later
- 2026-04-25 — Fix scrobble accounting: `ScrobbleStateMachine` uses receive `Date()` for wall-clock play time, not adapter media timestamps
- 2026-04-25 — Fix scrobble accrual on play→pause: add wall-clock delta whenever previous state was playing; emit candidate once threshold is reached; info-log close/drop reasons
- 2026-04-25 — Add best-effort Last.fm `track.updateNowPlaying` on `ScrobbleStateMachine.nowPlaying` output
