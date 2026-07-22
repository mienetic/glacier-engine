#!/usr/bin/env python3
"""tokenize.py — encode text → token ids using a HF tokenizer.json.

Bridges the gap between human text and Glacier's numeric-token CLI.
Reads text from stdin (or --text), writes space-separated token ids to
stdout. Pair with detokenize.py for the reverse direction.

Usage:
    echo "Hello, world" | python3 tools/tokenize.py tokenizer.json
    python3 tools/tokenize.py tokenizer.json --text "Hello" --add-special
"""
import argparse
import json
import sys


def load_tokenizer(path):
    """Minimal BPE tokenizer that reads HF tokenizer.json.

    Implements only the pieces Glacier needs: byte-level pre-tokenization,
    merge-based BPE encoding, and special-token insertion. It is NOT a
    full HF tokenizer — it skips normalization and the post-processor
    beyond a basic template. Sufficient for Qwen2.5, which is byte-level
    BPE without lowercasing.
    """
    with open(path) as f:
        tz = json.load(f)
    model = tz["model"]
    vocab = model["vocab"]  # token string → id
    merges = model.get("merges", [])  # list of "a b" merge rules in priority order

    # Special tokens (e.g. <|endoftext|>, <|im_start|>).
    added = tz.get("added_tokens", [])
    special = {t["content"]: t["id"] for t in added}

    # Build inverse vocab for decode.
    id_to_token = {v: k for k, v in vocab.items()}
    for tok, tid in special.items():
        id_to_token[tid] = tok

    return {
        "vocab": vocab,
        "merges": [(m.split()[0], m.split()[1]) for m in merges if len(m.split()) == 2],
        "special": special,
        "id_to_token": id_to_token,
        "model_type": model["type"],
    }


def encode(text, tz, add_special=False, bos=None, eos=None):
    """Encode text to a list of token ids using byte-level BPE."""
    # Qwen2.5 uses byte-level BPE: every UTF-8 byte maps to a unicode
    # char from a specific offset table, then BPE runs on that string.
    # We approximate by encoding to the byte-level alphabet that HF uses.
    # For ASCII-only text the byte-level alphabet is identity.
    byte_to_unicode = _byte_to_unicode_table()
    inv = {v: k for k, v in byte_to_unicode.items()}

    # Map each input byte to its byte-level unicode char.
    bs = text.encode("utf-8")
    chars = [byte_to_unicode[b] for b in bs]

    # Pre-merge consecutive identical chars is NOT done — BPE starts from
    # individual symbols and applies merges greedily.
    tokens = list(chars)

    # Greedy BPE: repeatedly apply the highest-priority merge present.
    # This is O(n²) but fine for short prompts.
    merges_by_pair = {}
    for i, (a, b) in enumerate(tz["merges"]):
        merges_by_pair[(a, b)] = i  # lower index = higher priority

    changed = True
    while changed and len(tokens) > 1:
        changed = False
        best_idx = -1
        best_pri = 1 << 30
        for i in range(len(tokens) - 1):
            pri = merges_by_pair.get((tokens[i], tokens[i + 1]))
            if pri is not None and pri < best_pri:
                best_pri = pri
                best_idx = i
        if best_idx >= 0:
            merged = tokens[best_idx] + tokens[best_idx + 1]
            tokens = tokens[:best_idx] + [merged] + tokens[best_idx + 2:]
            changed = True

    # Look up final tokens in vocab. Anything missing → use byte id 0 fallback.
    ids = []
    for tok in tokens:
        if tok in tz["vocab"]:
            ids.append(tz["vocab"][tok])
        else:
            # Unknown: emit raw byte id (byte-level fallback).
            # The byte-level alphabet's chars all have vocab entries in a
            # well-formed tokenizer, so this should rarely trigger.
            sys.stderr.write(f"warning: token '{tok}' not in vocab\n")
            ids.append(0)

    if add_special:
        out = []
        if bos is not None:
            out.append(bos)
        out.extend(ids)
        if eos is not None:
            out.append(eos)
        return out
    return ids


def decode(ids, tz):
    """Decode ids back to text. Joins token strings, then reverses the
    byte-level alphabet back to UTF-8 bytes."""
    byte_to_unicode = _byte_to_unicode_table()
    inv = {v: k for k, v in byte_to_unicode.items()}

    chars = []
    for i in ids:
        tok = tz["id_to_token"].get(i)
        if tok is None:
            continue
        # Skip Qwen special tokens.
        if tok.startswith("<|") and tok.endswith("|>"):
            continue
        chars.append(tok)

    # Reverse the byte-level mapping.
    out_bytes = bytearray()
    for c in "".join(chars):
        if c in inv:
            out_bytes.append(inv[c])
        else:
            # Multi-byte token char already (merged); encode directly.
            out_bytes.extend(c.encode("utf-8"))
    return out_bytes.decode("utf-8", errors="replace")


def _byte_to_unicode_table():
    """Reproduce HF's byte_to_unicode mapping (GPT-2 style).

    Maps each of the 256 byte values to a printable unicode char so BPE
    never sees whitespace/control bytes. Reversible.
    """
    bs = (
        list(range(ord("!"), ord("~") + 1))
        + list(range(ord("¡"), ord("¬") + 1))
        + list(range(ord("®"), ord("ÿ") + 1))
    )
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    cs = [chr(c) for c in cs]
    return dict(zip(bs, cs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tokenizer_json")
    ap.add_argument("--text", help="text to encode (default: stdin)")
    ap.add_argument("--add-special", action="store_true",
                    help="prepend BOS / append EOS if known")
    ap.add_argument("--decode", action="store_true",
                    help="decode mode: read ids from stdin, print text")
    args = ap.parse_args()

    tz = load_tokenizer(args.tokenizer_json)

    if args.decode:
        # Read ids from stdin: either space- or newline-separated.
        raw = sys.stdin.read().split()
        ids = [int(x) for x in raw if x.lstrip("-").isdigit()]
        sys.stdout.write(decode(ids, tz))
        sys.stdout.write("\n")
        return

    if args.text is not None:
        text = args.text
    else:
        text = sys.stdin.read()
        if text.endswith("\n"):
            text = text[:-1]

    bos = tz["special"].get("<|im_start|>") if args.add_special else None
    eos = tz["special"].get("<|endoftext|>") if args.add_special else None
    ids = encode(text, tz, add_special=args.add_special, bos=bos, eos=eos)
    print(" ".join(str(i) for i in ids))


if __name__ == "__main__":
    main()
