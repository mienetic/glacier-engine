#!/usr/bin/env python3
"""tok.py — HF tokenizers wrapper for Glacier.

Uses the official `tokenizers` library so we match Qwen's BPE exactly.
Glacier itself stays pure-Zig; this script is the bridge for text I/O
until a native Zig BPE decoder lands.

Modes:
    encode (default):  text on stdin → ids on stdout (space-separated)
    decode:            ids on stdin → text on stdout

Usage:
    printf 'Hello' | python3 tools/tok.py tokenizer.json
    printf '15496 11 995' | python3 tools/tok.py tokenizer.json decode

Optional Qwen chat template wrapping with --chat:
    python3 tools/tok.py tokenizer.json --chat "user question"
"""
import argparse
import sys

try:
    from tokenizers import Tokenizer
except ImportError:
    sys.stderr.write("error: pip install tokenizers\n")
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tokenizer_json")
    ap.add_argument("mode", nargs="?", default="encode",
                    choices=["encode", "decode"])
    ap.add_argument("--text", help="encode this text instead of stdin")
    ap.add_argument("--chat", help="wrap as Qwen chat user turn, then encode")
    ap.add_argument("--add-special", action="store_true", default=True,
                    help="add special tokens (default: on for encode)")
    ap.add_argument("--no-special", dest="add_special", action="store_false")
    ap.add_argument(
        "--strip-final-newline",
        action="store_true",
        help="remove exactly one final LF from stdin (never implicit)",
    )
    args = ap.parse_args()

    tz = Tokenizer.from_file(args.tokenizer_json)

    if args.mode == "decode":
        raw = sys.stdin.read().split()
        ids = [int(x) for x in raw if x.lstrip("-").isdigit()]
        text = tz.decode(ids)
        sys.stdout.write(text)
        if not text.endswith("\n"):
            sys.stdout.write("\n")
        return

    # Encode mode.
    if args.chat is not None:
        # Qwen2.5 chat template:
        #   <|im_start|>user\n{msg}<|im_end|>\n<|im_start|>assistant\n
        text = f"<|im_start|>user\n{args.chat}<|im_end|>\n<|im_start|>assistant\n"
    elif args.text is not None:
        text = args.text
    else:
        text = sys.stdin.read()
        if args.strip_final_newline and text.endswith("\n"):
            text = text[:-1]

    if args.add_special:
        enc = tz.encode(text)
    else:
        enc = tz.encode(text, add_special_tokens=False)
    print(" ".join(str(i) for i in enc.ids))


if __name__ == "__main__":
    main()
