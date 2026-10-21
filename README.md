# Super Voice

A menu bar app for the Mac that does speech, offline, and does it well:

- **Read aloud**: six Kokoro voices (Heart, Bella, Emma; Michael, Fenrir, Puck), the word being
  said lit up, pause and stop, save the audio.
- **Dictate**: talk for as long as you like (pauses don't stop it), edit it, keep it.
- **Transcribe**: drop audio or video files, get their text (and subtitles), kept with the rest.
- **Library**: everything kept, in a grid: search, filter, star, open to edit, read it back, copy,
  save as .txt / .srt / .vtt, delete.
- **AI listen**: talk with [Ollama](https://ollama.com) by voice: click the tile and talk, or say **"Micky"** (or "Ollama"),
  then talk; the answer is read back. It turns off after a minute with nothing said.
- **AI library**: every chat with it, by day. A new chat starts fresh, but ask about an earlier one,
  or about something you dictated, transcribed or noted, and it looks it up.
- **API**: every app on the Mac can speak and listen through it, the way they use Ollama. Each
  endpoint can be switched off from the panel, and the server stopped and started.

The speech runs on Apple's Neural Engine through
[FluidAudio](https://github.com/FluidInference/FluidAudio): Kokoro-82M to speak and Parakeet TDT v3
to listen (25 European languages), the same as Tool Mac Tool. Each model downloads once, the first
time (a few hundred MB, into `~/.cache/fluidaudio` and `~/Library/Application Support`); after that
nothing leaves the Mac. The only language model is the one you run yourself in Ollama, for AI
listen; everything else works without it.

## AI listen

Click the panel's **AI listen** tile and just talk: no wake word, and no window to open (the chat
works all the same; it shows in the **AI library**, and right-click the tile for its window and
settings). Or, with **always listen** on, say **"Micky"** (or "Ollama"), then talk: "Micky, what's a
good name for a cat?" starts it and asks. From then on everything you say goes to Ollama and the
answer is read back in your voice, until a minute passes with nothing said (30 seconds to 5
minutes, in its window), when it turns itself off. While it talks it isn't listening (so it doesn't
hear itself); say the next thing when it's done, or click **Stop talking**.

- **"Stop"** stops it talking. **"New chat"** starts over. **"Goodbye"** (or "that's all") turns it
  off. You can type instead of talking.
- Each start is a **new chat**, kept in the **AI library** as it goes. The model sees only the chat
  it's in, and is told the date and time (written out in full) with each message. It has tools to
  list the earlier chats (by date) and read any of them, and to list and read the library's
  dictations, transcripts and notes: ask ("what did we say about the budget last week?", "read me
  yesterday's dictation") and it looks them up. Tool calls are hand-rolled (a line of JSON in the
  model's answer, the result as the next message), not Ollama's tool calling, so any model can use
  them.
- **Scripts**: with [Tool Mac Tool Run](https://github.com/ainigh/toolmactoolrun) running, it can
  list and run your scripts and flows ("run my backup script"): every run shows a card on the Mac
  and waits for you to click **Run**. Its address (`http://127.0.0.1:8768`) is in the window's
  settings; clear it and the model can't.
- **Thinking**: off by default, for quick answers: the model is asked not to think (Ollama's
  `think: false`; "/no_think" for Qwen 3; as little as it goes for gpt-oss, which always thinks a
  bit), and anything it thinks anyway is never read out. The **Thinking** button in its window (or
  right-click the tile) turns it on. When it can't be turned off all the way (Ollama older than
  0.9, gpt-oss, or a model that thinks anyway), the window says so, with the command to run.
- **Ollama**: `http://127.0.0.1:11434` and the first model it has, unless you pick otherwise in the
  window. Everything stays on the Mac.

## For other apps

**[API.md](API.md)** is what client apps need: `http://127.0.0.1:8767`, with `/api/tts`,
`/api/stt`, `/api/transcribe`, `/api/say`, and OpenAI-compatible `/v1/audio/*`; the running service
serves it at `/api.md` too.
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
- **Read aloud, Dictate, Transcribe, Library, AI listen, AI library**: the tools, each in its own
  window.
- **Voice**: the default voice (click one to hear it) and speed, for the tools and for API calls
  that don't name one. Beside it, whether each model is ready.
- **Endpoints**: a switch for each (text to speech, speech to text, transcribe files, speak on this
  Mac, OpenAI-compatible); one that's off answers `503 endpoint_off`. **Copy URL**, **Copy API docs** (all of [API.md](API.md), ready to
  paste into another app or an assistant writing a client), and **Try it** (the service's own page,
  with a box to try each).
- **Allow other devices**: listen on the network too; callers from elsewhere need the token shown.
- **Update**, **Open at login**, **Quit**.

## Always listen and the board

**Listen** (the ear, next to Start) keeps the microphone open. Say **"mouse"** to open the panel
(it doesn't take the keyboard from the app you're in), then just talk: each thing you say, ended by
a pause, goes in the board's note, one note kept in sections, each under a subtitle. "Mouse, note
buy milk" in one go works too. "Mouse" again closes the panel, and so do 20 seconds with nothing
happening. Nothing is taken while the panel is closed, and neither is what the Mac says itself or
anything said while dictating. The panel grows to four columns while it's in use (the rectangles
button shows the board without listening, so you can type into it):

1. **The panel**, as before.
2. **Voice commands**: the subtitles (`note` to start with; add more over time). Say one first
   and what follows goes under it: "note, buy milk" adds "Buy milk" under `note`. Anything else
   goes under `search`, word for word ("search, …" said first works too). Click one to see what's
   under it.
3. **The note**: what was just added, then, for a search, the note's sentences that match it (best
   match first); for a command, what else is under that subtitle. The box on top takes typing
   (Return adds it, the same as saying it).
4. **Options** for what was just added: **Open** opens the note, scrolled to the best match with
   its sentence picked out (to what was just added when nothing matches). A line that's only a link
   opens in your browser instead, and `GET https://…` or `POST https://… {json}` is called and its
   answer shown. **Copy** copies the best match, or what you said. **No** takes it back out of the
   note. Click one, or just say it: "open", "copy", "no" (said alone, they're never added).

Everything said is kept. The note is in the library too (a note called "Board"), where it can be
read back, edited or saved as a file: `## note` starts the section under `note`, and each line
under it is one thing said. Entries from before the board kept one note are folded into it once,
under what they were filed under, and stay in the library as notes of their own.

## Working on it

```bash
swift test                 # the service's logic (VoiceCore): runs anywhere, Linux too
scripts/build-app.sh       # on a Mac: build/SuperVoice.app and build/SuperVoice.zip
```

| | |
|---|---|
| `Sources/VoiceCore` | Foundation only: the HTTP API (`API.swift`), API.md embedded (`APIDoc.swift`, generated by `scripts/embed-api-doc.sh`), HTTP parsing, voices, WAV/PCM, multipart, long-audio transcription, the library store, access rules, the assistant (`Assistant.swift`: wake words, the Ollama client, hand-rolled tool calls, the tools over the library, the conversation; `ToolRun.swift`: Tool Mac Tool Run's client and the tools over it) |
| `Sources/SuperVoice` | the Mac app: FluidAudio engine, Network.framework server, menu bar panel, the tools' windows, AI listen (`AssistantModel.swift`), updater |
| `Tests/VoiceCoreTests` | every endpoint against a fake engine, the parser, formats, the library, the assistant against a fake model |
| `scripts/build-app.sh`, `.github/workflows/build.yml`, `install.sh` | building, releasing (pushes to `main`), installing |
