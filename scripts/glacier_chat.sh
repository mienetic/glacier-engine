#!/usr/bin/env bash
# glacier_chat.sh — single-turn chat with a Qwen2.5 model via Glacier.
#
# Pipeline: text → Python tokenizer → ids file → glacier generate →
#           ids file → Python detokenizer → text
#
# Usage:
#   scripts/glacier_chat.sh <model.glacier> <tokenizer.json> "your question"
#
# Optional env vars:
#   GLACIER=./zig-out/bin/glacier     path to the glacier binary
#   N=64                               tokens to generate
#   TEMP=0.7                           sampling temperature (0 = greedy)
#   TOP_K=40                           top-k filtering
#   TOP_P=0.9                          nucleus threshold
#   SEED=42                            RNG seed
#   EOS=151645                         Qwen <|endoftext|> id

set -euo pipefail

MODEL="${1:?usage: glacier_chat.sh <model.glacier> <tokenizer.json> \"question\"}"
TZJSON="${2:?usage: glacier_chat.sh <model.glacier> <tokenizer.json> \"question\"}"
MESSAGE="${3:?usage: glacier_chat.sh <model.glacier> <tokenizer.json> \"question\"}"

GLACIER="${GLACIER:-./zig-out/bin/glacier}"
N="${N:-64}"
TEMP="${TEMP:-0.7}"
TOP_K="${TOP_K:-40}"
TOP_P="${TOP_P:-0.9}"
SEED="${SEED:-42}"
EOS="${EOS:-151645}"
TOOLSDIR="$(dirname "$0")/../tools"

TMPIDS=$(mktemp)
TMPIDS_OUT=$(mktemp)
trap 'rm -f "$TMPIDS" "$TMPIDS_OUT"' EXIT

# 1. Wrap in Qwen chat template and tokenize.
python3 "$TOOLSDIR/tok.py" "$TZJSON" --chat "$MESSAGE" > "$TMPIDS"

# 2. Run Glacier generation.
"$GLACIER" generate "$MODEL" \
    --ids-file "$TMPIDS" \
    --out-ids-file "$TMPIDS_OUT" \
    --n "$N" \
    --temp "$TEMP" \
    --top-k "$TOP_K" \
    --top-p "$TOP_P" \
    --seed "$SEED" \
    --eos "$EOS"

# 3. Detokenize.
echo "--- assistant ---"
python3 "$TOOLSDIR/tok.py" "$TZJSON" decode < "$TMPIDS_OUT"
