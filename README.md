# friday

Speaks text with Siri's own neural voices, straight from your Mac. No cloud, no
third-party binaries, no audio files shipped anywhere.

```bash
friday "Say this out loud"
echo "$REPLY" | friday -q -            # for a voice loop
friday -o line.wav "render to a file"
friday voices                          # installed voices and their asset path
friday --skill                         # agent skill file: capabilities, limits, exit codes
```

Installed as a symlink: `/opt/homebrew/bin/friday`.

## Default voice

The built-in pair is `simone` on the **standard** render path — the expressive
3B voice model is deliberately bypassed because it sounds theatrical. That pair
is overridable through a config file, and CLI flags always win over it:

```bash
friday config                                    # show effective settings
friday config set default-voice simone --standard
friday config set default-generation expressive
friday config set pace 2
friday config set sentence-chunking off
friday config unset default-voice                # also clears the derived generation
friday config reset
```

Stored at `~/.config/friday/config.json` (override the path with
`FRIDAY_CONFIG=/some/file.json`, which is how the tests stay isolated).

Precedence: CLI flag → config file → built-in (`simone`, standard).

## Subcommands

```bash
friday serve  [--port 8787] [--host 127.0.0.1] [--auth-token-env VAR] [--prewarm]
friday voices [--status NAME | --install NAME --language xx [--wait] | --manage | --default NAME]
friday config [set KEY VALUE | unset KEY | reset]
friday --completions zsh|bash|fish
friday --man
friday --skill
```

`--skill` prints the agent-facing contract: what friday can do, how to call it,
which flags matter, and which paths are unverified. It is embedded in the binary
so it cannot drift from the installed build.

`serve` also solves cold start: one process holds one `DaemonSession`, so every
request is warm (measured 47–72 ms to first audio versus ~0.5 s per CLI call).

### HTTP endpoints

```
POST /v1/audio/speech   {input, voice?, generation?, response_format: wav|pcm, speed?}
POST /say               {text, voice?}      synthesise, start playback, then return
                                            (synchronous: it does not return early)
POST /stop                                  cancel playback + synthesis (barge-in)
GET  /v1/models                             installed voices, OpenAI-shaped
GET  /healthz                               {status, voices, defaultVoice, uptimeSeconds}
```

`--auth-token-env VAR` requires `Authorization: Bearer $VAR` on every route.
Responses carry `X-Friday-Voice`, `X-Friday-Generation`, `X-Friday-Source`.

## Sentence chunking

On by default, and the measurements behind it are worth knowing exactly, because
they are messier than they first looked.

`sirittsd` picks its encoder per request and offers no control over it:

| observation | result |
|---|---|
| same text, repeated while the daemon is hot | `lpcm` 48 kHz — lossless |
| same text, after ~20 s idle | `opus` 48 kHz — about 50 kbps, lossy |
| four-sentence paragraph as one request | `opus`, 6 attempts out of 6 |
| the same paragraph as four requests | `lpcm`, 4 out of 4 |

Both encodings decode to the same number of samples for the same text, so this is
transport, not a different voice or model. `simone` and `Simone` even render
byte-identical audio, and `disableCompactVoice`, `forceOspreyTTS`,
`synthesisProfile` and `synthesisPriority` change nothing. At ~50 kbps the voice
sounds thinner, which is what was heard first and measured second.

The lever that actually works is `clearDeviceCache()` — a private no-argument
method on `DaemonSession` that costs 0.00 s and puts the next synthesis back on
the lossless encoder:

```
warm daemon, plain request            opus   synthesis 0.02s
clearDeviceCache(), then request      lpcm   synthesis 0.45s   <- 3/3 repeats
warm session held open, no clearing   opus   even after 120s idle
```

Warming the session is not a fix; it locks the daemon into the lossy mode. So
`friday` clears the cache before each request by default:

```bash
friday --lossless "default"      # explicit
friday --fast "accept opus"      # ~0.2s less synthesis per sentence
friday config set lossless off
```

Measured cost, four-sentence paragraph: lossless `lpcm` throughout in 2.20 s of
synthesis with first audio at 70 ms, versus mixed `lpcm`/`opus` in 1.65 s with
first audio at 44 ms. Renders report `src=` and `codec=lossy`, so the format is
visible rather than left to the ear.

`friday` also sends one sentence per request, so the first word plays while later
sentences are still rendering. The cost is a little cross-sentence prosody.

```bash
friday --chunked "default"        # explicit
friday --no-chunked "one request" # the old behaviour: lossy above one sentence
friday config set sentence-chunking off
```

Splitting is deliberately conservative: a boundary needs whitespace after the
terminator, so `18.5`, `a.m.`, `v2.0` stay whole; `Dr.`, `Mr.`, `e.g.`, `U.S.`
are guarded; quoted endings such as `"stop."` travel with their sentence. Word
timings are rebased onto the original text and the global timeline, so they stay
correct across chunks. Splitting stops at 200 chunks or 20,000 characters and
falls back to a single request.

## Word timings

```bash
friday --timings "print timings as JSON"
friday --timings-out t.json -o line.wav "write them to a file"
```

Two things worth knowing:

- Only the **standard** path produces timings. The expressive 3B model returns
  none, and the report says `"timingsSupported": false` rather than inventing
  them.
- `queryWordTimingSupport` under-reports on this build (answers false while
  still delivering timings), so the delivered set decides the flag.
- End times are derived from the next word's start, so every entry carries
  `endDerived: true`.

## Debugging

Failures print one line on stderr: what failed, why, and the next step. Nothing that
matters is silent — an unparsable flag is an error rather than text to speak, a bad
numeric value is rejected rather than defaulted, and a config file that exists but
cannot be parsed stops the run instead of quietly falling back to built-ins.

```bash
friday --debug "text"                        # stage trace on stderr
FRIDAY_DEBUG=1 friday propose "text"         # same, for a service or script
FRIDAY_DEBUG=1 FRIDAY_DEBUG_LOG=/tmp/f.log friday serve   # capture without the terminal
```

The trace covers config resolution, the resolved voice and asset key, which session and
render path was chosen, per-request source format and frame counts, any chunk that fails
to decode, and the playback drain.

Exit codes name the class of failure, so a script can branch without parsing text:

| code | meaning |
|---:|---|
| 0 | success |
| 1 | unexpected failure (re-run with `--debug`) |
| 2 | bad usage: unknown flag/subcommand, or invalid value |
| 3 | sirittsd unreachable |
| 4 | unknown voice (message suggests the nearest installed name) |
| 5 | config file unreadable or unparsable (message names file and key) |
| 6 | synthesis failed |
| 7 | timeout (message names stage and seconds) |
| 8 | no audio produced |
| 9 | output failed (file write, audio engine, or system helper) |
| 130 | cancelled with Ctrl-C, printed as nothing |

Over HTTP, failures use the OpenAI envelope `{"error": {"message", "type", "param",
"code"}}` with codes like `unknown_voice`, `invalid_json`, `daemon_unavailable`,
`timeout`, and every response carries `X-Request-Id`, which also appears in the server's
debug log.

## How it works

`/System/Library/PrivateFrameworks/SiriTTSService.framework` exposes a
`DaemonSession` that talks to `sirittsd`. The framework has no public Swift
interface, so `interfaces/` holds a hand-written one containing only what this
tool needs. A `DaemonSession` needs `_clientId = "com.apple.siritts-tool"` for
the expressive voices, plus `voicePacePreset` / `voiceExpressivityPreset` set by
KVC on the request context — without those the daemon silently substitutes a
generic legacy render.

The daemon returns audio in **three** shapes and chooses on its own:

| source | when | note |
|---|---|---|
| `lpcm` 16-bit int | standard path, single sentence | 22.05–48 kHz |
| `lpcm` 32-bit float | expressive, short text | 24 kHz |
| `opus` packets | standard path, multi-sentence | 48 kHz, ~50 kbps, lossy |
| `opus` packets | expressive, longer text | 48 kHz, 960 frames per packet |

Everything is normalised to 48 kHz float mono by `ChunkDecoder` before playback
or writing. Skipping that is what makes output sound shredded: float bytes under
an integer WAV header, or Opus packets written as PCM. Chunks can also arrive
with an all-zero `AudioStreamBasicDescription`, so a format is only trusted once
`isPlausibleFormat` accepts it.

Voice assets themselves are MobileAsset bundles (`com.apple.siri.tts.voice...`
under `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/`).

```bash
friday voices --available                      # Apple's full catalog: 149 assets
friday voices --install NAME --language en-GB --wait
friday voices --purge SPECIFIER --dry-run      # show what would be removed
friday voices --purge SPECIFIER --force        # actually delete it
```

`--install` subscribes to an asset; downloads are asynchronous, so `--wait`
polls the installed inventory. Language *frontend* bundles are separate from
voice bundles — an expressive en-GB voice fails with `Cannot find resource
asset` without them.

`--purge` is guarded: an ambiguous name is refused rather than guessed at, it
prints the plan and does nothing without `--force`, and success is judged by the
filesystem rather than by the elimination call's return value. The filesystem is
the only trustworthy signal because on this macOS the synchronous MobileAsset
client can report an entitlement error while `mobileassetd` still completes the
removal.

The catalog lives behind private classes with no headers, which makes two things
mandatory rather than optional: every getter checks its Objective-C type encoding
first (`locallyAvailable` is `B16@0:8`, `versionNumber` is `q16@0:8`; calling
`perform` on a scalar getter yields a bogus object pointer and crashes), and
`+alloc` must be reached through `class_getClassMethod` — asking the class object
for the instance implementation returns a forwarding stub that aborts on use.

## Layout

```
Sources/friday/main.swift        argument parsing, dispatch, Ctrl-C barge-in
Sources/friday/Config.swift      persisted defaults
Sources/friday/Voices.swift      catalog, resolution, generation policy
Sources/friday/Synthesizer.swift one synthesis path for CLI, prewarm and server
Sources/friday/Decoder.swift     Opus / float / int → 48 kHz float mono
Sources/friday/Speaker.swift     streaming playback, stop, drain
Sources/friday/Timings.swift     word timing assembly + JSON
Sources/friday/TextChunker.swift sentence splitting for the lossless path
Sources/friday/HTTPServer.swift  POSIX sockets, no dependencies
Sources/friday/Commands.swift    serve / voices / config
Sources/friday/Help.swift        usage, completion scripts, man page
Sources/friday/Util.swift        errors, WAV encoding, run-loop pump
```

## Verification status

Exercised end to end on macOS 27.2: CLI defaults and overrides, word timings
(including a 44-word sentence, which previously lost 28 words), timings to file,
prewarm, all config verbs, voice list/status/available/default, purge dry-run,
ambiguity and unknown-voice refusals, every failure path (typo'd flags, unknown
subcommands, bad numeric values, missing values, corrupt config, unknown voice),
completion scripts (zsh and bash pass their
own syntax checkers), man page, skill file, and every HTTP route
including bearer auth. Sentence splitting is checked against seven boundary
cases (abbreviations, decimals, quoted endings, ellipsis, no terminator), and
timings are verified to map back onto the original text after chunking. Audio
correctness is checked by amplitude (peak/rms) rather than by ear.

Not verified, deliberately or unavoidably:

- **Actual deletion of an installed bundle.** `--force` on a real voice would
  remove a working Apple asset, and the re-download path is itself untested, so
  only the elimination call ABI was proven — against a specifier that is not
  installed, where the call is a harmless no-op.
- **`--install` download and `--wait` polling** — never pulled a 20–250 MB
  bundle.
- **`/stop` preempting an in-flight synthesis** — the server is single-threaded
  on the main run loop (required by `sirittsd`), so `/stop` is queued behind the
  request it would cancel. CLI Ctrl-C barge-in does work: exit 130 in 0.73 s,
  including during playback drain after chunked synthesis has finished.
- **Clipping on a loud voice.** `nora` on the standard path renders 1.17% of samples
  at full scale (peak 1.000) and audibly distorts; `simone` and `Riya` are clean.
  No limiter is applied yet.

## Build

```bash
./build.sh      # swiftc; needs Command Line Tools with the macOS 26+ SDK
```

## Caveats

- Private Apple framework. Undocumented, unentitled, and an OS update can break
  it. Fine on your own Mac; not shippable to the App Store.
- Two installed voices differ only by case — `Simone` (neural) and `simone`
  (expressive). Exact-case matching runs first.
- `friday --prewarm` measures fast (~0.03 s) because the daemon acknowledges
  before loading; the useful place for prewarming is `friday serve --prewarm`,
  where the session survives.
- `say -v <name>` cannot do any of this: on macOS 27 it accepts any name, ignores
  it, and speaks in the default voice without an error.
- `AVAudioEngine.connect` and `AVAudioPlayerNode.play` are deprecated in macOS 27
  (4 build warnings); still functional.
