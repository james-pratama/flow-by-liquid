#!/bin/bash
# Runs the three model servers in the foreground (Flow reuses them instead of starting its own).
# Handy while iterating on prompts: the servers stay warm across app rebuilds.
set -euo pipefail
M="$HOME/Library/Application Support/Flow/models"
trap 'kill 0' EXIT
llama-server -m "$M/LFM2.5-2.6B-Q4_K_M.gguf" --host 127.0.0.1 --port 8181 -ngl 99 -c 32768 -np 2 &
llama-server -m "$M/LFM2.5-Audio-1.5B-Q8_0.gguf" --mmproj "$M/mmproj-LFM2.5-Audio-1.5B-Q8_0.gguf" --host 127.0.0.1 --port 8182 -ngl 99 -c 8192 -np 2 &
llama-server -m "$M/LFM2.5-Embedding-350M-Q8_0.gguf" --embeddings --host 127.0.0.1 --port 8183 -ngl 99 -c 4096 -np 2 &
wait
