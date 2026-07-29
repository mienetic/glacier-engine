//! Byte-level tokenizer profiles.
//!
//! The canonical `Utf8Byte*V1` profile validates UTF-8 and maps every input
//! byte to the same token id in [0, 255]. It has fixed manifest and prompt
//! wires, disables implicit special tokens, and rejects vocabularies below 256
//! instead of applying a fallback.
//!
//! `ByteTokenizer` remains the older compatibility profile. Its special tokens
//! live above 0xFF so they never collide with byte tokens.
//!   - 256: padding (not emitted by encode, used by batched callers)
//!   - 257: BOS (start of sequence)
//!   - 258: EOS (end of sequence, stops generation)
//!
//! When that compatibility profile's vocabulary is smaller than 256, encode
//! retains its historical modulo mapping. New evidence-bearing raw-text paths
//! must use the canonical profile.

const std = @import("std");

pub const PAD: u32 = 256;
pub const BOS: u32 = 257;
pub const EOS: u32 = 258;

pub const Digest = [32]u8;
pub const utf8_byte_manifest_abi: u64 = 0x4754_4f4b_0000_0001;
pub const utf8_byte_prompt_abi: u64 = 0x4754_5052_0000_0001;
pub const utf8_byte_manifest_bytes: usize = 192;
pub const utf8_byte_manifest_body_bytes: usize =
    utf8_byte_manifest_bytes - 32;
pub const utf8_byte_prompt_bytes: usize = 256;
pub const utf8_byte_prompt_body_bytes: usize =
    utf8_byte_prompt_bytes - 32;
pub const utf8_byte_max_input_bytes: u64 = 1024 * 1024;
pub const utf8_byte_token_count: u32 = 256;
pub const no_special_token: u32 = std.math.maxInt(u32);

pub const utf8_byte_manifest_magic =
    [_]u8{ 'G', 'T', 'O', 'K', 'V', '1', 0, 0 };
pub const utf8_byte_prompt_magic =
    [_]u8{ 'G', 'T', 'P', 'R', 'V', '1', 0, 0 };

const utf8_byte_manifest_domain =
    "glacier-utf8-byte-tokenizer-manifest-v1\x00";
const utf8_byte_domain_descriptor =
    "glacier-utf8-byte-token-domain-v1:" ++
    "strict-utf8;normalization=none;byte-token-base=0;" ++
    "byte-token-count=256;special-tokens=disabled;" ++
    "fallback=reject\x00";
const utf8_byte_behavior_descriptor =
    "glacier-utf8-byte-tokenizer-behavior-v1:" ++
    "one-token-per-input-byte;token-id=unsigned-byte;" ++
    "decode=token-id-as-byte;input-must-be-valid-utf8\x00";
const utf8_byte_raw_text_domain =
    "glacier-utf8-byte-tokenizer-raw-text-v1\x00";
const utf8_byte_token_stream_domain =
    "glacier-utf8-byte-tokenizer-token-stream-v1\x00";
const utf8_byte_prompt_domain =
    "glacier-utf8-byte-tokenizer-prompt-receipt-v1\x00";

const profile_utf8_byte_v1: u32 = 1;
const encoding_utf8: u32 = 1;
const normalization_none: u32 = 1;
const manifest_flags: u32 =
    (1 << 0) | // validates UTF-8 before allocation
    (1 << 1) | // token id equals the unsigned source byte
    (1 << 2) | // BOS/EOS/PAD insertion is disabled
    (1 << 3); // unsupported vocabulary/configuration rejects
const prompt_flags: u64 = 0;

pub const TokenizerError = error{
    VocabTooSmall,
    OutOfMemory,
};

pub const CanonicalError = error{
    InvalidLength,
    InvalidManifest,
    InvalidPrompt,
    UnsupportedVocabulary,
    InvalidLimit,
    EmptyInput,
    InputTooLarge,
    InvalidUtf8,
    InvalidToken,
    UnsafeDestination,
    OutOfMemory,
};

/// Fixed configuration for the only raw-text tokenizer profile currently
/// promoted into the prepared-text contract. The profile deliberately has no
/// implicit special tokens and no modulo fallback. Model vocabulary rows above
/// 255 remain unused by this tokenizer and are still part of the model
/// artifact identity.
pub const Utf8ByteManifestV1 = struct {
    abi_version: u64 = utf8_byte_manifest_abi,
    vocab_size: u32,
    max_input_bytes: u64,
    domain_sha256: Digest,
    behavior_sha256: Digest,
    config_sha256: Digest,
};

/// Canonical evidence that one exact UTF-8 byte string produced one exact
/// u32-token stream under a retained tokenizer manifest. The text and token
/// bytes are not embedded in the receipt.
pub const Utf8BytePromptReceiptV1 = struct {
    abi_version: u64 = utf8_byte_prompt_abi,
    tokenizer_domain_sha256: Digest,
    tokenizer_config_sha256: Digest,
    raw_text_sha256: Digest,
    token_ids_sha256: Digest,
    raw_text_bytes: u64,
    token_count: u64,
    receipt_sha256: Digest,
};

pub const Utf8ByteTokenizedPromptV1 = struct {
    allocator: std.mem.Allocator,
    manifest: Utf8ByteManifestV1,
    receipt: Utf8BytePromptReceiptV1,
    tokens: []u32,

    pub fn deinit(self: *Utf8ByteTokenizedPromptV1) void {
        self.allocator.free(self.tokens);
        self.* = undefined;
    }
};

pub fn utf8ByteDomainSha256V1() Digest {
    return sha256(utf8_byte_domain_descriptor);
}

pub fn utf8ByteBehaviorSha256V1() Digest {
    return sha256(utf8_byte_behavior_descriptor);
}

pub fn makeUtf8ByteManifestV1(
    vocab_size: u32,
    max_input_bytes: u64,
) CanonicalError!Utf8ByteManifestV1 {
    if (vocab_size < utf8_byte_token_count)
        return CanonicalError.UnsupportedVocabulary;
    if (max_input_bytes == 0 or
        max_input_bytes > utf8_byte_max_input_bytes)
        return CanonicalError.InvalidLimit;
    var value: Utf8ByteManifestV1 = .{
        .vocab_size = vocab_size,
        .max_input_bytes = max_input_bytes,
        .domain_sha256 = utf8ByteDomainSha256V1(),
        .behavior_sha256 = utf8ByteBehaviorSha256V1(),
        .config_sha256 = undefined,
    };
    var body: [utf8_byte_manifest_body_bytes]u8 = undefined;
    writeUtf8ByteManifestBodyV1(value, &body);
    value.config_sha256 = utf8ByteManifestRootV1(&body);
    return value;
}

pub fn utf8ByteManifestValidV1(
    value: Utf8ByteManifestV1,
) bool {
    if (value.abi_version != utf8_byte_manifest_abi or
        value.vocab_size < utf8_byte_token_count or
        value.max_input_bytes == 0 or
        value.max_input_bytes > utf8_byte_max_input_bytes or
        !digestEqual(
            value.domain_sha256,
            utf8ByteDomainSha256V1(),
        ) or
        !digestEqual(
            value.behavior_sha256,
            utf8ByteBehaviorSha256V1(),
        ))
        return false;
    var body: [utf8_byte_manifest_body_bytes]u8 = undefined;
    writeUtf8ByteManifestBodyV1(value, &body);
    return digestEqual(
        value.config_sha256,
        utf8ByteManifestRootV1(&body),
    );
}

pub fn encodeUtf8ByteManifestV1(
    value: Utf8ByteManifestV1,
    destination: []u8,
) CanonicalError![]u8 {
    if (destination.len != utf8_byte_manifest_bytes)
        return CanonicalError.InvalidLength;
    if (!utf8ByteManifestValidV1(value))
        return CanonicalError.InvalidManifest;
    var local: [utf8_byte_manifest_bytes]u8 = undefined;
    writeUtf8ByteManifestBodyV1(
        value,
        local[0..utf8_byte_manifest_body_bytes],
    );
    @memcpy(
        local[utf8_byte_manifest_body_bytes..],
        &value.config_sha256,
    );
    if (slicesOverlap(destination, &local))
        return CanonicalError.UnsafeDestination;
    @memcpy(destination, &local);
    return destination;
}

pub fn decodeUtf8ByteManifestV1(
    encoded: []const u8,
) CanonicalError!Utf8ByteManifestV1 {
    if (encoded.len != utf8_byte_manifest_bytes)
        return CanonicalError.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &utf8_byte_manifest_magic) or
        readU64(encoded, 8) != utf8_byte_manifest_abi or
        readU64(encoded, 16) != utf8_byte_manifest_bytes or
        readU32(encoded, 24) != profile_utf8_byte_v1 or
        readU32(encoded, 28) != encoding_utf8 or
        readU32(encoded, 32) != normalization_none or
        readU32(encoded, 36) != manifest_flags or
        readU32(encoded, 44) != 0 or
        readU32(encoded, 48) != utf8_byte_token_count or
        readU32(encoded, 52) != no_special_token or
        readU32(encoded, 56) != no_special_token or
        readU32(encoded, 60) != no_special_token or
        !allZero(encoded[136..utf8_byte_manifest_body_bytes]))
        return CanonicalError.InvalidManifest;
    const value: Utf8ByteManifestV1 = .{
        .vocab_size = readU32(encoded, 40),
        .max_input_bytes = readU64(encoded, 64),
        .domain_sha256 = encoded[72..104].*,
        .behavior_sha256 = encoded[104..136].*,
        .config_sha256 = encoded[utf8_byte_manifest_body_bytes..][0..32].*,
    };
    if (!utf8ByteManifestValidV1(value))
        return CanonicalError.InvalidManifest;
    return value;
}

pub fn tokenizeUtf8BytesV1(
    allocator: std.mem.Allocator,
    manifest: Utf8ByteManifestV1,
    text: []const u8,
) CanonicalError!Utf8ByteTokenizedPromptV1 {
    if (!utf8ByteManifestValidV1(manifest))
        return CanonicalError.InvalidManifest;
    if (text.len == 0) return CanonicalError.EmptyInput;
    if (text.len > manifest.max_input_bytes)
        return CanonicalError.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(text))
        return CanonicalError.InvalidUtf8;

    const tokens = allocator.alloc(u32, text.len) catch
        return CanonicalError.OutOfMemory;
    errdefer allocator.free(tokens);
    for (text, tokens) |byte, *token| token.* = byte;
    const raw_text_sha256 = utf8ByteRawTextRootV1(text);
    const token_ids_sha256 = utf8ByteTokenStreamRootV1(tokens);
    var receipt: Utf8BytePromptReceiptV1 = .{
        .tokenizer_domain_sha256 = manifest.domain_sha256,
        .tokenizer_config_sha256 = manifest.config_sha256,
        .raw_text_sha256 = raw_text_sha256,
        .token_ids_sha256 = token_ids_sha256,
        .raw_text_bytes = @intCast(text.len),
        .token_count = @intCast(tokens.len),
        .receipt_sha256 = undefined,
    };
    var body: [utf8_byte_prompt_body_bytes]u8 = undefined;
    writeUtf8BytePromptBodyV1(receipt, &body);
    receipt.receipt_sha256 = utf8BytePromptRootV1(&body);
    return .{
        .allocator = allocator,
        .manifest = manifest,
        .receipt = receipt,
        .tokens = tokens,
    };
}

/// Decode the exact inverse of the canonical profile. Unlike the compatibility
/// decoder, this path rejects special, wrapped, or out-of-byte-range tokens and
/// rejects a byte stream that is not valid UTF-8.
pub fn decodeUtf8BytesV1(
    allocator: std.mem.Allocator,
    manifest: Utf8ByteManifestV1,
    tokens: []const u32,
) CanonicalError![]u8 {
    if (!utf8ByteManifestValidV1(manifest))
        return CanonicalError.InvalidManifest;
    if (tokens.len == 0) return CanonicalError.EmptyInput;
    if (tokens.len > manifest.max_input_bytes)
        return CanonicalError.InputTooLarge;
    const bytes = allocator.alloc(u8, tokens.len) catch
        return CanonicalError.OutOfMemory;
    errdefer allocator.free(bytes);
    for (tokens, bytes) |token, *byte| {
        byte.* = std.math.cast(u8, token) orelse
            return CanonicalError.InvalidToken;
    }
    if (!std.unicode.utf8ValidateSlice(bytes))
        return CanonicalError.InvalidUtf8;
    return bytes;
}

pub fn utf8BytePromptValidForTokensV1(
    receipt: Utf8BytePromptReceiptV1,
    manifest: Utf8ByteManifestV1,
    text: []const u8,
    tokens: []const u32,
) bool {
    if (!utf8BytePromptStructurallyValidV1(receipt) or
        !utf8ByteManifestValidV1(manifest) or
        !std.unicode.utf8ValidateSlice(text) or
        text.len == 0 or
        text.len > manifest.max_input_bytes or
        receipt.raw_text_bytes != text.len or
        receipt.token_count != tokens.len or
        tokens.len != text.len or
        !digestEqual(
            receipt.tokenizer_domain_sha256,
            manifest.domain_sha256,
        ) or
        !digestEqual(
            receipt.tokenizer_config_sha256,
            manifest.config_sha256,
        ) or
        !digestEqual(
            receipt.raw_text_sha256,
            utf8ByteRawTextRootV1(text),
        ) or
        !digestEqual(
            receipt.token_ids_sha256,
            utf8ByteTokenStreamRootV1(tokens),
        ))
        return false;
    for (text, tokens) |byte, token| {
        if (token != byte) return false;
    }
    return true;
}

pub fn encodeUtf8BytePromptReceiptV1(
    value: Utf8BytePromptReceiptV1,
    destination: []u8,
) CanonicalError![]u8 {
    if (destination.len != utf8_byte_prompt_bytes)
        return CanonicalError.InvalidLength;
    if (!utf8BytePromptStructurallyValidV1(value))
        return CanonicalError.InvalidPrompt;
    var local: [utf8_byte_prompt_bytes]u8 = undefined;
    writeUtf8BytePromptBodyV1(
        value,
        local[0..utf8_byte_prompt_body_bytes],
    );
    @memcpy(
        local[utf8_byte_prompt_body_bytes..],
        &value.receipt_sha256,
    );
    if (slicesOverlap(destination, &local))
        return CanonicalError.UnsafeDestination;
    @memcpy(destination, &local);
    return destination;
}

pub fn decodeUtf8BytePromptReceiptV1(
    encoded: []const u8,
) CanonicalError!Utf8BytePromptReceiptV1 {
    if (encoded.len != utf8_byte_prompt_bytes)
        return CanonicalError.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &utf8_byte_prompt_magic) or
        readU64(encoded, 8) != utf8_byte_prompt_abi or
        readU64(encoded, 16) != utf8_byte_prompt_bytes or
        readU64(encoded, 24) != prompt_flags or
        !allZero(encoded[176..utf8_byte_prompt_body_bytes]))
        return CanonicalError.InvalidPrompt;
    const value: Utf8BytePromptReceiptV1 = .{
        .tokenizer_domain_sha256 = encoded[32..64].*,
        .tokenizer_config_sha256 = encoded[64..96].*,
        .raw_text_sha256 = encoded[96..128].*,
        .token_ids_sha256 = encoded[128..160].*,
        .raw_text_bytes = readU64(encoded, 160),
        .token_count = readU64(encoded, 168),
        .receipt_sha256 = encoded[utf8_byte_prompt_body_bytes..][0..32].*,
    };
    if (!utf8BytePromptStructurallyValidV1(value))
        return CanonicalError.InvalidPrompt;
    return value;
}

pub fn utf8ByteRawTextRootV1(text: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(utf8_byte_raw_text_domain);
    hashU64(&hash, @intCast(text.len));
    hash.update(text);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn utf8ByteTokenStreamRootV1(
    tokens: []const u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(utf8_byte_token_stream_domain);
    hashU64(&hash, @intCast(tokens.len));
    for (tokens) |token| hashU32(&hash, token);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn utf8ByteManifestRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(utf8_byte_manifest_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn utf8BytePromptRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(utf8_byte_prompt_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn utf8BytePromptStructurallyValidV1(
    value: Utf8BytePromptReceiptV1,
) bool {
    if (value.abi_version != utf8_byte_prompt_abi or
        value.raw_text_bytes == 0 or
        value.raw_text_bytes > utf8_byte_max_input_bytes or
        value.token_count != value.raw_text_bytes or
        !digestEqual(
            value.tokenizer_domain_sha256,
            utf8ByteDomainSha256V1(),
        ) or
        isZeroDigest(value.tokenizer_config_sha256) or
        isZeroDigest(value.raw_text_sha256) or
        isZeroDigest(value.token_ids_sha256))
        return false;
    var body: [utf8_byte_prompt_body_bytes]u8 = undefined;
    writeUtf8BytePromptBodyV1(value, &body);
    return digestEqual(
        value.receipt_sha256,
        utf8BytePromptRootV1(&body),
    );
}

fn writeUtf8ByteManifestBodyV1(
    value: Utf8ByteManifestV1,
    destination: []u8,
) void {
    std.debug.assert(
        destination.len == utf8_byte_manifest_body_bytes,
    );
    @memset(destination, 0);
    @memcpy(destination[0..8], &utf8_byte_manifest_magic);
    writeU64(destination, 8, utf8_byte_manifest_abi);
    writeU64(destination, 16, utf8_byte_manifest_bytes);
    writeU32(destination, 24, profile_utf8_byte_v1);
    writeU32(destination, 28, encoding_utf8);
    writeU32(destination, 32, normalization_none);
    writeU32(destination, 36, manifest_flags);
    writeU32(destination, 40, value.vocab_size);
    writeU32(destination, 44, 0);
    writeU32(destination, 48, utf8_byte_token_count);
    writeU32(destination, 52, no_special_token);
    writeU32(destination, 56, no_special_token);
    writeU32(destination, 60, no_special_token);
    writeU64(destination, 64, value.max_input_bytes);
    @memcpy(destination[72..104], &value.domain_sha256);
    @memcpy(destination[104..136], &value.behavior_sha256);
}

fn writeUtf8BytePromptBodyV1(
    value: Utf8BytePromptReceiptV1,
    destination: []u8,
) void {
    std.debug.assert(
        destination.len == utf8_byte_prompt_body_bytes,
    );
    @memset(destination, 0);
    @memcpy(destination[0..8], &utf8_byte_prompt_magic);
    writeU64(destination, 8, utf8_byte_prompt_abi);
    writeU64(destination, 16, utf8_byte_prompt_bytes);
    writeU64(destination, 24, prompt_flags);
    @memcpy(
        destination[32..64],
        &value.tokenizer_domain_sha256,
    );
    @memcpy(
        destination[64..96],
        &value.tokenizer_config_sha256,
    );
    @memcpy(destination[96..128], &value.raw_text_sha256);
    @memcpy(destination[128..160], &value.token_ids_sha256);
    writeU64(destination, 160, value.raw_text_bytes);
    writeU64(destination, 168, value.token_count);
}

fn sha256(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn writeU32(
    destination: []u8,
    offset: usize,
    value: u32,
) void {
    std.mem.writeInt(
        u32,
        destination[offset..][0..4],
        value,
        .little,
    );
}

fn writeU64(
    destination: []u8,
    offset: usize,
    value: u64,
) void {
    std.mem.writeInt(
        u64,
        destination[offset..][0..8],
        value,
        .little,
    );
}

fn readU32(source: []const u8, offset: usize) u32 {
    return std.mem.readInt(
        u32,
        source[offset..][0..4],
        .little,
    );
}

fn readU64(source: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        source[offset..][0..8],
        .little,
    );
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZeroDigest(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn slicesOverlap(
    left: []const u8,
    right: []const u8,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = left_start + left.len;
    const right_end = right_start + right.len;
    return left_start < right_end and right_start < left_end;
}

pub const ByteTokenizer = struct {
    /// Size of the model's vocabulary. Bytes map into [0, min(256, vocab)).
    vocab_size: u32,

    pub fn init(vocab_size: u32) ByteTokenizer {
        return .{ .vocab_size = vocab_size };
    }

    /// Encode text → token ids. Caller owns the returned slice. Optionally
    /// prepends BOS and appends EOS.
    pub fn encode(
        self: ByteTokenizer,
        allocator: std.mem.Allocator,
        text: []const u8,
        add_bos: bool,
        add_eos: bool,
    ) ![]u32 {
        var out: std.ArrayList(u32) = .{};
        defer out.deinit(allocator);
        if (add_bos) try out.append(allocator, BOS);
        for (text) |b| {
            // Map the byte into the vocab range. For vocab ≥ 256 this is
            // a pure byte→token identity; for smaller vocabs we wrap so
            // round-tripping still works for ASCII (collision only on
            // high-bit bytes, which the test fixture never sees).
            const tok: u32 = if (self.vocab_size >= 256)
                @intCast(b)
            else
                @as(u32, b) % self.vocab_size;
            try out.append(allocator, tok);
        }
        if (add_eos) try out.append(allocator, EOS);
        return out.toOwnedSlice(allocator);
    }

    /// Decode token ids → text. Bytes 0..255 map back to characters;
    /// special tokens are skipped. Caller owns the returned slice.
    pub fn decode(
        self: ByteTokenizer,
        allocator: std.mem.Allocator,
        tokens: []const u32,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);
        for (tokens) |t| {
            if (t == PAD or t == BOS or t == EOS) continue;
            const byte: u8 = if (self.vocab_size >= 256)
                @intCast(t & 0xFF)
            else
                @intCast(t % 256);
            try out.append(allocator, byte);
        }
        return out.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "byte round-trip preserves ASCII text" {
    const tz = ByteTokenizer.init(512);
    const text = "hello, glacier!";
    const ids = try tz.encode(testing.allocator, text, false, false);
    defer testing.allocator.free(ids);
    try testing.expectEqual(text.len, ids.len);
    // Each id is the byte value.
    try testing.expectEqual(@as(u32, 'h'), ids[0]);
    try testing.expectEqual(@as(u32, '!'), ids[text.len - 1]);

    const back = try tz.decode(testing.allocator, ids);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(text, back);
}

test "BOS/EOS are added when requested" {
    const tz = ByteTokenizer.init(512);
    const ids = try tz.encode(testing.allocator, "hi", true, true);
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 4), ids.len);
    try testing.expectEqual(BOS, ids[0]);
    try testing.expectEqual(@as(u32, 'h'), ids[1]);
    try testing.expectEqual(@as(u32, 'i'), ids[2]);
    try testing.expectEqual(EOS, ids[3]);
}

test "decode skips special tokens" {
    const tz = ByteTokenizer.init(512);
    const ids = [_]u32{ BOS, 'a', EOS, 'b', PAD };
    const back = try tz.decode(testing.allocator, &ids);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("ab", back);
}

test "small vocab wraps bytes modulo vocab_size" {
    // Fixture uses vocab=128. ASCII bytes < 128 should map to themselves.
    const tz = ByteTokenizer.init(128);
    const ids = try tz.encode(testing.allocator, "AB", false, false);
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(u32, 'A'), ids[0]);
    try testing.expectEqual(@as(u32, 'B'), ids[1]);
}

test "UTF-8 bytes survive round-trip" {
    const tz = ByteTokenizer.init(512);
    const text = "สวัสดี"; // Thai, multi-byte UTF-8
    const ids = try tz.encode(testing.allocator, text, false, false);
    defer testing.allocator.free(ids);
    try testing.expectEqual(text.len, ids.len); // 3 chars × ~3 bytes each
    const back = try tz.decode(testing.allocator, ids);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(text, back);
}

test "canonical UTF-8 byte tokenizer freezes manifest and prompt wires" {
    const manifest = try makeUtf8ByteManifestV1(512, 4096);
    try testing.expect(utf8ByteManifestValidV1(manifest));
    try testing.expectEqual(
        utf8ByteDomainSha256V1(),
        manifest.domain_sha256,
    );

    var manifest_wire: [utf8_byte_manifest_bytes]u8 = undefined;
    _ = try encodeUtf8ByteManifestV1(
        manifest,
        &manifest_wire,
    );
    const decoded_manifest =
        try decodeUtf8ByteManifestV1(&manifest_wire);
    try testing.expectEqualDeep(manifest, decoded_manifest);
    var expected_domain: Digest = undefined;
    var expected_config: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_domain,
        "96cdd6fe04e8717739f7a1dba92a30d9" ++
            "d80872a02fbd7a3e5c57d0125bd42ca9",
    );
    _ = try std.fmt.hexToBytes(
        &expected_config,
        "fb26676e591065fb5808f56b8f1ce047" ++
            "ba4dcb4e4b94b03a697011b576fdd3c9",
    );
    try testing.expectEqual(expected_domain, manifest.domain_sha256);
    try testing.expectEqual(expected_config, manifest.config_sha256);

    const text = "Glacier สวัสดี";
    var tokenized = try tokenizeUtf8BytesV1(
        testing.allocator,
        manifest,
        text,
    );
    defer tokenized.deinit();
    try testing.expectEqual(text.len, tokenized.tokens.len);
    for (text, tokenized.tokens) |byte, token| {
        try testing.expectEqual(@as(u32, byte), token);
    }
    try testing.expect(utf8BytePromptValidForTokensV1(
        tokenized.receipt,
        manifest,
        text,
        tokenized.tokens,
    ));
    const decoded_text = try decodeUtf8BytesV1(
        testing.allocator,
        manifest,
        tokenized.tokens,
    );
    defer testing.allocator.free(decoded_text);
    try testing.expectEqualStrings(text, decoded_text);

    var prompt_wire: [utf8_byte_prompt_bytes]u8 = undefined;
    _ = try encodeUtf8BytePromptReceiptV1(
        tokenized.receipt,
        &prompt_wire,
    );
    const decoded_receipt =
        try decodeUtf8BytePromptReceiptV1(&prompt_wire);
    try testing.expectEqualDeep(
        tokenized.receipt,
        decoded_receipt,
    );
    var expected_prompt_receipt: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_prompt_receipt,
        "4b4d165449392070e1f118bc6c638eb6" ++
            "9d9c6d31b264e494e70597d8f89934a4",
    );
    try testing.expectEqual(
        expected_prompt_receipt,
        tokenized.receipt.receipt_sha256,
    );

    for (manifest_wire, 0..) |_, index| {
        var mutated = manifest_wire;
        mutated[index] ^= 1;
        try testing.expectError(
            CanonicalError.InvalidManifest,
            decodeUtf8ByteManifestV1(&mutated),
        );
    }
    for (prompt_wire, 0..) |_, index| {
        var mutated = prompt_wire;
        mutated[index] ^= 1;
        try testing.expectError(
            CanonicalError.InvalidPrompt,
            decodeUtf8BytePromptReceiptV1(&mutated),
        );
    }
}

test "canonical UTF-8 byte tokenizer rejects fallback and malformed input" {
    try testing.expectError(
        CanonicalError.UnsupportedVocabulary,
        makeUtf8ByteManifestV1(255, 16),
    );
    try testing.expectError(
        CanonicalError.InvalidLimit,
        makeUtf8ByteManifestV1(256, 0),
    );
    try testing.expectError(
        CanonicalError.InvalidLimit,
        makeUtf8ByteManifestV1(
            256,
            utf8_byte_max_input_bytes + 1,
        ),
    );

    const manifest = try makeUtf8ByteManifestV1(256, 4);
    try testing.expectError(
        CanonicalError.EmptyInput,
        tokenizeUtf8BytesV1(
            testing.allocator,
            manifest,
            "",
        ),
    );
    try testing.expectError(
        CanonicalError.InputTooLarge,
        tokenizeUtf8BytesV1(
            testing.allocator,
            manifest,
            "12345",
        ),
    );
    const invalid_utf8 = [_]u8{ 0xc0, 0xaf };
    try testing.expectError(
        CanonicalError.InvalidUtf8,
        tokenizeUtf8BytesV1(
            testing.allocator,
            manifest,
            &invalid_utf8,
        ),
    );

    var tokenized = try tokenizeUtf8BytesV1(
        testing.allocator,
        manifest,
        "test",
    );
    defer tokenized.deinit();
    tokenized.tokens[2] = 256;
    try testing.expect(!utf8BytePromptValidForTokensV1(
        tokenized.receipt,
        manifest,
        "test",
        tokenized.tokens,
    ));
    try testing.expectError(
        CanonicalError.InvalidToken,
        decodeUtf8BytesV1(
            testing.allocator,
            manifest,
            tokenized.tokens,
        ),
    );
    try testing.expectError(
        CanonicalError.InvalidUtf8,
        decodeUtf8BytesV1(
            testing.allocator,
            manifest,
            &[_]u32{ 0xc0, 0xaf },
        ),
    );
}
