#!/bin/bash
# Build friday. Needs Command Line Tools with the macOS 26+ SDK.
#
# One build system: Package.swift describes the target, so the binary and the tests
# compile the same sources with the same flags. Testing additionally needs a toolchain
# that ships XCTest, which Command Line Tools does not — see README.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product friday
cp .build/release/friday friday
chmod +x friday
echo "built $PWD/friday"
