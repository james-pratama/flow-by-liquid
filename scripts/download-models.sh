#!/bin/bash
# Downloads the GGUF models Smiley runs locally (~12 GB) into ~/Library/Application Support/Smiley/models.
# Re-running resumes partial downloads.
set -euo pipefail
M="$HOME/Library/Application Support/Smiley/models"
mkdir -p "$M"
dl() { echo "↓ $2"; curl -L --fail -C - -o "$M/$2" "https://huggingface.co/$1/resolve/main/$2"; }
dl unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf                      # understands commands (fast)
dl Qwen/Qwen3-Embedding-0.6B-GGUF Qwen3-Embedding-0.6B-Q8_0.gguf        # memory search
dl ggml-org/Qwen3-ASR-1.7B-GGUF Qwen3-ASR-1.7B-Q8_0.gguf                # speech
dl ggml-org/Qwen3-ASR-1.7B-GGUF mmproj-Qwen3-ASR-1.7B-Q8_0.gguf
dl unsloth/Qwen3.5-9B-GGUF Qwen3.5-9B-Q4_K_M.gguf                      # answers and writing
echo "Models ready in $M"
