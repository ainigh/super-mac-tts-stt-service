# Super Voice

A menu bar app for the Mac that does speech, offline, and does it well:

- **Read aloud**: six Kokoro voices (Heart, Bella, Emma; Michael, Fenrir, Puck), the word being
  said lit up, pause and stop, save the audio.
- **Dictate**: talk for as long as you like (pauses don't stop it), edit it, keep it.
- **Transcribe**: drop audio or video files, get their text (and subtitles), kept with the rest.
- **Library**: everything kept, in a grid: search, filter, star, open to edit, read it back, copy,
  save as .txt / .srt / .vtt, delete.
- **API**: every app on the Mac can speak and listen through it, the way they use Ollama. Each
  endpoint can be switched off from the panel, and the server stopped and started.

No language models, no Ollama, nothing else. The speech runs on Apple's Neural Engine through
[FluidAudio](https://github.com/FluidInference/FluidAudio): Kokoro-82M to speak and Parakeet TDT v3
to listen (25 European languages), the same as Tool Mac Tool. Each model downloads once, the first
time (a few hundred MB, into `~/.cache/fluidaudio` and `~/Library/Application Support`); after that
nothing leaves the Mac.

## For other apps

**[API.md](API.md)** is what client apps need: `http://127.0.0.1:8767`, with `/api/tts`,
`/api/stt`, `/api/transcribe`, `/api/say`, and OpenAI-compatible `/v1/audio/*`.
[openapi.yaml](openapi.yaml) is the same, for code generators. Clients of glassvoice work by
changing the port.

```bash
curl -s localhost:8767/api/tts -d '{"text": "Hello there", "voice": "heart"}' -o hello.wav
curl -s localhost:8767/api/stt --data-binary @note.m4a
```

## Install

Paste this into Terminal (it installs Homebrew's `gh` if needed and signs you in to GitHub, since
the repository is private):

```bash
/bin/bash -c 'for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done; command -v gh >/dev/null || brew install gh; gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https -h github.com; gh api -H "Accept: application/vnd.github.raw" repos/ainigh/super-mac-tts-stt-service/contents/install.sh | bash'
```

It takes the latest release GitHub built; if there isn't one, it downloads the source and builds it
on your Mac (that needs Swift 6: Xcode 16 or recent command line tools). It installs into
`~/Applications/SuperVoice.app` and opens it: look for the waveform in the menu bar.

**Update**: the panel's bottom bar shows the version; when `main` has something newer it shows
**Update** (GitHub's build when there is one, otherwise it builds that commit here). Running the
install line again works too.

**Microphone**: the first time you dictate, macOS asks: click **Allow**.

## The panel

Click the waveform in the menu bar:

- **Listen**: always listen (see below). **Start / Stop**: serving the API (the tools keep working
  either way).
- **Read aloud, Dictate, Transcribe, Library**: the tools, each in its own window.
- **Voice**: the default voice (click one to hear it) and speed, for the tools and for API calls
  that don't name one. Beside it, whether each model is ready.
- **Endpoints**: a switch for each (text to speech, speech to text, transcribe files, speak on this
  Mac, OpenAI-compatible); one that's off answers `503 endpoint_off`. **Copy URL**, and **Try it**
  (the service's own page, with a box to try each).
- **Allow other devices**: listen on the network too; callers from elsewhere need the token shown.
- **Update**, **Open at login**, **Quit**.

## Always listen and the board

**Listen** (the ear, next to Start) keeps the microphone open: each thing you say, ended by a
pause, lands on the board beside the panel. The panel grows to four columns while it's in use (the
rectangles button shows the board without listening, to type into it):

1. **The panel** as before.
2. **Voice commands**: words you add over time (`notes` to start with). Say one first and what
   follows is filed under it: "notes, buy milk" goes under `#notes`. Anything else goes under
   `#note`. Click a command to see what's filed under it.
3. **Entries**: what you just said (or typed: the box takes typing too, and you can edit what was
   heard) sits on top, not added yet; under it, the entries searched with it, best match first.
4. **Options** for it: **Add** (it becomes the newest entry, on top), **Open** (the best match:
   a link opens in your browser; `GET https://…` or `POST https://… {json}` is called and its answer
   shown; anything else opens here, with **Copy**), **No** (drop it), **Copy** (the best match, or
   what you said when nothing matches). Click one, press Return (Add) or Escape (No), or just say
   it: "add", "open", "no", "copy".

Say **"mouse"** to open the panel (it doesn't take the keyboard from the app you're in) and
"mouse" again to close it. The panel closes after 20 seconds with nothing happening. While
something is waiting for an answer and the panel is closed, a dot shows next to the icon (an ear
while listening). What the Mac says itself, and anything said while dictating, is ignored. Board
entries are kept in the library too (as notes, with their tag).

## Working on it

```bash
swift test                 # the service's logic (VoiceCore): runs anywhere, Linux too
scripts/build-app.sh       # on a Mac: build/SuperVoice.app and build/SuperVoice.zip
```

| | |
|---|---|
| `Sources/VoiceCore` | Foundation only: the HTTP API (`API.swift`), HTTP parsing, voices, WAV/PCM, multipart, long-audio transcription, the library store, access rules |
| `Sources/SuperVoice` | the Mac app: FluidAudio engine, Network.framework server, menu bar panel, the tools' windows, updater |
| `Tests/VoiceCoreTests` | every endpoint against a fake engine, the parser, formats, the library |
| `scripts/build-app.sh`, `.github/workflows/build.yml`, `install.sh` | building, releasing (pushes to `main`), installing |
