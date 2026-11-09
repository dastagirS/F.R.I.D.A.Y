#!/bin/bash
# Build friday. Needs Command Line Tools with the macOS 26+ SDK.
#
# One build system: Package.swift describes the target, so the binary and the tests
# compile the same sources with the same flags. Testing additionally needs a toolchain
# that ships XCTest, which Command Line Tools does not — see README.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product friday
# Copy next to the destination and rename: an interrupted copy used to leave a truncated
# binary on PATH that the kernel kills on exec with no diagnostic.
cp .build/release/friday friday.new
chmod +x friday.new
mv friday.new friday
echo "built $PWD/friday"
