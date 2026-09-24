#!/bin/bash
# Downloads the LFM2.5 GGUF models Flow runs locally (~3.6 GB) into ~/Library/Application Support/Flow/models.
set -euo pipefail
M="$HOME/Library/Application Support/Flow/models"
mkdir -p "$M"
dl() { echo "↓ $2"; curl -L --fail -C - -o "$M/$2" "https://huggingface.co/$1/resolve/main/$2"; }
dl LiquidAI/LFM2.5-2.6B-GGUF LFM2.5-2.6B-Q4_K_M.gguf
dl LiquidAI/LFM2.5-Audio-1.5B-GGUF LFM2.5-Audio-1.5B-Q8_0.gguf
dl LiquidAI/LFM2.5-Audio-1.5B-GGUF mmproj-LFM2.5-Audio-1.5B-Q8_0.gguf
dl LiquidAI/LFM2.5-Embedding-350M-GGUF LFM2.5-Embedding-350M-Q8_0.gguf
echo "Models ready in $M"
