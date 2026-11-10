# friday

Local text-to-speech for macOS. Speaks with Siri's own neural voices — no cloud, no
third-party binaries.

```bash
friday "Say this out loud"
echo "$REPLY" | friday -q -          # for a voice loop
llm | friday --stream -              # speak sentences while the model is still writing
friday -o line.wav "render to a file"
friday serve --port 8787             # HTTP API
friday --skill                       # agent-facing contract: flags, limits, exit codes
```

Installed as `/opt/homebrew/bin/friday`.

## Voice and config

Default is `simone` on the **standard** render path. The expressive 3B model sounds
theatrical, so it stays opt-in via `--expressive`.

CLI flag → config file → built-in. Config lives at `~/.config/friday/config.json`;
a missing file is fine, an unparsable one is an error naming the file and key.

```bash
friday voices                                   # installed voices
friday voices --status simone                   # one voice in detail
friday voices --available                       # all 149 assets Apple offers
friday voices --install NAME --language en-GB --wait
friday voices --purge com.apple.siri.tts.voice.ar_SA.samer.neural.premium --dry-run
friday config                                   # effective settings
friday config set default-voice simone --standard
friday config set sentence-chunking off
friday config unset default-voice
friday config reset
```

`--purge` takes the full asset specifier — the last column of `voices --available` —
and does nothing without `--force`.

`FRIDAY_CONFIG=/path.json` overrides the config path (the tests use this).

## Server

```bash
friday serve [--port 8787] [--host 127.0.0.1] [--auth-token-env VAR] [--prewarm]
```

```
POST /v1/audio/speech   {input, voice?, generation?, response_format: wav|pcm, speed?, stream?}
POST /say               {text, voice?}   speak, then return when playback starts
POST /stop                               cancel the request in flight, or leftover playback
GET  /v1/models                          installed voices
GET  /healthz                            status, voice count, uptime
```

`--auth-token-env VAR` requires `Authorization: Bearer $VAR` on every route. Responses
carry `X-Request-Id`, `X-Friday-Voice`, `X-Friday-Generation` and `X-Friday-Source`.
Errors use the OpenAI envelope: `{"error": {"message", "type", "param", "code"}}`.

`/stop` is answered *while* a request runs — the listener is polled inside the wait
loop that a request spends blocked — so it does not queue behind the answer it is
cancelling. Every other path gets `503 busy` during that time:

```bash
friday stop                          # cancel whatever is in flight
friday stop --request-id 8d67751a    # refuse to cancel anything else (409 otherwise)
curl -X POST localhost:8787/stop -d '{"request_id":"8d67751a"}'
```

`serve` keeps one daemon session alive, so requests are warm: 47–72 ms to first audio
versus roughly 0.5 s for a cold CLI call.

## Streaming

Audio always streams — playback starts while synthesis continues.

```bash
llm | friday --stream -        # one sentence per request, spoken as it completes

# streamed audio out: chunked raw 48 kHz mono s16le
curl -N -X POST localhost:8787/v1/audio/speech \
  -d '{"input":"...","response_format":"pcm","stream":true}'

# streaming text in: NDJSON on a chunked body
printf '%s\n' '{"text":"First."}' '{"text":"Second.","end":true}' \
  | curl -N -X POST localhost:8787/say -H 'Transfer-Encoding: chunked' --data-binary @-
```

A streamed response returns first audio in ~60 ms where the buffered form needs ~2 s.
A stop ends the body cleanly, so the client receives a valid, shorter response rather
than a truncation it cannot tell from a crash.
`stream` requires `response_format: "pcm"` — WAV needs a length a stream cannot know.
NDJSON accepts `text`, `flush`, `voice`, `end`.

Bounds: 500 sentences and 20 000 characters per stream, 4 MB per chunked body, long
unpunctuated runs cut at a word boundary every 800 characters.

## Audio quality

The daemon picks its encoder per request and will not be told which to use; idle or
warm it answers lossy Opus (~50 kbps, audibly thinner). `friday` clears the daemon's
device cache before each request, which puts it back on lossless PCM.

```bash
friday --lossless "default"        # explicit
friday --fast "accept opus"        # ~0.2 s less synthesis per sentence
```

Text is split one sentence per request, so the first word plays while later sentences
render. Splitting is conservative: `18.5`, `a.m.`, `v2.0`, `Dr.`, `U.S.` and quoted
endings stay whole. Beyond 200 chunks or 20 000 characters it falls back to one request.

```bash
friday --chunked "default"           # one sentence per request
friday --no-chunked "one request"    # lossy above one sentence
friday config set lossless off
```

`--timings` prints word timings as JSON, `--timings-out FILE` writes them. Standard path
only; the expressive model returns none.

## Debugging

```bash
friday --debug "text"
FRIDAY_DEBUG=1 FRIDAY_DEBUG_LOG=/tmp/f.log friday serve
```

Exit codes name the failure class:

| code | meaning |
|---:|---|
| 0 | success |
| 1 | unexpected (re-run with `--debug`) |
| 2 | bad usage or invalid value |
| 3 | service unreachable (sirittsd, or `friday serve` for `stop`) |
| 4 | unknown voice (suggests the nearest installed name) |
| 5 | config unreadable or unparsable |
| 6 | synthesis failed |
| 7 | timeout |
| 8 | no audio produced |
| 9 | output failed |
| 10 | the daemon substituted a different voice (its asset is missing) |
| 130 | cancelled |

An unparsable flag is an error, not text to speak. Bad values are refused rather than
defaulted.

## Tests

```bash
./build.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
FRIDAY_AUDIO_TESTS=1 DEVELOPER_DIR=… swift test    # adds real synthesis
swift test --filter ChunkingTests                  # one area
```

64 XCTest cases, about 5 s. The 9 audio tests skip themselves unless
`FRIDAY_AUDIO_TESTS=1`: they need the daemon, this machine's voice assets, and they make
sound.

XCTest ships with Xcode, not Command Line Tools, so plain `swift test` fails with
`unable to resolve module dependency: 'XCTest'`. `DEVELOPER_DIR` points at a developer
directory that has it — no sudo, no `xcode-select` change. A one-time
`sudo xcode-select --switch /Applications/Xcode.app` also works. Building never needs
Xcode, only testing does. There is no CI: the audio checks need this machine.

## Limits

- Private Apple framework (`SiriTTSService`). An OS update can break it; not App
  Store shippable.
- Requests serialise: one connection at a time, and while one runs any other path is
  `503 busy`. Only `/stop` is answered, and only from inside the wait a request already
  spends blocked — so a stop is noticed at the next 20 ms slice, not instantly.
- `nora` clips on the standard path (1.17% of samples at full scale). `simone` and
  `Riya` are clean.
- `voices --install` and `--purge --force` have not been exercised against a real
  bundle.
- Premium Siri voices need the asset the daemon actually renders from. When it is
  missing the daemon substitutes its legacy voice and reports success, so friday checks
  the delivered rate and fails with exit 10 instead of speaking the wrong voice.
  `friday voices --status <voice>` shows which asset is `available` rather than
  `installed`.
- A request body that stops arriving is dropped after 300 s of silence.
- Uses `AVAudioEngine.connect` / `AVAudioPlayerNode.play`, deprecated in macOS 27.
- macOS 27 minimum.

## Layout

```
Sources/friday/          CLI, daemon session, decoder, speaker, HTTP server
Sources/FridayCore/      chunking, config, errors, WAV encoding, debug tracing
Tests/FridayTests/       logic, binary/HTTP, audio (opt-in)
Package.swift            one target, one test target
build.sh                 swift build -c release, copies the product
```

Implementation notes (encodings, cache behaviour, MobileAsset ABI): [docs/internals.md](docs/internals.md).
