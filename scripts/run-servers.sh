#!/bin/bash
# Runs the four model servers in the foreground (Smiley reuses them instead of starting its own).
# Handy while iterating on prompts: the servers stay warm across app rebuilds.
set -euo pipefail
M="$HOME/Library/Application Support/Smiley/models"
trap 'kill 0' EXIT
llama-server -m "$M/Qwen3.5-4B-Q4_K_M.gguf" --host 127.0.0.1 --port 8191 -ngl 99 --cache-ram 0 -c 16384 -np 2 -b 128 &
llama-server -m "$M/Qwen3-ASR-1.7B-Q8_0.gguf" --mmproj "$M/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf" --host 127.0.0.1 --port 8192 -ngl 99 --cache-ram 0 -c 8192 -np 2 &
llama-server -m "$M/Qwen3-Embedding-0.6B-Q8_0.gguf" --embeddings --pooling last --host 127.0.0.1 --port 8193 -ngl 99 --cache-ram 0 -c 4096 -np 2 &
llama-server -m "$M/Qwen3.5-9B-Q4_K_M.gguf" --host 127.0.0.1 --port 8194 -ngl 99 --cache-ram 0 -c 32768 -np 2 &
wait
