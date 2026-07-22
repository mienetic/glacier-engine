//! Canonical fixed-point price, quote and usage-settlement evidence.
//!
//! V1 never uses floating point and never turns an unknown token count, rate
//! or unbounded retry/reasoning dimension into zero. A price table is effective
//! dated and model/provider scoped. A conservative pre-dispatch quote chooses
//! the more expensive cached/input and visible/reasoning class when one request
//! ceiling covers both. The closed wire embeds the exact ProviderSettlementWire
//! and independently recomputes normalized usage, per-class nanocurrency,
//! rounding adjustment, quote savings or overrun.

const std = @import("std");
const gateway = @import("provider_token_gateway.zig");
const settlement_wire = @import("provider_settlement_wire.zig");

pub const Digest = gateway.Digest;
pub const price_table_abi: u64 = 0x4750_4350_0000_0001;
pub const quote_abi: u64 = 0x4750_4351_0000_0001;
pub const cost_settlement_abi: u64 = 0x4750_4353_0000_0001;
pub const wire_abi: u64 = 0x4750_4357_0000_0001;
pub const magic = [_]u8{ 'G', 'P', 'C', 'W', 'I', 'R', 'E', '1' };
pub const flag_require_known_quote: u32 = 1 << 0;
pub const allowed_flags: u32 = flag_require_known_quote;
pub const rate_denominator: u64 = 1_000_000;

const price_domain = "glacier-provider-price-table-v1\x00";
const quote_domain = "glacier-provider-cost-quote-v1\x00";
const settlement_domain = "glacier-provider-cost-settlement-v1\x00";
const envelope_domain = "glacier-provider-cost-wire-v1\x00";
const digest_bytes = @sizeOf(Digest);

pub const header_bytes: usize = magic.len + 8 + 8 + 4 + 4;
pub const known_u64_wire_bytes: usize = 1 + 8;
pub const rates_wire_bytes: usize = known_u64_wire_bytes * 5;
pub const breakdown_wire_bytes: usize = known_u64_wire_bytes * 12;
pub const price_table_wire_bytes: usize =
    8 + 8 + 32 + 32 + 8 * 3 + 3 + 3 + rates_wire_bytes + 32;
pub const quote_wire_bytes: usize =
    8 + 32 + 32 + 8 + breakdown_wire_bytes + 32;
pub const cost_settlement_wire_bytes: usize =
    8 + 32 * 3 + 8 + breakdown_wire_bytes + known_u64_wire_bytes * 2 + 32;
pub const encoded_bytes: usize = header_bytes + price_table_wire_bytes +
    quote_wire_bytes + settlement_wire.encoded_bytes +
    cost_settlement_wire_bytes + digest_bytes;

pub const Error = error{
    CapacityExceeded,
    InvalidMagic,
    InvalidAbi,
    InvalidLength,
    InvalidFlags,
    InvalidEnum,
    InvalidBoolean,
    InvalidPrice,
    InvalidQuote,
    InvalidSettlement,
    InvalidEnvelope,
    InvalidEvidence,
    ArithmeticOverflow,
};

pub const KnownU64V1 = struct {
    known: bool = false,
    value: u64 = 0,
};

pub const RoundingMode = enum(u8) {
    aggregate_ceiling,
    per_component_ceiling,
};

pub const ReasoningMode = enum(u8) {
    within_output,
    separate_unbounded,
};

pub const RetryMode = enum(u8) {
    included,
    separate_unbounded,
};

pub const RatesV1 = struct {
    uncached_input: KnownU64V1 = .{},
    cached_input: KnownU64V1 = .{},
    visible_output: KnownU64V1 = .{},
    reasoning: KnownU64V1 = .{},
    retry: KnownU64V1 = .{},
};

pub const PriceTableV1 = struct {
    abi_version: u64 = price_table_abi,
    provider_adapter_abi: u64 = 0,
    provider_namespace_sha256: Digest = gateway.zero_digest,
    model_sha256: Digest = gateway.zero_digest,
    price_epoch: u64 = 0,
    effective_from_unix_s: u64 = 0,
    effective_until_unix_s: u64 = 0,
    currency_code: [3]u8 = .{ 0, 0, 0 },
    rounding_mode: RoundingMode = .aggregate_ceiling,
    reasoning_mode: ReasoningMode = .within_output,
    retry_mode: RetryMode = .included,
    rates: RatesV1 = .{},
    price_sha256: Digest = gateway.zero_digest,
};

pub const BreakdownV1 = struct {
    uncached_input_units: KnownU64V1 = .{},
    cached_input_units: KnownU64V1 = .{},
    visible_output_units: KnownU64V1 = .{},
    reasoning_units: KnownU64V1 = .{},
    retry_units: KnownU64V1 = .{},
    uncached_input_nanos: KnownU64V1 = .{},
    cached_input_nanos: KnownU64V1 = .{},
    visible_output_nanos: KnownU64V1 = .{},
    reasoning_nanos: KnownU64V1 = .{},
    retry_nanos: KnownU64V1 = .{},
    rounding_adjustment_nanos: KnownU64V1 = .{},
    total_nanos: KnownU64V1 = .{},
};

pub const QuoteV1 = struct {
    abi_version: u64 = quote_abi,
    request_sha256: Digest = gateway.zero_digest,
    price_sha256: Digest = gateway.zero_digest,
    quoted_at_unix_s: u64 = 0,
    breakdown: BreakdownV1 = .{},
    quote_sha256: Digest = gateway.zero_digest,
};

pub const CostSettlementV1 = struct {
    abi_version: u64 = cost_settlement_abi,
    receipt_sha256: Digest = gateway.zero_digest,
    usage_sha256: Digest = gateway.zero_digest,
    price_sha256: Digest = gateway.zero_digest,
    settled_at_unix_s: u64 = 0,
    breakdown: BreakdownV1 = .{},
    overrun_nanos: KnownU64V1 = .{},
    savings_nanos: KnownU64V1 = .{},
    settlement_sha256: Digest = gateway.zero_digest,
};

pub const DecodedV1 = struct {
    flags: u32,
    price: PriceTableV1,
    quote: QuoteV1,
    provider_settlement: settlement_wire.DecodedV1,
    cost_settlement: CostSettlementV1,
    envelope_sha256: Digest,
};

pub fn makePriceTableV1(
    provider_adapter_abi: u64,
    provider_namespace_sha256: Digest,
    model_sha256: Digest,
    price_epoch: u64,
    effective_from_unix_s: u64,
    effective_until_unix_s: u64,
    currency_code: [3]u8,
    rounding_mode: RoundingMode,
    reasoning_mode: ReasoningMode,
    retry_mode: RetryMode,
    rates: RatesV1,
) Error!PriceTableV1 {
    var value: PriceTableV1 = .{
        .provider_adapter_abi = provider_adapter_abi,
        .provider_namespace_sha256 = provider_namespace_sha256,
        .model_sha256 = model_sha256,
        .price_epoch = price_epoch,
        .effective_from_unix_s = effective_from_unix_s,
        .effective_until_unix_s = effective_until_unix_s,
        .currency_code = currency_code,
        .rounding_mode = rounding_mode,
        .reasoning_mode = reasoning_mode,
        .retry_mode = retry_mode,
        .rates = rates,
    };
    value.price_sha256 = priceTableSha256(value);
    if (!priceTableValidV1(value)) return Error.InvalidPrice;
    return value;
}

pub fn priceTableSha256(value: PriceTableV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(price_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.provider_adapter_abi);
    hash.update(&value.provider_namespace_sha256);
    hash.update(&value.model_sha256);
    hashU64(&hash, value.price_epoch);
    hashU64(&hash, value.effective_from_unix_s);
    hashU64(&hash, value.effective_until_unix_s);
    hash.update(&value.currency_code);
    hashU8(&hash, @intFromEnum(value.rounding_mode));
    hashU8(&hash, @intFromEnum(value.reasoning_mode));
    hashU8(&hash, @intFromEnum(value.retry_mode));
    hashRates(&hash, value.rates);
    return finish(&hash);
}

pub fn priceTableValidV1(value: PriceTableV1) bool {
    if (value.abi_version != price_table_abi or
        value.provider_adapter_abi == 0 or value.price_epoch == 0 or
        value.effective_from_unix_s == 0 or
        (value.effective_until_unix_s != 0 and
            value.effective_until_unix_s <= value.effective_from_unix_s) or
        isZero(value.provider_namespace_sha256) or isZero(value.model_sha256) or
        !currencyValid(value.currency_code) or !ratesValid(value.rates))
        return false;
    if (value.retry_mode == .included and
        (!value.rates.retry.known or value.rates.retry.value != 0))
        return false;
    return std.mem.eql(
        u8,
        &value.price_sha256,
        &priceTableSha256(value),
    );
}

pub fn makeQuoteV1(
    price: PriceTableV1,
    request: gateway.RequestV1,
    quoted_at_unix_s: u64,
) Error!QuoteV1 {
    if (!priceTableValidV1(price) or !gateway.requestValidV1(request) or
        request.provider_adapter_abi != price.provider_adapter_abi or
        !std.mem.eql(u8, &request.model_sha256, &price.model_sha256) or
        !timeInPriceWindow(price, quoted_at_unix_s))
        return Error.InvalidQuote;
    const units = quoteUnits(price, request);
    var value: QuoteV1 = .{
        .request_sha256 = request.request_sha256,
        .price_sha256 = price.price_sha256,
        .quoted_at_unix_s = quoted_at_unix_s,
        .breakdown = try priceBreakdown(price, units),
    };
    value.quote_sha256 = quoteSha256(value);
    if (!quoteValidV1(price, request, value)) return Error.InvalidQuote;
    return value;
}

pub fn quoteSha256(value: QuoteV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(quote_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.request_sha256);
    hash.update(&value.price_sha256);
    hashU64(&hash, value.quoted_at_unix_s);
    hashBreakdown(&hash, value.breakdown);
    return finish(&hash);
}

pub fn quoteValidV1(
    price: PriceTableV1,
    request: gateway.RequestV1,
    value: QuoteV1,
) bool {
    if (value.abi_version != quote_abi or !priceTableValidV1(price) or
        !gateway.requestValidV1(request) or
        request.provider_adapter_abi != price.provider_adapter_abi or
        !std.mem.eql(u8, &request.model_sha256, &price.model_sha256) or
        !std.mem.eql(u8, &value.request_sha256, &request.request_sha256) or
        !std.mem.eql(u8, &value.price_sha256, &price.price_sha256) or
        !timeInPriceWindow(price, value.quoted_at_unix_s) or
        !breakdownValid(value.breakdown)) return false;
    const expected = makeQuoteUnchecked(price, request, value.quoted_at_unix_s) catch return false;
    return std.meta.eql(value.breakdown, expected.breakdown) and std.mem.eql(
        u8,
        &value.quote_sha256,
        &quoteSha256(value),
    );
}

fn makeQuoteUnchecked(
    price: PriceTableV1,
    request: gateway.RequestV1,
    quoted_at_unix_s: u64,
) Error!QuoteV1 {
    var value: QuoteV1 = .{
        .request_sha256 = request.request_sha256,
        .price_sha256 = price.price_sha256,
        .quoted_at_unix_s = quoted_at_unix_s,
        .breakdown = try priceBreakdown(price, quoteUnits(price, request)),
    };
    value.quote_sha256 = quoteSha256(value);
    return value;
}

pub fn makeCostSettlementV1(
    price: PriceTableV1,
    quote: QuoteV1,
    provider_settlement: settlement_wire.DecodedV1,
    settled_at_unix_s: u64,
) Error!CostSettlementV1 {
    if (!quoteValidV1(price, provider_settlement.request, quote) or
        settled_at_unix_s < quote.quoted_at_unix_s)
        return Error.InvalidSettlement;
    const breakdown = settlementBreakdown(
        price,
        provider_settlement.receipt,
    ) catch return Error.InvalidSettlement;
    const delta = quoteDelta(quote.breakdown.total_nanos, breakdown.total_nanos);
    var value: CostSettlementV1 = .{
        .receipt_sha256 = provider_settlement.receipt.receipt_sha256,
        .usage_sha256 = provider_settlement.receipt.usage.usage_sha256,
        .price_sha256 = price.price_sha256,
        .settled_at_unix_s = settled_at_unix_s,
        .breakdown = breakdown,
        .overrun_nanos = delta.overrun,
        .savings_nanos = delta.savings,
    };
    value.settlement_sha256 = costSettlementSha256(value);
    if (!costSettlementValidV1(
        price,
        quote,
        provider_settlement,
        value,
    )) return Error.InvalidSettlement;
    return value;
}

pub fn costSettlementSha256(value: CostSettlementV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(settlement_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.receipt_sha256);
    hash.update(&value.usage_sha256);
    hash.update(&value.price_sha256);
    hashU64(&hash, value.settled_at_unix_s);
    hashBreakdown(&hash, value.breakdown);
    hashKnown(&hash, value.overrun_nanos);
    hashKnown(&hash, value.savings_nanos);
    return finish(&hash);
}

pub fn costSettlementValidV1(
    price: PriceTableV1,
    quote: QuoteV1,
    provider_settlement: settlement_wire.DecodedV1,
    value: CostSettlementV1,
) bool {
    if (value.abi_version != cost_settlement_abi or
        !quoteValidV1(price, provider_settlement.request, quote) or
        value.settled_at_unix_s < quote.quoted_at_unix_s or
        !knownValid(value.overrun_nanos) or !knownValid(value.savings_nanos) or
        !breakdownValid(value.breakdown) or
        !std.mem.eql(
            u8,
            &value.receipt_sha256,
            &provider_settlement.receipt.receipt_sha256,
        ) or !std.mem.eql(
        u8,
        &value.usage_sha256,
        &provider_settlement.receipt.usage.usage_sha256,
    ) or !std.mem.eql(u8, &value.price_sha256, &price.price_sha256))
        return false;
    const expected_breakdown = settlementBreakdown(
        price,
        provider_settlement.receipt,
    ) catch return false;
    const expected_delta = quoteDelta(
        quote.breakdown.total_nanos,
        expected_breakdown.total_nanos,
    );
    return std.meta.eql(value.breakdown, expected_breakdown) and
        std.meta.eql(value.overrun_nanos, expected_delta.overrun) and
        std.meta.eql(value.savings_nanos, expected_delta.savings) and
        std.mem.eql(
            u8,
            &value.settlement_sha256,
            &costSettlementSha256(value),
        );
}

pub fn encodeV1(
    flags: u32,
    price: PriceTableV1,
    quote: QuoteV1,
    encoded_provider_settlement: []const u8,
    cost_settlement: CostSettlementV1,
    destination: []u8,
) Error![]const u8 {
    if (flags != flag_require_known_quote) return Error.InvalidFlags;
    if (encoded_provider_settlement.len != settlement_wire.encoded_bytes)
        return Error.InvalidLength;
    const provider_settlement = settlement_wire.decodeAndVerifyV1(
        encoded_provider_settlement,
    ) catch return Error.InvalidEvidence;
    if (!verifyEvidenceV1(
        flags,
        price,
        quote,
        provider_settlement,
        cost_settlement,
    )) return Error.InvalidEvidence;
    if (destination.len < encoded_bytes) return Error.CapacityExceeded;
    const output = destination[0..encoded_bytes];
    if (slicesOverlap(u8, encoded_provider_settlement, u8, output))
        return Error.InvalidEvidence;
    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(encoded_bytes);
    try writer.writeU32(flags);
    try writer.writeU32(0);
    try writePrice(&writer, price);
    try writeQuote(&writer, quote);
    try writer.writeBytes(encoded_provider_settlement);
    try writeCostSettlement(&writer, cost_settlement);
    if (writer.position + digest_bytes != output.len)
        return Error.InvalidLength;
    try writer.writeDigest(envelopeSha256(output[0..writer.position]));
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

pub fn decodeAndVerifyV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len != encoded_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    if (try reader.readU64() != encoded_bytes) return Error.InvalidLength;
    const flags = try reader.readU32();
    if (flags != flag_require_known_quote) return Error.InvalidFlags;
    if (try reader.readU32() != 0) return Error.InvalidFlags;
    const expected_root = envelopeSha256(encoded[0 .. encoded.len - digest_bytes]);
    if (!std.mem.eql(u8, &expected_root, encoded[encoded.len - digest_bytes ..]))
        return Error.InvalidEnvelope;
    const price = try readPrice(&reader);
    const quote = try readQuote(&reader);
    const provider_bytes = try reader.readBytes(settlement_wire.encoded_bytes);
    const provider_settlement = settlement_wire.decodeAndVerifyV1(
        provider_bytes,
    ) catch return Error.InvalidEvidence;
    const cost_settlement = try readCostSettlement(&reader);
    const envelope_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &envelope_sha256,
        &expected_root,
    )) return Error.InvalidEnvelope;
    if (!verifyEvidenceV1(
        flags,
        price,
        quote,
        provider_settlement,
        cost_settlement,
    )) return Error.InvalidEvidence;
    return .{
        .flags = flags,
        .price = price,
        .quote = quote,
        .provider_settlement = provider_settlement,
        .cost_settlement = cost_settlement,
        .envelope_sha256 = envelope_sha256,
    };
}

pub fn verifyEvidenceV1(
    flags: u32,
    price: PriceTableV1,
    quote: QuoteV1,
    provider_settlement: settlement_wire.DecodedV1,
    cost_settlement: CostSettlementV1,
) bool {
    return flags == flag_require_known_quote and
        quoteValidV1(price, provider_settlement.request, quote) and
        quote.breakdown.total_nanos.known and
        costSettlementValidV1(
            price,
            quote,
            provider_settlement,
            cost_settlement,
        );
}

const UnitsV1 = struct {
    uncached_input: KnownU64V1 = .{},
    cached_input: KnownU64V1 = .{},
    visible_output: KnownU64V1 = .{},
    reasoning: KnownU64V1 = .{},
    retry: KnownU64V1 = .{},
};

fn quoteUnits(price: PriceTableV1, request: gateway.RequestV1) UnitsV1 {
    var result: UnitsV1 = .{};
    if (price.rates.uncached_input.known and price.rates.cached_input.known) {
        if (price.rates.cached_input.value > price.rates.uncached_input.value) {
            result.cached_input = known(request.input_token_estimate);
            result.uncached_input = known(0);
        } else {
            result.uncached_input = known(request.input_token_estimate);
            result.cached_input = known(0);
        }
    } else {
        result.uncached_input = known(request.input_token_estimate);
        result.cached_input = unknown();
    }
    if (price.reasoning_mode == .within_output and
        price.rates.visible_output.known and price.rates.reasoning.known)
    {
        if (price.rates.reasoning.value > price.rates.visible_output.value) {
            result.visible_output = known(0);
            result.reasoning = known(request.max_output_tokens);
        } else {
            result.visible_output = known(request.max_output_tokens);
            result.reasoning = known(0);
        }
    } else {
        result.visible_output = known(request.max_output_tokens);
        result.reasoning = unknown();
    }
    result.retry = if (price.retry_mode == .included) known(0) else unknown();
    return result;
}

fn normalizeUsage(price: PriceTableV1, usage: gateway.UsageV1) Error!UnitsV1 {
    if (!gateway.usageValidV1(usage)) return Error.InvalidSettlement;
    var result: UnitsV1 = .{};
    result.cached_input = fromCount(usage.cached_input_tokens);
    if (usage.input_tokens.known and usage.cached_input_tokens.known) {
        if (usage.cached_input_tokens.value > usage.input_tokens.value)
            return Error.InvalidSettlement;
        result.uncached_input = known(
            usage.input_tokens.value - usage.cached_input_tokens.value,
        );
    } else {
        result.uncached_input = unknown();
    }
    result.reasoning = fromCount(usage.reasoning_tokens);
    if (price.reasoning_mode == .within_output) {
        if (usage.output_tokens.known and usage.reasoning_tokens.known) {
            if (usage.reasoning_tokens.value > usage.output_tokens.value)
                return Error.InvalidSettlement;
            result.visible_output = known(
                usage.output_tokens.value - usage.reasoning_tokens.value,
            );
        } else {
            result.visible_output = unknown();
        }
    } else {
        result.visible_output = fromCount(usage.output_tokens);
    }
    result.retry = if (price.retry_mode == .included)
        known(0)
    else
        fromCount(usage.retry_tokens);
    return result;
}

fn settlementBreakdown(
    price: PriceTableV1,
    receipt: gateway.AttemptReceiptV1,
) Error!BreakdownV1 {
    const units = try normalizeUsage(price, receipt.usage);
    if (receipt.outcome != .retryable_no_charge)
        return priceBreakdown(price, units);
    if (!receipt.usage.billable_tokens.known or
        receipt.usage.billable_tokens.value != 0)
        return Error.InvalidSettlement;
    return .{
        .uncached_input_units = units.uncached_input,
        .cached_input_units = units.cached_input,
        .visible_output_units = units.visible_output,
        .reasoning_units = units.reasoning,
        .retry_units = units.retry,
        .uncached_input_nanos = known(0),
        .cached_input_nanos = known(0),
        .visible_output_nanos = known(0),
        .reasoning_nanos = known(0),
        .retry_nanos = known(0),
        .rounding_adjustment_nanos = known(0),
        .total_nanos = known(0),
    };
}

fn priceBreakdown(price: PriceTableV1, units: UnitsV1) Error!BreakdownV1 {
    const unit_values = [_]KnownU64V1{
        units.uncached_input,
        units.cached_input,
        units.visible_output,
        units.reasoning,
        units.retry,
    };
    const rates = [_]KnownU64V1{
        price.rates.uncached_input,
        price.rates.cached_input,
        price.rates.visible_output,
        price.rates.reasoning,
        price.rates.retry,
    };
    var amounts: [5]KnownU64V1 = undefined;
    var numerators: [5]?u128 = undefined;
    for (unit_values, rates, 0..) |unit, rate, index| {
        numerators[index] = componentNumerator(rate, unit);
        amounts[index] = try componentAmount(
            rate,
            unit,
            price.rounding_mode == .per_component_ceiling,
        );
    }
    var adjustment = unknown();
    var total = unknown();
    if (price.rounding_mode == .per_component_ceiling) {
        adjustment = known(0);
        total = try sumKnown(&amounts);
    } else {
        var numerator_sum: u128 = 0;
        var all_known = true;
        for (numerators) |maybe| {
            if (maybe) |value| {
                numerator_sum = std.math.add(u128, numerator_sum, value) catch
                    return Error.ArithmeticOverflow;
            } else {
                all_known = false;
            }
        }
        if (all_known) {
            const rounded_total = try u128ToU64(ceilDiv(
                numerator_sum,
                rate_denominator,
            ));
            const floors = (try sumKnown(&amounts)).value;
            if (rounded_total < floors) return Error.ArithmeticOverflow;
            adjustment = known(rounded_total - floors);
            total = known(rounded_total);
        }
    }
    return .{
        .uncached_input_units = unit_values[0],
        .cached_input_units = unit_values[1],
        .visible_output_units = unit_values[2],
        .reasoning_units = unit_values[3],
        .retry_units = unit_values[4],
        .uncached_input_nanos = amounts[0],
        .cached_input_nanos = amounts[1],
        .visible_output_nanos = amounts[2],
        .reasoning_nanos = amounts[3],
        .retry_nanos = amounts[4],
        .rounding_adjustment_nanos = adjustment,
        .total_nanos = total,
    };
}

fn componentNumerator(rate: KnownU64V1, units: KnownU64V1) ?u128 {
    if ((rate.known and rate.value == 0) or (units.known and units.value == 0))
        return 0;
    if (!rate.known or !units.known) return null;
    return @as(u128, rate.value) * @as(u128, units.value);
}

fn componentAmount(
    rate: KnownU64V1,
    units: KnownU64V1,
    round_up: bool,
) Error!KnownU64V1 {
    const numerator = componentNumerator(rate, units) orelse return unknown();
    const amount = if (round_up)
        ceilDiv(numerator, rate_denominator)
    else
        numerator / rate_denominator;
    return known(try u128ToU64(amount));
}

fn sumKnown(values: []const KnownU64V1) Error!KnownU64V1 {
    var total: u64 = 0;
    for (values) |value| {
        if (!value.known) return unknown();
        total = std.math.add(u64, total, value.value) catch
            return Error.ArithmeticOverflow;
    }
    return known(total);
}

const QuoteDelta = struct {
    overrun: KnownU64V1,
    savings: KnownU64V1,
};

fn quoteDelta(quote: KnownU64V1, actual: KnownU64V1) QuoteDelta {
    if (!quote.known or !actual.known) return .{
        .overrun = unknown(),
        .savings = unknown(),
    };
    if (actual.value > quote.value) return .{
        .overrun = known(actual.value - quote.value),
        .savings = known(0),
    };
    return .{
        .overrun = known(0),
        .savings = known(quote.value - actual.value),
    };
}

fn known(value: u64) KnownU64V1 {
    return .{ .known = true, .value = value };
}

fn unknown() KnownU64V1 {
    return .{};
}

fn fromCount(value: gateway.CountV1) KnownU64V1 {
    return .{ .known = value.known, .value = value.value };
}

fn knownValid(value: KnownU64V1) bool {
    return value.known or value.value == 0;
}

fn ratesValid(value: RatesV1) bool {
    inline for (std.meta.fields(RatesV1)) |field|
        if (!knownValid(@field(value, field.name))) return false;
    return true;
}

fn breakdownValid(value: BreakdownV1) bool {
    inline for (std.meta.fields(BreakdownV1)) |field|
        if (!knownValid(@field(value, field.name))) return false;
    return true;
}

fn currencyValid(value: [3]u8) bool {
    for (value) |byte| if (byte < 'A' or byte > 'Z') return false;
    return true;
}

fn timeInPriceWindow(price: PriceTableV1, timestamp: u64) bool {
    return timestamp >= price.effective_from_unix_s and
        (price.effective_until_unix_s == 0 or
            timestamp < price.effective_until_unix_s);
}

fn ceilDiv(numerator: u128, denominator: u64) u128 {
    if (numerator == 0) return 0;
    return (numerator - 1) / denominator + 1;
}

fn u128ToU64(value: u128) Error!u64 {
    if (value > std.math.maxInt(u64)) return Error.ArithmeticOverflow;
    return @intCast(value);
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(usize, self.position, value.len) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.CapacityExceeded;
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU8(self: *Writer, value: u8) Error!void {
        try self.writeBytes(&.{value});
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        const end = std.math.add(usize, self.position, length) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        const result = self.bytes[self.position..end];
        self.position = end;
        return result;
    }

    fn readU8(self: *Reader) Error!u8 {
        return (try self.readBytes(1))[0];
    }

    fn readU32(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.readBytes(4))[0..4], .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try self.readBytes(8))[0..8], .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(digest_bytes));
        return value;
    }
};

fn writeKnown(writer: *Writer, value: KnownU64V1) Error!void {
    try writer.writeU8(@intFromBool(value.known));
    try writer.writeU64(value.value);
}

fn readKnown(reader: *Reader) Error!KnownU64V1 {
    const is_known = switch (try reader.readU8()) {
        0 => false,
        1 => true,
        else => return Error.InvalidBoolean,
    };
    return .{ .known = is_known, .value = try reader.readU64() };
}

fn writeRates(writer: *Writer, value: RatesV1) Error!void {
    inline for (std.meta.fields(RatesV1)) |field|
        try writeKnown(writer, @field(value, field.name));
}

fn readRates(reader: *Reader) Error!RatesV1 {
    var value: RatesV1 = .{};
    inline for (std.meta.fields(RatesV1)) |field|
        @field(value, field.name) = try readKnown(reader);
    return value;
}

fn writeBreakdown(writer: *Writer, value: BreakdownV1) Error!void {
    inline for (std.meta.fields(BreakdownV1)) |field|
        try writeKnown(writer, @field(value, field.name));
}

fn readBreakdown(reader: *Reader) Error!BreakdownV1 {
    var value: BreakdownV1 = .{};
    inline for (std.meta.fields(BreakdownV1)) |field|
        @field(value, field.name) = try readKnown(reader);
    return value;
}

fn writePrice(writer: *Writer, value: PriceTableV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.provider_adapter_abi);
    try writer.writeDigest(value.provider_namespace_sha256);
    try writer.writeDigest(value.model_sha256);
    try writer.writeU64(value.price_epoch);
    try writer.writeU64(value.effective_from_unix_s);
    try writer.writeU64(value.effective_until_unix_s);
    try writer.writeBytes(&value.currency_code);
    try writer.writeU8(@intFromEnum(value.rounding_mode));
    try writer.writeU8(@intFromEnum(value.reasoning_mode));
    try writer.writeU8(@intFromEnum(value.retry_mode));
    try writeRates(writer, value.rates);
    try writer.writeDigest(value.price_sha256);
}

fn readPrice(reader: *Reader) Error!PriceTableV1 {
    const abi_version = try reader.readU64();
    const provider_adapter_abi = try reader.readU64();
    const provider_namespace_sha256 = try reader.readDigest();
    const model_sha256 = try reader.readDigest();
    const price_epoch = try reader.readU64();
    const effective_from_unix_s = try reader.readU64();
    const effective_until_unix_s = try reader.readU64();
    var currency_code: [3]u8 = undefined;
    @memcpy(&currency_code, try reader.readBytes(3));
    const rounding_mode: RoundingMode = switch (try reader.readU8()) {
        0 => .aggregate_ceiling,
        1 => .per_component_ceiling,
        else => return Error.InvalidEnum,
    };
    const reasoning_mode: ReasoningMode = switch (try reader.readU8()) {
        0 => .within_output,
        1 => .separate_unbounded,
        else => return Error.InvalidEnum,
    };
    const retry_mode: RetryMode = switch (try reader.readU8()) {
        0 => .included,
        1 => .separate_unbounded,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .provider_adapter_abi = provider_adapter_abi,
        .provider_namespace_sha256 = provider_namespace_sha256,
        .model_sha256 = model_sha256,
        .price_epoch = price_epoch,
        .effective_from_unix_s = effective_from_unix_s,
        .effective_until_unix_s = effective_until_unix_s,
        .currency_code = currency_code,
        .rounding_mode = rounding_mode,
        .reasoning_mode = reasoning_mode,
        .retry_mode = retry_mode,
        .rates = try readRates(reader),
        .price_sha256 = try reader.readDigest(),
    };
}

fn writeQuote(writer: *Writer, value: QuoteV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.request_sha256);
    try writer.writeDigest(value.price_sha256);
    try writer.writeU64(value.quoted_at_unix_s);
    try writeBreakdown(writer, value.breakdown);
    try writer.writeDigest(value.quote_sha256);
}

fn readQuote(reader: *Reader) Error!QuoteV1 {
    return .{
        .abi_version = try reader.readU64(),
        .request_sha256 = try reader.readDigest(),
        .price_sha256 = try reader.readDigest(),
        .quoted_at_unix_s = try reader.readU64(),
        .breakdown = try readBreakdown(reader),
        .quote_sha256 = try reader.readDigest(),
    };
}

fn writeCostSettlement(
    writer: *Writer,
    value: CostSettlementV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.receipt_sha256);
    try writer.writeDigest(value.usage_sha256);
    try writer.writeDigest(value.price_sha256);
    try writer.writeU64(value.settled_at_unix_s);
    try writeBreakdown(writer, value.breakdown);
    try writeKnown(writer, value.overrun_nanos);
    try writeKnown(writer, value.savings_nanos);
    try writer.writeDigest(value.settlement_sha256);
}

fn readCostSettlement(reader: *Reader) Error!CostSettlementV1 {
    return .{
        .abi_version = try reader.readU64(),
        .receipt_sha256 = try reader.readDigest(),
        .usage_sha256 = try reader.readDigest(),
        .price_sha256 = try reader.readDigest(),
        .settled_at_unix_s = try reader.readU64(),
        .breakdown = try readBreakdown(reader),
        .overrun_nanos = try readKnown(reader),
        .savings_nanos = try readKnown(reader),
        .settlement_sha256 = try reader.readDigest(),
    };
}

fn hashKnown(hash: *std.crypto.hash.sha2.Sha256, value: KnownU64V1) void {
    hashU8(hash, @intFromBool(value.known));
    hashU64(hash, value.value);
}

fn hashRates(hash: *std.crypto.hash.sha2.Sha256, value: RatesV1) void {
    inline for (std.meta.fields(RatesV1)) |field|
        hashKnown(hash, @field(value, field.name));
}

fn hashBreakdown(hash: *std.crypto.hash.sha2.Sha256, value: BreakdownV1) void {
    inline for (std.meta.fields(BreakdownV1)) |field|
        hashKnown(hash, @field(value, field.name));
}

fn envelopeSha256(prefix: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(envelope_domain);
    hash.update(prefix);
    return finish(&hash);
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
    hash.update(&.{value});
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var value: Digest = undefined;
    hash.final(&value);
    return value;
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &gateway.zero_digest);
}

fn slicesOverlap(
    comptime Left: type,
    left: []const Left,
    comptime Right: type,
    right: []const Right,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, @sizeOf(Left)) catch
        return true;
    const right_bytes = std.math.mul(usize, right.len, @sizeOf(Right)) catch
        return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch
        return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch
        return true;
    return left_start < right_end and right_start < left_end;
}

fn resealForTest(encoded: []u8) void {
    const root_offset = encoded.len - digest_bytes;
    const root = envelopeSha256(encoded[0..root_offset]);
    @memcpy(encoded[root_offset..], &root);
}

fn testDigest(seed: u8) Digest {
    var value: Digest = undefined;
    @memset(&value, seed);
    return value;
}

const TestProviderEvidence = struct {
    request: gateway.RequestV1,
    receipt: gateway.AttemptReceiptV1,
    encoded: [settlement_wire.encoded_bytes]u8,
};

fn testProviderEvidence(
    outcome: gateway.AttemptOutcome,
    usage: gateway.UsageV1,
) !TestProviderEvidence {
    const request = try gateway.makeRequestV1(
        0x434f_5354_4144_5054,
        0x434f_5354_4953_4f4c,
        71,
        3,
        testDigest(0x11),
        testDigest(0x22),
        testDigest(0x33),
        testDigest(0x44),
        testDigest(0x55),
        100,
        50,
        .in_flight,
    );
    var intent: gateway.DispatchIntentV1 = .{
        .gateway_epoch = 0x434f_5354_4757_0001,
        .owner_slot_index = 2,
        .owner_generation = 9,
        .attempt_generation = 4,
        .request_sha256 = request.request_sha256,
        .dispatch_key_sha256 = gateway.dispatchKeySha256(request),
        .reserved_tokens = 150,
        .previous_event_chain_sha256 = testDigest(0x66),
    };
    intent.intent_sha256 = gateway.dispatchIntentSha256(intent);
    var receipt: gateway.AttemptReceiptV1 = .{
        .outcome = outcome,
        .intent = intent,
        .usage = usage,
        .result_sha256 = switch (outcome) {
            .succeeded, .resolved_success => testDigest(0x77),
            else => gateway.zero_digest,
        },
        .request_set_count = 3,
        .request_set_sha256 = testDigest(0x88),
        .event_sha256 = testDigest(0x99),
    };
    receipt.receipt_sha256 = gateway.attemptReceiptSha256(receipt);
    var encoded: [settlement_wire.encoded_bytes]u8 = undefined;
    _ = try settlement_wire.encodeV1(request, receipt, &encoded);
    return .{ .request = request, .receipt = receipt, .encoded = encoded };
}

fn testPrice(
    request: gateway.RequestV1,
    rounding_mode: RoundingMode,
) !PriceTableV1 {
    return makePriceTableV1(
        request.provider_adapter_abi,
        testDigest(0xa1),
        request.model_sha256,
        17,
        1_700_000_000,
        1_700_001_000,
        .{ 'U', 'S', 'D' },
        rounding_mode,
        .within_output,
        .included,
        .{
            .uncached_input = known(2_000_000_000),
            .cached_input = known(500_000_000),
            .visible_output = known(8_000_000_000),
            .reasoning = known(10_000_000_000),
            .retry = known(0),
        },
    );
}

const TestCostEvidence = struct {
    provider: TestProviderEvidence,
    decoded_provider: settlement_wire.DecodedV1,
    price: PriceTableV1,
    quote: QuoteV1,
    cost: CostSettlementV1,
};

fn testCostEvidence(outcome: gateway.AttemptOutcome) !TestCostEvidence {
    const usage = switch (outcome) {
        .retryable_no_charge => try gateway.makeUsageV1(
            null,
            null,
            null,
            null,
            null,
            0,
        ),
        .ambiguous => try gateway.makeUsageV1(100, null, 40, null, 3, null),
        .succeeded, .resolved_success => try gateway.makeUsageV1(
            100,
            20,
            40,
            8,
            0,
            80,
        ),
        .failed, .resolved_failure => try gateway.makeUsageV1(
            100,
            0,
            40,
            0,
            0,
            60,
        ),
    };
    const provider = try testProviderEvidence(outcome, usage);
    const decoded_provider = try settlement_wire.decodeAndVerifyV1(
        &provider.encoded,
    );
    const price = try testPrice(provider.request, .per_component_ceiling);
    const quote = try makeQuoteV1(price, provider.request, 1_700_000_100);
    const cost = try makeCostSettlementV1(
        price,
        quote,
        decoded_provider,
        1_700_000_200,
    );
    return .{
        .provider = provider,
        .decoded_provider = decoded_provider,
        .price = price,
        .quote = quote,
        .cost = cost,
    };
}

test "fixed-point quote and authoritative usage settlement stay exact" {
    const evidence = try testCostEvidence(.succeeded);
    try std.testing.expect(evidence.quote.breakdown.total_nanos.known);
    try std.testing.expectEqual(
        @as(u64, 700_000),
        evidence.quote.breakdown.total_nanos.value,
    );
    try std.testing.expectEqual(
        @as(u64, 60),
        evidence.cost.breakdown.uncached_input_units.value,
    );
    try std.testing.expectEqual(
        @as(u64, 40),
        evidence.cost.breakdown.cached_input_units.value,
    );
    try std.testing.expectEqual(
        @as(u64, 12),
        evidence.cost.breakdown.visible_output_units.value,
    );
    try std.testing.expectEqual(
        @as(u64, 8),
        evidence.cost.breakdown.reasoning_units.value,
    );
    try std.testing.expectEqual(
        @as(u64, 316_000),
        evidence.cost.breakdown.total_nanos.value,
    );
    try std.testing.expectEqual(
        @as(u64, 384_000),
        evidence.cost.savings_nanos.value,
    );
    try std.testing.expectEqual(@as(u64, 0), evidence.cost.overrun_nanos.value);
}

test "all provider outcomes preserve known and unknown cost semantics" {
    inline for (std.meta.tags(gateway.AttemptOutcome)) |outcome| {
        const evidence = try testCostEvidence(outcome);
        try std.testing.expect(verifyEvidenceV1(
            flag_require_known_quote,
            evidence.price,
            evidence.quote,
            evidence.decoded_provider,
            evidence.cost,
        ));
        if (outcome == .ambiguous) {
            try std.testing.expect(!evidence.cost.breakdown.total_nanos.known);
            try std.testing.expect(!evidence.cost.savings_nanos.known);
            try std.testing.expect(!evidence.cost.overrun_nanos.known);
        } else if (outcome == .retryable_no_charge) {
            try std.testing.expect(evidence.cost.breakdown.total_nanos.known);
            try std.testing.expectEqual(
                @as(u64, 0),
                evidence.cost.breakdown.total_nanos.value,
            );
            try std.testing.expectEqual(
                evidence.quote.breakdown.total_nanos.value,
                evidence.cost.savings_nanos.value,
            );
        } else {
            try std.testing.expect(evidence.cost.breakdown.total_nanos.known);
        }
    }
}

test "authoritative usage above the declared quote records exact overrun" {
    const provider = try testProviderEvidence(
        .succeeded,
        try gateway.makeUsageV1(200, 100, 0, 0, 0, 300),
    );
    const decoded = try settlement_wire.decodeAndVerifyV1(&provider.encoded);
    const price = try testPrice(provider.request, .per_component_ceiling);
    const quote = try makeQuoteV1(price, provider.request, 1_700_000_100);
    const cost = try makeCostSettlementV1(
        price,
        quote,
        decoded,
        1_700_000_200,
    );
    try std.testing.expectEqual(
        @as(u64, 700_000),
        quote.breakdown.total_nanos.value,
    );
    try std.testing.expectEqual(
        @as(u64, 1_200_000),
        cost.breakdown.total_nanos.value,
    );
    try std.testing.expectEqual(
        @as(u64, 500_000),
        cost.overrun_nanos.value,
    );
    try std.testing.expectEqual(@as(u64, 0), cost.savings_nanos.value);
}

test "aggregate and per-component rounding remain explicit" {
    const provider = try testProviderEvidence(
        .succeeded,
        try gateway.makeUsageV1(1, 1, 0, 0, 0, 1),
    );
    const decoded = try settlement_wire.decodeAndVerifyV1(&provider.encoded);
    var aggregate = try testPrice(provider.request, .aggregate_ceiling);
    aggregate.rates = .{
        .uncached_input = known(1),
        .cached_input = known(1),
        .visible_output = known(1),
        .reasoning = known(1),
        .retry = known(0),
    };
    aggregate.price_sha256 = priceTableSha256(aggregate);
    const aggregate_quote = try makeQuoteV1(
        aggregate,
        provider.request,
        1_700_000_100,
    );
    const aggregate_cost = try makeCostSettlementV1(
        aggregate,
        aggregate_quote,
        decoded,
        1_700_000_200,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        aggregate_cost.breakdown.total_nanos.value,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        aggregate_cost.breakdown.rounding_adjustment_nanos.value,
    );

    var per_component = aggregate;
    per_component.rounding_mode = .per_component_ceiling;
    per_component.price_sha256 = priceTableSha256(per_component);
    const component_quote = try makeQuoteV1(
        per_component,
        provider.request,
        1_700_000_100,
    );
    const component_cost = try makeCostSettlementV1(
        per_component,
        component_quote,
        decoded,
        1_700_000_200,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        component_cost.breakdown.total_nanos.value,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        component_cost.breakdown.rounding_adjustment_nanos.value,
    );
}

test "unbounded separately billed dimensions cannot authorize known quote" {
    const provider = try testProviderEvidence(
        .succeeded,
        try gateway.makeUsageV1(100, 20, 40, 8, 3, 80),
    );
    const decoded = try settlement_wire.decodeAndVerifyV1(&provider.encoded);
    var price = try testPrice(provider.request, .per_component_ceiling);
    price.retry_mode = .separate_unbounded;
    price.rates.retry = known(1_000_000_000);
    price.price_sha256 = priceTableSha256(price);
    const quote = try makeQuoteV1(price, provider.request, 1_700_000_100);
    try std.testing.expect(!quote.breakdown.total_nanos.known);
    const cost = try makeCostSettlementV1(
        price,
        quote,
        decoded,
        1_700_000_200,
    );
    try std.testing.expect(!verifyEvidenceV1(
        flag_require_known_quote,
        price,
        quote,
        decoded,
        cost,
    ));
    try std.testing.expect(costSettlementValidV1(
        price,
        quote,
        decoded,
        cost,
    ));
}

test "cost wire round trips and binds every nested record" {
    const evidence = try testCostEvidence(.succeeded);
    var bytes: [encoded_bytes + 16]u8 = [_]u8{0xcc} ** (encoded_bytes + 16);
    const encoded = try encodeV1(
        flag_require_known_quote,
        evidence.price,
        evidence.quote,
        &evidence.provider.encoded,
        evidence.cost,
        &bytes,
    );
    try std.testing.expectEqual(@as(usize, 1461), encoded_bytes);
    try std.testing.expectEqual(encoded_bytes, encoded.len);
    try std.testing.expectEqual(
        @as(u8, 0xcc),
        bytes[encoded_bytes],
    );
    const decoded = try decodeAndVerifyV1(encoded);
    try std.testing.expect(std.meta.eql(evidence.price, decoded.price));
    try std.testing.expect(std.meta.eql(evidence.quote, decoded.quote));
    try std.testing.expect(std.meta.eql(
        evidence.cost,
        decoded.cost_settlement,
    ));
    const expected = [_]u8{
        0x39, 0x3a, 0x66, 0x8d, 0x69, 0x14, 0xcc, 0x1d,
        0x23, 0x04, 0x20, 0x70, 0xa2, 0x80, 0x70, 0x1e,
        0x2f, 0x32, 0xb5, 0x4e, 0x2a, 0xf5, 0x3b, 0x9d,
        0xf1, 0xf0, 0xf6, 0xcd, 0x11, 0xa1, 0xad, 0x4b,
    };
    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &decoded.envelope_sha256,
    );
}

test "cost wire rejects every resealed pre-root byte mutation" {
    const evidence = try testCostEvidence(.succeeded);
    var bytes: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(
        flag_require_known_quote,
        evidence.price,
        evidence.quote,
        &evidence.provider.encoded,
        evidence.cost,
        &bytes,
    );
    var mutated: [encoded_bytes]u8 = undefined;
    for (0..encoded_bytes - digest_bytes) |offset| {
        @memcpy(&mutated, encoded);
        mutated[offset] ^= 0x01;
        resealForTest(&mutated);
        if (decodeAndVerifyV1(&mutated)) |_| {
            return error.AcceptedMutation;
        } else |_| {}
    }
}

test "cost evidence rejects temporal identity arithmetic and semantic drift" {
    const evidence = try testCostEvidence(.succeeded);
    try std.testing.expectError(
        Error.InvalidQuote,
        makeQuoteV1(evidence.price, evidence.provider.request, 1),
    );
    var wrong_model = evidence.provider.request;
    wrong_model.model_sha256 = testDigest(0xee);
    wrong_model.request_sha256 = gateway.requestSha256(wrong_model);
    try std.testing.expectError(
        Error.InvalidQuote,
        makeQuoteV1(evidence.price, wrong_model, 1_700_000_100),
    );
    var drifted_cost = evidence.cost;
    drifted_cost.breakdown.total_nanos.value += 1;
    drifted_cost.settlement_sha256 = costSettlementSha256(drifted_cost);
    try std.testing.expect(!costSettlementValidV1(
        evidence.price,
        evidence.quote,
        evidence.decoded_provider,
        drifted_cost,
    ));
    const overflow_rate = KnownU64V1{
        .known = true,
        .value = std.math.maxInt(u64),
    };
    const overflow_units = KnownU64V1{
        .known = true,
        .value = std.math.maxInt(u64),
    };
    try std.testing.expectError(
        Error.ArithmeticOverflow,
        componentAmount(overflow_rate, overflow_units, true),
    );
}

test "wire layout is fixed width and independent of native padding" {
    try std.testing.expectEqual(@as(usize, 32), header_bytes);
    try std.testing.expectEqual(@as(usize, 9), known_u64_wire_bytes);
    try std.testing.expectEqual(@as(usize, 45), rates_wire_bytes);
    try std.testing.expectEqual(@as(usize, 108), breakdown_wire_bytes);
    try std.testing.expectEqual(@as(usize, 187), price_table_wire_bytes);
    try std.testing.expectEqual(@as(usize, 220), quote_wire_bytes);
    try std.testing.expectEqual(@as(usize, 270), cost_settlement_wire_bytes);
    try std.testing.expectEqual(@as(usize, 1461), encoded_bytes);
}
