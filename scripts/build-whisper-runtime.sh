#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_COMMIT="f3ff80ea8da044e5b8833e7ba54ee174504c518d"
SOURCE="$ROOT/build/whisper.cpp-$WHISPER_COMMIT"
BUILD="$SOURCE/build-promptmeet"
OUTPUT="$ROOT/desktop-macos/.local/whisper"

if [ ! -d "$SOURCE/.git" ]; then
  git clone https://github.com/ggerganov/whisper.cpp.git "$SOURCE"
  git -C "$SOURCE" checkout "$WHISPER_COMMIT"
fi

if [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$WHISPER_COMMIT" ]; then
  echo "Unexpected whisper.cpp revision in $SOURCE" >&2
  exit 1
fi

cmake \
  -S "$SOURCE" \
  -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=ON \
  -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$BUILD" --config Release --target whisper-cli whisper-server -j "$(sysctl -n hw.ncpu)"

mkdir -p "$OUTPUT/bin"
cp "$BUILD/bin/whisper-cli" "$OUTPUT/bin/whisper-cli"
cp "$BUILD/bin/whisper-server" "$OUTPUT/bin/whisper-server"
chmod +x "$OUTPUT/bin/whisper-cli" "$OUTPUT/bin/whisper-server"

if [ -f "$SOURCE/ggml/src/ggml-metal/ggml-metal.metal" ]; then
  cp "$SOURCE/ggml/src/ggml-metal/ggml-metal.metal" "$OUTPUT/ggml-metal.metal"
fi

echo "$OUTPUT/bin/whisper-server"
