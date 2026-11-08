# friday internals

Notes behind the behaviour described in the README. Measurements come from macOS 27.2
on an M3 Air; they explain decisions, not promises.

## The stack

`/System/Library/PrivateFrameworks/SiriTTSService.framework` exposes `DaemonSession`,
which talks to `sirittsd`. There is no public Swift interface, so `interfaces/` holds a
hand-written one containing only what this tool needs.

- `_clientId = "com.apple.siritts-tool"` is required for the expressive voices, together
  with `voicePacePreset` / `voiceExpressivityPreset` set by KVC on the request context.
  Without them the daemon silently substitutes a generic legacy render.
- Everything runs on the main thread because the daemon delivers its callbacks through
  the run loop; the HTTP server is single-threaded for the same reason.

## Encodings

The daemon chooses per request:

| source | when | note |
|---|---|---|
| `lpcm` 16-bit int | standard path, single sentence | 22.05–48 kHz |
| `lpcm` 32-bit float | expressive, short text | 24 kHz |
| `opus` packets | standard, multi-sentence or idle daemon | 48 kHz, ~50 kbps, lossy |
| `opus` packets | expressive, longer text | 48 kHz, 960 frames per packet |

All of it is normalised to 48 kHz float mono by `ChunkDecoder` before playback or
writing. Getting that wrong is what makes output sound shredded: float bytes under an
integer WAV header, or Opus packets written as PCM. Chunks can arrive with an all-zero
`AudioStreamBasicDescription`, so a format is only trusted once `isPlausibleFormat`
accepts it.

## Why lossless needs a cache drop

| observation | result |
|---|---|
| same text, repeated while the daemon is hot | `lpcm` |
| same text, after ~20 s idle | `opus` |
| four-sentence paragraph as one request | `opus`, 6/6 |
| the same paragraph as four requests | `lpcm`, 4/4 |
| warm session held open, no clearing | `opus`, even after 120 s |

`clearDeviceCache()` — a private no-argument method on `DaemonSession`, 0.00 s — returns
the next synthesis to `lpcm` (3/3 repeats). Warming the session is not a fix; it locks
the daemon into the lossy mode. Cost on a four-sentence paragraph: 2.20 s of synthesis
with first audio at 70 ms, versus 1.65 s and 44 ms with `--fast`.

Eleven KVC knobs (`synthesisProfile`, `style`, `textProcessingStyle`, `whisper`,
`disableFallbackVoice`, `minimizeDeviceUsage`, `privacySensitive`, `disableCompactVoice`,
`forceOspreyTTS`, `disableThermalFallback`, `synthesisPriority`) change nothing.

`simone` and `Simone` render byte-identical audio on this build, so the case-collision
warning is documentation rather than a live hazard.

## Sentence chunking

One sentence per request raises the odds of the lossless encoder and lowers
time-to-first-word. Boundaries need whitespace after the terminator, so `18.5`, `a.m.`
and `v2.0` stay whole; `Dr.`, `Mr.`, `e.g.`, `U.S.` are guarded; quoted endings travel
with their sentence; `a.m.`/`p.m.` only close a sentence when a capital follows. Word
timings are rebased onto the original text and global timeline.

Limits: 200 chunks or 20 000 characters, then the caller's single-request path.

## Word timings

- Standard path only; the expressive model returns none and the report says
  `"timingsSupported": false` instead of inventing entries.
- `queryWordTimingSupport` under-reports on this build (answers false while still
  delivering timings), so the delivered set decides the flag.
- End times are derived from the next word's start, hence `endDerived: true`.
- Short text yields one coarse range, so per-word granularity is never guaranteed.

## Voice assets

MobileAsset bundles (`com.apple.siri.tts.voice...`) live under
`/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/`. Language
*frontend* bundles are separate from voice bundles; an expressive en-GB voice without
its frontend fails with `Cannot find resource asset`.

`--install` subscribes to an asset and downloads asynchronously, so `--wait` polls the
installed inventory. `--purge` refuses an ambiguous name rather than guessing, prints
its plan without `--force`, and judges success by the filesystem rather than by the
elimination call's return value — on this macOS the synchronous client can report an
entitlement error while `mobileassetd` completes the removal.

The catalog sits behind private classes with no headers, which forces two habits:

- Check the Objective-C type encoding before calling a getter: `locallyAvailable` is
  `B16@0:8`, `versionNumber` is `q16@0:8`. `perform` on a scalar getter returns a bogus
  object pointer and crashes.
- Reach `+alloc` through `class_getClassMethod`; asking the class object for the
  instance implementation returns a forwarding stub that aborts on use.

## Smaller facts

- `friday --prewarm` looks fast (~0.03 s) because the daemon acknowledges before
  loading. The useful place to prewarm is `friday serve --prewarm`, where the session
  survives.
- `say -v <name>` cannot do any of this: macOS 27 accepts any name, ignores it, and
  speaks in the default voice without an error.
- A streamed response measured 59 ms to first audio where the buffered response for the
  same text took 2015 ms; over NDJSON the first sentence was spoken at 340 ms while the
  second line arrived at 3.3 s.
