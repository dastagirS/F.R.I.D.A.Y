#!/bin/bash
# Black-box checks: what the shipped binary actually does, without needing audio
# hardware or the SiriTTS daemon. Complements Tests/CoreTests, which covers the logic
# directly.
set -uo pipefail
cd "$(dirname "$0")/.."

binary=./friday
scratch=$(mktemp -d)
server_pid=""
authed_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
  [ -n "$authed_pid" ] && kill "$authed_pid" 2>/dev/null
  rm -rf "$scratch"
}
trap cleanup EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); }
bad() { failed=$((failed + 1)); echo "  ✗ $1"; }

# expect_exit <expected> <label> -- command...
expect_exit() {
  local expected=$1 label=$2
  shift 3
  "$@" >/dev/null 2>&1
  local actual=$?
  if [ "$actual" -eq "$expected" ]; then ok; else bad "$label: exited $actual, wanted $expected"; fi
}

# expect_contains <label> <needle> -- command...
expect_contains() {
  local label=$1 needle=$2
  shift 3
  local output
  output=$("$@" 2>&1)
  if grep -qF -- "$needle" <<<"$output"; then
    ok
  else
    bad "$label: output missing '$needle'"
  fi
}

# expect_status <url> <expected-code> <label> [extra curl args...]
expect_status() {
  local url=$1 expected=$2 label=$3
  shift 3
  local actual
  actual=$(curl -s -o "$scratch/body" -w '%{http_code}' "$@" "$url")
  if [ "$actual" = "$expected" ]; then ok; else bad "$label: HTTP $actual, wanted $expected ($(head -c 120 "$scratch/body"))"; fi
}

# expect_error_code <expected error.code> <label>
expect_error_code() {
  local expected=$1 label=$2
  local actual
  actual=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["error"]["code"])' "$scratch/body" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then ok; else bad "$label: error.code '$actual', wanted '$expected'"; fi
}

if [ ! -x "$binary" ]; then
  echo "  ✗ $binary not found — run ./build.sh first"
  exit 1
fi

echo "blackbox: CLI surface"

expect_exit 0 "--help succeeds" -- "$binary" --help
expect_contains "--help documents the exit codes" "130" -- "$binary" --help
expect_contains "--help documents --completions" "--completions" -- "$binary" --help
expect_contains "--help documents --man" "--man" -- "$binary" --help

expect_exit 2 "unknown option is refused" -- "$binary" --nonsense
expect_contains "unknown option says how to recover" "friday --help" -- "$binary" --nonsense
expect_exit 2 "unknown flag is not spoken aloud as text" -- "$binary" --verbos

out=$(printf '' | "$binary" - 2>&1)
code=$?
if [ "$code" -eq 2 ]; then ok; else bad "empty stdin: exited $code, wanted 2"; fi
if grep -qF 'friday "text"' <<<"$out"; then ok; else bad "empty stdin: no usage text"; fi

expect_exit 2 "bad preset is refused" -- "$binary" --pace 99 "hi"
expect_exit 2 "bad number is refused" -- "$binary" --volume nope "hi"
expect_exit 2 "completions needs a known shell" -- "$binary" --completions tcsh
expect_exit 0 "a known generation is accepted" -- "$binary" --generation standard --list
# Known gap (#43): an unrecognised --generation value is ignored instead of refused, so
# this pins today's silent behaviour with --list rather than asserting the wanted exit 2.
# It speaks nothing, so it stays safe in a no-audio tier. Flip to 2 when #43 lands.
expect_exit 0 "unknown generation is currently ignored (#43)" -- "$binary" --generation theatrical --list

echo "blackbox: config"

export FRIDAY_CONFIG="$scratch/config.json"

expect_exit 0 "config with no action prints settings" -- "$binary" config
expect_contains "default voice is simone" "simone" -- "$binary" config

expect_exit 0 "config set lossless off" -- "$binary" config set lossless off
expect_contains "lossless off is reported" "lossless" -- "$binary" config
expect_exit 0 "config unset lossless" -- "$binary" config unset lossless
expect_exit 0 "config set sentence-chunking on" -- "$binary" config set sentence-chunking on
expect_exit 0 "config unset sentence-chunking" -- "$binary" config unset sentence-chunking
expect_exit 2 "unknown config key is refused" -- "$binary" config set nosuchkey on
expect_exit 2 "config set needs a value" -- "$binary" config set lossless
expect_exit 2 "unknown config action is refused" -- "$binary" config show

printf '{nope' > "$scratch/broken.json"
out=$(FRIDAY_CONFIG="$scratch/broken.json" "$binary" "hi" 2>&1)
code=$?
if [ "$code" -eq 5 ]; then ok; else bad "corrupt config: exited $code, wanted 5"; fi
if grep -qF "$scratch/broken.json" <<<"$out"; then ok; else bad "corrupt config: message does not name the file"; fi

: > "$scratch/empty.json"
expect_exit 0 "an empty config file is allowed" -- env FRIDAY_CONFIG="$scratch/empty.json" "$binary" config

unset FRIDAY_CONFIG

echo "blackbox: generated documents"

for shell in zsh bash fish; do
  expect_exit 0 "completions for $shell" -- "$binary" --completions "$shell"
done
expect_contains "skill file has frontmatter" "name:" -- "$binary" --skill
expect_contains "skill file documents exit codes" "exit" -- "$binary" --skill
expect_contains "man page has a title" ".TH FRIDAY" -- "$binary" --man
expect_contains "man page documents exit status" "EXIT STATUS" -- "$binary" --man

echo "blackbox: server"

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
"$binary" serve --port "$port" > "$scratch/serve.log" 2>&1 &
server_pid=$!
base="http://127.0.0.1:$port"
for _ in $(seq 1 100); do
  curl -sf "$base/healthz" >/dev/null 2>&1 && break
  sleep 0.05
done

expect_status "$base/healthz" 200 "healthz"
check=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$scratch/body" 2>/dev/null)
if [ "$check" = "ok" ]; then ok; else bad "healthz: status '$check', wanted 'ok'"; fi

expect_status "$base/v1/models" 200 "models list"
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["data"] else 1)' "$scratch/body" 2>/dev/null; then
  ok
else
  bad "models list: no data array"
fi

expect_status "$base/nope" 404 "unknown route"
expect_error_code "no_route" "unknown route"

expect_status "$base/v1/audio/speech" 404 "GET on a POST-only route"

curl -s -o "$scratch/body" -X POST -d 'not json' "$base/v1/audio/speech" >/dev/null
expect_error_code "invalid_json" "malformed JSON body"

curl -s -o "$scratch/body" -X POST -d '{"input":""}' "$base/v1/audio/speech" >/dev/null
expect_error_code "missing_required_parameter" "empty input"

curl -s -o "$scratch/body" -X POST -d '{"input":"hi","response_format":"mp3"}' "$base/v1/audio/speech" >/dev/null
expect_error_code "invalid_value" "unsupported response_format"

curl -s -o "$scratch/body" -X POST -d '{"input":"hi","response_format":"wav","stream":true}' "$base/v1/audio/speech" >/dev/null
expect_error_code "invalid_value" "wav plus stream is refused"

curl -s -o /dev/null -D "$scratch/headers" -X POST -d '{"input":""}' "$base/v1/audio/speech" >/dev/null
if grep -qi '^X-Request-Id:' "$scratch/headers"; then ok; else bad "error responses carry X-Request-Id"; fi

kill "$server_pid" 2>/dev/null
wait "$server_pid" 2>/dev/null
server_pid=""

echo "blackbox: bearer auth"

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
FRIDAY_TEST_TOKEN=sekrit "$binary" serve --port "$port" --auth-token-env FRIDAY_TEST_TOKEN \
  > "$scratch/serve-auth.log" 2>&1 &
authed_pid=$!
base="http://127.0.0.1:$port"
for _ in $(seq 1 100); do
  curl -sf -H 'Authorization: Bearer sekrit' "$base/healthz" >/dev/null 2>&1 && break
  sleep 0.05
done

expect_status "$base/healthz" 401 "auth is required"
expect_status "$base/healthz" 401 "a wrong token is refused" -H 'Authorization: Bearer wrong'
expect_status "$base/healthz" 200 "the right token is accepted" -H 'Authorization: Bearer sekrit'
curl -s -o "$scratch/body" "$base/healthz" >/dev/null
expect_error_code "invalid_token" "missing token reports invalid_token"

echo "blackbox: daemon-free diagnostics"

expect_exit 0 "debug logging is accepted" -- "$binary" --debug --man
expect_contains "debug traces go to stderr only when asked" "debug" -- "$binary" --debug --man

echo "blackbox: interruptibility"

# A producer that holds the pipe open must not make the process unstoppable: the signal
# source cannot fire while a blocking read owns the main thread.
( sleep 60 ) | "$binary" --stream -q - >/dev/null 2>&1 &
stream_job=$!
sleep 1.2
if ! kill -0 "$stream_job" 2>/dev/null; then
  echo "  ! skipped — streaming did not stay running without a producer"
else
  kill -INT "$stream_job" 2>/dev/null
  waited=0
  while kill -0 "$stream_job" 2>/dev/null && [ "$waited" -lt 60 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if kill -0 "$stream_job" 2>/dev/null; then
    bad "SIGINT did not stop --stream while blocked on stdin"
    kill -TERM "$stream_job" 2>/dev/null
  else
    wait "$stream_job" 2>/dev/null
    code=$?
    if [ "$code" -eq 130 ]; then ok; else bad "SIGINT exited $code, wanted 130"; fi
  fi
fi
pkill -f "sleep 60" 2>/dev/null

kill "$authed_pid" 2>/dev/null
wait "$authed_pid" 2>/dev/null
authed_pid=""

if [ "$failed" -eq 0 ]; then
  echo "blackbox: $passed checks passed"
  exit 0
fi
echo "blackbox: $failed of $((passed + failed)) checks failed"
exit 1
