#!/usr/bin/env sh
# secret-age.sh — thin wrapper that locates python3 and delegates to secret-age.py
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$SCRIPT_DIR/secret-age.py"

# Prefer an active virtual-env / pyenv shim, then fall back to common paths.
for candidate in python3 python python3.11 python3.10 python3.9; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done

if [ -z "${PYTHON:-}" ]; then
  echo "  ✗ python3 not found — install Python 3.7+ and ensure it is on PATH" >&2
  exit 1
fi

exec "$PYTHON" "$PY" "$@"
