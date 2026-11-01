#!/bin/sh
# Compile the helper, report the permissions, and take one real screenshot.
#
# This is the end-to-end check that does not need the Harness running: if these
# three steps pass, screen_view will work, and the only thing left to verify is a
# click.
#
#   ./tools/verify.sh              # → build/probe.png + JSON on stdout
#   ./tools/verify.sh all          # capture every display into build/probe-all.png
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
out="$here/build"
mkdir -p "$out"

"$here/tools/build.sh" >/dev/null
binary="$out/pilot-mac"

echo "=== selftest"
"$binary" selftest > "$out/selftest.json"
python3 -m json.tool "$out/selftest.json" || cat "$out/selftest.json"

echo
echo "=== capture"
mode="${1:-primary}"
params="$out/probe-params.json"
png="$out/probe.png"
if [ "$mode" = "all" ]; then
	png="$out/probe-all.png"
fi
cat > "$params" <<EOF
{
  "screen": "$mode",
  "includeCursor": true,
  "rulers": true,
  "out": "$png"
}
EOF

if "$binary" probe "$params" > "$out/probe.json"; then
	python3 -m json.tool "$out/probe.json" || cat "$out/probe.json"
	echo
	# sips ships with macOS and is the cheapest way to prove the PNG is real.
	sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null || true
	echo
	echo "frame: $png"
	echo "open it and check three things: the rulers are labelled with screen coordinates,"
	echo "the red crosshair sits where the pointer is, and the picture is what you see."
else
	cat "$out/probe.json"
	exit 1
fi
