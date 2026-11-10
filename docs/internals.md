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
- Daemon callbacks do **not** arrive on the main thread: `didGenerateAudio`,
  `didGenerateWordTimings` and the synthesis completion all run on sirittsd's own
  threads (`Thread.isMainThread` is false, measured). They signal a semaphore; the main
  thread pumps its run loop while waiting, which is what lets the SIGINT dispatch source
  and timers fire. Request handling is serial because the accept loop handles one
  connection at a time, not because of thread affinity.
- A stop has to be answered while a request runs, and the main thread is busy waiting.
  It polls the listener with `poll(…, 0)` on each 20 ms slice of that wait (`pumpRunLoop`
  takes a `tick`), so `/stop` is served at most one slice late, on the same thread, and
  anything else gets 503. An earlier design used a second accepting thread with an
  "in flight" flag; a client that sent its next request immediately after reading a
  response could be refused while that flag was still set, so it was replaced. The audio
  callback still writes chunks from the daemon's thread, which is why nothing else touches
  that socket during a stream.
- A stop has to be answerable whenever the main thread is blocked, which is in two places:
  waiting for a synthesis, and waiting for the next chunk of a request body. Both poll the
  listener. The body reader switches to 200 ms receive slices while a tick is attached and
  gives up after 300 s of silence, so a stalled producer cannot pin the server.
- The cancel flag is cleared once per request, not per synthesis, and checked before each
  utterance is submitted. Clearing it inside `synthesize()` lost stops that arrived while
  the body was still arriving — the server answered `stopped: true` and then spoke anyway.
- A missing voice asset does not fail; the daemon substitutes its legacy Vocalizer render
  and returns success, so the only evidence is the delivered rate. Measured on macOS 27.2:
  premium Siri voices arrive at 48 kHz behind an installed `natural` asset, at 24 kHz
  behind `neural`, and at 22.05 kHz when the asset the daemon wants is absent — at which
  point every en-US name returns byte-identical audio (`md5 edf6ab13…` for simone, nora,
  aaron, quinn, damon, en-US-F, en-US-G). friday checks the rate on the first chunk and
  stops before a sample reaches the speaker or the stream (`isLegacySubstitution`). The
  tell survives `--fast` and a warm daemon because the fallback is delivered as
  22.05 kHz lpcm in every observed case; a fallback delivered as opus (always 48 kHz)
  would evade the rate check, which is the residual hole in this detection.
- Rejected fix, with evidence: giving the standard path the expressive client identity
  (`_clientId = "com.apple.siritts-tool"`) does *not* restore the 48 kHz voice. It routes
  en-US voices to the neural model instead (24 kHz, same 73,440 frames as the expressive
  render of the same text) — which is the family the user rejected by ear — and makes every
  en-GB voice fail with `FrontendOverrideAction: Cannot find resource asset`. The identity
  stays where it belongs: the expressive path.
- Installing is not a name lookup. `subscribe(voices:)` matches the `assetKey` the daemon
  computes for the voice it is handed, and `SynthesisVoice(language:name:)` on its own
  computes `en_US:undefined:undefined:simone:undefined:0` — no asset, so the request is
  accepted and nothing downloads. The identity has to be rebuilt from the catalog record:
  technology as Apple's VoiceType number (vocalizer 1, custom 2, gryphon 3, neural 4,
  neuralAX 5, natural 6), gender, footprint 2, and the asset's own version, then checked
  against `nativeAssetKey` before sending. Two spellings matter: identities are hyphenated
  (`en-IN:natural:female:Riya:premium:5049`, byte-identical to the key of the installed
  en-IN Riya asset) and MobileAsset specifiers are underscored
  (`…voice.en_IN.riya.natural.premium`). `voices --install --dry-run` prints the identity. Measured end to end with the 33 MB
  en-IN Aman `neuralAX` premium asset: subscribe → installed in ~12 s, and the voice then
  rendered at 48 kHz on the standard path, so `neuralAX` is a Siri-path family alongside
  `natural` (a `neural` asset alone is not). Elimination is routed through mobileassetd and
  is asynchronous — ~20 s before the bundle leaves the asset root — so `--purge` polls for
  up to 60 s; checking once, immediately, reported a successful purge as a failure. A
  purged voice also stays in the daemon's inventory until that refreshes, so "already
  installed" is decided by the asset store, not by the daemon's list.
- `subscribe(voices:)` returns without error whether or not a transfer starts, so
  `voices --install` cannot report progress and does not claim any; the asset store is the
  only witness, and `--wait` polls it by specifier. Before that, `--wait` polled the
  daemon's voice list, which only changes after the asset lands, so it could never observe
  progress and always ended in a timeout.

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
