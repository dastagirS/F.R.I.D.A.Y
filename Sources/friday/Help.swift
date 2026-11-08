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
