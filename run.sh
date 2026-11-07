#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

MODE="${1:-run}"

swift build -c release

BIN="$ROOT/.build/release/CursorUsageMenubar"

case "$MODE" in
  status)
    # one-shot headless check via swift script helper
    python3 "$ROOT/scripts/status.py"
    ;;
  run|"")
    # kill previous instance of this binary path if any
    pkill -f "$BIN" 2>/dev/null || true
    exec "$BIN"
    ;;
  *)
    echo "usage: $0 [run|status]" >&2
    exit 2
    ;;
esac
