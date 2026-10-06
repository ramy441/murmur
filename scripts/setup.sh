#!/bin/bash
# One-time setup: Python worker venv + both models. The only step that touches the network.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/Murmur"
VENV="$SUPPORT/venv"
HUB="$HOME/.cache/huggingface/hub"
MODELS=("mlx-community/parakeet-tdt-0.6b-v3" "mlx-community/Qwen3-4B-Instruct-2507-4bit")

command -v ffmpeg >/dev/null || { echo "ffmpeg missing: brew install ffmpeg"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing: brew install python"; exit 1; }

if [[ ! -x "$VENV/bin/python3" ]]; then
    mkdir -p "$SUPPORT"
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet parakeet-mlx mlx-lm

for id in "${MODELS[@]}"; do
    blobs="$HUB/models--${id//\//--}/blobs"
    if [[ -d "$blobs" ]] && [[ -n "$(ls "$blobs")" ]] && ! ls "$blobs" | grep -q '\.incomplete$'; then
        echo "ready  $id"
    else
        echo "fetch  $id"
        "$VENV/bin/python3" -c "from huggingface_hub import snapshot_download; snapshot_download('$id')"
    fi
done

echo "setup done, now: ./build.sh --install"
