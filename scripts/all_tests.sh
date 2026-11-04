#!/usr/bin/env bash
# The local checks. Usage: ROC=/path/to/roc scripts/all_tests.sh [--e2e]
# With --e2e, also builds examples/client.roc, starts tests/echo_server.py on
# port 9001 and the app on 8088, and checks /echo with curl (needs python3).
set -euo pipefail
ROC="${ROC:-roc}"
cd "$(dirname "$0")/.."
# Keep the roc cache and the build output inside the repository.
export ROC_CACHE_DIR="${ROC_CACHE_DIR:-$PWD/.cache/roc}"
mkdir -p "$ROC_CACHE_DIR"

"$ROC" version
"$ROC" fmt --check src examples
"$ROC" check src/main.roc
for f in examples/*.roc; do
	"$ROC" check "$f"
done

if [[ "${1:-}" == "--e2e" ]]; then
	out="$PWD/.cache/e2e"
	mkdir -p "$out"
	"$ROC" build examples/client.roc --output="$out/client"
	python3 -I tests/echo_server.py 9001 2>"$out/server.log" &
	server=$!
	"$out/client" >"$out/app.log" 2>&1 &
	app=$!
	trap 'kill $server $app 2>/dev/null || true' EXIT
	sleep 2
	reply="$(curl -s -m 60 http://127.0.0.1:8088/echo)"
	echo "$reply"
	grep -q 'closed: { by: Us, clean: True, code: 1000' <<<"$reply"
	grep -q 'server closed: { by: Peer, clean: True, code: 4000' <<<"$reply"
fi
