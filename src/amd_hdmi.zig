// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! AMD revision-3 display-codec protocol. Validate the narrow source-published
//! stereo format through physical vendor verbs; there is no standard ELD RAM.
const std = @import("std");
pub const set_sink_index: u16 = 0x780;
pub const get_sink_data: u16 = 0xf81;
pub const set_descriptor: u16 = 0x776;
pub const get_descriptor: u16 = 0xf76;
pub const get_speakers: u16 = 0xf70;
pub const get_latency: u16 = 0xf7b;
pub const set_allocation: u16 = 0x771;
pub const set_downmix: u16 = 0x772;
pub const set_remap: u16 = 0x789;
pub const set_ramp: u16 = 0x770;
pub const set_hbr: u16 = 0x77c;
pub const get_hbr: u16 = 0xf7c;
pub fn supported(vendor: u32, revision: u32) bool {
    return vendor == 0x1002aa01 and (revision & 0xff00) >= 0x0300;
}
pub fn slotVerb(slot: u3) u16 {
    return (@as(u16, slot) / 2) + (if (slot & 1 == 0) @as(u16, 0x777) else 0x785);
}
pub fn slotValue(slot: u3, enabled: bool) u8 {
    return if (enabled and slot < 2) (@as(u8, slot) << 4) | 1 else 0;
}
/// The source implements one SAD, not an invented union of receiver formats.
/// The full physical port, name, manufacturer, product, PCM descriptor and
/// lip-sync data must agree before using the copied route as canonical ELD.
pub fn verify(reader: anytype, bytes: []const u8) bool {
    if (bytes.len < 24 or bytes.len > 40 or bytes.len % 4 != 0 or bytes[0] != 16 or
        4 + @as(usize, bytes[2]) * 4 != bytes.len or bytes[5] >> 4 != 1 or bytes[5] & 0x0c != 0 or bytes[7] != 1) return false;
    const name: usize = bytes[4] & 31;
    if (name > 16 or 23 + name > bytes.len or !std.mem.eql(u8, bytes[20 + name ..][0..3], &.{ 9, 4, 1 })) return false;
    const speaker = reader.verb(get_speakers, 0) orelse return false;
    if (speaker & 0x37f != 0x101) return false;
    const fields = [_]struct { index: u8, value: u32 }{
        .{ .index = 0, .value = std.mem.readInt(u16, bytes[16..18], .little) },
        .{ .index = 1, .value = std.mem.readInt(u16, bytes[18..20], .little) },
        .{ .index = 2, .value = @intCast(name) },
        .{ .index = 3, .value = std.mem.readInt(u32, bytes[8..12], .little) },
        .{ .index = 4, .value = std.mem.readInt(u32, bytes[12..16], .little) },
    };
    for (fields) |field| {
        _ = reader.verb(set_sink_index, field.index) orelse return false;
        if ((reader.verb(get_sink_data, 0) orelse return false) != field.value) return false;
    }
    for (bytes[20..][0..name], 0..) |byte, i| {
        _ = reader.verb(set_sink_index, @intCast(5 + i)) orelse return false;
        if ((reader.verb(get_sink_data, 0) orelse return false) != byte) return false;
    }
    _ = reader.verb(set_descriptor, 8) orelse return false;
    if ((reader.verb(get_descriptor, 0) orelse return false) != 0x04010409) return false;
    const latency = reader.verb(get_latency, 0) orelse return false;
    const expected: u32 = if (bytes[6] == 0) 0 else (@as(u32, bytes[6]) + 1) | 0x100;
    return latency & 0xffff == expected;
}

/// Vendor SET/GET pairs must confirm the selected channel layout. A command
/// response alone cannot prove that the codec accepted a programmed value.
pub fn program(reader: anytype, command: u16, value: u8) bool {
    _ = reader.verb(command, value) orelse return false;
    const actual = reader.verb(command | 0x800, 0) orelse return false;
    return actual & 0xff == value;
}
pub fn pcmMode(reader: anytype) bool {
    const previous = reader.verb(get_hbr, 0) orelse return false;
    if (previous & 0x10 == 0) return true;
    _ = reader.verb(set_hbr, @truncate(previous & ~@as(u32, 0x10))) orelse return false;
    const actual = reader.verb(get_hbr, 0) orelse return false;
    return actual & 0x10 == 0;
}
