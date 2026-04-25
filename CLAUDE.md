# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Gumball** is a macOS-only menu-bar app (no Dock icon) written in Swift + SwiftUI. It monitors system Now Playing events via a bundled Perl adapter and scrobbles tracks to Last.fm.

- **Platform**: macOS 15.0+, arm64 only (universal is a build-flag flip later)
- **Entry point**: `Gumball/Gumball/App.swift`
- **Xcode project**: `Gumball/Gumball.xcodeproj`

## Build & Run

Open `Gumball/Gumball.xcodeproj` in Xcode. No CLI build, no package manager.

Before running, set these environment variables in the Xcode scheme (Run → Arguments → Environment Variables):
- `LASTFM_API_KEY`
- `LASTFM_SHARED_SECRET`

Credentials are stored in `~/.zshrc` (or equivalent) — not in the repo.

## Architecture

Data flows in a linear pipeline:

```
mediaremote-adapter subprocess (Perl + bundled C framework)
    ↓ JSON lines via stdout (AsyncStream)
NowPlayingWatcher  →  NowPlayingEvent
    ↓
ScrobbleStateMachine (actor)
    ├─ .nowPlaying  →  ScrobbleFlushService.updateNowPlaying (best-effort)
    └─ .scrobbleCandidate
    ↓
ScrobbleQueue (actor, SQLite)
    ↓ batch drain ≤50 rows every 30s
ScrobbleFlushService (actor)
    ↓ POST track.scrobble
Last.fm API
```

**`App.swift` / `AppDelegate`** owns the lifecycle: three concurrent loops (event processing, 5s housekeeping, 30s flush) plus the auth flow.

### Key modules

| Directory | Purpose |
|-----------|---------|
| `Sources/NowPlaying/` | Spawns adapter subprocess, parses JSON line-by-line, reconnects with exponential backoff |
| `Sources/Scrobble/` | State machine, SQLite queue, flush service |
| `Sources/LastFM/` | API client, desktop auth flow, session key + username storage |
| `Sources/Util/` | Keychain wrapper (Security framework, raw API) |
| `Sources/Debug/` | Menu bar popover (`GumballMenuBarCommands`), debug queue window (`DebugQueueView`), and `@MainActor` ObservableObject bridges — all in `DebugQueueView.swift` |

### Menu bar UI

`GumballMenuBarCommands` (280 px popover) has four sections: now-playing artwork + track metadata, playback controls, auth/pending status, and actions. Track title, artist, and album are clickable `LastFMMetadataLink` buttons that open the corresponding Last.fm page.

**Playback controls** use `PlaybackController`, which calls `MRMediaRemoteSendCommand` by `dlopen`/`dlsym`-ing `MediaRemote.framework` directly — separate from and simpler than the Perl adapter subprocess.

### Scrobble state machine

- Uses **wall-clock time** (`Date()`) to accumulate `playedSeconds`, not the adapter's `elapsedTime` — avoids seek jumps inflating play time.
- Eligibility: `duration > 30s AND (played ≥ duration/2 OR played ≥ 240s)`.
- Idle close: paused → 60s timeout, playing-but-eligible → 180s timeout.

### Last.fm signing

Parameters are sorted **ASCII order** before signing (so `artist[10]` sorts before `artist[2]`). This matches Last.fm's spec and matters for batch scrobble POSTs.

### Retry policy

- Error codes 11, 16 → backoff, increment attempts.
- Error code 9 → session invalid, clear Keychain key, re-auth.
- All others → permanently fail the row.

### Adapter subprocess

Bundled at `Resources/mediaremote-adapter/bin/mediaremote-adapter.pl` with a vendored `MediaRemoteAdapter.framework`. Spawned with `stream --no-diff --no-artwork` flags so every update is a full snapshot. The `NowPlayingSource` protocol isolates this dependency.

### Storage

- **SQLite**: `~/Library/Application Support/Gumball/gumball.sqlite3` — raw `import SQLite3` bindings, no GRDB.
- **Keychain**: session key at account `sessionKey`, username at account `username`, both under service `com.gumball.Gumball.lastfm`.

## Dependencies

No Swift Package Manager packages. All dependencies are Apple system frameworks (`Foundation`, `SwiftUI`, `AppKit`, `CryptoKit`, `Security`, `SQLite3`) plus the vendored Perl adapter.

## Reference docs

- `gumball-spec.md` — full technical spec, v0.1 MVP scope, v0.2+ roadmap
- `DEVLOG.md` — short-lived handoff notes; update this after each session
