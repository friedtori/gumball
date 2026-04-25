# Gumball

macOS menu-bar app (no Dock icon) that watches system “Now Playing” and (later) scrobbles to Last.fm.

This repo currently contains the **NowPlayingWatcher** + adapter subprocess plumbing only (no UI, no Last.fm yet).

## Requirements

- macOS 15+
- Apple Silicon (arm64)
- Xcode (to build the app bundle)

## Last.fm desktop auth (console-driven)

Set these environment variables in your Xcode scheme (Run → Arguments → Environment Variables):

- `LASTFM_API_KEY`
- `LASTFM_SHARED_SECRET`

On launch, Gumball will:

- call `auth.getToken`
- open the browser for user approval
- poll `auth.getSession` until authorized
- store the session key in **macOS Keychain** under service `com.gumball.Gumball.lastfm`

## Adapter bundling

Per spec, the app will spawn:

`/usr/bin/perl <bundled>/mediaremote-adapter.pl stream <framework_path>`

This repo includes a placeholder `Resources/mediaremote-adapter/` directory. Replace it with the real contents from the upstream `mediaremote-adapter` project:

- `mediaremote-adapter.pl`
- the adapter’s bundled `MediaRemote.framework` (or whatever framework path you intend to pass)

The Swift code expects these to be present in the app bundle resources at runtime.

