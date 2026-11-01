#!/bin/sh
# Build the macOS helper without installing the plugin.
#
# The plugin builds this itself, on first use, into ~/Library/Caches/dsh-pilot/bin.
# This script exists for the case where you want to see the compiler output, run
# `pilot-mac selftest` by hand, or check a change before the plugin picks it up.
#
#   ./tools/build.sh            → ./build/pilot-mac
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
out="$here/build/pilot-mac"
mkdir -p "$here/build"

if ! command -v xcrun >/dev/null 2>&1 && ! command -v swiftc >/dev/null 2>&1; then
	echo "pilot: no Swift compiler found. Install the Xcode Command Line Tools:" >&2
	echo "       xcode-select --install" >&2
	exit 1
fi

compiler=$(xcrun -f swiftc 2>/dev/null || echo swiftc)

# -parse-as-library: the entry point is `@main` in PilotRuntime.swift, not a
# main.swift with top-level code.
"$compiler" -O -parse-as-library -module-name Pilot -o "$out" \
	"$here/lib/darwin/Pilot.swift" \
	"$here/lib/darwin/PilotWindows.swift" \
	"$here/lib/darwin/PilotInput.swift" \
	"$here/lib/darwin/PilotCapture.swift" \
	"$here/lib/darwin/PilotAction.swift" \
	"$here/lib/darwin/PilotRuntime.swift"

echo "built $out"
echo
echo "next:"
echo "  $out selftest | python3 -m json.tool"
echo "  ./tools/verify.sh"
