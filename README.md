# Super Voice

A menu bar app for the Mac that does speech, offline, and does it well:

- **Read aloud**: six Kokoro voices (Heart, Bella, Emma; Michael, Fenrir, Puck), the word being
  said lit up, pause and stop, save the audio.
- **Dictate**: talk for as long as you like (pauses don't stop it), edit it, keep it.
- **Transcribe**: drop audio or video files, get their text (and subtitles), kept with the rest.
- **Library**: everything kept, in a grid: search, filter, star, open to edit, read it back, copy,
  save as .txt / .srt / .vtt, delete.
- **AI listen**: talk with [Ollama](https://ollama.com) by voice: click the tile and talk, or say **"Tom"**
  (or wave at the camera), then talk; the answer is read back. Wave, or press Stop talking, to stop it (or turn **Barge in** on and talk over it). It turns off
  after three minutes with nothing said, with a sound as it does. Soft sounds every few seconds say
  what it's working on.
- **Tom and Jerry**: a second assistant, Jerry, with his own model and voice, who does the work.
  Tom hands him jobs with a spec, you hear them both, Jerry's tool calls that change something wait
  for your approval, and Tom checks each result and sends it back if it misses. Tom learns from each
  job into a memory you can read and edit, which also holds your standing instructions for both.
- **Skills**: what the model can use besides talking, each switched on or off beside the panel:
  your library (reading, and adding or changing notes when you ask), your default browser (search,
  open pages, read and find text on them), files, the clipboard, the Mac's status, a calculator, and
  your scripts.
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
settings). Or, with **Listen** on (the ear), say **"Tom"**, then talk: "Tom, what's a good name
for a cat?" starts it and asks. "Tom" is the only thing always listening acts on. From then on
everything you say goes to Ollama and the answer is read back, until three minutes pass with
nothing said (one to ten minutes, in its window), when it plays its off sound (always, sounds on or
off) and turns itself off. Saying "goodbye" plays it too.

- **Pauses**: a pause ends what you said, unless it sounds unfinished ("…and the", "…because",
  a trailing comma, no full stop): then it waits a moment longer for the rest. And if more comes
  while the model is still working on the first half, the two are asked as one question.
- **While it talks** it doesn't listen (so nothing you say then is taken for its own voice coming
  back and thrown away); the **Stop talking** button, a wave at the camera, or waiting for it to
  finish, and then talk. **Barge in** (off unless you turn it on, in its window) keeps it listening
  while it talks, so you can cut in: what it hears then is told apart by its words: "stop", "wait"
  or "Tom" said first always cuts in; with echo cancellation on, anything else too when it's
  clearly you (three new words or more); the rest is dropped as its own voice. Headphones help.
- **Echo cancellation** (off unless you turn it on, **Echo** in its window, from the next start):
  its microphone and its voice share one audio engine with Apple's voice processing (as in
  FaceTime), so Kokoro's voice is taken back out of what the microphone hears and it doesn't hear
  itself. It's off by default because on some Macs the microphone it gives is heard (the meter
  moves) but nothing is understood; the plain microphone is heard everywhere. Voice processing is
  only on while AI Listen runs, and if the microphone gives only silence with it, it's turned off by
  itself (until the app starts again). Where it isn't available (some audio devices), the window
  says so.
- **Not hearing you?** Every phrase it cuts is logged as it's written down (Console.app, search for
  `phrase`): how long and how loud it was, and what came of it. A meter that moves with nothing
  logged means no phrase was cut; a phrase `written: ""` means the recognizer made nothing of it.
- **"Stop"** stops it talking. **"New chat"** starts over. **"Goodbye"** (or "that's all") turns it
  off. You can type instead of talking.
- **Voice prints**: on top of echo cancellation and the words, its voices are told from yours by how
  they sound. Each Kokoro voice it uses is enrolled once (it says a sentence, which becomes a speaker
  print, a CAM++ embedding on the Neural Engine; the model downloads once, about 7 MB), and yours is
  learned from what you say while nobody's talking. While a voice plays, each phrase heard is
  compared: closer to theirs than to yours, it's the voice coming back through the microphone, and
  it's dropped before it's even written down; what sounds like you gets through. **Prints** in its
  window turns it off.
- **Working sounds**: while it works, a soft sound every three seconds says what it's doing: one for
  the model thinking (a different one for Jerry), one for the browser, one for files and the library,
  one for the scripts. **Working** in its window turns them off (so does **Sounds**).
- **Wave**: with **Listen** on, the camera watches for a wave (a hand going left and right a few
  times; Apple's hand pose detection, about ten frames a second, nothing kept or sent anywhere): a
  wave starts it like saying "Tom", and while it talks, stops it talking. The camera's light is on
  while it watches. The hand button on the panel (or **Wave** in its window) turns the camera off.
- Each start is a **new chat**, kept in the **AI library** as it goes. The model sees only the chat
  it's in, and is told the date and time (written out in full) with each message. Tool calls are
  hand-rolled (a line of JSON in the model's answer, the result as the next message), not Ollama's
  tool calling, so any model can use them.

### Tom and Jerry

Turn the **Jerry** skill on (the panel's Skills column, or right-click the AI listen tile) and there
are two of them in the room with you: **Tom**, the supervisor, who you talk to, and **Jerry**, the
worker, with his own model (the same as Tom's unless you pick another, in AI Listen's window) and
his own voice (the first of the other kind from Tom's, unless you pick one). You talk only to Tom;
Jerry can't see or hear you, only what Tom sends him, and you hear them both.

- **Jobs.** With Jerry on, Tom has no tools of his own but the jobs and his memory: anything that
  takes a tool (the web, files, the library, scripts, sums) he hands Jerry as a job, with a spec:
  the goal, constraints (from what he knows of you), what counts as done, and what to bring back.
  You hear Tom brief it ("Jerry, job 3: …"); the spec is in the window. Jerry works it with the
  skills, saying what he's doing as he goes in his own voice, and ends it with a result, read out in
  his voice. Tom is told, checks the result against his spec, and sends it back with what to change
  if it misses (up to three times, without asking you); if it's right, he says only what you still
  need to know, or nothing. Jobs run one at a time, oldest first; one sent back, or unblocked, goes
  first. When Jerry can't go on without an answer he asks Tom, who answers from what he knows, or
  asks you. Jobs are kept across chats and launches (the **Jobs** list in AI Listen's window shows
  each one's status, spec, result, tools and log; **Clear finished** forgets the ones that are over);
  a job left running when the app stops is queued again next time.
- **Approvals.** Jerry's tool calls that change something (library editing, scripts) wait for you:
  a card in the window with **Approve** and **Reject**, and Tom's voice asks "yes or no?"; say
  "yes", "go ahead", "no" or "reject". A rejected call comes back to Jerry as rejected, and he goes
  on without it. **Approve** in the window's settings makes it everything (every tool, even looking
  things up) or nothing.
- **Tom watches.** Tom is told of everything that happens to a job (a tool proposed, approved,
  rejected or run; a question; a result; a failure) and usually says nothing; he can correct Jerry
  mid-job. **Tom watches every step** off tells him only of questions, results and failures, which
  is quicker on a slow model.
- **Memory.** Tom learns: after a job he notes what it taught him in his memory, in three sections
  (your preferences, how to brief Jerry, what went wrong), which he reads at the start of every turn
  and prunes himself (sixty notes at most). **Memory** in AI Listen's window (or right-click the
  tile) opens it: read it, edit it, and give Tom and Jerry **standing instructions** of your own,
  which go after their system prompts. Tom keeps his memory with Jerry off too. Jerry keeps nothing
  between chats: each new chat starts him fresh.
- The whole room is one chat in the AI library, with who said what to whom, and the jobs' lines.
  "Stop" stops Tom and the voices; Jerry's job carries on.

### Skills

The panel's columns while AI Listen is on (or pinned with the rectangles button): the skills,
each with a switch (the model is told only about those on), what the model used, newest first
(click one for all of it, to copy, open or hear), and the board's searches.

- **Library**: list and read earlier chats, and the dictations, transcripts and notes ("what did we
  say about the budget last week?", "read me yesterday's dictation").
- **Library editing**: add notes, and change dictations, transcripts and notes (replace or add to
  their text, rename, star) when you ask ("note: call Sam at four", "add eggs to my shopping
  note"). Never chats, and nothing is deleted. Only a tool saves: if the model says it saved
  something when nothing did, it's told so and asked to do it, and each real save shows a line in
  AI Listen ("Saved in the library: …") and in what it used.
- **Browser**: in your default browser: web searches (Google, or set your own),
  your sites (Wikipedia and YouTube to start with; add one as `name https://…{query}`), opening a
  page, reading the page you have open, and finding text on it (highlighted, scrolled to). Safari
  and the Chromium browsers (Chrome, Brave, Edge, Arc, Vivaldi, Opera) are read in place once
  **Allow JavaScript from Apple Events** is on (Safari: Develop menu; Chrome: View > Developer),
  and macOS asks once to let Super Voice control the browser. Any other browser (or that off), the
  page still opens there and is read by fetching it.
  **Show the browser as it opens pages** (on by default) brings it to the front as it opens a page;
  off, pages open behind, and "show me" brings it forward.
- **This app**: "show me my library", "open my shopping note", "find the budget chat": it opens the
  app's own windows (the library at an item or searched, the AI library, Dictate, Read aloud,
  Transcribe, AI Listen, the panel).
- **Files**: find files with Spotlight, list folders, read text, Markdown, code, CSV, JSON, PDF,
  RTF and Word files. Only to look; hidden files and folders and `~/Library` (but iCloud Drive)
  stay out, and so does anything outside your home folder, `/Applications` and `/Volumes`.
- **Clipboard**, **This Mac** (the app in front, apps open, battery, disk, memory, macOS) and the
  **Calculator** (sums worked out exactly, not guessed).
- **Jerry**: the second assistant (see above): the `tell_jerry` tool, which Tom uses to hand him
  something; it ends Tom's turn, and the message is delivered once it's been heard.
- **Scripts**: with [Tool Mac Tool Run](https://github.com/ainigh/toolmactoolrun) running, it can
  list and run your scripts and flows ("run my backup script"): every run shows a card on the Mac
  and waits for you to click **Run**. Its address (`http://127.0.0.1:8768`) is in the window's
  settings; clear it and the model can't.
- **Thinking**: off by default, for quick answers: the model is asked not to think (Ollama's
  `think: false`; "/no_think" for Qwen 3; as little as it goes for gpt-oss, which always thinks a
  bit), and anything it thinks anyway is never read out. The **Thinking** button in its window (or
  right-click the tile) turns it on. When it can't be turned off all the way (Ollama older than
  0.9, gpt-oss, or a model that thinks anyway), the window says so, with the command to run.
- **Quick answers**: with thinking off it's asked for the shortest answer that does it, straight
  away (and an answer can't run on). The model is loaded as AI Listen starts and kept loaded for
  30 minutes, and what's sent first stays the same from one question to the next, so Ollama
  doesn't read it all again: only the new question is.
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

- **Listen**: always listen for "Tom" (see below). The hand: with Listen on, watch the camera for a
  wave, which starts AI Listen too. The rectangles: show the skills. **Start / Stop**: serving the
  API (the tools keep working either way).
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

## Always listen

**Listen** (the ear, next to Start) keeps the microphone open for one word: **"Tom"**, which starts
AI Listen (see above); "Tom, …" said in one go asks it straight away. With the hand button on too,
the camera watches for a wave, which starts it as well. Nothing else said is acted
on or kept, and nothing is heard while dictating, while the Mac speaks itself, or while AI Listen
has the microphone. (The board's voice commands and note from before are gone; the note stays in
the library, as a note called "Board".)

## Working on it

```bash
swift test                 # the service's logic (VoiceCore): runs anywhere, Linux too
scripts/build-app.sh       # on a Mac: build/SuperVoice.app and build/SuperVoice.zip
```

| | |
|---|---|
| `Sources/VoiceCore` | Foundation only: the HTTP API (`API.swift`), API.md embedded (`APIDoc.swift`, generated by `scripts/embed-api-doc.sh`), HTTP parsing, voices, WAV/PCM, multipart, long-audio transcription, the library store, access rules, the assistant (`Assistant.swift`: the wake word, the Ollama client, hand-rolled tool calls, the tools over the library, the conversation; `Team.swift`: Tom and Jerry, who's addressed, the handoff; `Skills.swift`: the skills, the browser, files and the calculator; `Listening.swift`: when a sentence is done, telling its own voice from yours by the words, and what a wave is; `ToolRun.swift`: Tool Mac Tool Run's client and the tools over it) |
| `Sources/SuperVoice` | the Mac app: FluidAudio engine, Network.framework server, menu bar panel, the tools' windows, AI listen (`AssistantModel.swift`: the room, the two agents, the voice queue and deliveries, the working sounds; `VoicePrints.swift`: the voices told from yours; `Wave.swift`: the camera), the skills board (`SkillsModel.swift`, `SkillsViews.swift`) and what they need from the Mac (`MacSkills.swift`), updater |
| `Tests/VoiceCoreTests` | every endpoint against a fake engine, the parser, formats, the library, the assistant against a fake model |
| `scripts/build-app.sh`, `.github/workflows/build.yml`, `install.sh` | building, releasing (pushes to `main`), installing |
