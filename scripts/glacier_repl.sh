#!/usr/bin/env bash
# glacier_repl.sh — interactive multi-turn chat with a Qwen2.5 model.
#
# Keeps the conversation in a growing context and generates responses
# interactively. Type 'quit' or Ctrl-C to exit.
#
# Usage:
#   scripts/glacier_repl.sh <model.glacier> <tokenizer.json>
#
# Optional env vars (same as glacier_chat.sh):
#   GLACIER, N, TEMP, TOP_K, TOP_P, SEED, EOS

set -euo pipefail

MODEL="${1:?usage: glacier_repl.sh <model.glacier> <tokenizer.json>}"
TZJSON="${2:?usage: glacier_repl.sh <model.glacier> <tokenizer.json>}"

GLACIER="${GLACIER:-./zig-out/bin/glacier}"
N="${N:-128}"
TEMP="${TEMP:-0.7}"
TOP_K="${TOP_K:-40}"
TOP_P="${TOP_P:-0.9}"
SEED="${SEED:-42}"
EOS="${EOS:-151645}"
TOOLSDIR="$(dirname "$0")/../tools"

# Accumulate conversation tokens (space-separated).
CONV_IDS=""

echo "Glacier REPL — Qwen2.5 via Glacier Engine"
echo "Type 'quit' to exit. Type 'reset' to clear conversation."
echo ""

while true; do
    echo -n "user> "
    read -r MESSAGE || break

    if [ "$MESSAGE" = "quit" ] || [ "$MESSAGE" = "exit" ]; then
        echo "Goodbye."
        break
    fi

    if [ "$MESSAGE" = "reset" ]; then
        CONV_IDS=""
        echo "(conversation cleared)"
        echo ""
        continue
    fi

    if [ -z "$MESSAGE" ]; then
        continue
    fi

    # Tokenize this user turn.
    TMPIDS=$(mktemp)
    TMPIDS_OUT=$(mktemp)
    trap 'rm -f "$TMPIDS" "$TMPIDS_OUT"' EXIT

    # Build the full conversation: previous context + new user turn.
    USER_IDS=$(python3 "$TOOLSDIR/tok.py" "$TZJSON" --chat "$MESSAGE" 2>/dev/null)
    if [ -z "$CONV_IDS" ]; then
        CONV_IDS="$USER_IDS"
    else
        CONV_IDS="$CONV_IDS $USER_IDS"
    fi

    echo "$CONV_IDS" > "$TMPIDS"

    # Generate response.
    "$GLACIER" generate "$MODEL" \
        --ids-file "$TMPIDS" \
        --out-ids-file "$TMPIDS_OUT" \
        --n "$N" \
        --temp "$TEMP" \
        --top-k "$TOP_K" \
        --top-p "$TOP_P" \
        --seed "$SEED" \
        --eos "$EOS" 2>/dev/null

    # Detokenize.
    RESPONSE=$(python3 "$TOOLSDIR/tok.py" "$TZJSON" decode < "$TMPIDS_OUT" 2>/dev/null)
    echo "assistant> $RESPONSE"
    echo ""

    # Append response tokens to conversation for multi-turn context.
    RESP_IDS=$(cat "$TMPIDS_OUT")
    CONV_IDS="$CONV_IDS $RESP_IDS"

    rm -f "$TMPIDS" "$TMPIDS_OUT"
done
