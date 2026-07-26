#!/bin/bash

set -euo pipefail

ROOT="${PROMPTMEET_PACKAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REQUIRED=(
  "backend/requirements-desktop.txt"
  "desktop-macos/Resources/Info.plist"
  "desktop-macos/THIRD_PARTY_NOTICES.md"
)
missing=0

for relative_path in "${REQUIRED[@]}"; do
  if [ ! -s "$ROOT/$relative_path" ]; then
    echo "Missing packaging input: $relative_path" >&2
    missing=1
  fi
done

exit "$missing"
