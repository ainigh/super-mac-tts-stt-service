# Super Voice

A menu bar app for the Mac that does speech, offline, and does it well:

- **Read aloud**: six Kokoro voices (Heart, Bella, Emma; Michael, Fenrir, Puck), the word being
  said lit up, pause and stop, save the audio.
- **Dictate**: talk for as long as you like (pauses don't stop it), edit it, keep it.
- **Transcribe**: drop audio or video files, get their text (and subtitles), kept with the rest.
- **Library**: everything kept, in a grid: search, filter, star, open to edit, read it back, copy,
  save as .txt / .srt / .vtt, delete. It's the second tab of the AI library window (⌘2).
- **AI listen**: talk with [Ollama](https://ollama.com) by voice: click the tile and talk, or say **"Tom"**
  (or wave at the camera), then talk; the answer is read back. Wave, or press Stop talking, to stop it (or turn **Barge in** on and talk over it). It turns off
  after three minutes with nothing said, with a sound as it does. Soft sounds every few seconds say
  what it's working on.
- **Tom, Jerry and Jane**: three assistants, each with a model and a voice. Tom is the face: you
  talk to him, he works out what you want and hands every request on, and tells you where it
  stands. Jerry is the engine: he does and looks things up, with your scripts and the library. Jane
  is the brain: she answers what takes knowing or judging, and reviews a job Tom sends back. Tom
  learns from each job into a memory you can read and edit, which also holds your standing
  instructions. The app says "standing down" before it turns off, and not while work is pending.
- **Skills**: what the model can use besides talking, each switched on or off beside the panel:
  your library (reading, and adding or changing notes when you ask) and your scripts and flows in
  [Tool Mac Tool Run](https://github.com/ainigh/tool-mac-tool-run), which reach everything else on
  the Mac (the browser and the web, files, the clipboard, the Mac itself), each run waiting for
  your click.
- **AI library**: every chat with it, by day, and the library beside it (two tabs, one window). A
  new chat starts fresh, but ask about an earlier one, or about something you dictated, transcribed
  or noted, and it looks it up. A chat shows there as it goes, what you said as soon as you said it.
- **API**: every app on the Mac can speak and listen through it, the way they use Ollama, and use
  its model (`/api/model/chat`, AI Listen's). Each endpoint can be switched off from the panel, and
  the server stopped and started.
- **Super Face**: the ears and the mouth are two apps. [Super
  Face](https://github.com/ainigh/JUST-super-mac-tts-ONLY-service) is a 3D avatar, head to toes, on
  the desktop; while it runs, everything Super Voice says is said by the avatar, with lip-sync and
  expressions (chosen by Super Voice's model), and nothing it says is taken for you (see below).

The speech runs on Apple's Neural Engine through
[FluidAudio](https://github.com/FluidInference/FluidAudio): Kokoro-82M to speak and Parakeet TDT v3
to listen (25 European languages), the same as Tool Mac Tool. Each model downloads once, the first
time (a few hundred MB, into `~/.cache/fluidaudio` and `~/Library/Application Support`); after that
nothing leaves the Mac. The only language model is the one you run yourself in Ollama, for AI
listen; everything else works without it.

## AI listen

Click the panel's **AI listen** tile and just talk: no wake word, and no window to open (the chat
works all the same; it shows in the **AI library**, and right-click the tile for its window and
settings). Or, with **Listen** on (the ear), say **"Tom"** (he answers "Yes?"), then talk: "Tom, what's a good name
for a cat?" starts it and asks. "Tom" is the only thing always listening acts on. From then on
everything you say goes to Ollama and the answer is read back, until three minutes pass with
nothing said (one to ten minutes, in its window), when it plays its off sound (always, sounds on or
off) and turns itself off. Saying "goodbye" plays it too.

- **Pauses**: a pause ends what you said (about two seconds; **Pause** in its window makes it
  shorter or longer: if it doesn't wait for you to finish, pick a longer one), unless it sounds
  unfinished ("…and the", "…because", a trailing comma, no full stop): then it waits a moment
  longer for the rest. And if more comes while the model is still working on the first half, the
  two are asked as one question.
- **Models**: the panel's **Models** row picks which of Ollama's models Tom talks with, and which
  Jerry does (the same as Tom's unless you pick another).
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
- **Working sounds**: while it works, a sound every two and a half seconds says what it's doing
  (loud enough to hear across the room, under the voices): one for Tom thinking, one for Jerry, one
  for Jane, one for a script, one for the library. **Working** in its window turns them off (so does
  **Sounds**).
- **Wave**: with **Listen** on, the camera watches for a wave (a hand going left and right a few
  times; Apple's hand pose detection, about ten frames a second, nothing kept or sent anywhere): a
  wave starts it like saying "Tom", and while it talks, stops it talking. The camera's light is on
  while it watches. The hand button on the panel (or **Wave** in its window) turns the camera off.
- Each start is a **new chat**, kept in the **AI library** as it goes. The model sees only the chat
  it's in, and is told the date and time (written out in full) with each message. Tool calls are
  hand-rolled (a line of JSON in the model's answer, the result as the next message), not Ollama's
  tool calling, so any model can use them.

### Tom, Jerry and Jane

Turn the **Jerry** skill on (the panel's Skills column, or right-click the AI listen tile) and there
are three of them in the room with you, each with a model (Tom's unless you pick another) and a
voice of their own. You talk only to Tom; the others can't see or hear you, only what Tom sends
them, and you hear all three.

- **Tom is the face.** He understands what you want, hands it on, follows it, and tells you where
  it stands; he never answers a request himself, not even one he knows ("what are the five senses?"
  goes to Jane). Anything to do or look up goes to Jerry; anything to know, explain, decide or write
  goes to Jane. He answers in his own words only about the jobs: where they stand, what came back,
  what you still need. Each thing you say reaches him with where the jobs stand now, so "how's it
  going?" is answered from the jobs, and while one is open he starts with it. Words that promise
  work without the call ("I'll have Jerry check") are caught, and he's told to make the call.
- **Jane is the brain.** A question of Tom's (`ask_jane`) is a job of hers: she answers it from what
  she knows, straight, in her voice, with no tools, and says what would settle it when she doesn't
  know. When something goes wrong that Tom can't sort out, he asks her what to do.
- **Jobs.** Anything that takes doing (the web, files, the library, scripts) Tom hands Jerry as a
  job, with a spec:
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
- **Approvals.** Jerry's tool calls that change the library, or stop a run, wait for you: a card in
  the window with **Approve** and **Reject**, and Tom's voice asks "yes or no?"; say "yes", "go
  ahead", "no" or "reject". A script's run waits for its own card on the Mac instead. A rejected call comes back to Jerry as rejected, and he goes
  on without it. **Approve** in the window's settings makes it everything (every tool, even looking
  things up) or nothing.
- **Tom watches.** Tom is told of everything that happens to a job (a tool proposed, approved,
  rejected or run; a question; a result; a failure) and usually says nothing; he can correct Jerry
  mid-job. **Tom watches every step** off tells him only of questions, results and failures, which
  is quicker on a slow model.
- **Jane, the reviewer.** When Tom sends a job back, Jane steps in before Jerry takes it up again.
  She sees only the job: what you said just before Tom delegated it, Tom's spec and messages, what
  Jerry said as he worked, which tools he used, and what he brought back; nothing else of the chat,
  and none of Tom's memory. Her stance is suspicion of how intelligent and systematic the two of
  them are being: did Jerry read the spec, check against the done criteria, use the right tools in
  the right order, assume what he should have looked up; is Tom's spec vague. She tells Jerry what
  to do differently, step by step, in her own voice (you hear her; nobody talks to her), and leaves;
  she does none of the work herself and has no tools. If the job comes back again, so does she. Her
  model and voice are set in AI Listen's window (Jerry's, and the first voice that's neither Tom's
  nor Jerry's, unless you pick others); **Jane** there turns her off.
- **Status, and standing down.** Tom owns every job until you have what you asked for: he's told to
  forget none, and to say where things stand when a job has been going a while (every minute or two
  he's asked whether you've heard lately). With nothing said for the turn-off time, the app doesn't
  simply turn off: over work pending (a job of this chat still open, one running or queued, a tool
  waiting on you, Jane reviewing) it stays on and says so; otherwise it asks Tom whether anything is
  still owed to you, and only on his word (or none, after another period) says **"standing down"**
  in his voice and turns off. Cut in while it says so and it stays on.
- **Memory.** Tom learns: after a job he notes what it taught him in his memory, in three sections
  (your preferences, how to brief Jerry, what went wrong), which he reads at the start of every turn
  and prunes himself (sixty notes at most). **Memory** in AI Listen's window (or right-click the
  tile) opens it: read it, edit it, and give Tom and Jerry **standing instructions** of your own,
  which go after their system prompts. Tom keeps his memory with Jerry off too. Jerry keeps nothing
  between chats: each new chat starts him fresh.
- **Keeping them on track.** The models are small, so each is told its part as numbered rules with
  a worked example in its own tools, and the app catches the usual slips and asks once for the
  right thing instead: Tom talking to Jerry in words (Jerry hears only tool calls), Tom saying "I
  can't", Jerry ending a job in words without `finish` or `ask_tom`, a tool call cut off or not
  JSON, Jerry still calling tools after a job's ten rounds (asked to finish with what he has), two
  moves in one answer (only the first is made, and he's told), and the same goal delegated twice
  (not created; the open job is named). What Tom says about a job Jerry is on reaches him mid-job,
  with his next call to the model. Jerry starts each job with an empty chat (the job's past is in
  his briefing), and every chat asks Ollama for 16k of context, so a page read doesn't push the spec
  out of the model's sight.
- The whole room is one chat in the AI library, with who said what to whom, and the jobs' lines.
  "Stop" stops Tom and the voices; Jerry's job carries on. **"Stop everything"** (or Tom's
  `stop_everything` tool, when you ask him to stop it all) stops the voices, Tom, Jerry, Jane,
  every open job, a tool waiting on you, and every run still going on the Mac.
- **Scripts and flows run through the Mac's own card.** Jerry's `run_script`, `run_flow` and
  `run_flow_code` ask Tool Mac Tool Run for the run, and nothing runs until you click **Run** on the
  card the Mac shows (that click is the approval: the app asks nothing of its own for these). The
  call waits for your click and for the run, and comes back with what it printed, so Jerry reads
  the result and finishes with it. An older Tool Mac Tool Run that answers at once with a **request
  id** is followed by the app every two seconds instead, its state written onto the job and told to
  Tom.
- **What there is to run.** As AI Listen starts, the app asks Tool Mac Tool Run for its scripts and
  flows: Jerry is told each by name with what it does (and what it can't undo), Tom what they come
  to, so specs name scripts that exist. The panel's column lists them, with a button to ask again.

### Skills

The panel's columns, always out beside it: the team (what Tom, Jerry and Jane are each doing, and
their models), the jobs, the skills, each with a switch (the model is told only about those on),
and the scripts Tool Mac Tool Run has; then what they used, newest first (click one for all of it,
to copy, open or hear). When the screen hasn't room for them all beside the panel, they scroll
sideways.

- **Library**: list and read earlier chats, and the dictations, transcripts and notes ("what did we
  say about the budget last week?", "read me yesterday's dictation").
- **Library editing**: add notes, and change dictations, transcripts and notes (replace or add to
  their text, rename, star) when you ask ("note: call Sam at four", "add eggs to my shopping
  note"). Never chats, and nothing is deleted. Only a tool saves: if the model says it saved
  something when nothing did, it's told so and asked to do it, and each real save shows a line in
  AI Listen ("Saved in the library: …") and in what it used.
- **Scripts**: with [Tool Mac Tool Run](https://github.com/ainigh/tool-mac-tool-run) running, it
  runs your scripts and flows: that's how it reaches the browser and the web, files, the clipboard
  and the Mac ("what page is open?", "run my backup script"). Every run shows a card on the Mac and
  waits for you to click **Run**. Its address (`http://127.0.0.1:8768`) is in the window's settings;
  clear it and the model can't.
- **Jerry**: the team (see above): Tom's `delegate`, `ask_jane`, `message_jerry`, `job_status`,
  `cancel_job` and `stop_everything`.
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

## Super Face: the mouth

Super Voice is the ears and the model; [Super Face](https://github.com/ainigh/JUST-super-mac-tts-ONLY-service)
is the mouth and the face, its own app with its own API (`http://127.0.0.1:8769`). With it running
(the panel's **Speak through Super Face**, on unless you switch it off, shows a green dot):

- **It speaks.** AI Listen's Tom, Jerry and Jane, and `/api/say`, are said by the avatar, each in
  their voice, and the avatar shows itself to say it. Stopping (a word, a wave, the button) stops
  it there too. If Super Face isn't running, or its voice is still downloading the first time, the
  Mac's own Kokoro voice says it, as before. Read aloud stays here (it lights up each word).
- **It isn't heard as you.** Super Face knows exactly what it said and when, so every phrase heard
  (by AI Listen, and by always listen) is checked with it first (`POST /api/echo`): its own words
  coming back through the microphone, even a little misheard, are dropped; what's new is yours.
  That holds for what the avatar says for other apps too. No echo cancellation needed for it (its
  voice doesn't go through Super Voice's audio engine, so **Echo** doesn't take it out).
- **One model.** The avatar's expressions and gestures are chosen by Super Voice's model (Tom's),
  through `/api/model/chat`: Super Face has no model of its own and never talks to Ollama.

## For other apps

**[API.md](API.md)** is what client apps need: `http://127.0.0.1:8767`, with `/api/tts`,
`/api/stt`, `/api/transcribe`, `/api/say`, `/api/model/chat`, and OpenAI-compatible `/v1/audio/*`; the running service
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

Click the waveform in the menu bar. The panel is two columns: the tools and the models on the
left, the voice, endpoints and sharing on the right, with the switches across the top and the bottom
bar under both.

- **Listen**: always listen for "Tom" (see below). The hand: with Listen on, watch the camera for a
  wave, which starts AI Listen too. **Start / Stop**: serving the API (the tools keep working
  either way).
- **Read aloud, Dictate, Transcribe, Library, AI listen, AI library**: the tools, each in its own
  window (the library and the AI library share one, a tab each).
- **Voice**: the default voice (click one to hear it) and speed, for the tools and for API calls
  that don't name one. Beside it, whether each model is ready.
- **Endpoints**: a switch for each (text to speech, speech to text, transcribe files, speak on this
  Mac, OpenAI-compatible, the model for other apps); one that's off answers `503 endpoint_off`. **Copy URL**, **Copy API docs** (all of [API.md](API.md), ready to
  paste into another app or an assistant writing a client), and **Try it** (the service's own page,
  with a box to try each).
- **Allow other devices**: listen on the network too; callers from elsewhere need the token shown.
- **Speak through Super Face**: while the avatar app runs, it says what Super Voice says (green: it's
  running; **Get it** when it isn't).
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
| `Sources/VoiceCore` | Foundation only: the HTTP API (`API.swift`), the model for other apps (`Model.swift`), Super Face's client (`Face.swift`), API.md embedded (`APIDoc.swift`, generated by `scripts/embed-api-doc.sh`), HTTP parsing, voices, WAV/PCM, multipart, long-audio transcription, the library store, access rules, the assistant (`Assistant.swift`: the wake word, the Ollama client, hand-rolled tool calls, the tools over the library, the conversation; `Team.swift`: Tom, Jerry and Jane, their prompts, and catching a turn that drifts; `Skills.swift`: the skills (the library, editing, scripts, the team); `Listening.swift`: when a sentence is done, telling its own voice from yours by the words, and what a wave is; `ToolRun.swift`: Tool Mac Tool Run's client and the tools over it) |
| `Sources/SuperVoice` | the Mac app: FluidAudio engine, Network.framework server, menu bar panel, the tools' windows, AI listen (`AssistantModel.swift`: the room, the two agents, the voice queue and deliveries, the working sounds; `VoicePrints.swift`: the voices told from yours; `Wave.swift`: the camera), Super Face (`FaceLink.swift`: whether it runs, what's said through it, what's heard checked with it), and the columns beside the panel: the team, its jobs, the skills and the scripts (`SkillsModel.swift`, `SkillsViews.swift`), updater |
| `Tests/VoiceCoreTests` | every endpoint against a fake engine, the parser, formats, the library, the assistant against a fake model |
| `scripts/build-app.sh`, `.github/workflows/build.yml`, `install.sh` | building, releasing (pushes to `main`), installing |
