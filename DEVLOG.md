# Gumball — dev handoff

Short-lived notes for **Cursor / Claude / Xcode** so the next session doesn’t guess. Commit updates when you switch tools or land a chunk of work.

## Current state

- macOS 15+ SwiftUI app, `LSUIElement`, arm64; Xcode project `Gumball/Gumball.xcodeproj`
- `NowPlayingWatcher` → bundled `mediaremote-adapter` (`bin/` + `build/MediaRemoteAdapter.framework`)
- `ScrobbleStateMachine` (wall-clock play time, scrobble eligibility, idle close rules)
- `ScrobbleQueue` (SQLite) under `~/Library/Application Support/Gumball/gumball.sqlite3`
- Last.fm: desktop auth (token + browser + `auth.getSession`), session key in **Keychain**; API key/secret via **env** only
- **No** full `track.scrobble` sender, **no** menu bar UI yet (beyond empty Settings for lifecycle)

## Secrets / where things live

- `LASTFM_API_KEY`, `LASTFM_SHARED_SECRET`: Xcode scheme **Environment Variables** (not in source)
- Session key: Keychain service `com.gumball.Gumball.lastfm`, account `sessionKey`
- Scrobble DB: Application Support `Gumball/gumball.sqlite3`

## Next (suggested)

- [ ] Last.fm: `track.scrobble` batch + retry policy (11/16, re-auth 9)
- [ ] Wire queue drain after auth; mark rows sent / failed
- [ ] Menu bar: status item, current track, auth state, debug log tail

## Notes & gotchas

- If build breaks after switching IDEs, check `project.pbxproj` for duplicate UUIDs, target membership, and `OTHER_LDFLAGS` for `-lsqlite3` if `SQLite3` is used.
- Vendored adapter is large; future cleanup may gitignore `build/` and document a rebuild step—coordinate before stripping.

## Recent changes (log here)

- _Add one line per meaningful commit or handoff. Example: `2026-04-25 — Initial git + devlog; queue + lastfm auth skeleton`_
