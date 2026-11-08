#!/bin/bash
# Build friday. Needs Command Line Tools with the macOS 26+ SDK.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -I interfaces \
  -F /System/Library/PrivateFrameworks \
  -Xlinker -weak_framework -Xlinker SiriTTSService \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/info.plist" \
  Sources/friday/*.swift -o friday
echo "built $PWD/friday"
