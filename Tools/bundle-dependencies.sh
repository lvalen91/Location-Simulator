#!/usr/bin/env bash
#
# Freeze pymobiledevice3 (CLI) and the location daemon into standalone arm64
# binaries under Resources/vendor/, so the shipped .app needs NO system Python
# or pymobiledevice3 install. Run this BEFORE building a release .app:
#
#     ./Tools/bundle-dependencies.sh
#     xcodegen generate          # picks up Resources/vendor as a folder ref
#     xcodebuild ... build
#
# The produced binaries are large (~30-50 MB each) and are intentionally NOT
# committed — regenerate them per release / when bumping pymobiledevice3.
#
# Requirements: Homebrew Python (modern; the system 3.9 is too old) + network.
# The frozen binaries are arm64-only, which matches the macOS 27 deployment
# target (Intel/Rosetta is gone after macOS 27).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Resources/vendor"
DAEMON_SRC="$ROOT/Resources/location_daemon.py"

BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"
PYBIN="$("$BREW" --prefix)/bin/python3"
if [ ! -x "$PYBIN" ]; then
  echo "error: Homebrew python3 not found at $PYBIN — run: brew install python" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Creating build venv with $PYBIN"
"$PYBIN" -m venv "$WORK/venv"
# shellcheck disable=SC1091
source "$WORK/venv/bin/activate"
pip install --upgrade pip pyinstaller pymobiledevice3

SITE="$(python -c 'import pymobiledevice3, os; print(os.path.dirname(pymobiledevice3.__file__))')"
mkdir -p "$VENDOR"

common_args=(
  --onefile
  --noconfirm
  --clean
  --collect-all pymobiledevice3
  --collect-submodules pymobiledevice3
  # Several deps (readchar, pymobiledevice3 itself, …) read their own package
  # metadata at runtime via importlib.metadata; bundle it for the whole tree.
  --recursive-copy-metadata pymobiledevice3
  --distpath "$VENDOR"
  --workpath "$WORK/build"
  --specpath "$WORK"
)

echo "==> Freezing pymobiledevice3 CLI (discovery + tunneld)"
pyinstaller "${common_args[@]}" --name pymobiledevice3 "$SITE/__main__.py"

echo "==> Freezing location_daemon (persistent DVT connection)"
pyinstaller "${common_args[@]}" --name location_daemon "$DAEMON_SRC"

chmod +x "$VENDOR/pymobiledevice3" "$VENDOR/location_daemon"
echo "==> Done. Vendored binaries:"
ls -lh "$VENDOR"
echo
echo "Smoke test (no device needed):"
echo "  \"$VENDOR/pymobiledevice3\" usbmux list"
echo
echo "NOTE: tunneld-as-root and the DVT daemon must be validated against a real"
echo "iPhone. If a subcommand fails with a missing-module error, add it via"
echo "--hidden-import in this script and re-run."
