#!/usr/bin/env python3
"""reference_layer0.py — numpy reference for Qwen2.5 layer-0 forward.

Computes every intermediate of a single transformer layer using numpy,
so we can diff each step against Glacier's output and localize the
numerics bug. Reads weights directly from the safetensors file (no
torch dependency).

Usage:
    python3 tools/reference_layer0.py model.safetensors tokenizer.json "Hi"

Prints max-abs of each intermediate. Compare with:
    glacier dump-activations model.glacier --ids-file prompt.ids
"""
import json
import struct
import sys
import numpy as np

def load_safetensors(path):
    """Return {name: (np.ndarray f32, shape, dtype_str)}."""
    with open(path, "rb") as f:
        hlen = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(hlen))
        data_start = 8 + hlen
        tensors = {}
        for name, info in header.items():
            if name == "__metadata__":
                continue
            off, end = info["data_offsets"]
            f.seek(data_start + off)
            raw = f.read(end - off)
            dtype = info["dtype"]
            shape = info["shape"]
            if dtype == "BF16":
                u16 = np.frombuffer(raw, dtype=np.uint16)
                arr = (u16.astype(np.uint32) << 16).view(np.float32).reshape(shape)
            elif dtype == "F16":
                # F16 → F32 via numpy's float16 then cast.
                arr = np.frombuffer(raw, dtype=np.float16).astype(np.float32).reshape(shape)
            elif dtype == "F32":
                arr = np.frombuffer(raw, dtype=np.float32).reshape(shape)
            else:
                continue
            tensors[name] = arr
    return tensors


def rmsnorm(x, weight, eps):
    """RMSNorm: x / sqrt(mean(x^2) + eps) * weight."""
    ms = np.mean(x.astype(np.float32) ** 2, axis=-1, keepdims=True)
    return x * (1.0 / np.sqrt(ms + eps)) * weight


def silu(x):
    return x / (1.0 + np.exp(-x))


def softmax(x, axis=-1):
    x = x - np.max(x, axis=axis, keepdims=True)
    e = np.exp(x)
    return e / np.sum(e, axis=axis, keepdims=True)


def rope(x, num_heads, head_dim, theta=1000000.0):
    """Apply RoPE to x of shape [seq, num_heads*head_dim] in-place conceptually."""
    seq = x.shape[0]
    # GPT-NeoX style: pairs (i, i+head_dim/2).
    inv_freq = 1.0 / (theta ** (np.arange(0, head_dim, 2, dtype=np.float32) / head_dim))
    positions = np.arange(seq, dtype=np.float32)
    freqs = np.outer(positions, inv_freq)  # [seq, head_dim/2]
    cos = np.cos(freqs)  # [seq, head_dim/2]
    sin = np.sin(freqs)
    out = x.copy().reshape(seq, num_heads, head_dim)
    for h in range(num_heads):
        for k in range(head_dim // 2):
            x0 = out[:, h, k]
            x1 = out[:, h, k + head_dim // 2]
            out[:, h, k] = x0 * cos[:, k] - x1 * sin[:, k]
            out[:, h, k + head_dim // 2] = x0 * sin[:, k] + x1 * cos[:, k]
    return out.reshape(seq, num_heads * head_dim)


def main():
    sf_path = sys.argv[1]
    tz_path = sys.argv[2]
    text = sys.argv[3] if len(sys.argv) > 3 else "Hi"

    W = load_safetensors(sf_path)

    # Tokenize via HF tokenizers (chat template).
    from tokenizers import Tokenizer
    tz = Tokenizer.from_file(tz_path)
    chat = f"<|im_start|>user\n{text}<|im_end|>\n<|im_start|>assistant\n"
    ids = tz.encode(chat).ids
    print(f"prompt ids ({len(ids)}): {ids}")

    # Model config (Qwen2.5-0.5B).
    dim = 896
    hidden = 4864
    n_heads = 14
    n_kv_heads = 2
    head_dim = 64
    eps = 1e-6
    theta = 1000000.0
    kv_dim = n_kv_heads * head_dim

    # Embedding lookup.
    emb = W["model.embed_tokens.weight"]  # [vocab, dim]
    x = emb[np.array(ids)]  # [seq, dim]
    print(f"embedding:    shape={x.shape} max={np.abs(x).max():.4f}")

    # ---- Layer 0 ----
    L = "model.layers.0"
    inp_norm = W[f"{L}.input_layernorm.weight"]
    h_norm = rmsnorm(x, inp_norm, eps)
    print(f"h_norm:       shape={h_norm.shape} max={np.abs(h_norm).max():.4f}")

    wq = W[f"{L}.self_attn.q_proj.weight"]  # [dim, dim]
    bq = W[f"{L}.self_attn.q_proj.bias"]
    q = h_norm @ wq.T + bq
    print(f"q:            shape={q.shape} max={np.abs(q).max():.4f}")

    wk = W[f"{L}.self_attn.k_proj.weight"]  # [kv_dim, dim]
    bk = W[f"{L}.self_attn.k_proj.bias"]
    k = h_norm @ wk.T + bk
    print(f"k:            shape={k.shape} max={np.abs(k).max():.4f}")

    wv = W[f"{L}.self_attn.v_proj.weight"]
    bv = W[f"{L}.self_attn.v_proj.bias"]
    v = h_norm @ wv.T + bv
    print(f"v:            shape={v.shape} max={np.abs(v).max():.4f}")

    # RoPE on q and k.
    q = rope(q, n_heads, head_dim, theta)
    k = rope(k, n_kv_heads, head_dim, theta)
    print(f"q after rope: max={np.abs(q).max():.4f}")
    print(f"k after rope: max={np.abs(k).max():.4f}")

    # Attention (causal, GQA).
    q_r = q.reshape(q.shape[0], n_heads, head_dim)  # [seq, n_heads, hd]
    k_r = k.reshape(k.shape[0], n_kv_heads, head_dim)  # [seq, n_kv, hd]
    v_r = v.reshape(v.shape[0], n_kv_heads, head_dim)
    group = n_heads // n_kv_heads

    attn_out = np.zeros((q.shape[0], dim), dtype=np.float32)
    seq = q.shape[0]
    scale = 1.0 / np.sqrt(head_dim)
    for h in range(n_heads):
        kv_h = h // group
        for i in range(seq):
            scores = (q_r[i, h] @ k_r[:i+1, kv_h].T) * scale  # [i+1]
            probs = softmax(scores)
            ctx = probs @ v_r[:i+1, kv_h]  # [head_dim]
            attn_out[i, h*head_dim:(h+1)*head_dim] = ctx
    print(f"attn_out:     shape={attn_out.shape} max={np.abs(attn_out).max():.4f}")

    wo = W[f"{L}.self_attn.o_proj.weight"]
    bo = W.get(f"{L}.self_attn.o_proj.bias")
    proj = attn_out @ wo.T
    if bo is not None:
        proj = proj + bo
    print(f"proj (wo):    shape={proj.shape} max={np.abs(proj).max():.4f}")

    h = x + proj
    print(f"h (residual): shape={h.shape} max={np.abs(h).max():.4f}")

    # MLP block.
    post_norm = W[f"{L}.post_attention_layernorm.weight"]
    mlp_norm = rmsnorm(h, post_norm, eps)
    w_gate = W[f"{L}.mlp.gate_proj.weight"]
    w_up = W[f"{L}.mlp.up_proj.weight"]
    w_down = W[f"{L}.mlp.down_proj.weight"]
    gate = silu(mlp_norm @ w_gate.T) * (mlp_norm @ w_up.T)
    down = gate @ w_down.T
    out = h + down
    print(f"mlp_norm:     max={np.abs(mlp_norm).max():.4f}")
    print(f"gate*up:      max={np.abs(gate).max():.4f}")
    print(f"down:         max={np.abs(down).max():.4f}")
    print(f"LAYER 0 OUT:  shape={out.shape} max={np.abs(out).max():.4f}")

    # Save the layer-0 output for diffing.
    np.save("/tmp/ref_layer0_out.npy", out)
    np.save("/tmp/ref_attn_out.npy", attn_out)
    np.save("/tmp/ref_q.npy", q)
    print("\nSaved /tmp/ref_layer0_out.npy, /tmp/ref_attn_out.npy, /tmp/ref_q.npy")


if __name__ == "__main__":
    main()
