#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_ROOT="$ROOT/desktop-macos"
APP="$ROOT/dist/PromptMeet.app"
CONTENTS="$APP/Contents"

"$ROOT/scripts/check-macos-package-inputs.sh"

if [ "${PROMPTMEET_SKIP_WHISPER_BUILD:-0}" != "1" ]; then
  "$ROOT/scripts/build-whisper-runtime.sh"
fi
if [ "${PROMPTMEET_SKIP_PYTHON_BUILD:-0}" != "1" ]; then
  "$ROOT/scripts/prepare-desktop-python.sh"
fi

if [ ! -x "$MACOS_ROOT/.local/whisper/bin/whisper-cli" ]; then
  echo "Missing local Whisper runtime" >&2
  exit 1
fi
if [ ! -x "$MACOS_ROOT/.local/whisper/bin/whisper-server" ]; then
  echo "Missing persistent local Whisper server" >&2
  exit 1
fi
if [ ! -x "$ROOT/build/desktop-python/bin/python3" ]; then
  echo "Missing desktop companion Python runtime" >&2
  exit 1
fi

cd "$MACOS_ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/companion/python" "$CONTENTS/Resources/whisper"
cp "$MACOS_ROOT/.build/release/PromptMeet" "$CONTENTS/MacOS/PromptMeet"
cp "$MACOS_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp -R "$MACOS_ROOT/.local/whisper/." "$CONTENTS/Resources/whisper/"
cp "$MACOS_ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"

rsync -a \
  --exclude '.env' \
  --exclude 'venv' \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude 'tests' \
  --exclude 'temp' \
  --exclude '.pytest_cache' \
  --exclude '.DS_Store' \
  --exclude 'logs' \
  --exclude 'recordings' \
  --exclude '*.bak' \
  "$ROOT/backend/" "$CONTENTS/Resources/companion/backend/"

rsync -a \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  "$ROOT/build/desktop-python/" "$CONTENTS/Resources/companion/python/"

if find "$APP" -name '.env' -o -name '*.pyc' -o -name 'Result.txt' | grep -q .; then
  echo "Bundle contains excluded development files" >&2
  exit 1
fi

SECRET_MATCHES="$(
  grep -R -l -E 'sk-[A-Za-z0-9_-]{20,}' "$APP" 2>/dev/null \
    | grep -v '/site-packages/packaging/licenses/_spdx.py$' \
    || true
)"
if [ -n "$SECRET_MATCHES" ]; then
  echo "Bundle contains an API key literal" >&2
  exit 1
fi

SIGN_IDENTITY="${PROMPTMEET_CODE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi

codesign --force --sign "$SIGN_IDENTITY" \
  --identifier com.promptmeet.desktop.whisper-cli \
  "$CONTENTS/Resources/whisper/bin/whisper-cli"
codesign --force --sign "$SIGN_IDENTITY" \
  --identifier com.promptmeet.desktop.whisper-server \
  "$CONTENTS/Resources/whisper/bin/whisper-server"
codesign --force --deep --sign "$SIGN_IDENTITY" \
  --identifier com.promptmeet.desktop \
  --entitlements "$MACOS_ROOT/Resources/PromptMeet.entitlements" \
  --options runtime \
  "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP"
