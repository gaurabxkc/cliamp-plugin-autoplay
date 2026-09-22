# cliamp-plugin-autoplay

Endless similar-track playback for [cliamp](https://github.com/bjarneo/cliamp), like Spotify's autoplay.

When your queue is about to run out, autoplay asks [Last.fm](https://www.last.fm) for songs similar to what's playing, finds them on Spotify, and queues them, so the music keeps going.

## Why Last.fm

Spotify removed its recommendations and related-artists APIs for apps registered after November 2024, so a cliamp setup with its own Spotify client ID can't ask Spotify what's similar. Last.fm's similarity data is free, needs only an API key, and covers music from everywhere.

## Example

What one top-up queues for a few different songs:

| Playing | Autoplay queues |
|---|---|
| Daft Punk – Get Lucky | Avicii – Wake Me Up · Breakbot – Baby I'm Yours · David Guetta – Titanium |
| Bad Bunny – Tití Me Preguntó | Daddy Yankee – Gasolina · KAROL G – LATINA FOREVA · Rauw Alejandro – Qué Pasaría... |
| Radiohead – Karma Police | Pixies – Where Is My Mind? · Foo Fighters – Everlong · The Smashing Pumpkins – 1979 |
| Burna Boy – Last Last | Fireboy DML – Peru · 1da Banton – No Wahala · Wizkid – Joro |

## Install

```sh
cliamp plugins install gaurabxkc/cliamp-plugin-autoplay
```

Already have it installed? Remove it first — `plugins install` will not overwrite an existing plugin:

```sh
cliamp plugins remove autoplay
cliamp plugins install gaurabxkc/cliamp-plugin-autoplay
```

Then add this to cliamp's `config.toml`. It lives beside the `plugins` folder cliamp just printed: `~/.config/cliamp/config.toml` on Linux and macOS, `%APPDATA%\cliamp\config.toml` (for example `C:\Users\you\AppData\Roaming\cliamp\config.toml`) on Windows — **not** `C:\Users\you\.config\cliamp`.

```toml
[plugins]
allowed_binaries = "cliamp"   # lets autoplay run `cliamp remote call`

[plugins.autoplay]
api_key = "your-last.fm-key"  # free, instant: https://www.last.fm/api/account/create
```

Restart cliamp and play a song from Spotify.

## Use

- It works on its own: when fewer than 5 songs are left, it fills the queue back up in one go (at least 3 songs at a time).
- **Ctrl+T** turns it on or off.
- To try it right away: `cliamp plugins call autoplay test "Artist" "Title"`
- To see what it is doing: `cliamp plugins call autoplay status`

## Settings

All optional, under `[plugins.autoplay]`:

| Key | Default | What it does |
|---|---|---|
| `keep` | `5` | Top up when fewer than this many songs are left |
| `add` | `3` | The minimum number of songs to queue each time |
| `enabled` | `true` | Start with autoplay on |
| `binary` | `cliamp` | Full path to cliamp, if it isn't on the player's `$PATH` |

## How it works

1. Last.fm `track.getSimilar` for the playing song. If that has nothing new, it falls back to similar artists' top tracks.
2. Candidates are mixed so one top-up doesn't come from a single artist, and anything played in the last hour is skipped.
3. Each one is looked up with `cliamp remote call provider.search`, then queued with `track.queue`.

Searching and queueing both happen inside cliamp with its own Spotify login. The plugin never reads your credentials.

## Troubleshooting

Start with `cliamp plugins call autoplay status`: it reports whether autoplay is on, whether the Last.fm key is set, which binary it calls, how many songs are ahead, and any wait it is in. Then check `plugins.log` in your cliamp config directory.

- `cannot run cliamp`: add `cliamp` (or the full path you set in `binary`) to `allowed_binaries`.
- `last.fm rejected the API key`: the key is wrong, or the account is suspended. Autoplay goes idle rather than asking again on every track; `status` shows `REJECTED` with Last.fm's own message. Get a key at https://www.last.fm/api/account/create, replace `api_key`, and restart cliamp.
- `config.toml` edits seem to do nothing on Windows: check the path. `%APPDATA%\cliamp\config.toml`, not `~/.config/cliamp`. `cliamp plugins call autoplay status` echoes the settings it actually loaded.
- Nothing is queued for some songs: Last.fm has no similar tracks for them, and autoplay tries again on the next song.
- Nothing happens right after you edit a playlist: a round that just ran holds a short cooldown, and one that found nothing waits 90s. Autoplay re-checks by itself when the wait ends.

## License

MIT
