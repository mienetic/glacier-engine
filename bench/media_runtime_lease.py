"""Independent oracle for per-buffer LeaseTree media runtime receipts."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from bench import media_contract as media
from bench import media_decode_fixture as fixture_api
from bench import media_runtime_txn as flat_runtime
from bench import media_transform as transform


class MediaRuntimeLeaseError(ValueError):
    """A hierarchical media ownership record is invalid."""


Record = dict[str, Any]
RUNTIME_ABI = 0x474D524C00000001
RECEIPT_ABI = 0x474D524500000001
RECEIPT_MAGIC = b"GMRLEAS1"
RECEIPT_BODY_BYTES = 1504
RECEIPT_BYTES = 1536
BINDING_RECORD_BYTES = 136
MAXIMUM_BINDINGS = 4
MAPPING_ACCOUNTING_BYTES = 128
ALLOWED_FLAGS = 0
RESOURCE_DOMAIN = b"glacier-media-runtime-lease-resource-v1\x00"
BINDING_DOMAIN = b"glacier-media-runtime-lease-bindings-v1\x00"
RECEIPT_DOMAIN = b"glacier-media-runtime-lease-receipt-v1\x00"
RESOURCE_RECEIPT_DOMAIN = 0x7265636569707431
LEASE_TREE_DOMAIN = 0x6C65617365747231
LEASE_TREE_STATE_DOMAIN = 0x6C65617365737431
LEASE_NODE_DOMAIN = 0x6C656173656E6431
SCOPE_KEY_BASE = 0x6D726C7300000000
ALLOCATION_KEY_BASE = 0x6D726C6100000000
BINDING_KEY_BASE = 0x6D726C6200000000
DECODED_SOURCE = 1
MAPPINGS = 2
SCRATCH = 3
OUTPUT = 4
SCOPE = 0
ALLOCATION = 1
LIVE = 1
U64_MAX = (1 << 64) - 1
U32_MAX = (1 << 32) - 1
ZERO_DIGEST = bytes(32)
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
DIGEST_FIELDS = (
    "fixture_sha256",
    "transform_plan_sha256",
    "transform_receipt_sha256",
    "resource_claim_sha256",
    "timeline_event_sha256",
    "publication_commit_sha256",
    "output_sha256",
    "mapping_chain_sha256",
    "binding_manifest_sha256",
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= U64_MAX:
        raise MediaRuntimeLeaseError("u64 out of range")
    return struct.pack("<Q", value)


def _read(encoded: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", encoded, offset)[0]


def _digest(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32 or value == ZERO_DIGEST:
        raise MediaRuntimeLeaseError("invalid digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _mix64(value: int) -> int:
    value &= U64_MAX
    value ^= value >> 30
    value = (value * 0xBF58476D1CE4E5B9) & U64_MAX
    value ^= value >> 27
    value = (value * 0x94D049BB133111EB) & U64_MAX
    value ^= value >> 31
    return value


def _checked_add(left: int, right: int) -> int:
    result = left + right
    if result > U64_MAX:
        raise MediaRuntimeLeaseError("u64 addition overflow")
    return result


def _checked_mul(left: int, right: int) -> int:
    result = left * right
    if result > U64_MAX:
        raise MediaRuntimeLeaseError("u64 multiplication overflow")
    return result


def _zero_claim() -> Record:
    return {field: 0 for field in CLAIM_FIELDS}


def _claim(value: Record, *, allow_zero: bool = False) -> Record:
    try:
        claim = {name: value[name] for name in CLAIM_FIELDS}
    except (KeyError, TypeError):
        raise MediaRuntimeLeaseError("invalid resource claim") from None
    for field in CLAIM_FIELDS:
        _u64(claim[field])
    if not allow_zero and not any(claim.values()):
        raise MediaRuntimeLeaseError("empty resource claim")
    return claim


def _claim_bytes(value: Record) -> bytes:
    claim = _claim(value, allow_zero=True)
    return b"".join(_u64(claim[field]) for field in CLAIM_FIELDS)


def _add_claims(left: Record, right: Record) -> Record:
    return {
        field: _checked_add(left[field], right[field]) for field in CLAIM_FIELDS
    }


def parent_claim(encoded_fixture_bytes: int) -> Record:
    _u64(encoded_fixture_bytes)
    return _claim(
        {
            **_zero_claim(),
            "capsule_bytes": fixture_api.PLAN_BYTES + transform.PLAN_BYTES,
            "io_bytes": encoded_fixture_bytes,
            "queue_slots": 1,
        }
    )


def dynamic_claim(plan_value: Record) -> Record:
    plan = transform.decode_plan(transform.encode_plan(plan_value))
    return _claim(
        {
            **_zero_claim(),
            "activation_bytes": plan["source_bytes"],
            "output_journal_bytes": plan["output_bytes"],
            "staging_bytes": _checked_add(
                _checked_mul(plan["logical_units"], MAPPING_ACCOUNTING_BYTES),
                plan["scratch_bytes"],
            ),
        }
    )


def total_claim(encoded_fixture_bytes: int, plan_value: Record) -> Record:
    return _add_claims(
        parent_claim(encoded_fixture_bytes),
        dynamic_claim(plan_value),
    )


def roles_for_plan(plan_value: Record) -> tuple[int, ...]:
    plan = transform.decode_plan(transform.encode_plan(plan_value))
    roles = [DECODED_SOURCE, MAPPINGS]
    if plan["scratch_bytes"]:
        roles.append(SCRATCH)
    roles.append(OUTPUT)
    return tuple(roles)


def claim_for_role(plan_value: Record, role: int) -> Record:
    plan = transform.decode_plan(transform.encode_plan(plan_value))
    claim = _zero_claim()
    if role == DECODED_SOURCE:
        claim["activation_bytes"] = plan["source_bytes"]
    elif role == MAPPINGS:
        claim["staging_bytes"] = _checked_mul(
            plan["logical_units"], MAPPING_ACCOUNTING_BYTES
        )
    elif role == SCRATCH and plan["scratch_bytes"]:
        claim["staging_bytes"] = plan["scratch_bytes"]
    elif role == OUTPUT:
        claim["output_journal_bytes"] = plan["output_bytes"]
    else:
        raise MediaRuntimeLeaseError("invalid lease role")
    return _claim(claim)


def resource_receipt(
    bank_epoch: int,
    owner_key: int,
    claim_value: Record,
    slot_index: int = 0,
    generation: int = 1,
) -> Record:
    claim = _claim(claim_value)
    for value in (bank_epoch, slot_index, generation, owner_key):
        _u64(value)
    if bank_epoch == 0 or slot_index > U32_MAX or generation == 0 or owner_key == 0:
        raise MediaRuntimeLeaseError("invalid resource identity")
    integrity = _mix64(RESOURCE_RECEIPT_DOMAIN ^ bank_epoch)
    integrity = _mix64(integrity ^ slot_index)
    integrity = _mix64(integrity ^ generation)
    integrity = _mix64(integrity ^ owner_key)
    for field in CLAIM_FIELDS:
        integrity = _mix64(integrity ^ claim[field])
    return {
        "bank_epoch": bank_epoch,
        "slot_index": slot_index,
        "generation": generation,
        "owner_key": owner_key,
        "claim": claim,
        "integrity": integrity,
    }


def _resource_receipt(value: Record) -> Record:
    try:
        expected = resource_receipt(
            value["bank_epoch"],
            value["owner_key"],
            value["claim"],
            value["slot_index"],
            value["generation"],
        )
        integrity = value["integrity"]
    except (KeyError, TypeError):
        raise MediaRuntimeLeaseError("invalid resource receipt") from None
    _u64(integrity)
    if expected["integrity"] != integrity:
        raise MediaRuntimeLeaseError("invalid resource receipt integrity")
    return expected


def _node_integrity(
    parent: Record,
    tree_key: int,
    identity_generation: int,
    node_index: int,
    generation: int,
    parent_index: int,
    parent_generation: int,
    node_key: int,
    tenant_key: int,
    binding_key: int,
    kind: int,
    ceiling: Record,
    claim_value: Record,
) -> int:
    result = _mix64(LEASE_NODE_DOMAIN ^ parent["integrity"])
    for value in (
        tree_key,
        identity_generation,
        node_index,
        generation,
        parent_index,
        parent_generation,
        node_key,
        tenant_key,
        binding_key,
        kind,
    ):
        result = _mix64(result ^ value)
    for field in CLAIM_FIELDS:
        result = _mix64(result ^ ceiling[field])
    for field in CLAIM_FIELDS:
        result = _mix64(result ^ claim_value[field])
    return result


def _node(
    parent: Record,
    tree_key: int,
    identity_generation: int,
    node_index: int,
    generation: int,
    parent_index: int,
    parent_generation: int,
    node_key: int,
    tenant_key: int,
    binding_key: int,
    kind: int,
    ceiling: Record,
    claim_value: Record,
    subtree_claim: Record,
) -> Record:
    claim = _claim(claim_value, allow_zero=True)
    ceiling = _claim(ceiling)
    subtree = _claim(subtree_claim, allow_zero=True)
    return {
        "node_index": node_index,
        "generation": generation,
        "parent_index": parent_index,
        "parent_generation": parent_generation,
        "node_key": node_key,
        "tenant_key": tenant_key,
        "binding_key": binding_key,
        "kind": kind,
        "state": LIVE,
        "ceiling": ceiling,
        "claim": claim,
        "subtree_claim": subtree,
        "pending_generation": 0,
        "pin_count": 0,
        "published_references": 0,
        "integrity": _node_integrity(
            parent,
            tree_key,
            identity_generation,
            node_index,
            generation,
            parent_index,
            parent_generation,
            node_key,
            tenant_key,
            binding_key,
            kind,
            ceiling,
            claim,
        ),
    }


def _node_evidence(node: Record) -> Record:
    return {
        field: node[field]
        for field in (
            "node_index",
            "generation",
            "parent_index",
            "parent_generation",
            "node_key",
            "tenant_key",
            "binding_key",
            "integrity",
        )
    }


def _tree_state_digest(
    tree_key: int,
    identity_generation: int,
    structural_revision: int,
    current: Record,
    nodes: list[Record],
) -> int:
    result = _mix64(LEASE_TREE_STATE_DOMAIN ^ tree_key)
    for value in (
        identity_generation,
        structural_revision,
        len(nodes),
        0,
        0,
        0,
        0,
        0,
        U32_MAX,
        0,
    ):
        result = _mix64(result ^ value)
    for field in CLAIM_FIELDS:
        result = _mix64(result ^ current[field])
        result = _mix64(result)
    result = _mix64(result)
    for index, node in enumerate(nodes):
        for value in (
            index,
            node["integrity"],
            node["state"],
            node["pending_generation"],
            node["pin_count"],
            node["published_references"],
        ):
            result = _mix64(result ^ value)
        for field in CLAIM_FIELDS:
            result = _mix64(result ^ node["subtree_claim"][field])
    return result


def _tree_integrity(parent: Record, tree: Record) -> int:
    result = _mix64(LEASE_TREE_DOMAIN ^ parent["integrity"])
    for field in (
        "tree_key",
        "authority_key",
        "identity_generation",
        "generation",
        "structural_revision",
    ):
        result = _mix64(result ^ tree[field])
    for field in CLAIM_FIELDS:
        result = _mix64(result ^ tree["ceiling"][field])
    for field in CLAIM_FIELDS:
        result = _mix64(result ^ tree["current"][field])
    result = _mix64(result ^ tree["active_nodes"])
    result = _mix64(result ^ tree["state_digest"])
    return result


def isolated_tree_evidence(
    encoded_fixture_bytes: int,
    plan_value: Record,
    bank_epoch: int,
    owner_key: int,
    tree_key: int,
    authority_key: int,
    tenant_key: int,
) -> tuple[Record, list[Record]]:
    plan = transform.decode_plan(transform.encode_plan(plan_value))
    roles = roles_for_plan(plan)
    parent = resource_receipt(
        bank_epoch,
        owner_key,
        parent_claim(encoded_fixture_bytes),
    )
    nodes: list[Record] = []
    bindings: list[Record] = []
    identity_generation = 1
    for index, role in enumerate(roles):
        role_claim = claim_for_role(plan, role)
        scope = _node(
            parent,
            tree_key,
            identity_generation,
            index,
            3 + 2 * index,
            U32_MAX,
            identity_generation,
            SCOPE_KEY_BASE | role,
            tenant_key,
            0,
            SCOPE,
            role_claim,
            _zero_claim(),
            role_claim,
        )
        nodes.append(scope)
    allocation_generation_start = 4 + 2 * len(roles)
    for index, role in enumerate(roles):
        role_claim = claim_for_role(plan, role)
        allocation = _node(
            parent,
            tree_key,
            identity_generation,
            len(roles) + index,
            allocation_generation_start + index,
            index,
            nodes[index]["generation"],
            ALLOCATION_KEY_BASE | role,
            tenant_key,
            BINDING_KEY_BASE | role,
            ALLOCATION,
            role_claim,
            role_claim,
            role_claim,
        )
        nodes.append(allocation)
        bindings.append(
            {
                "role": role,
                "scope": _node_evidence(nodes[index]),
                "allocation": _node_evidence(allocation),
            }
        )
    dynamic = dynamic_claim(plan)
    tree = {
        "parent": parent,
        "tree_key": tree_key,
        "authority_key": authority_key,
        "identity_generation": identity_generation,
        "generation": 5 + 3 * len(roles),
        "structural_revision": 3 + len(roles),
        "ceiling": dynamic,
        "current": dynamic,
        "active_nodes": len(nodes),
        "state_digest": 0,
        "integrity": 0,
    }
    tree["state_digest"] = _tree_state_digest(
        tree_key,
        identity_generation,
        tree["structural_revision"],
        dynamic,
        nodes,
    )
    tree["integrity"] = _tree_integrity(parent, tree)
    return tree, bindings


def _node_evidence_bytes(node: Record) -> bytes:
    return b"".join(
        _u64(node[field])
        for field in (
            "node_index",
            "generation",
            "parent_index",
            "parent_generation",
            "node_key",
            "tenant_key",
            "binding_key",
            "integrity",
        )
    )


def _binding_bytes(binding: Record) -> bytes:
    return b"".join(
        (
            _u64(binding["role"]),
            _node_evidence_bytes(binding["scope"]),
            _node_evidence_bytes(binding["allocation"]),
        )
    )


def binding_manifest_root(
    tree: Record,
    bindings: list[Record],
    tenant_key: int,
) -> bytes:
    return _hash(
        BINDING_DOMAIN,
        _u64(RECEIPT_ABI),
        _u64(tree["parent"]["integrity"]),
        _u64(tree["tree_key"]),
        _u64(tree["identity_generation"]),
        _u64(tenant_key),
        _u64(len(bindings)),
        *(_binding_bytes(binding) for binding in bindings),
    )


def resource_commitment(
    request_epoch: int,
    total: Record,
    tree: Record,
    bindings: list[Record],
    tenant_key: int,
    fixture_sha256: bytes,
    transform_plan_sha256: bytes,
) -> bytes:
    parent = _resource_receipt(tree["parent"])
    binding_root = binding_manifest_root(tree, bindings, tenant_key)
    return _hash(
        RESOURCE_DOMAIN,
        _u64(RUNTIME_ABI),
        _u64(request_epoch),
        _u64(parent["bank_epoch"]),
        _u64(parent["slot_index"]),
        _u64(parent["generation"]),
        _u64(parent["owner_key"]),
        _claim_bytes(parent["claim"]),
        _u64(parent["integrity"]),
        _claim_bytes(total),
        *(
            _u64(tree[field])
            for field in (
                "tree_key",
                "authority_key",
                "identity_generation",
                "generation",
                "structural_revision",
            )
        ),
        _claim_bytes(tree["ceiling"]),
        _claim_bytes(tree["current"]),
        _u64(tree["active_nodes"]),
        _u64(tree["state_digest"]),
        _u64(tree["integrity"]),
        binding_root,
        _u64(tenant_key),
        _digest(fixture_sha256),
        _digest(transform_plan_sha256),
    )


def _receipt_body(receipt: Record) -> bytes:
    output = bytearray(RECEIPT_BODY_BYTES)
    output[:112] = b"".join(
        (
            RECEIPT_MAGIC,
            _u64(RECEIPT_ABI),
            _u64(RECEIPT_BYTES),
            _u64(ALLOWED_FLAGS),
            *(
                _u64(receipt[field])
                for field in (
                    "operation",
                    "kind",
                    "request_epoch",
                    "resource_sequence",
                    "media_sequence",
                    "logical_units",
                    "output_bytes",
                    "mapping_count",
                    "binding_count",
                    "provisional_binding_count",
                )
            ),
        )
    )
    output[112:192] = _claim_bytes(receipt["total_claim"])
    tree = receipt["tree"]
    parent = tree["parent"]
    output[192:272] = _claim_bytes(parent["claim"])
    output[272:376] = b"".join(
        (
            _u64(parent["bank_epoch"]),
            _u64(parent["slot_index"]),
            _u64(parent["generation"]),
            _u64(parent["owner_key"]),
            _u64(parent["integrity"]),
            *(
                _u64(tree[field])
                for field in (
                    "tree_key",
                    "authority_key",
                    "identity_generation",
                    "generation",
                    "structural_revision",
                    "active_nodes",
                    "state_digest",
                    "integrity",
                )
            ),
        )
    )
    output[376:456] = _claim_bytes(tree["ceiling"])
    output[456:536] = _claim_bytes(tree["current"])
    for index, binding in enumerate(receipt["bindings"]):
        start = 536 + index * BINDING_RECORD_BYTES
        output[start : start + BINDING_RECORD_BYTES] = _binding_bytes(binding)
    for index, field in enumerate(DIGEST_FIELDS):
        start = 1080 + index * 32
        output[start : start + 32] = _digest(receipt[field])
    output[1368:1376] = _u64(receipt["tenant_key"])
    return bytes(output)


def receipt_root(receipt: Record) -> bytes:
    return _hash(RECEIPT_DOMAIN, _receipt_body(receipt))


def _zero_binding() -> Record:
    zero_node = {
        field: 0
        for field in (
            "node_index",
            "generation",
            "parent_index",
            "parent_generation",
            "node_key",
            "tenant_key",
            "binding_key",
            "integrity",
        )
    }
    return {"role": 0, "scope": dict(zero_node), "allocation": dict(zero_node)}


def _receipt(value: Record) -> Record:
    try:
        tree_value = value["tree"]
        parent = _resource_receipt(tree_value["parent"])
        tree = {
            "parent": parent,
            "tree_key": tree_value["tree_key"],
            "authority_key": tree_value["authority_key"],
            "identity_generation": tree_value["identity_generation"],
            "generation": tree_value["generation"],
            "structural_revision": tree_value["structural_revision"],
            "ceiling": _claim(tree_value["ceiling"]),
            "current": _claim(tree_value["current"]),
            "active_nodes": tree_value["active_nodes"],
            "state_digest": tree_value["state_digest"],
            "integrity": tree_value["integrity"],
        }
        receipt = {
            field: value[field]
            for field in (
                "operation",
                "kind",
                "request_epoch",
                "resource_sequence",
                "media_sequence",
                "logical_units",
                "output_bytes",
                "mapping_count",
                "binding_count",
                "provisional_binding_count",
                "tenant_key",
            )
        }
        receipt["total_claim"] = _claim(value["total_claim"])
        receipt["tree"] = tree
        receipt["bindings"] = [
            {
                "role": binding["role"],
                "scope": dict(binding["scope"]),
                "allocation": dict(binding["allocation"]),
            }
            for binding in value["bindings"]
        ]
        for field in DIGEST_FIELDS:
            receipt[field] = _digest(value[field])
        receipt["receipt_sha256"] = _digest(value["receipt_sha256"])
    except (KeyError, TypeError):
        raise MediaRuntimeLeaseError("invalid lease runtime receipt") from None
    for field in (
        "operation",
        "kind",
        "request_epoch",
        "resource_sequence",
        "media_sequence",
        "logical_units",
        "output_bytes",
        "mapping_count",
        "binding_count",
        "provisional_binding_count",
        "tenant_key",
        "tree_key",
        "authority_key",
        "identity_generation",
        "generation",
        "structural_revision",
        "active_nodes",
        "state_digest",
        "integrity",
    ):
        _u64(tree[field] if field in tree else receipt[field])
    for binding in receipt["bindings"]:
        _u64(binding["role"])
        if binding["role"] not in (0, DECODED_SOURCE, MAPPINGS, SCRATCH, OUTPUT):
            raise MediaRuntimeLeaseError("invalid lease role")
        for node in (binding["scope"], binding["allocation"]):
            for value in node.values():
                _u64(value)
            if node["node_index"] > U32_MAX or node["parent_index"] > U32_MAX:
                raise MediaRuntimeLeaseError("node index out of range")
    if (
        receipt["operation"]
        not in (
            transform.IMAGE_CROP_NEAREST_TILE,
            transform.AUDIO_MIX_DECIMATE,
            transform.VIDEO_KEYFRAME_SELECT,
        )
        or receipt["kind"] not in (media.IMAGE, media.AUDIO, media.VIDEO)
        or receipt["request_epoch"] == 0
        or receipt["resource_sequence"] != 0
        or receipt["media_sequence"] == 0
        or receipt["logical_units"] == 0
        or receipt["output_bytes"] == 0
        or receipt["mapping_count"] != receipt["logical_units"]
        or not 0 < receipt["binding_count"] <= MAXIMUM_BINDINGS
        or receipt["provisional_binding_count"] + 1 != receipt["binding_count"]
        or len(receipt["bindings"]) != MAXIMUM_BINDINGS
        or receipt["tenant_key"] == 0
        or tree["active_nodes"] > U32_MAX
        or tree["integrity"] != _tree_integrity(parent, tree)
        or receipt["binding_manifest_sha256"]
        != binding_manifest_root(
            tree,
            receipt["bindings"][: receipt["binding_count"]],
            receipt["tenant_key"],
        )
        or receipt["receipt_sha256"] != receipt_root(receipt)
        or any(
            binding != _zero_binding()
            for binding in receipt["bindings"][receipt["binding_count"] :]
        )
    ):
        raise MediaRuntimeLeaseError("contradictory lease runtime receipt")
    return receipt


def encode_receipt(value: Record) -> bytes:
    receipt = _receipt(value)
    return _receipt_body(receipt) + receipt["receipt_sha256"]


def _read_node(encoded: bytes, offset: int) -> Record:
    fields = (
        "node_index",
        "generation",
        "parent_index",
        "parent_generation",
        "node_key",
        "tenant_key",
        "binding_key",
        "integrity",
    )
    node = {field: _read(encoded, offset + index * 8) for index, field in enumerate(fields)}
    if node["node_index"] > U32_MAX or node["parent_index"] > U32_MAX:
        raise MediaRuntimeLeaseError("node index out of range")
    return node


def decode_receipt(encoded: bytes) -> Record:
    if (
        not isinstance(encoded, bytes)
        or len(encoded) != RECEIPT_BYTES
        or encoded[:8] != RECEIPT_MAGIC
        or _read(encoded, 8) != RECEIPT_ABI
        or _read(encoded, 16) != RECEIPT_BYTES
        or _read(encoded, 24) != ALLOWED_FLAGS
        or any(encoded[1376:1504])
        or encoded[1504:] != _hash(RECEIPT_DOMAIN, encoded[:1504])
    ):
        raise MediaRuntimeLeaseError("invalid lease runtime receipt wire")
    bindings = []
    for index in range(MAXIMUM_BINDINGS):
        start = 536 + index * BINDING_RECORD_BYTES
        bindings.append(
            {
                "role": _read(encoded, start),
                "scope": _read_node(encoded, start + 8),
                "allocation": _read_node(encoded, start + 72),
            }
        )
    parent = {
        "bank_epoch": _read(encoded, 272),
        "slot_index": _read(encoded, 280),
        "generation": _read(encoded, 288),
        "owner_key": _read(encoded, 296),
        "claim": {
            field: _read(encoded, 192 + index * 8)
            for index, field in enumerate(CLAIM_FIELDS)
        },
        "integrity": _read(encoded, 304),
    }
    tree = {
        "parent": parent,
        "tree_key": _read(encoded, 312),
        "authority_key": _read(encoded, 320),
        "identity_generation": _read(encoded, 328),
        "generation": _read(encoded, 336),
        "structural_revision": _read(encoded, 344),
        "active_nodes": _read(encoded, 352),
        "state_digest": _read(encoded, 360),
        "integrity": _read(encoded, 368),
        "ceiling": {
            field: _read(encoded, 376 + index * 8)
            for index, field in enumerate(CLAIM_FIELDS)
        },
        "current": {
            field: _read(encoded, 456 + index * 8)
            for index, field in enumerate(CLAIM_FIELDS)
        },
    }
    receipt = {
        "operation": _read(encoded, 32),
        "kind": _read(encoded, 40),
        "request_epoch": _read(encoded, 48),
        "resource_sequence": _read(encoded, 56),
        "media_sequence": _read(encoded, 64),
        "logical_units": _read(encoded, 72),
        "output_bytes": _read(encoded, 80),
        "mapping_count": _read(encoded, 88),
        "binding_count": _read(encoded, 96),
        "provisional_binding_count": _read(encoded, 104),
        "total_claim": {
            field: _read(encoded, 112 + index * 8)
            for index, field in enumerate(CLAIM_FIELDS)
        },
        "tree": tree,
        "bindings": bindings,
        **{
            field: encoded[1080 + index * 32 : 1112 + index * 32]
            for index, field in enumerate(DIGEST_FIELDS)
        },
        "tenant_key": _read(encoded, 1368),
        "receipt_sha256": encoded[1504:1536],
    }
    return _receipt(receipt)


def build_execution_receipt(
    state_before: Record,
    encoded_fixture: bytes,
    encoded_transform_plan: bytes,
    transform_receipt: Record,
    output: bytes,
    mappings: list[Record],
    bank_epoch: int,
    owner_key: int,
    tree_key: int,
    authority_key: int,
    tenant_key: int,
) -> tuple[Record, Record]:
    transform.verify_receipt(
        encoded_fixture,
        encoded_transform_plan,
        transform_receipt,
        output,
        mappings,
    )
    parsed_fixture = fixture_api.parse_fixture(encoded_fixture)
    plan = transform.decode_plan(encoded_transform_plan)
    plan_sha256 = transform.plan_sha256(encoded_transform_plan)
    tree, active_bindings = isolated_tree_evidence(
        len(encoded_fixture),
        plan,
        bank_epoch,
        owner_key,
        tree_key,
        authority_key,
        tenant_key,
    )
    total = total_claim(len(encoded_fixture), plan)
    resource_sha256 = resource_commitment(
        state_before["request_epoch"],
        total,
        tree,
        active_bindings,
        tenant_key,
        parsed_fixture["fixture_sha256"],
        plan_sha256,
    )
    event = flat_runtime.timeline_event_for_plan(
        plan,
        parsed_fixture,
        state_before,
        plan_sha256,
    )
    publication = media.prepare_publication(
        state_before,
        event,
        transform_receipt["output_sha256"],
        resource_sha256,
    )
    bindings = active_bindings + [
        _zero_binding() for _ in range(MAXIMUM_BINDINGS - len(active_bindings))
    ]
    receipt = {
        "operation": plan["operation"],
        "kind": plan["kind"],
        "request_epoch": state_before["request_epoch"],
        "resource_sequence": 0,
        "media_sequence": publication["sequence"],
        "logical_units": plan["logical_units"],
        "output_bytes": plan["output_bytes"],
        "mapping_count": plan["logical_units"],
        "binding_count": len(active_bindings),
        "provisional_binding_count": len(active_bindings) - 1,
        "total_claim": total,
        "tree": tree,
        "bindings": bindings,
        "fixture_sha256": parsed_fixture["fixture_sha256"],
        "transform_plan_sha256": plan_sha256,
        "transform_receipt_sha256": transform_receipt["receipt_sha256"],
        "resource_claim_sha256": resource_sha256,
        "timeline_event_sha256": media.timeline_event_root(event),
        "publication_commit_sha256": publication["commit_sha256"],
        "output_sha256": transform_receipt["output_sha256"],
        "mapping_chain_sha256": transform_receipt["mapping_chain_sha256"],
        "binding_manifest_sha256": binding_manifest_root(
            tree, active_bindings, tenant_key
        ),
        "tenant_key": tenant_key,
        "receipt_sha256": ZERO_DIGEST,
    }
    receipt["receipt_sha256"] = receipt_root(receipt)
    return _receipt(receipt), media.commit_publication(state_before, publication)


def verify_execution_receipt(
    state_before: Record,
    encoded_fixture: bytes,
    encoded_transform_plan: bytes,
    transform_receipt: Record,
    output: bytes,
    mappings: list[Record],
    expected_owner_key: int,
    expected_tree_key: int,
    expected_authority_key: int,
    expected_tenant_key: int,
    receipt_value: Record,
) -> None:
    receipt = _receipt(receipt_value)
    transform.verify_receipt(
        encoded_fixture,
        encoded_transform_plan,
        transform_receipt,
        output,
        mappings,
    )
    parsed_fixture = fixture_api.parse_fixture(encoded_fixture)
    plan = transform.decode_plan(encoded_transform_plan)
    plan_sha256 = transform.plan_sha256(encoded_transform_plan)
    roles = roles_for_plan(plan)
    tree = receipt["tree"]
    if (
        receipt["total_claim"] != total_claim(len(encoded_fixture), plan)
        or tree["parent"]["claim"] != parent_claim(len(encoded_fixture))
        or tree["ceiling"] != dynamic_claim(plan)
        or tree["current"] != dynamic_claim(plan)
        or tree["parent"]["owner_key"] != expected_owner_key
        or tree["tree_key"] != expected_tree_key
        or tree["authority_key"] != expected_authority_key
        or receipt["tenant_key"] != expected_tenant_key
        or receipt["request_epoch"] != state_before["request_epoch"]
        or receipt["operation"] != plan["operation"]
        or receipt["kind"] != plan["kind"]
        or receipt["logical_units"] != plan["logical_units"]
        or receipt["output_bytes"] != plan["output_bytes"]
        or receipt["binding_count"] != len(roles)
        or receipt["provisional_binding_count"] != len(roles) - 1
        or tree["active_nodes"] != len(roles) * 2
        or receipt["fixture_sha256"] != parsed_fixture["fixture_sha256"]
        or receipt["transform_plan_sha256"] != plan_sha256
        or receipt["transform_receipt_sha256"]
        != transform_receipt["receipt_sha256"]
        or receipt["output_sha256"] != transform_receipt["output_sha256"]
        or receipt["mapping_chain_sha256"]
        != transform_receipt["mapping_chain_sha256"]
    ):
        raise MediaRuntimeLeaseError("lease runtime receipt mismatch")
    seen_node_indices: set[int] = set()
    for index, role in enumerate(roles):
        binding = receipt["bindings"][index]
        role_claim = claim_for_role(plan, role)
        scope = binding["scope"]
        allocation = binding["allocation"]
        expected_scope_integrity = _node_integrity(
            tree["parent"],
            tree["tree_key"],
            tree["identity_generation"],
            scope["node_index"],
            scope["generation"],
            scope["parent_index"],
            scope["parent_generation"],
            scope["node_key"],
            scope["tenant_key"],
            scope["binding_key"],
            SCOPE,
            role_claim,
            _zero_claim(),
        )
        expected_allocation_integrity = _node_integrity(
            tree["parent"],
            tree["tree_key"],
            tree["identity_generation"],
            allocation["node_index"],
            allocation["generation"],
            allocation["parent_index"],
            allocation["parent_generation"],
            allocation["node_key"],
            allocation["tenant_key"],
            allocation["binding_key"],
            ALLOCATION,
            role_claim,
            role_claim,
        )
        if (
            binding["role"] != role
            or scope["node_index"] == allocation["node_index"]
            or scope["node_index"] in seen_node_indices
            or allocation["node_index"] in seen_node_indices
            or scope["parent_index"] != U32_MAX
            or scope["parent_generation"] != tree["identity_generation"]
            or scope["node_key"] != SCOPE_KEY_BASE | role
            or scope["tenant_key"] != expected_tenant_key
            or scope["binding_key"] != 0
            or allocation["parent_index"] != scope["node_index"]
            or allocation["parent_generation"] != scope["generation"]
            or allocation["node_key"] != ALLOCATION_KEY_BASE | role
            or allocation["tenant_key"] != expected_tenant_key
            or allocation["binding_key"] != BINDING_KEY_BASE | role
            or scope["integrity"] != expected_scope_integrity
            or allocation["integrity"] != expected_allocation_integrity
        ):
            raise MediaRuntimeLeaseError("invalid lease binding")
        seen_node_indices.add(scope["node_index"])
        seen_node_indices.add(allocation["node_index"])
    active_bindings = receipt["bindings"][: receipt["binding_count"]]
    resource_sha256 = resource_commitment(
        receipt["request_epoch"],
        receipt["total_claim"],
        tree,
        active_bindings,
        receipt["tenant_key"],
        receipt["fixture_sha256"],
        receipt["transform_plan_sha256"],
    )
    event = flat_runtime.timeline_event_for_plan(
        plan, parsed_fixture, state_before, plan_sha256
    )
    publication = media.prepare_publication(
        state_before,
        event,
        transform_receipt["output_sha256"],
        resource_sha256,
    )
    if (
        receipt["resource_claim_sha256"] != resource_sha256
        or receipt["timeline_event_sha256"] != media.timeline_event_root(event)
        or receipt["publication_commit_sha256"] != publication["commit_sha256"]
    ):
        raise MediaRuntimeLeaseError("invalid lease publication evidence")
