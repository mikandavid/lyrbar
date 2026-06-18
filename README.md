# 🎵 Lyrbar

> Synced Spotify lyrics, live in your macOS menu bar.

`lyrbar` logs into your Spotify account, watches whatever you're playing (on any device — phone, desktop, web), and shows the current lyric line right in the menu bar. Click it to view full lyrics, control playback and device, and change lyrics providers/offset.

```
♪  I said ooh, I'm blinded by the lights
```

---

## ✨ Features

- 📝 **Synced lyrics in the menu bar** — the current line updates in real time.
- 🔐 **Spotify login** via OAuth (Authorization Code + PKCE — no client secret stored).
- 📖 **Full-lyrics popover** with album art, **play/pause · previous · next** transport, a scrubbable progress bar, auto-scroll highlight and **click-a-line-to-seek**. Opens already scrolled to the current line.
- 🎶 **"Up next" preview** — peeks at your Spotify queue and shows the next track right in the popover.
- 🔊 **Switch playback device** — lists your Spotify Connect devices (computer, phone, speaker…) and hands playback off to whichever you pick.
- 🔄 **Multiple providers** — [LRCLIB](https://lrclib.net) (primary) and NetEase (fallback). Wrong lyrics? **Try next match** cycles candidates; the provider is switchable.
- ⏱️ **Per-song offset slider** (±5 s) to nudge timing — the offset is remembered per track in the library, so a song you've tuned stays tuned next time.
- 📏 **Width slider** — macOS doesn't let an item claim the *entire* menu bar (it's shared and laid out from both sides), so lyrbar gives you a width slider (120–700 px) instead.
- ⌨️ **One-command control** from the terminal: `lyrbar on`.

---

## 📋 Requirements

- **macOS 13+** and the Swift toolchain (Xcode or Command Line Tools).
- **A free Spotify account.** (Playback control / seek needs Premium, like all of Spotify's Web API playback endpoints; lyrics display works on free.)

---

## 🚀 Setup (one time)

1. **Create a Spotify app** at <https://developer.spotify.com/dashboard> → *Create app*.
   - **Redirect URI** must be exactly:
     ```
     http://127.0.0.1:8888/callback
     ```
   - Under *APIs*, tick **Web API**. Save.
   - Copy the **Client ID**.

2. **Install + configure:**
   ```sh
   cd lyrbar
   ./bin/lyrbar install          # symlinks lyrbar onto ~/.local/bin (optional)
   lyrbar setup <your_client_id> # or do this from the menu bar item later
   ```

3. **Run it:**
   ```sh
   lyrbar on
   ```
   Click the menu bar item → **Log in to Spotify…** → approve in the browser.
   That's it — play something and the lyrics appear.

> You can also do the whole setup from the menu: the item shows *Set Spotify Client ID…* and *Log in to Spotify…* until you're connected.

---

## 💻 Commands

```
lyrbar on             build (if needed) and launch in the menu bar
lyrbar off            quit
lyrbar restart        restart
lyrbar status         show running + login state
lyrbar logs           tail the log
lyrbar build          rebuild the release binary
lyrbar setup <id>     save your Spotify Client ID
lyrbar login          (re)run the browser login
lyrbar logout         clear stored tokens
lyrbar warmup         bulk pre-fetch lyrics for your top/liked/recent songs
lyrbar install [dir]  symlink onto your PATH (default ~/.local/bin)
```

---

## 🎯 Using it

- **Left-click** the menu bar item → full-lyrics popover: album art + transport controls at the top, lyrics below, an *Up next* line, and the next-match / trash / device / provider / width / offset / quit controls in the footer. Click a lyric line (or scrub the progress bar) to seek. Transport (play/pause/skip) and device switching need Spotify Premium.
- **Right-click** (or ⌃-click) → menu: per-song offset slider, width slider, provider picker, *Try next match*, *Reload lyrics*, login/logout, quit.

---

## 🔧 How it works

- **Playback**: polls `GET /v1/me/player/currently-playing` every ~2 s for the true position, then extrapolates locally at 10 Hz so the highlight is smooth between polls. The offset slider is applied on top.
- **Lyrics**: LRCLIB `get` (exact signature match) + `search` (fuzzy, ranked by **title + artist similarity and duration**) yields candidates; NetEase is a fallback / alternative source. LRC timestamps are parsed into a sorted line list; the active line is found by binary search. Candidates whose script doesn't match the track (e.g. Chinese lyrics for an English song) are filtered out in Auto mode.
- **Offset**: the lyric offset applies only to the song that's playing and is stored per track in the SQLite library (an `offset_ms` column), so retuning a track once keeps it aligned every future play.
- **Pre-loading**: when a track starts, lyrbar reads your Spotify queue (`/v1/me/player/queue`) and pre-fetches lyrics for the next 2 tracks, so the words are ready the instant the next song begins. The same queue read feeds the popover's *Up next* preview.
- **Device switching**: reads `/v1/me/player/devices` and transfers playback with `PUT /v1/me/player` (`device_ids`) — the 🔊 button in the popover footer.
- **Persistent library**: every fetched lyric is cached **forever** in a SQLite database (`~/.config/lyrbar/lyrics.sqlite3`). Already-seen songs load instantly with no network. **Build lyrics library from Spotify…** (menu) or `lyrbar warmup` (terminal) bulk-pre-fetches lyrics for your top tracks (long/medium/short term ≈ last year), your full Liked Songs, recently played, the playlists you own, and your saved albums. (Followed/editorial playlists are skipped so a giant "This Is…" list doesn't flood your library.) *A complete year of play history isn't available via the Web API; a true year needs Spotify's GDPR "Extended streaming history" export.*
- **Trash wrong matches**: the 🗑 button (popover) or "Trash these lyrics" (menu) permanently rejects the current lyrics for that track — they'll never show again, and lyrbar will look for an alternative.
- **Idle auto-suspend**: after **10 minutes** with playback paused/stopped, lyrbar stops polling Spotify entirely. Click the menu bar item (or "▶︎ Resume syncing") to start again — it never auto-resumes.
- **Auth**: PKCE flow. A throwaway loopback HTTP server on `127.0.0.1:8888` catches the redirect. The refresh token lives in `~/.config/lyrbar/tokens.json` (mode `0600`); access tokens are refreshed automatically.

---

## 📁 Files & state

- Preferences (offset, width, provider, client ID): `com.lyrbar.app` defaults domain (`~/Library/Preferences/com.lyrbar.app.plist`).
- Tokens: `~/.config/lyrbar/tokens.json`.
- PID / log: `~/.config/lyrbar/`.

---

## ⚠️ Notes / limits

- "Fill the whole menu bar" isn't supported by macOS (`NSStatusItem` shares the bar and there's no API to claim all free space), so lyrbar uses a fixed width set by the **Menu bar width** slider (in the popover) while a track is playing, and collapses to just the ♪ glyph when nothing is playing. The item truncates long lines.
- If lyrics look wrong, use **Try next match** or switch the provider; you can also fine-tune timing with the offset slider.
