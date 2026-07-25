#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PROMPTMEET_BOOTSTRAP_PYTHON:-python3}"
VENV="$ROOT/build/desktop-python"
REQUIREMENTS="$ROOT/backend/requirements-desktop.txt"

if [ ! -x "$VENV/bin/python3" ]; then
  "$PYTHON" -m venv --copies "$VENV"
fi

"$VENV/bin/python3" -m pip install \
  --disable-pip-version-check \
  --quiet \
  --trusted-host pypi.org \
  --trusted-host files.pythonhosted.org \
  -r "$REQUIREMENTS"

"$VENV/bin/python3" - <<'PY'
import fastapi
import httpx
import pydantic
import uvicorn
print("desktop-python-ready")
PY

