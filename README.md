# friday

Speaks text with Siri's own neural voices, straight from your Mac. No cloud, no
third-party binaries, no audio files shipped anywhere.

```bash
friday "Say this out loud"
echo "$REPLY" | friday -q -            # for a voice loop
friday -o line.wav "render to a file"
friday voices                          # installed voices and their asset path
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
```

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
| `lpcm` 16-bit int | standard path | 22.05–48 kHz |
| `lpcm` 32-bit float | expressive, short text | 24 kHz |
| `opus` packets | expressive, longer text | 48 kHz, needs real decoding |

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
Sources/friday/HTTPServer.swift  POSIX sockets, no dependencies
Sources/friday/Commands.swift    serve / voices / config
Sources/friday/Help.swift        usage, completion scripts, man page
Sources/friday/Util.swift        errors, WAV encoding, run-loop pump
```

## Verification status

Exercised end to end on macOS 27.2: CLI defaults and overrides, word timings
(including a 44-word sentence, which previously lost 28 words), timings to file,
prewarm, all config verbs, voice list/status/available/default, purge dry-run,
ambiguity and unknown-voice refusals, completion scripts, man page, exit codes,
and every HTTP route including bearer auth. Audio correctness is checked by
amplitude (peak/rms) rather than by ear.

Not verified, deliberately or unavoidably:

- **Actual deletion of an installed bundle.** `--force` on a real voice would
  remove a working Apple asset, and the re-download path is itself untested, so
  only the elimination call ABI was proven — against a specifier that is not
  installed, where the call is a harmless no-op.
- **`--install` download and `--wait` polling** — never pulled a 20–250 MB
  bundle.
- **`/stop` preempting an in-flight synthesis** — the server is single-threaded
  on the main run loop (required by `sirittsd`), so `/stop` is queued behind the
  request it would cancel. CLI Ctrl-C barge-in does work: exit 130 in 0.73 s.

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
