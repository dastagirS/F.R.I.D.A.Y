#!/bin/bash
# Audio checks: the tier that needs the SiriTTS daemon and real voice assets. Not part
# of the default run because it synthesises speech (slow, and it makes sound unless
# every call is quiet).
set -uo pipefail
cd "$(dirname "$0")/.."

binary=./friday
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); }
bad() { failed=$((failed + 1)); echo "  ✗ $1"; }

# speak <outfile> <text> [extra args...] — synthesise quietly to a WAV, print stderr.
speak() {
  local out=$1 text=$2
  shift 2
  "$binary" -q "$@" -o "$out" "$text" >"$scratch/last-stdout" 2>"$scratch/last-stderr"
  return $?
}

# Measures a WAV without extra tooling: peak and RMS as fractions of full scale.
measure() {
  python3 - "$1" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "rb") as f:
    frames = f.readframes(f.getnframes())
    width, channels, rate = f.getsampwidth(), f.getnchannels(), f.getframerate()
peaks = int.from_bytes(frames, "little", signed=False)
count = len(frames) // 2
values = [int.from_bytes(frames[i * 2:i * 2 + 2], "little", signed=True) for i in range(count)]
peak = max((abs(v) for v in values), default=0) / 32768.0
rms = (sum(v * v for v in values) / count) ** 0.5 / 32768.0 if count else 0.0
print(f"{rate} {width} {channels} {count} {peak:.6f} {rms:.6f}")
PY
}

if [ ! -x "$binary" ]; then
  echo "  ✗ $binary not found — run ./build.sh first"
  exit 1
fi

echo "audio: daemon availability"
if ! speak "$scratch/probe.wav" "ok" || [ ! -s "$scratch/probe.wav" ]; then
  echo "  audio: skipped — no audio produced (daemon or voice assets unavailable)"
  cat "$scratch/last-stderr" 2>/dev/null | head -3 | sed 's/^/    /'
  exit 0
fi
ok

echo "audio: rendering"
speak "$scratch/short.wav" "Testing one two three."
if [ $? -eq 0 ]; then ok; else bad "short text failed: $(head -1 "$scratch/last-stderr")"; fi

read -r rate width channels frames peak rms <<<"$(measure "$scratch/short.wav")"
if [ "$rate" = "48000" ]; then ok; else bad "sample rate is $rate, wanted 48000"; fi
if [ "$width" = "2" ]; then ok; else bad "sample width is $width bytes, wanted 2"; fi
if [ "$channels" = "1" ]; then ok; else bad "channels is $channels, wanted 1"; fi
if [ "$frames" -gt 8000 ]; then ok; else bad "only $frames frames for a spoken sentence"; fi
if python3 -c "import sys; sys.exit(0 if $rms > 0.01 else 1)"; then
  ok
else
  bad "audio is silent (rms $rms)"
fi

echo "audio: the locked-in voice stays clean"
speak "$scratch/clean.wav" "Good evening. All systems are online and responding normally."
read -r _ _ _ _ clean_peak _ <<<"$(measure "$scratch/clean.wav")"
if python3 -c "import sys; sys.exit(0 if $clean_peak < 0.995 else 1)"; then
  ok
else
  bad "simone peaks at $clean_peak — clipping regression"
fi
if grep -q "codec=lossy" "$scratch/last-stderr"; then
  bad "default run fell back to the lossy encoder: $(grep 'codec=lossy' "$scratch/last-stderr" | head -1)"
else
  ok
fi

echo "audio: chunking"
speak "$scratch/paragraph.wav" "First sentence here. Second sentence here. Third one closes it."
read -r _ _ _ paragraph_frames _ _ <<<"$(measure "$scratch/paragraph.wav")"
if [ "$paragraph_frames" -gt 20000 ]; then ok; else bad "three-sentence paragraph rendered only $paragraph_frames frames"; fi

echo "audio: timings"
speak "$scratch/timed.wav" "Hello there." --timings --timings-out "$scratch/timings.json"
if [ -s "$scratch/timings.json" ]; then ok; else bad "no timings file was written"; fi
if python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
entries = data.get('timings') or []
sys.exit(0 if entries and all('start' in e and 'end' in e and 'utf16Location' in e for e in entries) else 1)
" "$scratch/timings.json" 2>/dev/null; then
  ok
else
  bad "timings file has no usable entries"
fi
# Recorded in #15: the daemon reports one coarse range for a short utterance, so
# per-word granularity is never guaranteed. Keep the expectation loose but visible.
entry_count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('timings') or []))" "$scratch/timings.json" 2>/dev/null)
if [ "${entry_count:-0}" -ge 1 ]; then
  ok
  [ "${entry_count}" -eq 1 ] && echo "  ! short text produced $entry_count coarse timing range (see #15)"
else
  bad "timings entry count is ${entry_count:-unreadable}"
fi

echo "audio: refusal paths"
"$binary" -q -o "$scratch/none.wav" -v zzzznotavoice "hello" >/dev/null 2>&1
if [ $? -eq 4 ]; then ok; else bad "unknown voice exited $?, wanted 4"; fi

"$binary" -q -o "$scratch/silent.wav" "   " >/dev/null 2>&1
code=$?
if [ "$code" -eq 2 ]; then ok; else bad "whitespace-only text exited $code, wanted 2"; fi

echo "audio: known gap — loud voice clipping (#10)"
speak "$scratch/nora.wav" "Good evening. All systems are online and responding normally." -v nora --standard
if [ -s "$scratch/nora.wav" ]; then
  read -r _ _ _ _ nora_peak _ <<<"$(measure "$scratch/nora.wav")"
  if python3 -c "import sys; sys.exit(0 if $nora_peak >= 0.999 else 1)"; then
    echo "  ! nora peaks at $nora_peak — still clipping, as recorded in ticket #10"
  else
    echo "  ! nora peaks at $nora_peak — no longer clipping; ticket #10 can close"
  fi
fi

echo "audio: server streaming"

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
"$binary" serve --port "$port" > "$scratch/serve.log" 2>&1 &
server_pid=$!
stop_server() { kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; }
trap 'stop_server; rm -rf "$scratch"' EXIT
for _ in $(seq 1 100); do
  curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
  sleep 0.05
done

probe=$(python3 - "$port" <<'PY'
import json, socket, sys, time

port = int(sys.argv[1])

def post_chunked(payload, path, second_chunk=b""):
    head = (f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            f"Transfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n").encode()
    s = socket.create_connection(("127.0.0.1", port), timeout=180)
    s.sendall(head + b"%x\r\n" % len(payload) + payload + b"\r\n")
    if second_chunk:
        time.sleep(1.0)
        s.sendall(b"%x\r\n" % len(second_chunk) + second_chunk + b"\r\n")
    s.sendall(b"0\r\n\r\n")
    data = b""
    while True:
        piece = s.recv(65536)
        if not piece:
            break
        data += piece
    s.close()
    return data.split(b"\r\n")[0].decode(errors="replace"), data

out = {}

# A single chunk larger than 256 KB is legal; refusing it reset the connection while the
# body limit advertised 4 MB.
big = b" " * (300 * 1024) + json.dumps({"input": "hi", "response_format": "pcm"}).encode()
status, body = post_chunked(big, "/v1/audio/speech")
out["bigchunk"] = "1" if " 200 " in status and len(body) > 1000 else "0:" + status

status, body = post_chunked(
    json.dumps({"input": "stream check", "response_format": "pcm", "stream": True}).encode(),
    "/v1/audio/speech",
)
headers = body.split(b"\r\n\r\n", 1)[0]
out["stream"] = "1" if " 200 " in status and b"Transfer-Encoding: chunked" in headers else "0:" + status

# NDJSON in: sentence one is spoken while sentence two is still being written.
first = json.dumps({"text": "First sentence here."}).encode() + b"\n"
second = json.dumps({"text": "Second sentence here.", "end": True}).encode() + b"\n"
status, body = post_chunked(first, "/say", second_chunk=second)
body_only = body.split(b"\r\n\r\n", 1)[-1]
try:
    sentences = json.loads(body_only.decode()).get("sentences")
except Exception:
    sentences = None
out["ndjson"] = str(sentences) if " 200 " in status else "0:" + status

for key, value in out.items():
    print(key + "=" + value)
PY
)

value_of() { sed -n "s/^$1=//p" <<<"$probe"; }

if [ "$(value_of bigchunk)" = "1" ]; then ok; else bad "300 KB single chunk rejected: $(value_of bigchunk)"; fi
if [ "$(value_of stream)" = "1" ]; then ok; else bad "streamed pcm response broken: $(value_of stream)"; fi
if [ "$(value_of ndjson)" = "2" ]; then ok; else bad "NDJSON /say spoke $(value_of ndjson) sentence(s), wanted 2"; fi

stop_server

if [ "$failed" -eq 0 ]; then
  echo "audio: $passed checks passed"
  exit 0
fi
echo "audio: $failed of $((passed + failed)) checks failed"
exit 1
