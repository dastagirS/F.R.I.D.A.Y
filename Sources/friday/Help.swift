import Foundation

let usageText = """
friday — speak text with Siri's voices, locally

USAGE
  friday [options] TEXT | -
  friday [options] --list
  friday serve    [--port 8787] [--host 127.0.0.1] [--auth-token-env VAR]
  friday voices   [--status NAME | --install NAME --language xx | --manage | --default NAME]
  friday config   [set KEY VALUE [--standard|--expressive] | unset KEY | reset]

OPTIONS
  -v, --voice NAME        exact name or asset key, then case-insensitive, then substring
      --language en-IN    pick by language
      --generation G      standard | expressive
      --standard          force the calm render path
      --expressive        force the on-device 3B model
      --pace 1-5          expressive presets (default 3)
      --expressivity 1-5  expressive presets (default 3)
  -r, --rate F            speech rate multiplier (1.0 = normal)
      --pitch F           pitch multiplier
      --volume F          volume multiplier
  -o, --out FILE          write a 48 kHz 16-bit WAV instead of playing
      --timings           print word timings as JSON (standard path only)
      --timings-out FILE  write word timings JSON to FILE
      --prewarm           load the voice/model without speaking
      --chunked           one sentence per request: lossless audio (default)
      --no-chunked        send the whole text as one request (lossy above one
                          sentence, where the daemon switches to ~50 kbps Opus)
  -l, --list              list installed voices
  -q, --quiet             suppress the timing line
      --completions SH    print a completion script (zsh | bash | fish)
      --man               print the man page (roff)
  -h, --help              this text

Word timings come only from the standard render path; the expressive 3B model
returns none, and friday reports timingsSupported: false rather than inventing them.
"""

let voicesUsageText = """
friday voices — inspect and manage the Siri voice assets

  friday voices                              list installed voices
  friday voices --status NAME                is this voice installed?
  friday voices --install NAME --language xx request a voice from Apple's catalog
  friday voices --install NAME --language xx --wait [--timeout SECONDS]
  friday voices --available                  list Apple's downloadable catalog
  friday voices --purge NAME|SPECIFIER [--dry-run|--force]
                                             delete a local voice bundle;
                                             refuses without --force
  friday voices --manage                     open Accessibility settings
  friday voices --default NAME [--standard]  persist NAME as the default voice
"""

let configUsageText = """
friday config — persisted defaults (CLI flags always win)

  friday config                                         show effective settings
  friday config set default-voice NAME [--standard]     persist default voice
  friday config set default-generation standard|expressive
  friday config set sentence-chunking on|off
  friday config set pace 1-5
  friday config set expressivity 1-5
  friday config unset KEY
  friday config reset
"""

let completionScripts: [String: String] = [
  "zsh": """
#compdef friday
_friday() {
  local -a subcommands voices
  subcommands=(serve voices config)
  if (( CURRENT == 2 )); then
    _describe 'subcommand' subcommands
  fi
  _arguments \\
    '-v[voice name]:voice:(simone nora damon aaron quinn martha arthur Riya)' \\
    '--voice[voice name]:voice:' \\
    '--language[language tag]:language:(en-US en-IN en-GB)' \\
    '--generation[render path]:path:(standard expressive)' \\
    '--standard[force the calm render path]' \\
    '--expressive[force the on-device 3B model]' \\
    '--pace[expressive pace 1-5]:pace:(1 2 3 4 5)' \\
    '--expressivity[expressive intensity 1-5]:level:(1 2 3 4 5)' \\
    '-r[rate multiplier]:rate:' '--rate[rate multiplier]:rate:' \\
    '--pitch[pitch multiplier]:pitch:' '--volume[volume multiplier]:volume:' \\
    '-o[write a WAV file]:file:_files' '--out[write a WAV file]:file:_files' \\
    '--timings[print word timings JSON]' '--timings-out[write timings JSON]:file:_files' \\
    '--prewarm[load the voice without speaking]' \\
    '--chunked[one sentence per request: lossless]' \\
    '--no-chunked[send the whole text as one request]' \\
    '--man[print the manual page]' \\
    '--skill[print the agent skill file]' \\
    '-l[list voices]' '--list[list voices]' \\
    '-q[quiet]' '--quiet[quiet]' \\
    '--completions[print completion script]:shell:(zsh bash fish)' \\
    '--man[print man page]' \\
    '-h[help]' '--help[help]' \\
    '*:text:'
}
_friday "$@"
""",
  "bash": """
_friday() {
  local cur prev subcommands
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  subcommands="serve voices config"
  case "$prev" in
    -v|--voice) COMPREPLY=( $(compgen -W "simone nora damon aaron quinn martha arthur Riya" -- "$cur") ); return ;;
    --language) COMPREPLY=( $(compgen -W "en-US en-IN en-GB" -- "$cur") ); return ;;
    --generation) COMPREPLY=( $(compgen -W "standard expressive" -- "$cur") ); return ;;
    --completions) COMPREPLY=( $(compgen -W "zsh bash fish" -- "$cur") ); return ;;
    -o|--out|--timings-out) COMPREPLY=( $(compgen -f -- "$cur") ); return ;;
  esac
  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
  fi
}
complete -F _friday friday
""",
  "fish": """
complete -c friday -n '__fish_use_subcommand' -a 'serve voices config'
complete -c friday -s v -l voice -d 'voice name' -a 'simone nora damon aaron quinn martha arthur Riya'
complete -c friday -l language -d 'language tag' -a 'en-US en-IN en-GB'
complete -c friday -l generation -d 'render path' -a 'standard expressive'
complete -c friday -l standard -d 'force the calm render path'
complete -c friday -l expressive -d 'force the on-device 3B model'
complete -c friday -l pace -d 'expressive pace 1-5'
complete -c friday -l expressivity -d 'expressive intensity 1-5'
complete -c friday -s r -l rate -d 'rate multiplier'
complete -c friday -o out -d 'write a WAV file' -r
complete -c friday -l timings -d 'print word timings JSON'
complete -c friday -l prewarm -d 'load the voice without speaking'
complete -c friday -l chunked -d 'one sentence per request, lossless audio'
complete -c friday -l no-chunked -d 'send the whole text as one request'
complete -c friday -l skill -d 'print the agent skill file'
complete -c friday -s l -l list -d 'list voices'
complete -c friday -s q -l quiet -d 'quiet'
complete -c friday -l completions -a 'zsh bash fish'
complete -c friday -l man -d 'print man page'
""",
]

let manPage = """
.TH FRIDAY 1 "friday"
.SH NAME
friday \\- speak text with Siri's voices, locally
.SH SYNOPSIS
.B friday
[\\fIoptions\\fR] \\fITEXT\\fR | \\-
.br
.B friday serve
[\\fB\\-\\-port\\fR N] [\\fB\\-\\-host\\fR H] [\\fB\\-\\-auth-token-env\\fR VAR]
.br
.B friday voices
[\\fB\\-\\-status\\fR NAME | \\fB\\-\\-install\\fR NAME \\fB\\-\\-language\\fR xx | \\fB\\-\\-manage\\fR | \\fB\\-\\-default\\fR NAME]
.br
.B friday config
[set KEY VALUE | unset KEY | reset]
.SH DESCRIPTION
Speaks text with the Siri voices installed on this Mac by driving Apple's private
SiriTTSService framework. Audio is normalised to 48 kHz float mono regardless of
whether the daemon streams integer PCM, 32-bit float PCM or Opus packets.
.PP
The default voice comes from the config file, falling back to the built-in
"simone" on the standard render path. Command line flags always win.
.SH OPTIONS
.TP
.BR \\-v ", " \\-\\-voice " " NAME
Exact name or asset key first, then case-insensitive, then substring.
.TP
.BR \\-\\-language " " TAG
Select by language, for example en-IN.
.TP
.BR \\-\\-generation " " standard|expressive
Choose the render path explicitly.
.TP
.BR \\-\\-standard
Force the calm render path even for expressive voice assets.
.TP
.BR \\-\\-expressive
Force the on-device 3B speech model.
.TP
.BR \\-\\-pace " " 1\\-5 ", " \\-\\-expressivity " " 1\\-5
Expressive presets. Defaults come from the config file, then 3.
.TP
.BR \\-o ", " \\-\\-out " " FILE
Write a 48 kHz 16-bit WAV instead of playing.
.TP
.BR \\-\\-timings
Print word timings as JSON. Standard render path only; the expressive model
returns none and the report says so.
.TP
.BR \\-\\-prewarm
Load the voice and model without speaking.
.TP
.BR \\-l ", " \\-\\-list
List installed voices with their generation.
.SH SERVER
.B friday serve
listens on 127.0.0.1:8787 by default and exposes
.BR POST " /v1/audio/speech" ,
.BR POST " /say" ,
.BR POST " /stop" ,
.BR GET " /v1/models" ,
.BR GET " /healthz" .
Pass \\fB\\-\\-auth-token-env VAR\\fR to require a bearer token from environment VAR.
.SH EXIT STATUS
2 usage, 3 daemon unavailable, 4 unknown voice, 6 synthesis failed, 7 timeout,
8 nothing captured, 130 cancelled.
.SH CAVEATS
Uses a private Apple framework. Undocumented, unentitled, and an OS update can
break it. Not shippable to the App Store.
"""

// Printed by --skill so an agent can load friday's contract in one shot, the way
// other CLIs ship a SKILL.md. Kept in the binary rather than a sidecar file so the
// documentation cannot drift away from the installed build.
let skillText = #"""
---
name: friday
description: "Speak text aloud on this Mac with Siri's real neural voices through the local friday CLI or its HTTP service. Use when the user asks to hear text spoken, wants voice output from a script, agent loop, or service, or asks about friday's voices, word timings, sentence chunking, HTTP API, or configuration. Runs fully offline."
---

# friday

Local text-to-speech. `friday` renders text with Siri's neural voices by driving the
private `SiriTTSService` daemon (`sirittsd`), playing it or writing a 48 kHz mono WAV.
Nothing leaves the machine and nothing is installed from the network.

Apple does not expose these voices publicly. `say -v <name>` accepts any name, ignores
it, and speaks the default voice instead, so never substitute `say` when the user asked
for these voices.

## Check availability

```bash
command -v friday
```

If it is missing, report that rather than reaching for `say`.

## Speak

```bash
friday "text"                    # play through the speakers
friday -q -                      # read stdin silently: the loop-friendly form
echo "$REPLY" | friday -q -      # what a speech-to-text -> LLM -> speech loop uses
friday -o line.wav "text"        # write a file instead of playing
```

Options: `-v/--voice`, `--language`, `--standard`, `--expressive`, `--pace 1-5`,
`--expressivity 1-5`, `-r/--rate`, `--pitch`, `--volume`, `-o/--out`, `-q/--quiet`,
`--timings`, `--timings-out FILE`, `--prewarm`, `--chunked`, `--no-chunked`,
`--completions zsh|bash|fish`, `--man`, `--skill`.

Progress goes to stderr only. `-q` suppresses it, so stdout stays clean for JSON.

The built-in default is voice `simone` (en-US) on the standard path. Keep it unless the
user asks for something else; it was chosen over the alternatives by ear.

## Defaults and config

Precedence: CLI flag, then `~/.config/friday/config.json`, then built-in
(`simone`, `standard`, chunking on). `FRIDAY_CONFIG` overrides the file path.

```bash
friday config                                  # show what is in effect and its source
friday config set default-voice simone --standard
friday config set default-generation standard|expressive
friday config set sentence-chunking on|off
friday config set pace 3
friday config set expressivity 3
```

Voice and render path are separate settings: an asset can be reachable through both.
`--standard` forces the standard path even on an expressive asset.

## Rendering paths

`standard` is the everyday neural path: fast, natural, returns word timings.

`expressive` runs a 3B voice model. It needs a pace and expressivity preset, only
engages for the daemon's expressive client identity, and without those presets the
daemon silently substitutes a generic legacy render. It sounds theatrical and was
rejected by the user; use it only when explicitly asked, and never as a default.

## Sentence chunking

The daemon chooses its encoder per request and cannot be told which to use: lossless
48 kHz PCM on some requests, roughly 50 kbps Opus on others, for identical text. The
choice tracks internal daemon state, not the text or the flags, so a render can come
back lossy no matter what you pass.

Small requests land on the lossless encoder far more often than whole paragraphs, so
`friday` sends one sentence per request by default, which also lowers time to first
word. `--no-chunked` sends the whole text as one request. Either way the render reports
`codec=lossy` on stderr when the daemon went lossy, and `src=` always shows the real
source format; treat lossless as likely, never guaranteed.

Chunking costs a little cross-sentence prosody. It bounds itself to 200 chunks and
20,000 characters, and falls back to a single request beyond either.

## Word timings

```bash
friday --timings --standard -v simone "text"
friday --timings-out words.json "text"
```

JSON with `schemaVersion`, `voice`, `assetKey`, `language`, `generation`,
`timingsSupported`, and per-word `text`, `start`, `end`, `endDerived`, `utf16Location`,
`utf16Length`. Locations index the original input, correctly rebased across chunks.
End times are derived from the next word's start, hence `endDerived: true`; the final
word ends at the audio duration.

The expressive path returns no timings and reports `timingsSupported: false` rather
than inventing them. Timings are not yet wired into the HTTP endpoints.

## Warm start

```bash
friday --prewarm            # acknowledge in ~0.03s, the session then dies
friday serve --prewarm      # the only form that keeps a session warm
```

## HTTP service

```bash
friday serve --port 8787 [--host 127.0.0.1] [--auth-token-env FRIDAY_TOKEN] [--prewarm]
```

- `GET /healthz` liveness
- `GET /v1/models` installed voices in OpenAI list shape
- `POST /v1/audio/speech` OpenAI-compatible: `input` (or `text`), `voice`, `response_format` (`wav`|`pcm`), `rate`
- `POST /say` speak, returning after playback finishes
- `POST /stop` barge-in: cancel and drop queued audio

Bearer auth is enabled by naming an environment variable with `--auth-token-env`.
Binding a non-loopback host without a token warns: this exposes the microphone-free
speaker to the network.

Limits worth knowing before building on it: the server runs synthesis on a single main
run loop, so `/stop` cannot preempt an in-flight synthesis, requests serialise, and
there is no TLS, CORS, or keep-alive. A dropped `AudioStreamBasicDescription` on a
terminator chunk used to corrupt WAV output; decoding now normalises every chunk.

## Voices

```bash
friday voices                                   # installed, with asset nature
friday voices --available                       # full catalog: 149 assets
friday voices --status NAME                     # what that name resolves to
friday voices --install NAME --language en-US --wait
friday voices --purge SPEC --dry-run             # then drop --dry-run
friday voices --manage
friday voices --default NAME [--standard]
```

Names are matched case-sensitively first, so `Simone` (neural, `:neural:`) and `simone`
(expressive fmvoice) are different requests. Bundles live under
`/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/`.

`--install` downloads 20-250 MB per bundle; it is implemented but not verified against a
real download here. `--purge` refuses ambiguity, does nothing without `--force`, and
judges success by the filesystem because the daemon can report a spurious entitlement
error after `mobileassetd` completes the removal. Do not purge or install unless the
user asked for that voice by name.

## Exit codes

`0` ok, `2` usage or config, `3` daemon unavailable, `4` unknown voice, `6` synthesis
failed, `7` timeout, `8` nothing captured, `130` cancelled. Ctrl-C during playback is a
barge-in and exits 130, so treat 130 as success when the user interrupted.

## Latency on this machine (M3, 16 GB)

First audio 35-80 ms when warm, ~0.5 s cold. A sentence synthesises in 0.15-0.6 s;
a 25 s paragraph in 2-3 s with chunking. Ctrl-C silences audio in ~0.7 s. For a
conversational loop the budget is roughly 1.2 s from end of speech to first spoken
word: ~300 ms speech recognition, ~650 ms for the model's first sentence, ~250 ms TTS.

## Rules for agents

- Put text on stdin with `friday -q -`; do not build shell strings around user text.
- Never invent a voice name. Check `friday voices`, and treat exit 4 as "ask the user".
- Never replace friday with `say`; it cannot reach these voices.
- Leave chunking on unless the user wants the single-request sound.
- Speak per sentence as an answer streams rather than waiting to read a whole page.
- Ask before `--install`, `--purge`, or anything that changes system assets.
- Read exit codes; 130 means the user interrupted, not a failure.

## Known gaps

No test suite. Timings are absent over HTTP. The server cannot preempt synthesis.
`--install` is unproven end to end. This relies on a private framework that an OS
update can break, and it is not App Store shippable.
"""#
