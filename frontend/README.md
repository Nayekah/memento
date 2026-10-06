# Memento Scoreboard

> Arcade-style live scoreboard for Memento practicums.

[Root README](../README.md) · [Backend Guide](../backend/README.md)

The scoreboard is a Vite, React, and TypeScript single-page app. Caddy serves
the built files from the `proxy` image, so there is no Node.js process in
production. It shows one practicum at a time, polls that practicum's
leaderboard endpoint, and reads its settings from `/config/config.json`, which
organizers can edit without a rebuild.

## Development

```bash
cd frontend
npm ci
mkdir -p public/config
cp config.example.json public/config/config.json
npm run dev
```

Open `http://localhost:5173/?mock` to use generated students: 130 when
`practicum` is `datalab`, 126 when it is `bomblab`. Mock data exists only in
development builds. Without `?mock`, the dev server proxies `/api` to `http://localhost:8067`; set
`VITE_API_PROXY` to use another backend.

```bash
npm run typecheck
npm test
npm run build
```

`public/config/` is ignored by Git, so local backgrounds and music stay out of
the repository.

## Configuration

In production, `config.json` and its media live in the directory mounted by
`SCOREBOARD_CONFIG_DIR` (default `backend/scoreboard-config`). The page reads
it on load and again every minute. Invalid fields fall back to defaults, and a
missing file shows the default title with no deadline, backgrounds, or music.

| Field | Meaning |
| --- | --- |
| `title` | Large heading, for example `Praktikum 1 II2130`. Also used as the browser tab title. |
| `motd` | Scrolling message of the day. |
| `deadline` | ISO 8601 time with an offset, for example `2026-10-16T13:00:00+07:00`. Omit it to hide the countdown. |
| `practicum` | The `id` of the one practicum to show. Unknown or missing values fall back to the first entry in `practicums`. |
| `pageSize` | Rows shown before VIEW MORE, 5 to 100 (default 20). |
| `refreshSeconds` | Leaderboard polling interval, 5 to 300 (default 15). |
| `practicums` | Known practicums, each with `id`, `endpoint`, and optional `name` and `scoreLabel`. Only the one selected by `practicum` is shown. |
| `backgrounds` | `src`, `pos` (CSS background position), and `credit`. |
| `music` | `title`, `artist`, and `src`. Tracks play in this order. |

Media paths are relative to the config directory, such as
`backgrounds/zeta.webp`, or absolute paths on the same origin. URLs on other
hosts are ignored on purpose, because students reach the page through the exam
network. Endpoints must be same-origin paths.

To move from Praktikum 1 to Praktikum 2, change `title`, `deadline`, and
`practicum` (for example to `"bomblab"`) and save. Open pages pick it up within
a minute.

A practicum whose endpoint returns 404 or 501 shows "THIS PRACTICUM HAS NO
SCOREBOARD YET". The backend currently serves only `GET /api/v1/leaderboard`
for Data Lab, so `bomblab` stays in that state until a Bomb Lab endpoint
returns the same `{"entries": [{"rank", "name", "score", "max_score"}]}`
shape.

### Preparing media

Use 1920-pixel WebP backgrounds and 128 kbps MP3 music:

```bash
magick original.png -resize 1920x -quality 78 backgrounds/name.webp
ffmpeg -i original.flac -vn -map_metadata 0 -c:a libmp3lame -b:a 128k music/name.mp3
```

Background art and music are usually copyrighted. Credit the artist in
`credit` and do not commit the files.

## Behaviour

- The countdown turns amber below ten minutes, flashes red below one minute,
  and shows TIME UP at the deadline. Scores stay visible.
- Searching covers every student, not only the visible rows. An exact name
  match is remembered as "you": the HUD and a pinned strip show your rank, and
  the strip jumps to your row.
- Rank changes since the previous poll show as `+n` or `-n`, and changed scores
  flash.
- Every page load picks a random background and a random starting track; the
  playlist then continues in config order.
- Music is off until someone presses play, and no audio is downloaded before
  that. A time slider shows elapsed and total time and seeks within the track
  once it has loaded. A track that fails to load is skipped.
- Volume, shuffle, the collapsed player, and the remembered name are stored in
  the browser only.

| Key | Action |
| --- | --- |
| `H` | VIEW ART hides the scoreboard; VIEW SCORES or `Esc` brings it back |
| `B` | Random background |
| `M` | Play or pause music |
| `N` / `P` | Next or previous track |
| `S` | Shuffle |
