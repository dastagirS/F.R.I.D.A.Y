#!/bin/bash
# Build friday. Needs Command Line Tools with the macOS 26+ SDK.
set -euo pipefail
cd "$(dirname "$0")"
# Everything compiles as one module: FridayCore holds the logic that needs no daemon
# (chunker, config, error taxonomy, WAV coding) and is compiled a second time by
# test.sh against the checks in Tests/CoreTests, so the code under test is the code
# that ships rather than a copy of it.
swiftc -O -I interfaces \
  -F /System/Library/PrivateFrameworks \
  -Xlinker -weak_framework -Xlinker SiriTTSService \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/info.plist" \
  Sources/friday/*.swift Sources/FridayCore/*.swift -o friday
echo "built $PWD/friday"
