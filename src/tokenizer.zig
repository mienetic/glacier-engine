//! Byte-level tokenizer.
//!
//! The simplest tokenizer that still works on arbitrary text: every input
//! byte maps to one token id in [0, 255]. This sidesteps BPE/unigram
//! training entirely and lets the engine accept UTF-8 text without a
//! vocabulary file. The trade-off is that sequence lengths are 2-4×
//! longer than a real subword tokenizer would produce, which hurts
//! generation speed — but for an MVP that needs to prove the *plumbing*
//! works end-to-end, byte-level is the right choice.
//!
//! Special tokens live above 0xFF so they never collide with byte tokens.
//!   - 256: padding (not emitted by encode, used by batched callers)
//!   - 257: BOS (start of sequence)
//!   - 258: EOS (end of sequence, stops generation)
//!
//! When the model's vocab_size is larger than 256+specials, the extra ids
//! are simply unused by this tokenizer. When it is smaller (the test
//! fixture uses vocab=128), encode() falls back to mapping each byte
//! mod vocab_size so round-tripping still works for ASCII.

const std = @import("std");

pub const PAD: u32 = 256;
pub const BOS: u32 = 257;
pub const EOS: u32 = 258;

pub const TokenizerError = error{
    VocabTooSmall,
    OutOfMemory,
};

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
