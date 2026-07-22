"""Independent fixed-point codec and verifier for provider cost wire v1."""

from __future__ import annotations

import copy
import hashlib
import struct
from typing import Any

from bench import provider_settlement_wire as settlement_wire


class WireError(ValueError):
    """The price, quote, usage settlement or canonical envelope is invalid."""


Digest = bytes
Record = dict[str, Any]

PRICE_TABLE_ABI = 0x4750435000000001
QUOTE_ABI = 0x4750435100000001
COST_SETTLEMENT_ABI = 0x4750435300000001
WIRE_ABI = 0x4750435700000001
MAGIC = b"GPCWIRE1"
FLAG_REQUIRE_KNOWN_QUOTE = 1
RATE_DENOMINATOR = 1_000_000
U64_MAX = (1 << 64) - 1

AGGREGATE_CEILING = 0
PER_COMPONENT_CEILING = 1
REASONING_WITHIN_OUTPUT = 0
REASONING_SEPARATE_UNBOUNDED = 1
RETRY_INCLUDED = 0
RETRY_SEPARATE_UNBOUNDED = 1

HEADER_BYTES = 32
KNOWN_U64_WIRE_BYTES = 9
RATES_WIRE_BYTES = 45
BREAKDOWN_WIRE_BYTES = 108
PRICE_TABLE_WIRE_BYTES = 187
QUOTE_WIRE_BYTES = 220
COST_SETTLEMENT_WIRE_BYTES = 270
ENCODED_BYTES = 1461

PRICE_DOMAIN = b"glacier-provider-price-table-v1\x00"
QUOTE_DOMAIN = b"glacier-provider-cost-quote-v1\x00"
SETTLEMENT_DOMAIN = b"glacier-provider-cost-settlement-v1\x00"
ENVELOPE_DOMAIN = b"glacier-provider-cost-wire-v1\x00"

RATE_NAMES = (
    "uncached_input",
    "cached_input",
    "visible_output",
    "reasoning",
    "retry",
)
UNIT_NAMES = tuple(f"{name}_units" for name in RATE_NAMES)
AMOUNT_NAMES = tuple(f"{name}_nanos" for name in RATE_NAMES)
BREAKDOWN_NAMES = (
    *UNIT_NAMES,
    *AMOUNT_NAMES,
    "rounding_adjustment_nanos",
    "total_nanos",
)


def _u8(value: int) -> bytes:
    if not 0 <= value <= 0xFF:
        raise WireError("u8 out of range")
    return struct.pack("<B", value)


def _u32(value: int) -> bytes:
    if not 0 <= value <= 0xFFFFFFFF:
        raise WireError("u32 out of range")
    return struct.pack("<I", value)


def _u64(value: int) -> bytes:
    if not 0 <= value <= U64_MAX:
        raise WireError("u64 out of range")
    return struct.pack("<Q", value)


def _hash(domain: bytes, *parts: bytes) -> Digest:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _digest(value: bytes, *, allow_zero: bool = False) -> Digest:
    if not isinstance(value, bytes) or len(value) != 32:
        raise WireError("invalid digest")
    if not allow_zero and value == bytes(32):
        raise WireError("zero digest is not allowed")
    return value


def known(value: int) -> Record:
    _u64(value)
    return {"known": True, "value": value}


def unknown() -> Record:
    return {"known": False, "value": 0}


def _known_bytes(value: Record) -> bytes:
    is_known = value.get("known")
    amount = value.get("value")
    if not isinstance(is_known, bool) or not isinstance(amount, int):
        raise WireError("invalid known-u64 value")
    if not is_known and amount != 0:
        raise WireError("unknown value must carry canonical zero")
    return _u8(int(is_known)) + _u64(amount)


def _rates_bytes(rates: Record) -> bytes:
    return b"".join(_known_bytes(rates[name]) for name in RATE_NAMES)


def _breakdown_bytes(value: Record) -> bytes:
    return b"".join(_known_bytes(value[name]) for name in BREAKDOWN_NAMES)


def price_table_sha256(value: Record) -> Digest:
    return _hash(
        PRICE_DOMAIN,
        _u64(value["abi_version"]),
        _u64(value["provider_adapter_abi"]),
        value["provider_namespace_sha256"],
        value["model_sha256"],
        _u64(value["price_epoch"]),
        _u64(value["effective_from_unix_s"]),
        _u64(value["effective_until_unix_s"]),
        value["currency_code"],
        _u8(value["rounding_mode"]),
        _u8(value["reasoning_mode"]),
        _u8(value["retry_mode"]),
        _rates_bytes(value["rates"]),
    )


def make_price_table(
    provider_adapter_abi: int,
    provider_namespace_sha256: Digest,
    model_sha256: Digest,
    price_epoch: int,
    effective_from_unix_s: int,
    effective_until_unix_s: int,
    currency_code: bytes,
    rounding_mode: int,
    reasoning_mode: int,
    retry_mode: int,
    rates: Record,
) -> Record:
    value = {
        "abi_version": PRICE_TABLE_ABI,
        "provider_adapter_abi": provider_adapter_abi,
        "provider_namespace_sha256": provider_namespace_sha256,
        "model_sha256": model_sha256,
        "price_epoch": price_epoch,
        "effective_from_unix_s": effective_from_unix_s,
        "effective_until_unix_s": effective_until_unix_s,
        "currency_code": currency_code,
        "rounding_mode": rounding_mode,
        "reasoning_mode": reasoning_mode,
        "retry_mode": retry_mode,
        "rates": copy.deepcopy(rates),
    }
    value["price_sha256"] = price_table_sha256(value)
    _verify_price(value)
    return value


def _verify_price(value: Record) -> None:
    if value["abi_version"] != PRICE_TABLE_ABI:
        raise WireError("invalid price ABI")
    if value["provider_adapter_abi"] == 0 or value["price_epoch"] == 0:
        raise WireError("zero provider adapter or price epoch")
    _u64(value["provider_adapter_abi"])
    _u64(value["price_epoch"])
    _digest(value["provider_namespace_sha256"])
    _digest(value["model_sha256"])
    start = value["effective_from_unix_s"]
    end = value["effective_until_unix_s"]
    if start == 0 or (end != 0 and end <= start):
        raise WireError("invalid effective price window")
    _u64(start)
    _u64(end)
    currency = value["currency_code"]
    if not isinstance(currency, bytes) or len(currency) != 3:
        raise WireError("currency must be exactly three bytes")
    if any(byte < ord("A") or byte > ord("Z") for byte in currency):
        raise WireError("currency must be uppercase ASCII")
    if value["rounding_mode"] not in (AGGREGATE_CEILING, PER_COMPONENT_CEILING):
        raise WireError("invalid rounding mode")
    if value["reasoning_mode"] not in (
        REASONING_WITHIN_OUTPUT,
        REASONING_SEPARATE_UNBOUNDED,
    ):
        raise WireError("invalid reasoning mode")
    if value["retry_mode"] not in (RETRY_INCLUDED, RETRY_SEPARATE_UNBOUNDED):
        raise WireError("invalid retry mode")
    for name in RATE_NAMES:
        _known_bytes(value["rates"][name])
    retry_rate = value["rates"]["retry"]
    if value["retry_mode"] == RETRY_INCLUDED and (
        not retry_rate["known"] or retry_rate["value"] != 0
    ):
        raise WireError("included retry requires a known-zero retry rate")
    if value["price_sha256"] != price_table_sha256(value):
        raise WireError("price digest mismatch")


def _time_in_price_window(price: Record, timestamp: int) -> bool:
    return timestamp >= price["effective_from_unix_s"] and (
        price["effective_until_unix_s"] == 0
        or timestamp < price["effective_until_unix_s"]
    )


def _quote_units(price: Record, request: Record) -> Record:
    rates = price["rates"]
    units = {name: unknown() for name in UNIT_NAMES}
    if rates["uncached_input"]["known"] and rates["cached_input"]["known"]:
        if rates["cached_input"]["value"] > rates["uncached_input"]["value"]:
            units["uncached_input_units"] = known(0)
            units["cached_input_units"] = known(request["input_token_estimate"])
        else:
            units["uncached_input_units"] = known(request["input_token_estimate"])
            units["cached_input_units"] = known(0)
    else:
        units["uncached_input_units"] = known(request["input_token_estimate"])
        units["cached_input_units"] = unknown()
    if (
        price["reasoning_mode"] == REASONING_WITHIN_OUTPUT
        and rates["visible_output"]["known"]
        and rates["reasoning"]["known"]
    ):
        if rates["reasoning"]["value"] > rates["visible_output"]["value"]:
            units["visible_output_units"] = known(0)
            units["reasoning_units"] = known(request["max_output_tokens"])
        else:
            units["visible_output_units"] = known(request["max_output_tokens"])
            units["reasoning_units"] = known(0)
    else:
        units["visible_output_units"] = known(request["max_output_tokens"])
        units["reasoning_units"] = unknown()
    units["retry_units"] = (
        known(0) if price["retry_mode"] == RETRY_INCLUDED else unknown()
    )
    return units


def _component_numerator(rate: Record, units: Record) -> int | None:
    if (rate["known"] and rate["value"] == 0) or (
        units["known"] and units["value"] == 0
    ):
        return 0
    if not rate["known"] or not units["known"]:
        return None
    return rate["value"] * units["value"]


def _ceil_div(numerator: int, denominator: int) -> int:
    return 0 if numerator == 0 else (numerator - 1) // denominator + 1


def _checked_u64(value: int) -> int:
    _u64(value)
    return value


def _price_breakdown(price: Record, units: Record) -> Record:
    amounts: Record = {}
    numerators: list[int | None] = []
    for index, name in enumerate(RATE_NAMES):
        unit_name = UNIT_NAMES[index]
        amount_name = AMOUNT_NAMES[index]
        numerator = _component_numerator(price["rates"][name], units[unit_name])
        numerators.append(numerator)
        if numerator is None:
            amounts[amount_name] = unknown()
        elif price["rounding_mode"] == PER_COMPONENT_CEILING:
            amounts[amount_name] = known(
                _checked_u64(_ceil_div(numerator, RATE_DENOMINATOR))
            )
        else:
            amounts[amount_name] = known(
                _checked_u64(numerator // RATE_DENOMINATOR)
            )
    if price["rounding_mode"] == PER_COMPONENT_CEILING:
        adjustment = known(0)
        if all(amounts[name]["known"] for name in AMOUNT_NAMES):
            total = known(
                _checked_u64(sum(amounts[name]["value"] for name in AMOUNT_NAMES))
            )
        else:
            total = unknown()
    elif all(value is not None for value in numerators):
        rounded = _checked_u64(
            _ceil_div(sum(value for value in numerators if value is not None), RATE_DENOMINATOR)
        )
        floors = _checked_u64(sum(amounts[name]["value"] for name in AMOUNT_NAMES))
        if rounded < floors:
            raise WireError("aggregate rounding underflow")
        adjustment = known(rounded - floors)
        total = known(rounded)
    else:
        adjustment = unknown()
        total = unknown()
    result = {name: copy.deepcopy(units[name]) for name in UNIT_NAMES}
    result.update(amounts)
    result["rounding_adjustment_nanos"] = adjustment
    result["total_nanos"] = total
    return result


def quote_sha256(value: Record) -> Digest:
    return _hash(
        QUOTE_DOMAIN,
        _u64(value["abi_version"]),
        value["request_sha256"],
        value["price_sha256"],
        _u64(value["quoted_at_unix_s"]),
        _breakdown_bytes(value["breakdown"]),
    )


def make_quote(price: Record, request: Record, quoted_at_unix_s: int) -> Record:
    _verify_price(price)
    settlement_wire._verify_request(request)  # noqa: SLF001
    if request["provider_adapter_abi"] != price["provider_adapter_abi"]:
        raise WireError("quote provider adapter mismatch")
    if request["model_sha256"] != price["model_sha256"]:
        raise WireError("quote model mismatch")
    if not _time_in_price_window(price, quoted_at_unix_s):
        raise WireError("quote outside effective price window")
    value = {
        "abi_version": QUOTE_ABI,
        "request_sha256": request["request_sha256"],
        "price_sha256": price["price_sha256"],
        "quoted_at_unix_s": quoted_at_unix_s,
        "breakdown": _price_breakdown(price, _quote_units(price, request)),
    }
    value["quote_sha256"] = quote_sha256(value)
    _verify_quote(price, request, value)
    return value


def _verify_quote(price: Record, request: Record, value: Record) -> None:
    if value["abi_version"] != QUOTE_ABI:
        raise WireError("invalid quote ABI")
    _verify_price(price)
    settlement_wire._verify_request(request)  # noqa: SLF001
    if request["provider_adapter_abi"] != price["provider_adapter_abi"]:
        raise WireError("quote provider adapter mismatch")
    if request["model_sha256"] != price["model_sha256"]:
        raise WireError("quote model mismatch")
    if value["request_sha256"] != request["request_sha256"]:
        raise WireError("quote request mismatch")
    if value["price_sha256"] != price["price_sha256"]:
        raise WireError("quote price mismatch")
    if not _time_in_price_window(price, value["quoted_at_unix_s"]):
        raise WireError("quote outside effective price window")
    expected = _price_breakdown(price, _quote_units(price, request))
    if value["breakdown"] != expected:
        raise WireError("quote breakdown mismatch")
    if value["quote_sha256"] != quote_sha256(value):
        raise WireError("quote digest mismatch")


def _from_count(value: Record) -> Record:
    return {"known": value["known"], "value": value["value"]}


def _normalize_usage(price: Record, usage: Record) -> Record:
    settlement_wire._verify_usage(usage)  # noqa: SLF001
    cached = _from_count(usage["cached_input_tokens"])
    if usage["input_tokens"]["known"] and cached["known"]:
        if cached["value"] > usage["input_tokens"]["value"]:
            raise WireError("cached input exceeds input")
        uncached = known(usage["input_tokens"]["value"] - cached["value"])
    else:
        uncached = unknown()
    reasoning = _from_count(usage["reasoning_tokens"])
    if price["reasoning_mode"] == REASONING_WITHIN_OUTPUT:
        if usage["output_tokens"]["known"] and reasoning["known"]:
            if reasoning["value"] > usage["output_tokens"]["value"]:
                raise WireError("reasoning exceeds output")
            visible = known(usage["output_tokens"]["value"] - reasoning["value"])
        else:
            visible = unknown()
    else:
        visible = _from_count(usage["output_tokens"])
    retry = (
        known(0)
        if price["retry_mode"] == RETRY_INCLUDED
        else _from_count(usage["retry_tokens"])
    )
    return {
        "uncached_input_units": uncached,
        "cached_input_units": cached,
        "visible_output_units": visible,
        "reasoning_units": reasoning,
        "retry_units": retry,
    }


def _settlement_breakdown(price: Record, receipt: Record) -> Record:
    units = _normalize_usage(price, receipt["usage"])
    if receipt["outcome"] != settlement_wire.RETRYABLE_NO_CHARGE:
        return _price_breakdown(price, units)
    billable = receipt["usage"]["billable_tokens"]
    if not billable["known"] or billable["value"] != 0:
        raise WireError("no-charge retry lacks known-zero billable usage")
    result = {name: copy.deepcopy(units[name]) for name in UNIT_NAMES}
    result.update({name: known(0) for name in AMOUNT_NAMES})
    result["rounding_adjustment_nanos"] = known(0)
    result["total_nanos"] = known(0)
    return result


def _quote_delta(quote: Record, actual: Record) -> tuple[Record, Record]:
    if not quote["known"] or not actual["known"]:
        return unknown(), unknown()
    if actual["value"] > quote["value"]:
        return known(actual["value"] - quote["value"]), known(0)
    return known(0), known(quote["value"] - actual["value"])


def cost_settlement_sha256(value: Record) -> Digest:
    return _hash(
        SETTLEMENT_DOMAIN,
        _u64(value["abi_version"]),
        value["receipt_sha256"],
        value["usage_sha256"],
        value["price_sha256"],
        _u64(value["settled_at_unix_s"]),
        _breakdown_bytes(value["breakdown"]),
        _known_bytes(value["overrun_nanos"]),
        _known_bytes(value["savings_nanos"]),
    )


def make_cost_settlement(
    price: Record,
    quote: Record,
    provider_settlement: Record,
    settled_at_unix_s: int,
) -> Record:
    request = provider_settlement["request"]
    receipt = provider_settlement["receipt"]
    _verify_quote(price, request, quote)
    if settled_at_unix_s < quote["quoted_at_unix_s"]:
        raise WireError("cost settlement predates quote")
    breakdown = _settlement_breakdown(price, receipt)
    overrun, savings = _quote_delta(
        quote["breakdown"]["total_nanos"], breakdown["total_nanos"]
    )
    value = {
        "abi_version": COST_SETTLEMENT_ABI,
        "receipt_sha256": receipt["receipt_sha256"],
        "usage_sha256": receipt["usage"]["usage_sha256"],
        "price_sha256": price["price_sha256"],
        "settled_at_unix_s": settled_at_unix_s,
        "breakdown": breakdown,
        "overrun_nanos": overrun,
        "savings_nanos": savings,
    }
    value["settlement_sha256"] = cost_settlement_sha256(value)
    _verify_cost_settlement(price, quote, provider_settlement, value)
    return value


def _verify_cost_settlement(
    price: Record,
    quote: Record,
    provider_settlement: Record,
    value: Record,
) -> None:
    if value["abi_version"] != COST_SETTLEMENT_ABI:
        raise WireError("invalid cost settlement ABI")
    request = provider_settlement["request"]
    receipt = provider_settlement["receipt"]
    _verify_quote(price, request, quote)
    if value["settled_at_unix_s"] < quote["quoted_at_unix_s"]:
        raise WireError("cost settlement predates quote")
    if value["receipt_sha256"] != receipt["receipt_sha256"]:
        raise WireError("cost settlement receipt mismatch")
    if value["usage_sha256"] != receipt["usage"]["usage_sha256"]:
        raise WireError("cost settlement usage mismatch")
    if value["price_sha256"] != price["price_sha256"]:
        raise WireError("cost settlement price mismatch")
    expected = _settlement_breakdown(price, receipt)
    overrun, savings = _quote_delta(
        quote["breakdown"]["total_nanos"], expected["total_nanos"]
    )
    if value["breakdown"] != expected:
        raise WireError("cost settlement breakdown mismatch")
    if value["overrun_nanos"] != overrun or value["savings_nanos"] != savings:
        raise WireError("cost quote delta mismatch")
    if value["settlement_sha256"] != cost_settlement_sha256(value):
        raise WireError("cost settlement digest mismatch")


def verify_evidence(evidence: Record) -> None:
    if evidence["flags"] != FLAG_REQUIRE_KNOWN_QUOTE:
        raise WireError("cost wire must require a known quote")
    _verify_quote(
        evidence["price"],
        evidence["provider_settlement"]["request"],
        evidence["quote"],
    )
    if not evidence["quote"]["breakdown"]["total_nanos"]["known"]:
        raise WireError("cost admission quote is unknown")
    _verify_cost_settlement(
        evidence["price"],
        evidence["quote"],
        evidence["provider_settlement"],
        evidence["cost_settlement"],
    )


def _price_bytes(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            _u64(value["provider_adapter_abi"]),
            value["provider_namespace_sha256"],
            value["model_sha256"],
            _u64(value["price_epoch"]),
            _u64(value["effective_from_unix_s"]),
            _u64(value["effective_until_unix_s"]),
            value["currency_code"],
            _u8(value["rounding_mode"]),
            _u8(value["reasoning_mode"]),
            _u8(value["retry_mode"]),
            _rates_bytes(value["rates"]),
            value["price_sha256"],
        )
    )


def _quote_bytes(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            value["request_sha256"],
            value["price_sha256"],
            _u64(value["quoted_at_unix_s"]),
            _breakdown_bytes(value["breakdown"]),
            value["quote_sha256"],
        )
    )


def _cost_settlement_bytes(value: Record) -> bytes:
    return b"".join(
        (
            _u64(value["abi_version"]),
            value["receipt_sha256"],
            value["usage_sha256"],
            value["price_sha256"],
            _u64(value["settled_at_unix_s"]),
            _breakdown_bytes(value["breakdown"]),
            _known_bytes(value["overrun_nanos"]),
            _known_bytes(value["savings_nanos"]),
            value["settlement_sha256"],
        )
    )


def encode_evidence(evidence: Record) -> bytes:
    verify_evidence(evidence)
    provider_envelope = evidence["provider_settlement_envelope"]
    if len(provider_envelope) != settlement_wire.ENCODED_BYTES:
        raise WireError("invalid nested provider settlement length")
    if settlement_wire.decode_and_verify(provider_envelope) != evidence[
        "provider_settlement"
    ]:
        raise WireError("nested provider settlement substitution")
    prefix = b"".join(
        (
            MAGIC,
            _u64(WIRE_ABI),
            _u64(ENCODED_BYTES),
            _u32(evidence["flags"]),
            _u32(0),
            _price_bytes(evidence["price"]),
            _quote_bytes(evidence["quote"]),
            provider_envelope,
            _cost_settlement_bytes(evidence["cost_settlement"]),
        )
    )
    if len(prefix) != ENCODED_BYTES - 32:
        raise WireError("internal cost wire length mismatch")
    return prefix + _hash(ENVELOPE_DOMAIN, prefix)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.position = 0

    def take(self, length: int) -> bytes:
        end = self.position + length
        if end > len(self.data):
            raise WireError("truncated cost wire")
        result = self.data[self.position : end]
        self.position = end
        return result

    def u8(self) -> int:
        return self.take(1)[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def digest(self) -> Digest:
        return self.take(32)


def _read_known(reader: _Reader) -> Record:
    flag = reader.u8()
    if flag not in (0, 1):
        raise WireError("noncanonical known-u64 boolean")
    return {"known": bool(flag), "value": reader.u64()}


def _read_rates(reader: _Reader) -> Record:
    return {name: _read_known(reader) for name in RATE_NAMES}


def _read_breakdown(reader: _Reader) -> Record:
    return {name: _read_known(reader) for name in BREAKDOWN_NAMES}


def _read_price(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "provider_adapter_abi": reader.u64(),
        "provider_namespace_sha256": reader.digest(),
        "model_sha256": reader.digest(),
        "price_epoch": reader.u64(),
        "effective_from_unix_s": reader.u64(),
        "effective_until_unix_s": reader.u64(),
        "currency_code": reader.take(3),
        "rounding_mode": reader.u8(),
        "reasoning_mode": reader.u8(),
        "retry_mode": reader.u8(),
        "rates": _read_rates(reader),
        "price_sha256": reader.digest(),
    }


def _read_quote(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "request_sha256": reader.digest(),
        "price_sha256": reader.digest(),
        "quoted_at_unix_s": reader.u64(),
        "breakdown": _read_breakdown(reader),
        "quote_sha256": reader.digest(),
    }


def _read_cost_settlement(reader: _Reader) -> Record:
    return {
        "abi_version": reader.u64(),
        "receipt_sha256": reader.digest(),
        "usage_sha256": reader.digest(),
        "price_sha256": reader.digest(),
        "settled_at_unix_s": reader.u64(),
        "breakdown": _read_breakdown(reader),
        "overrun_nanos": _read_known(reader),
        "savings_nanos": _read_known(reader),
        "settlement_sha256": reader.digest(),
    }


def decode_and_verify(encoded: bytes) -> Record:
    if len(encoded) != ENCODED_BYTES:
        raise WireError("invalid cost wire length")
    reader = _Reader(encoded)
    if reader.take(8) != MAGIC or reader.u64() != WIRE_ABI:
        raise WireError("invalid cost wire magic or ABI")
    if reader.u64() != ENCODED_BYTES:
        raise WireError("invalid declared cost wire length")
    flags = reader.u32()
    if flags != FLAG_REQUIRE_KNOWN_QUOTE or reader.u32() != 0:
        raise WireError("invalid cost wire flags")
    expected_root = _hash(ENVELOPE_DOMAIN, encoded[:-32])
    if encoded[-32:] != expected_root:
        raise WireError("cost envelope digest mismatch")
    price = _read_price(reader)
    quote = _read_quote(reader)
    provider_envelope = reader.take(settlement_wire.ENCODED_BYTES)
    try:
        provider_settlement = settlement_wire.decode_and_verify(provider_envelope)
    except settlement_wire.WireError as exc:
        raise WireError("invalid nested provider settlement") from exc
    cost_settlement = _read_cost_settlement(reader)
    envelope_sha256 = reader.digest()
    if reader.position != len(encoded) or envelope_sha256 != expected_root:
        raise WireError("trailing cost data or envelope root drift")
    evidence = {
        "flags": flags,
        "price": price,
        "quote": quote,
        "provider_settlement": provider_settlement,
        "provider_settlement_envelope": provider_envelope,
        "cost_settlement": cost_settlement,
        "envelope_sha256": envelope_sha256,
    }
    verify_evidence(evidence)
    return evidence


def reseal_for_test(encoded: bytes) -> bytes:
    if len(encoded) != ENCODED_BYTES:
        raise WireError("invalid cost wire length")
    return encoded[:-32] + _hash(ENVELOPE_DOMAIN, encoded[:-32])


def _seed_digest(seed: int) -> Digest:
    return bytes((seed,)) * 32


def build_demo_evidence(outcome: int = settlement_wire.SUCCEEDED) -> Record:
    request: Record = {
        "abi_version": settlement_wire.REQUEST_ABI,
        "provider_adapter_abi": 0x434F535441445054,
        "isolation_key": 0x434F535449534F4C,
        "request_key": 71,
        "request_generation": 3,
        "model_sha256": _seed_digest(0x11),
        "context_sha256": _seed_digest(0x22),
        "tool_schema_sha256": _seed_digest(0x33),
        "policy_sha256": _seed_digest(0x44),
        "sampling_sha256": _seed_digest(0x55),
        "input_token_estimate": 100,
        "max_output_tokens": 50,
        "reuse_policy": 1,
    }
    request["request_sha256"] = settlement_wire.request_sha256(request)
    intent: Record = {
        "abi_version": settlement_wire.INTENT_ABI,
        "gateway_epoch": 0x434F535447570001,
        "owner_slot_index": 2,
        "owner_generation": 9,
        "attempt_generation": 4,
        "request_sha256": request["request_sha256"],
        "dispatch_key_sha256": settlement_wire.dispatch_key_sha256(request),
        "reserved_tokens": 150,
        "previous_event_chain_sha256": _seed_digest(0x66),
    }
    intent["intent_sha256"] = settlement_wire.intent_sha256(intent)
    if outcome == settlement_wire.RETRYABLE_NO_CHARGE:
        usage = settlement_wire.make_usage(None, None, None, None, None, 0)
    elif outcome == settlement_wire.AMBIGUOUS:
        usage = settlement_wire.make_usage(100, None, 40, None, 3, None)
    elif outcome in (settlement_wire.SUCCEEDED, settlement_wire.RESOLVED_SUCCESS):
        usage = settlement_wire.make_usage(100, 20, 40, 8, 0, 80)
    elif outcome in (settlement_wire.FAILED, settlement_wire.RESOLVED_FAILURE):
        usage = settlement_wire.make_usage(100, 0, 40, 0, 0, 60)
    else:
        raise WireError("invalid fixture outcome")
    receipt: Record = {
        "abi_version": settlement_wire.RECEIPT_ABI,
        "outcome": outcome,
        "intent": intent,
        "usage": usage,
        "result_sha256": (
            _seed_digest(0x77)
            if outcome in (settlement_wire.SUCCEEDED, settlement_wire.RESOLVED_SUCCESS)
            else bytes(32)
        ),
        "request_set_count": 3,
        "request_set_sha256": _seed_digest(0x88),
        "event_sha256": _seed_digest(0x99),
    }
    receipt["receipt_sha256"] = settlement_wire.receipt_sha256(receipt)
    provider_envelope = settlement_wire.encode_evidence(request, receipt)
    provider_settlement = settlement_wire.decode_and_verify(provider_envelope)
    price = make_price_table(
        request["provider_adapter_abi"],
        _seed_digest(0xA1),
        request["model_sha256"],
        17,
        1_700_000_000,
        1_700_001_000,
        b"USD",
        PER_COMPONENT_CEILING,
        REASONING_WITHIN_OUTPUT,
        RETRY_INCLUDED,
        {
            "uncached_input": known(2_000_000_000),
            "cached_input": known(500_000_000),
            "visible_output": known(8_000_000_000),
            "reasoning": known(10_000_000_000),
            "retry": known(0),
        },
    )
    quote = make_quote(price, request, 1_700_000_100)
    cost_settlement = make_cost_settlement(
        price, quote, provider_settlement, 1_700_000_200
    )
    evidence = {
        "flags": FLAG_REQUIRE_KNOWN_QUOTE,
        "price": price,
        "quote": quote,
        "provider_settlement": provider_settlement,
        "provider_settlement_envelope": provider_envelope,
        "cost_settlement": cost_settlement,
    }
    verify_evidence(evidence)
    return evidence
