#!/bin/bash
# friday's local checks. Tiers are opt-in because they cost different things:
#   (default)   core logic + build — no daemon, no audio
#   --server    adds the black-box binary and HTTP checks
#   --audio     adds real synthesis, timings and clipping measurement (needs the daemon)
#   --all       everything
# Run from anywhere; it works relative to its own directory.
set -uo pipefail
cd "$(dirname "$0")"

with_server=0
with_audio=0
case "${1:-}" in
  "") ;;
  --server) with_server=1 ;;
  --audio) with_audio=1 ;;
  --all) with_server=1; with_audio=1 ;;
  -h | --help)
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "unknown option '$1'; use --server, --audio, --all or nothing" >&2
    exit 2
    ;;
esac

failures=0
started=$(date +%s)

echo "build"
if ./build.sh >/dev/null 2>&1; then
  echo "  ok  binary rebuilt"
else
  echo "  ✗   build failed — run ./build.sh to see why"
  exit 1
fi

echo "core"
mkdir -p .build
if ! swiftc -O -module-name CoreTests Sources/FridayCore/*.swift Tests/CoreTests/main.swift -o .build/core-tests 2>"$PWD/.build/core-tests.log"; then
  echo "  ✗   core tests did not compile"
  sed -n '1,12p' .build/core-tests.log | sed 's/^/      /'
  failures=$((failures + 1))
elif ! ./.build/core-tests; then
  failures=$((failures + 1))
fi

if [ "$with_server" -eq 1 ]; then
  echo "blackbox"
  ./Tests/blackbox.sh || failures=$((failures + 1))
fi

if [ "$with_audio" -eq 1 ]; then
  echo "audio"
  ./Tests/audio.sh || failures=$((failures + 1))
fi

elapsed=$(( $(date +%s) - started ))
if [ "$failures" -eq 0 ]; then
  echo "all checks passed in ${elapsed}s"
  exit 0
fi
echo "$failures tier(s) failed in ${elapsed}s"
exit 1
