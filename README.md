# Gumball

macOS menu-bar app (no Dock icon) that watches system “Now Playing” and (later) scrobbles to Last.fm.

This repo currently contains **Now Playing** + **scrobble state machine** + **SQLite queue** + **Last.fm desktop auth** (no full scrobble sender / menu UI yet).

## Git + GitHub

Local git is initialized on branch `main`. To push to GitHub:

1. Create a new empty repository on GitHub (no README/license if you want a clean first push).
2. From this directory:

```bash
cd /path/to/Gumball
git remote add origin https://github.com/YOUR_USER/Gumball.git
git push -u origin main
```

Use SSH if you prefer: `git@github.com:YOUR_USER/Gumball.git`

**Do not commit** API keys or `LASTFM_*` secrets; use Xcode scheme env vars or a local `.env` that stays gitignored.

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

`Gumball/Gumball/Resources/mediaremote-adapter/` contains a vendored copy of the adapter (including `bin/mediaremote-adapter.pl` and a built `MediaRemoteAdapter.framework` under `build/`). The Swift code expects those paths in the app bundle at runtime.

If you trim the repo later, you can gitignore local CMake build outputs and document a one-step script to rebuild the framework—just keep the `.pl` + framework layout the app resolves.

