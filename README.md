# Easy Reader

Save a web page from your iPhone and listen to a clean, spoken version of it.

The project has two parts:

- `server/`: a Node server that renders pages in Chromium, extracts the article with Defuddle, and creates audio.
- `ios/`: a small SwiftUI client for adding URLs, following conversion progress, and playing the result.

## Run the server

Requirements: Node 22+, an OpenAI API key, Codex CLI for optional AI cleanup, and either macOS or Linux with ffmpeg. Tailscale is recommended for private remote access.

```sh
cd server
npm install
npx playwright install chromium
cp .env.example .env
# Add OPENAI_API_KEY to .env
npm run dev
```

Check it with:

```sh
curl http://localhost:8787/health
curl -X POST http://localhost:8787/v1/articles \
  -H 'content-type: application/json' \
  -d '{"source":{"type":"url","url":"https://example.com"},"cleanup":false}'
```

You can also submit pasted text and optionally request conservative AI cleanup:

```sh
curl -X POST http://localhost:8787/v1/articles \
  -H 'content-type: application/json' \
  -d '{"source":{"type":"text","title":"Optional title","text":"At least 100 characters of content…"},"cleanup":true}'
```

Cleanup runs through `codex exec` in an ephemeral, read-only session with shell and web tools disabled. It preserves the author's voice and wording, making only the smallest edits needed for listenable prose. `CODEX_PATH` and `CODEX_CLEANUP_MODEL` are optional environment overrides.

The server binds to `127.0.0.1` by default. Expose it privately to the tailnet with HTTPS:

```sh
tailscale serve --bg 8787
```

Then put the resulting `https://…ts.net` URL in the iOS app's Settings screen. The address is stored in the app's shared user defaults and is not compiled into the source. If you set `API_TOKEN` on the server, enter the same value in the app.

Configuration is read from environment variables (and from `server/.env` during local development). See `server/.env.example` for every supported value. Never commit `server/.env`; it is ignored by Git.

## Run persistently on Linux

The included systemd unit expects the repository at `/opt/easy-reader`, secrets in `/etc/easy-reader.env`, and persistent article data in `/var/lib/easy-reader`. Install dependencies with `npm ci`, then install the Playwright Chromium runtime at the path used by the service with `PLAYWRIGHT_BROWSERS_PATH=/opt/easy-reader/.playwright npx playwright install chromium`. Enable the service with:

```sh
sudo cp deploy/easy-reader.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now easy-reader
```

Keep `/etc/easy-reader.env` readable only by root. A minimal production configuration is:

```dotenv
HOST=127.0.0.1
PORT=8787
DATA_DIR=/var/lib/easy-reader
OPENAI_API_KEY=replace-me
CODEX_PATH=codex
```

## Build the iOS app

The project is described by XcodeGen so the project file remains reproducible:

```sh
brew install xcodegen
cd ios
xcodegen generate
open EasyReader.xcodeproj
```

Select your development team and run on the iPhone. Background audio is already declared in the project spec.

### Codex and simulator testing

This repository includes a project-scoped XcodeBuildMCP configuration in `.codex/config.toml`, pinned to version 2.6.2. After first opening or trusting the repository, restart the Codex task so the MCP tools are loaded. Codex can then generate builds, boot a simulator, install and launch the app, inspect accessibility state, and capture screenshots and logs.

The equivalent direct CLI check is:

```sh
xcodebuildmcp simulator build --scheme EasyReader --project-path ios/EasyReader.xcodeproj
```

## Current MVP

- asynchronous article jobs with visible processing states
- URL extraction or directly pasted text input
- optional, voice-preserving cleanup through Codex CLI
- rendered JavaScript pages through Playwright
- Defuddle extraction and metadata
- OpenAI high-quality speech generation with sentence-aware chunking, precise inter-chunk gaps, and AAC output
- selectable OpenAI or Speechify TTS providers through `TTS_PROVIDER`
- persistent on-disk library and audio cache
- native SwiftUI library, URL entry, settings, Share Sheet intake, and background-capable player

Before signing, register the `group.com.larryhudson.EasyReader` App Group for both targets (or replace it with an App Group owned by your Apple developer account in the two entitlements files and Swift sources).
