# Super Voice API

Super Voice is a menu bar app for the Mac that speaks and listens on this machine, offline, and
serves both to any other app over HTTP, the way Ollama serves models:

- **TTS**: Kokoro-82M, six voices (three women, three men).
- **STT**: Parakeet TDT v3 (25 European languages, detected by itself).

Both run on Apple's Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio),
the same engine and voices as Tool Mac Tool. Each model downloads once (a few hundred MB, into
`~/.cache/fluidaudio`); after that nothing leaves the Mac.

This document is the contract for client apps. It's stable: new fields may be added to responses,
but nothing listed here changes meaning.

```
Base URL   http://127.0.0.1:8767
```

## In one minute

```bash
# text -> speech (WAV)
curl -s localhost:8767/api/tts -d '{"text": "Hello there", "voice": "heart"}' -o hello.wav

# speech -> text
curl -s localhost:8767/api/stt --data-binary @note.m4a
# {"text":"Remind me to call Sam at four.","duration":2.81}

# a long file -> timestamped lines, streamed as they're done (NDJSON)
curl -sN localhost:8767/api/transcribe --data-binary @meeting.mp3

# the same file as subtitles
curl -s 'localhost:8767/api/transcribe?format=srt' --data-binary @meeting.mp3 -o meeting.srt

# say something out loud on the Mac
curl -s localhost:8767/api/say -d '{"text": "Build finished"}'

# or use any OpenAI SDK
curl -s localhost:8767/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model": "kokoro", "input": "Hello", "voice": "bella", "response_format": "wav"}' -o hello.wav
curl -s localhost:8767/v1/audio/transcriptions -F file=@note.m4a -F model=parakeet
```

## Endpoints

| route | switch | does |
|---|---|---|
| `GET  /api/health` | — | whether it's up, which endpoints are on, how the models are doing |
| `GET  /api/voices` | — | the six voices, and the default voice and speed |
| `POST /api/tts` | `tts` | text → `audio/wav` (24 kHz, mono, 16-bit); `"stream": true` sends each sentence as it's made |
| `POST /api/stt` | `stt` | audio (any length, any common format) → `{"text"}` |
| `POST /api/transcribe` | `transcribe` | audio file → NDJSON stream of timestamped segments, or JSON / text / SRT / VTT in one go |
| `POST /api/say` | `say` | text → spoken on this Mac's speakers (queued) |
| `POST /api/say/stop` | `say` | stops speaking and empties the queue |
| `GET  /v1/models` | `openai` | OpenAI-compatible model list |
| `POST /v1/audio/speech` | `openai` + `tts` | OpenAI-compatible TTS |
| `POST /v1/audio/transcriptions` | `openai` + `stt` | OpenAI-compatible STT |
| `GET  /` | — | a status page, with a box to try each endpoint |

**Switches.** Each endpoint group can be turned off or on from the menu bar panel (and the whole
server stopped and started) without quitting the app. A call to a group that's off gets
`503 {"error": "tts is turned off in Super Voice", "code": "endpoint_off"}`. When the server is
stopped, connections are refused. `GET /api/health` always says what's on.

---

### `GET /api/health`

```json
{
  "ok": true,
  "service": "supervoice",
  "version": "0.1.0",
  "port": 8767,
  "uptime": 3641,
  "tts": true, "stt": true, "transcribe": true, "say": true, "openai": true,
  "models": {
    "tts": {"name": "kokoro-82m",          "state": "ready"},
    "stt": {"name": "parakeet-tdt-0.6b-v3", "state": "downloading", "progress": 0.42}
  }
}
```

- The top-level booleans say which endpoint groups are on. (They're the same keys glassvoice's
  health uses, so clients that check `health.tts` work against either.)
- `port` is the port it's listening on and `uptime` how many seconds it has been serving.
- `models.*.state` is one of `not_loaded` (loads on first use), `downloading` (with `progress`, 0
  to 1), `loading`, `ready`, `failed` (with `message`).

Use it to check the service is there before offering speech in your UI: a refused connection or a
timeout means Super Voice isn't running.

### `GET /api/voices`

```json
{
  "default": "af_heart",
  "speed": 1.0,
  "voices": [
    {"id": "af_heart",   "name": "Heart",   "gender": "female", "accent": "us", "alias": "f1"},
    {"id": "af_bella",   "name": "Bella",   "gender": "female", "accent": "us", "alias": "f2"},
    {"id": "bf_emma",    "name": "Emma",    "gender": "female", "accent": "uk", "alias": "f3"},
    {"id": "am_michael", "name": "Michael", "gender": "male",   "accent": "us", "alias": "m1"},
    {"id": "am_fenrir",  "name": "Fenrir",  "gender": "male",   "accent": "us", "alias": "m2"},
    {"id": "am_puck",    "name": "Puck",    "gender": "male",   "accent": "us", "alias": "m3"}
  ]
}
```

`default` and `speed` are what the user picked in the app; they're used whenever a request leaves
`voice` or `speed` out.

**Naming a voice.** Anywhere a `voice` is taken, any of these work (case doesn't matter):

| you send | means |
|---|---|
| `af_heart` | the Kokoro id |
| `heart` | the name |
| `f1` … `f3`, `m1` … `m3` | best first: f1 Heart, f2 Bella, f3 Emma, m1 Michael, m2 Fenrir, m3 Puck |
| `female` / `male` | f1 / m1 |
| nothing, `null`, `""` | the app's default voice |

The short names `f1`–`f3` and `m1`–`m3` mean the same voices as in glassvoice and never change.
An unknown name on `/api/*` is `400 {"code": "unknown_voice"}`; on `/v1/*` it falls back to the
default voice (OpenAI SDKs send names like `alloy`).

### `POST /api/tts`

Request (JSON):

```json
{"text": "Hello there. How are you today?", "voice": "f1", "speed": 1.0, "stream": false}
```

| field | | |
|---|---|---|
| `text` | required | up to 20,000 characters; numbers, dates, money and abbreviations are read naturally |
| `voice` | optional | see *Naming a voice* |
| `speed` | optional | 0.5 to 2.0; default: the app's speed (1.0 unless the user changed it) |
| `format` | optional | `wav` (default) or `pcm` (raw 16-bit little-endian, 24 kHz, mono, no header) |
| `stream` | optional | `true`: send each sentence as soon as it's made (see below) |

A plain-text body (`Content-Type: text/plain`) is taken as `text`, with the defaults.

Response: `200`, `Content-Type: audio/wav` (or `audio/pcm`), with headers `X-Voice: af_heart` and
`X-Sample-Rate: 24000`.

**Streaming.** With `"stream": true` the response is chunked: a WAV header first (its length fields
set to the maximum, as for any live stream), then the audio of each sentence as it's made. The
first sound arrives after the first sentence (a fraction of a second) rather than after the whole
text. Browsers' `<audio>`, `ffplay` and `AVPlayer` all play it as it comes; for the lowest
latency, use `"format": "pcm"` and feed the bytes to your own audio output.

```js
const r = await fetch("http://127.0.0.1:8767/api/tts", {
  method: "POST",
  headers: {"Content-Type": "application/json"},
  body: JSON.stringify({text: "Hello there", voice: "bella"}),
});
new Audio(URL.createObjectURL(await r.blob())).play();
```

### `POST /api/stt`

Send the audio as the request body: WAV, AIFF, CAF, MP3, M4A/AAC, FLAC, or a video's sound track
(MP4, MOV). Any sample rate, mono or stereo. Raw PCM works too, with
`?format=pcm&rate=16000&channels=1` (16-bit little-endian). `multipart/form-data` with a `file`
field is also accepted.

```bash
curl -s localhost:8767/api/stt --data-binary @note.m4a
```

```json
{"text": "Remind me to call Sam at four.", "duration": 2.81, "time": 0.19}
```

`duration` is the audio's length and `time` how long writing it down took, both in seconds. Any
length works (long audio is cut at quiet moments into pieces under a minute), but this answers only
once it's all done; for long files use `/api/transcribe`, which reports as it goes.
`?lang=` is accepted and ignored (Parakeet detects the language), for glassvoice compatibility.

Silence or no speech gives `{"text": ""}`, not an error.

### `POST /api/transcribe`

The same body as `/api/stt`. By default the answer is a stream of NDJSON events, one JSON object
per line, `Content-Type: application/x-ndjson`, sent as the work goes:

```
{"type":"info","duration":1834.2}
{"type":"progress","done":0.0,"total":1834.2}
{"type":"segment","start":0.0,"end":4.36,"text":"Okay, let's get started."}
{"type":"segment","start":4.36,"end":9.8,"text":"First item is the budget."}
{"type":"progress","done":58.1,"total":1834.2}
…
{"type":"done","text":"Okay, let's get started. First item is the budget. …"}
```

| event | fields |
|---|---|
| `info` | `duration`: the audio's length in seconds |
| `progress` | `done`, `total`: seconds of audio written down so far, and in all |
| `segment` | `start`, `end` (seconds), `text`: one phrase, in order |
| `done` | `text`: everything, joined |
| `error` | `message`; the stream ends after it |

Closing the connection stops the work.

**All at once.** `?format=` gives the whole result in one response instead:

| `format` | response |
|---|---|
| `json` | `{"text", "duration", "segments": [{"start", "end", "text"}, …]}` |
| `txt` | plain text |
| `srt` | SubRip subtitles |
| `vtt` | WebVTT subtitles |

```python
import json, requests
with open("meeting.mp3", "rb") as f:
    r = requests.post("http://127.0.0.1:8767/api/transcribe", data=f, stream=True)
    for line in r.iter_lines():
        ev = json.loads(line)
        if ev["type"] == "segment":
            print(f'{ev["start"]:7.1f}  {ev["text"]}')
```

### `POST /api/say`

```json
{"text": "Build finished", "voice": "m1", "speed": 1.0}
```

Speaks on this Mac's speakers, in turn after anything already queued, and answers at once:
`202 {"ok": true, "id": "9F2C…", "queued": 1}`. `POST /api/say/stop` stops it and empties the
queue: `{"ok": true, "stopped": 2}`.

---

## OpenAI-compatible

For apps that already speak OpenAI's audio API: point the SDK's base URL at
`http://127.0.0.1:8767/v1`. The API key can be anything (unless a token is set; see *Access*).

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8767/v1", api_key="local")

with client.audio.speech.with_streaming_response.create(
        model="kokoro", voice="heart", input="Hello there", response_format="wav") as r:
    r.stream_to_file("hello.wav")

text = client.audio.transcriptions.create(model="parakeet", file=open("note.m4a", "rb")).text
```

```js
import OpenAI from "openai";
const client = new OpenAI({baseURL: "http://127.0.0.1:8767/v1", apiKey: "local"});
const t = await client.audio.transcriptions.create({model: "parakeet", file: fs.createReadStream("note.m4a")});
```

**`POST /v1/audio/speech`**: JSON `{model, input, voice, speed, response_format}`.
- `model`: anything (`kokoro`, `tts-1`, … all mean Kokoro).
- `voice`: see *Naming a voice*; names it doesn't know (`alloy`, …) get the default voice.
- `response_format`: `wav` or `pcm` (24 kHz). Anything else (`mp3` is the SDKs' default, `opus`,
  `aac`, `flac`) is answered with WAV and `Content-Type: audio/wav`; players read it either way,
  but ask for `wav` to get what you expect.
- `instructions` is ignored.

**`POST /v1/audio/transcriptions`**: `multipart/form-data` with `file`, `model` (anything:
`parakeet`, `whisper-1`, …), `language` (ignored), `prompt` (ignored) and `response_format`:
`json` (default, `{"text"}`), `text`, `srt`, `vtt` or `verbose_json` (with `duration` and
`segments`).

**`GET /v1/models`**: `kokoro` and `parakeet`.

Errors on `/v1/*` have OpenAI's shape: `{"error": {"message", "type", "code"}}`.

---

## Errors

`/api/*` errors are JSON, `{"error": "what went wrong", "code": "…"}`:

| status | `code` | when |
|---|---|---|
| 400 | `missing_text`, `bad_speed`, `unknown_voice`, `bad_request` | the request isn't right |
| 401 | `unauthorized` | a token is set and the request didn't send it (see *Access*) |
| 404 | `not_found` | no such route |
| 413 | `too_large` | text over 20,000 characters, or a body over 2 GB |
| 415 | `unsupported_audio` | the audio couldn't be read |
| 503 | `endpoint_off` | that endpoint is turned off in the app |
| 503 | `model_loading` | the model is still downloading for the first time; has `progress`, and a `Retry-After` header |
| 500 | `failed` | anything else; `error` says what |

Once a model has been downloaded it loads in a second or two; requests made meanwhile just wait.
Only the very first download answers `model_loading`, so clients can show "Getting the voices
ready… 42%" and retry.

## Access

- It listens on **127.0.0.1** only: other machines can't reach it. Programs on this Mac (curl,
  scripts, apps, servers) are always answered.
- **Browsers.** Pages from this machine (`http://localhost:*`, `http://127.0.0.1:*`) may call it
  (CORS). Other origins are refused unless added in the app's settings (globs like
  `https://app.example.com`; `*` allows any). Requests whose `Host` names another machine are
  refused, so a website can't reach it by pointing its own domain at 127.0.0.1.
- **Sharing on the network** (off by default): the panel's *Allow other devices* switch makes it
  listen on all interfaces and requires a token from everyone but this Mac:
  `Authorization: Bearer <token>`. The token is shown in the panel, with a copy button.

## Versus glassvoice

Clients written for glassvoice (`127.0.0.1:8766`) work against Super Voice by changing the port:
`/api/health`, `/api/voices`, `/api/tts`, `/api/stt`, `/api/transcribe` and `/api/say` take and
return the same things, and voices `f1`–`f3` / `m1`–`m3` are the same voices. Not here:
`/api/events` and `/api/command` (Glass's live voice with barge-in), the `language` event (Parakeet
doesn't report one), and voices beyond the six.

A machine-readable description is in [openapi.yaml](openapi.yaml).
