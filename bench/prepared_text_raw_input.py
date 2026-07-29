"""Independent UTF-8 byte-tokenizer and raw-plan binding verifier."""

from __future__ import annotations

import hashlib
import struct
from typing import Mapping, Sequence


class RawInputError(ValueError):
    """The tokenizer or raw-input evidence is not canonical."""


DIGEST_BYTES = 32
U32_MAX = (1 << 32) - 1
U64_MAX = (1 << 64) - 1
MANIFEST_ABI = 0x4754_4F4B_0000_0001
PROMPT_ABI = 0x4754_5052_0000_0001
BINDING_ABI = 0x4750_5452_0000_0001
LOCAL_PLAN_ABI = 0x474C_5450_0000_0001
BOUND_PLAN_ABI = 0x474C_5443_0000_0001
MANIFEST_BYTES = 192
MANIFEST_BODY_BYTES = 160
PROMPT_BYTES = 256
PROMPT_BODY_BYTES = 224
BINDING_BYTES = 480
BINDING_BODY_BYTES = 448
MAX_INPUT_BYTES = 1024 * 1024
TOKEN_COUNT = 256
NO_SPECIAL_TOKEN = (1 << 32) - 1
MANIFEST_MAGIC = b"GTOKV1\x00\x00"
PROMPT_MAGIC = b"GTPRV1\x00\x00"
BINDING_MAGIC = b"GPTRAW1\x00"
MANIFEST_FLAGS = 0xF

MANIFEST_DOMAIN = b"glacier-utf8-byte-tokenizer-manifest-v1\x00"
DOMAIN_DESCRIPTOR = (
    b"glacier-utf8-byte-token-domain-v1:"
    b"strict-utf8;normalization=none;byte-token-base=0;"
    b"byte-token-count=256;special-tokens=disabled;"
    b"fallback=reject\x00"
)
BEHAVIOR_DESCRIPTOR = (
    b"glacier-utf8-byte-tokenizer-behavior-v1:"
    b"one-token-per-input-byte;token-id=unsigned-byte;"
    b"decode=token-id-as-byte;input-must-be-valid-utf8\x00"
)
RAW_TEXT_DOMAIN = b"glacier-utf8-byte-tokenizer-raw-text-v1\x00"
TOKEN_STREAM_DOMAIN = (
    b"glacier-utf8-byte-tokenizer-token-stream-v1\x00"
)
PROMPT_DOMAIN = (
    b"glacier-utf8-byte-tokenizer-prompt-receipt-v1\x00"
)
PREPARED_PROMPT_DOMAIN = b"glacier-prepared-text-prompt-v1\x00"
BINDING_DOMAIN = b"glacier-prepared-text-raw-input-binding-v1\x00"
LOCAL_PLAN_DOMAIN = b"glacier-prepared-text-plan-v1\x00"
BOUND_PLAN_DOMAIN = b"glacier-prepared-text-bound-plan-v1\x00"
CLAIM_FIELDS = (
    "capsule_bytes",
    "kv_bytes",
    "activation_bytes",
    "partial_bytes",
    "logits_bytes",
    "output_journal_bytes",
    "staging_bytes",
    "device_bytes",
    "io_bytes",
    "queue_slots",
)


def _sha(*parts: bytes) -> bytes:
    digest = hashlib.sha256()
    for part in parts:
        digest.update(part)
    return digest.digest()


def _u32(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= U32_MAX:
        raise RawInputError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise RawInputError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != DIGEST_BYTES:
        raise RawInputError("invalid digest")
    return value


def tokenizer_domain_sha256() -> bytes:
    return _sha(DOMAIN_DESCRIPTOR)


def tokenizer_behavior_sha256() -> bytes:
    return _sha(BEHAVIOR_DESCRIPTOR)


def manifest_wire(vocab_size: int, max_input_bytes: int) -> bytes:
    _u32(vocab_size)
    _u64(max_input_bytes)
    if vocab_size < TOKEN_COUNT:
        raise RawInputError("unsupported vocabulary")
    if not 0 < max_input_bytes <= MAX_INPUT_BYTES:
        raise RawInputError("invalid input limit")
    body = bytearray(MANIFEST_BODY_BYTES)
    body[0:8] = MANIFEST_MAGIC
    struct.pack_into("<QQ", body, 8, MANIFEST_ABI, MANIFEST_BYTES)
    struct.pack_into(
        "<IIIIIIIIIIQ",
        body,
        24,
        1,
        1,
        1,
        MANIFEST_FLAGS,
        vocab_size,
        0,
        TOKEN_COUNT,
        NO_SPECIAL_TOKEN,
        NO_SPECIAL_TOKEN,
        NO_SPECIAL_TOKEN,
        max_input_bytes,
    )
    body[72:104] = tokenizer_domain_sha256()
    body[104:136] = tokenizer_behavior_sha256()
    return bytes(body) + _sha(MANIFEST_DOMAIN, bytes(body))


def decode_manifest(encoded: bytes) -> Mapping[str, object]:
    if not isinstance(encoded, bytes) or len(encoded) != MANIFEST_BYTES:
        raise RawInputError("invalid manifest length")
    if (
        encoded[:8] != MANIFEST_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != MANIFEST_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != MANIFEST_BYTES
        or struct.unpack_from("<I", encoded, 24)[0] != 1
        or struct.unpack_from("<I", encoded, 28)[0] != 1
        or struct.unpack_from("<I", encoded, 32)[0] != 1
        or struct.unpack_from("<I", encoded, 36)[0] != MANIFEST_FLAGS
        or struct.unpack_from("<I", encoded, 44)[0] != 0
        or struct.unpack_from("<I", encoded, 48)[0] != TOKEN_COUNT
        or struct.unpack_from("<I", encoded, 52)[0]
        != NO_SPECIAL_TOKEN
        or struct.unpack_from("<I", encoded, 56)[0]
        != NO_SPECIAL_TOKEN
        or struct.unpack_from("<I", encoded, 60)[0]
        != NO_SPECIAL_TOKEN
        or any(encoded[136:MANIFEST_BODY_BYTES])
        or encoded[72:104] != tokenizer_domain_sha256()
        or encoded[104:136] != tokenizer_behavior_sha256()
        or encoded[MANIFEST_BODY_BYTES:]
        != _sha(MANIFEST_DOMAIN, encoded[:MANIFEST_BODY_BYTES])
    ):
        raise RawInputError("invalid manifest")
    vocab_size = struct.unpack_from("<I", encoded, 40)[0]
    max_input_bytes = struct.unpack_from("<Q", encoded, 64)[0]
    if vocab_size < TOKEN_COUNT or not 0 < max_input_bytes <= MAX_INPUT_BYTES:
        raise RawInputError("invalid manifest bounds")
    return {
        "vocab_size": vocab_size,
        "max_input_bytes": max_input_bytes,
        "domain_sha256": encoded[72:104],
        "behavior_sha256": encoded[104:136],
        "config_sha256": encoded[MANIFEST_BODY_BYTES:],
    }


def raw_text_sha256(raw_text: bytes) -> bytes:
    return _sha(RAW_TEXT_DOMAIN, _u64(len(raw_text)), raw_text)


def token_ids_sha256(tokens: Sequence[int]) -> bytes:
    digest = hashlib.sha256()
    digest.update(TOKEN_STREAM_DOMAIN)
    digest.update(_u64(len(tokens)))
    for token in tokens:
        digest.update(_u32(token))
    return digest.digest()


def prepared_prompt_sha256(tokens: Sequence[int]) -> bytes:
    digest = hashlib.sha256()
    digest.update(PREPARED_PROMPT_DOMAIN)
    digest.update(_u64(len(tokens)))
    for token in tokens:
        digest.update(_u32(token))
    return digest.digest()


def tokenize(
    text: str,
    *,
    vocab_size: int,
    max_input_bytes: int,
) -> tuple[tuple[int, ...], bytes, bytes]:
    if type(text) is not str:
        raise RawInputError("text must be str")
    manifest = manifest_wire(vocab_size, max_input_bytes)
    try:
        encoded = text.encode("utf-8", "strict")
    except UnicodeEncodeError as error:
        raise RawInputError("invalid UTF-8 text") from error
    if not encoded:
        raise RawInputError("empty input")
    if len(encoded) > max_input_bytes:
        raise RawInputError("input too large")
    config = decode_manifest(manifest)
    tokens = tuple(encoded)
    body = bytearray(PROMPT_BODY_BYTES)
    body[0:8] = PROMPT_MAGIC
    struct.pack_into("<QQQ", body, 8, PROMPT_ABI, PROMPT_BYTES, 0)
    body[32:64] = _digest(config["domain_sha256"])
    body[64:96] = _digest(config["config_sha256"])
    body[96:128] = raw_text_sha256(encoded)
    body[128:160] = token_ids_sha256(tokens)
    struct.pack_into("<QQ", body, 160, len(encoded), len(tokens))
    prompt = bytes(body) + _sha(PROMPT_DOMAIN, bytes(body))
    return tokens, manifest, prompt


def decode_prompt(encoded: bytes) -> Mapping[str, object]:
    if not isinstance(encoded, bytes) or len(encoded) != PROMPT_BYTES:
        raise RawInputError("invalid prompt length")
    if (
        encoded[:8] != PROMPT_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != PROMPT_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != PROMPT_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[176:PROMPT_BODY_BYTES])
        or encoded[32:64] != tokenizer_domain_sha256()
        or encoded[PROMPT_BODY_BYTES:]
        != _sha(PROMPT_DOMAIN, encoded[:PROMPT_BODY_BYTES])
    ):
        raise RawInputError("invalid prompt")
    raw_bytes, token_count = struct.unpack_from("<QQ", encoded, 160)
    if (
        raw_bytes == 0
        or raw_bytes > MAX_INPUT_BYTES
        or token_count != raw_bytes
        or any(
            encoded[offset : offset + DIGEST_BYTES] == bytes(DIGEST_BYTES)
            for offset in (64, 96, 128)
        )
    ):
        raise RawInputError("invalid prompt fields")
    return {
        "tokenizer_domain_sha256": encoded[32:64],
        "tokenizer_config_sha256": encoded[64:96],
        "raw_text_sha256": encoded[96:128],
        "token_ids_sha256": encoded[128:160],
        "raw_text_bytes": raw_bytes,
        "token_count": token_count,
        "receipt_sha256": encoded[PROMPT_BODY_BYTES:],
    }


def binding_wire_from_report(report: Mapping[str, object]) -> bytes:
    def report_digest(name: str) -> bytes:
        value = report.get(name)
        if not isinstance(value, str) or len(value) != 64:
            raise RawInputError(f"invalid {name}")
        try:
            decoded = bytes.fromhex(value)
        except ValueError as error:
            raise RawInputError(f"invalid {name}") from error
        if decoded == bytes(DIGEST_BYTES):
            raise RawInputError(f"zero {name}")
        return decoded

    prompt_tokens = report.get("prompt_tokens")
    prompt_bytes = report.get("prompt_bytes")
    request_epoch = report.get("request_epoch")
    if (
        type(prompt_tokens) is not int
        or type(prompt_bytes) is not int
        or prompt_tokens <= 0
        or prompt_tokens != prompt_bytes
        or prompt_bytes > MAX_INPUT_BYTES
        or prompt_bytes > U64_MAX
        or type(request_epoch) is not int
        or request_epoch <= 0
        or request_epoch > U64_MAX
    ):
        raise RawInputError("invalid binding scalars")
    body = bytearray(BINDING_BODY_BYTES)
    body[0:8] = BINDING_MAGIC
    struct.pack_into(
        "<QQQ", body, 8, BINDING_ABI, BINDING_BYTES, 0
    )
    fields = (
        "tokenizer_domain_sha256",
        "tokenizer_config_sha256",
        "prompt_receipt_sha256",
        "raw_text_sha256",
        "token_ids_sha256",
        "prepared_prompt_sha256",
        "local_plan_sha256",
        "bound_plan_sha256",
        "artifact_sha256",
        "execution_plan_sha256",
        "residency_binding_sha256",
        "artifact_license_sha256",
    )
    for index, name in enumerate(fields):
        offset = 32 + index * DIGEST_BYTES
        body[offset : offset + DIGEST_BYTES] = report_digest(name)
    struct.pack_into(
        "<QQQ",
        body,
        416,
        request_epoch,
        prompt_tokens,
        prompt_bytes,
    )
    return bytes(body) + _sha(BINDING_DOMAIN, bytes(body))


def binding_root_from_report(report: Mapping[str, object]) -> bytes:
    return binding_wire_from_report(report)[BINDING_BODY_BYTES:]


def decode_binding(encoded: bytes) -> Mapping[str, object]:
    if not isinstance(encoded, bytes) or len(encoded) != BINDING_BYTES:
        raise RawInputError("invalid binding length")
    if (
        encoded[:8] != BINDING_MAGIC
        or struct.unpack_from("<Q", encoded, 8)[0] != BINDING_ABI
        or struct.unpack_from("<Q", encoded, 16)[0] != BINDING_BYTES
        or struct.unpack_from("<Q", encoded, 24)[0] != 0
        or any(encoded[440:BINDING_BODY_BYTES])
        or encoded[BINDING_BODY_BYTES:]
        != _sha(BINDING_DOMAIN, encoded[:BINDING_BODY_BYTES])
    ):
        raise RawInputError("invalid binding")
    names = (
        "tokenizer_domain_sha256",
        "tokenizer_config_sha256",
        "prompt_receipt_sha256",
        "raw_text_sha256",
        "token_ids_sha256",
        "prepared_prompt_sha256",
        "local_plan_sha256",
        "bound_plan_sha256",
        "artifact_sha256",
        "execution_plan_sha256",
        "residency_binding_sha256",
        "artifact_license_sha256",
    )
    value: dict[str, object] = {
        name: encoded[32 + index * DIGEST_BYTES : 64 + index * DIGEST_BYTES]
        for index, name in enumerate(names)
    }
    request_epoch, prompt_tokens, prompt_bytes = struct.unpack_from(
        "<QQQ", encoded, 416
    )
    value.update(
        request_epoch=request_epoch,
        prompt_tokens=prompt_tokens,
        prompt_bytes=prompt_bytes,
        binding_sha256=encoded[BINDING_BODY_BYTES:],
    )
    if (
        value["tokenizer_domain_sha256"] != tokenizer_domain_sha256()
        or request_epoch == 0
        or prompt_tokens == 0
        or prompt_tokens != prompt_bytes
        or prompt_bytes > MAX_INPUT_BYTES
        or any(
            value[name] == bytes(DIGEST_BYTES)
            for name in names[1:]
        )
    ):
        raise RawInputError("invalid binding fields")
    return value


def local_plan_sha256(
    *,
    source_fingerprint: bytes,
    abi_fingerprint: bytes,
    container_bytes: int,
    container_sha256: bytes,
    prompt_tokens: int,
    prompt_sha256: bytes,
    max_new_tokens: int,
    eos_token: int,
    seed: int,
    claim: Mapping[str, object],
) -> bytes:
    try:
        claim_values = tuple(claim[name] for name in CLAIM_FIELDS)
    except (KeyError, TypeError):
        raise RawInputError("invalid local-plan claim") from None
    return _sha(
        LOCAL_PLAN_DOMAIN,
        _u64(LOCAL_PLAN_ABI),
        _digest(source_fingerprint),
        _digest(abi_fingerprint),
        _u64(container_bytes),
        _digest(container_sha256),
        _u64(prompt_tokens),
        _digest(prompt_sha256),
        _u64(max_new_tokens),
        _u32(eos_token),
        _u64(seed),
        *(_u64(value) for value in claim_values),
    )


def bound_plan_sha256(
    *,
    local_plan_sha256: bytes,
    artifact_sha256: bytes,
    execution_plan_sha256: bytes,
    residency_binding_sha256: bytes,
    tokenizer_domain_sha256: bytes,
    tokenizer_config_sha256: bytes,
    artifact_license_sha256: bytes,
) -> bytes:
    return _sha(
        BOUND_PLAN_DOMAIN,
        _u64(BOUND_PLAN_ABI),
        _digest(local_plan_sha256),
        _digest(artifact_sha256),
        _digest(execution_plan_sha256),
        _digest(residency_binding_sha256),
        _digest(tokenizer_domain_sha256),
        _digest(tokenizer_config_sha256),
        _digest(artifact_license_sha256),
    )
