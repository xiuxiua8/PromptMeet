#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/PromptMeet.app"

echo "============================================"
echo " PromptMeet macOS App - Build & Package"
echo "============================================"
echo ""

# ----------- step 1: dependencies (skip by default; pass --full to rebuild) -----------
if [ "${1:-}" = "--full" ]; then
  echo "[1/3] Building Whisper runtime..."
  PROMPTMEET_SKIP_WHISPER_BUILD=0 bash "$ROOT/scripts/build-whisper-runtime.sh" 2>&1

  echo "[2/3] Preparing Python companion runtime..."
  PROMPTMEET_SKIP_PYTHON_BUILD=0 bash "$ROOT/scripts/prepare-desktop-python.sh" 2>&1
else
  echo "[1/3] Skipping Whisper rebuild   (use --full to rebuild)"
  echo "[2/3] Skipping Python rebuild    (use --full to rebuild)"
fi

# ----------- step 3: compile Swift + assemble .app -----------
echo "[3/3] Building Swift release + packaging .app..."
PROMPTMEET_SKIP_WHISPER_BUILD=1 PROMPTMEET_SKIP_PYTHON_BUILD=1 \
  bash "$ROOT/scripts/build-macos-app.sh" 2>&1

echo ""
echo "============================================"
echo " ✅  Done: $APP"
echo "============================================"

# ----------- optionally launch -----------
if [ "${2:-}" = "--run" ] || [ "${1:-}" = "--run" ]; then
  echo ""
  echo "🚀  Launching PromptMeet..."
  open "$APP"
fi
