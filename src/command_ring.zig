const std = @import("std");

pub const RingSize = struct {
    entries: u16,
    selector: u8,
};

/// CORBSIZE/RIRBSIZE advertise 2, 16 and 256 entries in bits 4, 5 and 6.
/// Prefer the largest common size so pointer wrap remains a power-of-two
/// operation, but reject a register that advertises no legal size.
pub fn chooseSize(size_register: u8) ?RingSize {
    if ((size_register & 0x40) != 0) return .{ .entries = 256, .selector = 2 };
    if ((size_register & 0x20) != 0) return .{ .entries = 16, .selector = 1 };
    if ((size_register & 0x10) != 0) return .{ .entries = 2, .selector = 0 };
    return null;
}

pub fn next(pointer: u16, entries: u16) u16 {
    if (entries == 0) return 0;
    return (pointer + 1) % entries;
}

pub fn normalize(pointer: u16, entries: u16) u16 {
    if (entries == 0) return 0;
    return pointer % entries;
}

pub fn isFull(write_pointer: u16, read_pointer: u16, entries: u16) bool {
    return next(write_pointer, entries) == read_pointer % entries;
}

pub const Response = struct {
    value: u32,
    codec: u8,
    unsolicited: bool,
};

pub fn decodeResponse(value: u32, extended: u32) Response {
    return .{
        .value = value,
        .codec = @truncate(extended & 0x0F),
        .unsolicited = (extended & 0x10) != 0,
    };
}

pub fn isMatchingSolicited(response: Response, codec: u8) bool {
    return !response.unsolicited and response.codec == (codec & 0x0F);
}

/// Immediate Commands are a diagnostic escape hatch, not an automatic
/// replacement for a failed regular transport. A caller must opt in.
pub fn useImmediateFallback(corb_ready: bool, immediate_enabled: bool) bool {
    return !corb_ready and immediate_enabled;
}

test "ring size negotiation prefers largest supported size" {
    try std.testing.expectEqual(@as(u16, 256), chooseSize(0x70).?.entries);
    try std.testing.expectEqual(@as(u8, 1), chooseSize(0x20).?.selector);
    try std.testing.expectEqual(@as(u16, 2), chooseSize(0x10).?.entries);
    try std.testing.expectEqual(@as(?RingSize, null), chooseSize(0));
}

test "pointer wrap and full detection are bounded" {
    try std.testing.expectEqual(@as(u16, 0), next(255, 256));
    try std.testing.expectEqual(@as(u16, 1), normalize(257, 256));
    try std.testing.expectEqual(@as(u16, 15), normalize(255, 16));
    try std.testing.expect(isFull(15, 0, 16));
    try std.testing.expect(!isFull(14, 0, 16));
}

test "response matching rejects unsolicited and wrong codec entries" {
    const solicited = decodeResponse(0x1234, 0x0000_0002);
    try std.testing.expect(isMatchingSolicited(solicited, 2));
    try std.testing.expect(!isMatchingSolicited(solicited, 1));
    try std.testing.expect(!isMatchingSolicited(decodeResponse(0x1234, 0x12), 2));
}

test "Immediate fallback requires explicit opt in" {
    try std.testing.expect(!useImmediateFallback(false, false));
    try std.testing.expect(useImmediateFallback(false, true));
    try std.testing.expect(!useImmediateFallback(true, true));
}
