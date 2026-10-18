# Super Voice

A menu bar app for the Mac that does speech, offline, and does it well:

- **Read aloud**: six Kokoro voices (Heart, Bella, Emma; Michael, Fenrir, Puck).
- **Dictate**: talk, and it's written down and kept.
- **Transcribe**: drop an audio file, get its text, kept with the rest.
- **Library**: everything written down, in a grid, to search, open, edit, read back, copy or delete.
- **API**: every app on the Mac can speak and listen through it, the way they use Ollama.

No language models, no Ollama, nothing else. The speech runs on Apple's Neural Engine through
[FluidAudio](https://github.com/FluidInference/FluidAudio): Kokoro-82M to speak and Parakeet TDT v3
to listen, the same as Tool Mac Tool.

## For other apps

**[API.md](API.md)** is what client apps need: `http://127.0.0.1:8767`, with `/api/tts`,
`/api/stt`, `/api/transcribe`, `/api/say`, and OpenAI-compatible `/v1/audio/*`.
[openapi.yaml](openapi.yaml) is the same, for code generators.

```bash
curl -s localhost:8767/api/tts -d '{"text": "Hello there", "voice": "heart"}' -o hello.wav
curl -s localhost:8767/api/stt --data-binary @note.m4a
```

## Status

The API is specified; the app is being built. See [GOAL.md](GOAL.md) for what it's for.
