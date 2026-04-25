# Gumball — Spec

macOS-only desktop app that watches the system "Now Playing" state and scrobbles to Last.fm.

## Problem

Last.fm scrobbling on macOS is broken/incomplete:
- No official Apple Music support.
- Spotify works only via Spotify's server-side integration; misses local files, AirPlay, browsers, anything not played in a Spotify client.
- Goal: one app, scrobbles whatever macOS thinks is playing.

## Goals

- Scrobble from any source feeding macOS Now Playing.
- Follow Last.fm scrobble rules: track > 30s, played for ≥50% of duration **or** 4 minutes (whichever first).
- Survive restarts without losing pending scrobbles.
- Optional: clean up bad metadata before commit.

## Non-goals (v0.1)

- Windows / Linux / iOS.
- Library, loved tracks, charts, recommendations, lyrics.

---

## Critical technical risk — MediaRemote post-macOS 15.4

Starting macOS 15.4, Apple added entitlement verification in `mediaremoted`. `MRMediaRemoteGetNowPlayingInfo` etc. are denied to non-Apple processes. **Calling MediaRemote directly from a third-party app is dead.**

Known workarounds:

| Approach | Viability |
|---|---|
| `mediaremote-adapter` (ungive) — bundled Perl script invoked via `/usr/bin/perl`, which is entitled (`com.apple.perl`). Streams JSON to stdout. | **Recommended.** No SIP changes. Used by `media-control` (brew) and Music Presence. |
| JXA / `osascript` polling | Works but no artwork, polling lag, no event subscription. |
| MediaRemoteWizard code injection | Requires SIP off. Not distributable. |

**MVP path: bundle `mediaremote-adapter`, spawn as subprocess, parse stdout.**

Risk acknowledgement: this loophole may itself close in a future macOS release. Code should isolate the Now Playing source behind an interface (`NowPlayingSource` protocol) so the underlying mechanism can be swapped without touching downstream logic.

The adapter's JSON output includes (selected): `bundleIdentifier`, `parentApplicationBundleIdentifier`, `playing`, `title`, `artist`, `album`, `duration`, `elapsedTime`, `timestamp`, `artworkData`, `artworkMimeType`, `isMusicApp`, `trackNumber`. The `parentApplicationBundleIdentifier` resolves the WebKit case (browsers report `com.apple.WebKit.GPU` as bundle; parent has the actual browser).

---

## Architecture

```
[mediaremote-adapter subprocess]
       ↓ JSON lines on stdout
[NowPlayingWatcher]
       ↓ NowPlayingEvent { title, artist, album, duration, position, playing, ts }
[ScrobbleStateMachine] — tracks one "current play"; emits NowPlaying ping + final scrobble
       ↓ enqueue
[Persistent queue (SQLite)]
       ↓ flush, batched up to 50
[Last.fm client] — signed POST, retry on codes 11/16, re-auth on 9
       ↓
last.fm
```

---

## Components

### 1. NowPlayingWatcher

- Spawn `mediaremote-adapter.pl stream <framework_path>`.
- Parse JSON line-by-line. Treat stderr as non-fatal logs.
- Respawn on exit with exponential backoff.
- Normalize to a single event struct; debounce repeated identical events.

### 2. ScrobbleStateMachine

State = current track + accumulated *playing wall-clock time*.

- New track event → close out previous track (decide: scrobble or drop), open new state.
- "Played" = wall-clock time in `playing=true` state. Do **not** trust `position` deltas (seeks lie).
- On track close:
  - `duration > 30` AND (`played >= duration/2` OR `played >= 240`) → enqueue scrobble.
- On new-track start, fire `track.updateNowPlaying` (best-effort, don't queue).
- Edge cases:
  - Replay of same track → separate scrobble per play.
  - Long pause → doesn't accrue play time.
  - App crash mid-play → unconfirmed plays are lost (acceptable; only commit confirmed).

### 3. ScrobbleQueue (SQLite)

- Rows: id, artist, track, album, album_artist, mbid, duration, ts, attempts, last_error.
- `pending` / `sent` / `permanently_failed` (e.g., bad-metadata ignored codes).
- Survives restart. Flushed on connectivity + on track end.

### 4. Last.fm client

- API key + shared secret embedded (acceptable per desktop auth flow).
- First-launch flow: `auth.getToken` → open browser → user authorizes → `auth.getSession` → session key stored in **macOS Keychain**.
- Request signing: sort params alphabetically, concat `<name><value>`, append secret, MD5.
- Batch scrobbles up to 50 per `track.scrobble` call. **Note**: with array notation, sort param names by ASCII (so `artist[10]` precedes `artist[1]`) when computing the signature.
- Retry policy: codes 11, 16 → backoff retry. Code 9 → re-auth. Other codes → mark `permanently_failed`, don't retry.
- Don't auto-apply corrections returned by `updateNowPlaying` — those are advisory.

### 5. Metadata cleanup (optional)

For garbage titles like `"Song (Official Video) [HQ]"`:

1. **`track.getCorrection`** (Last.fm) — cheapest first pass.
2. **MusicBrainz** `/ws/2/recording` — broader catalog, 1 req/s rate limit, requires `User-Agent` header with contact info.
3. Discogs — alternative.

UX rule: **never auto-rewrite scrobble metadata.** Show proposed correction; user confirms. Cache `(rawArtist, rawTitle) → confirmedCorrection` so each garbage title is asked once.

---

## Tech stack — decisions

| Decision | Choice | Notes |
|---|---|---|
| Language / framework | **Swift + SwiftUI** | Native menu bar / status item / floating window. macOS-only anyway. |
| Storage | **SQLite** (GRDB.swift) | Simple, persistent, batchable. |
| Background mode | **`LSUIElement = YES`** | Menu-bar only, no Dock icon. |
| Min macOS | **15.0+** | Adapter is the path on every supported version. No JXA fallback needed in v0.1. |
| Architecture | **arm64 only (Apple Silicon)** for v0.1 | Two-way door: flip `ARCHS` in build settings later for universal. Bundled adapter framework is already universal (x86_64 + arm64) — no upstream blocker. |
| Distribution | **GitHub Releases**, signed & notarized `.pkg` | Not App Store (private framework would block review anyway). Auto-update via Sparkle = post-v0.1. |
| Background launch | LaunchAgent (`SMAppService`) | Optional toggle in prefs. |

---

## v0.1 (MVP) scope

Menu-bar only, single user, scrobbles working end-to-end.

1. SwiftUI app, `LSUIElement = YES`, arm64, macOS 15+.
2. Bundled `mediaremote-adapter` (Perl script + framework + helper) as resources.
3. Last.fm desktop-auth flow on first launch; session key in **Keychain**.
4. `NowPlayingWatcher` → `ScrobbleStateMachine` → SQLite queue → Last.fm client, with retry.
5. Menu bar icon shows: current track (title / artist), today's scrobble count, auth state, "pause scrobbling" toggle, "open log", "preferences", "quit".
6. In-memory log of last 100 events viewable from menu (helps debug adapter quirks).
7. Code-signed and notarized `.pkg` published to GitHub Releases.

## v0.2 — metadata correction

- Manual confirm flow: candidate corrections via `track.getCorrection`, MusicBrainz `/ws/2/recording` as fallback.
- User confirms once per `(rawArtist, rawTitle)`; cached locally.
- **Never auto-rewrite** scrobble metadata.
- Surface the prompt in a popover from the menu bar item.

## Post-v0.2 / nice-to-haves

- **Per-app filter** — include/exclude by bundle ID using both `bundleIdentifier` and `parentApplicationBundleIdentifier`. UI: list of detected sources in preferences (e.g., `com.spotify.client`, `com.apple.Music`, `com.google.Chrome` resolved via parent) with toggles. Default-allow with deny-list. *This same primitive is the Spotify-dedup answer:* if user has Spotify's server-side Last.fm integration on, they toggle off `com.spotify.client` here.
- **Floating mini-player** — once Figma exists. Always-on-top window, album art + transport. Commands via `MRMediaRemoteSendCommand` (also exposed by the adapter).
- **Pre-scrobble edit panel** — quick edit before commit.
- **Stats view** — today / week counts, recent N tracks.
- **Universal binary** — flip `ARCHS` for Intel support if requested.
- **Auto-update** — Sparkle.

---

## Decisions (resolved)

| # | Topic | Decision |
|---|---|---|
| 1 | Distribution | GitHub Releases, signed & notarized `.pkg`. Not App Store. |
| 2 | Min macOS | 15.0+. |
| 3 | Architecture | arm64 only for v0.1. Universal is a build-flag flip later (two-way door). |
| 4 | UI surface in v0.1 | Menu bar only. Mini-player deferred (no Figma yet). |
| 5 | Metadata correction | v0.2, not v0.1. |
| 6 | Per-app filter / Spotify dedup | Same feature. Use `bundleIdentifier` + `parentApplicationBundleIdentifier` from adapter. Lands post-v0.2 with a preferences UI. |

---

## Suggested file layout

```
Gumball/
  Gumball/
    App.swift
    Sources/
      NowPlaying/
        NowPlayingWatcher.swift
        AdapterProcess.swift
        NowPlayingEvent.swift
      Scrobble/
        ScrobbleStateMachine.swift
        ScrobbleQueue.swift
      LastFM/
        Client.swift
        Auth.swift
        Signing.swift
        Models.swift
      Metadata/
        Corrector.swift
        LastFMCorrection.swift
        MusicBrainzCorrection.swift
      UI/
        MenuBarController.swift
        AuthWindow.swift
        LogWindow.swift
      Util/
        Keychain.swift
        Logger.swift
    Resources/
      mediaremote-adapter/      # bundled from ungive
  GumballTests/
```

---

## References

- mediaremote-adapter: https://github.com/ungive/mediaremote-adapter
- `media-control` CLI (brew): https://github.com/ungive/mediaremote-adapter (same repo, brew tap `ungive/media-control`)
- Rust bindings (alternative path): https://github.com/nohackjustnoobb/media-remote
- Last.fm scrobbling overview: https://www.last.fm/api/scrobbling
- Last.fm desktop auth: https://www.last.fm/api/desktopauth
- `track.scrobble`: https://www.last.fm/api/show/track.scrobble
- `track.updateNowPlaying`: https://www.last.fm/api/show/track.updateNowPlaying
- `track.getCorrection`: https://www.last.fm/api/show/track.getCorrection
- MusicBrainz API: https://musicbrainz.org/doc/MusicBrainz_API
- Apple Feedback FB17228659 (public API request): https://github.com/feedback-assistant/reports/issues/637
