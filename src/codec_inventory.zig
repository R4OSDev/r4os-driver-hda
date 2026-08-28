const std = @import("std");

pub const max_codec_addresses: usize = 15;
pub const max_nodes: usize = 256;

pub const NodeRange = struct {
    start: u8,
    count: u8,
    end_exclusive: u16,
};

pub fn decodeNodeRange(parameter: u32) ?NodeRange {
    const start: u8 = @truncate((parameter >> 16) & 0xFF);
    const count: u8 = @truncate(parameter & 0xFF);
    const end = @as(u16, start) + @as(u16, count);
    if (end > max_nodes) return null;
    return .{ .start = start, .count = count, .end_exclusive = end };
}

pub fn codecPresent(mask: u16, address: u8) bool {
    if (address >= max_codec_addresses) return false;
    return (mask & (@as(u16, 1) << @intCast(address))) != 0;
}

pub fn collectCodecAddresses(mask: u16, out: *[max_codec_addresses]u8) u8 {
    var count: u8 = 0;
    var address: u8 = 0;
    while (address < max_codec_addresses) : (address += 1) {
        if (!codecPresent(mask, address)) continue;
        out[@intCast(count)] = address;
        count += 1;
    }
    return count;
}

pub fn appendAudioFunctionGroup(nodes: *[max_nodes]u8, count: *u16, node: u8) bool {
    if (count.* >= nodes.len) return false;
    nodes[count.*] = node;
    count.* += 1;
    return true;
}

test "all fifteen codec addresses are retained" {
    var addresses: [max_codec_addresses]u8 = undefined;
    const count = collectCodecAddresses(0x7FFF, &addresses);
    try std.testing.expectEqual(@as(u8, 15), count);
    try std.testing.expectEqual(@as(u8, 0), addresses[0]);
    try std.testing.expectEqual(@as(u8, 14), addresses[14]);
}

test "full eight-bit node range is legal and overflow is rejected" {
    const full = decodeNodeRange((@as(u32, 1) << 16) | 255).?;
    try std.testing.expectEqual(@as(u16, 256), full.end_exclusive);
    try std.testing.expectEqual(@as(?NodeRange, null), decodeNodeRange((@as(u32, 250) << 16) | 7));
}

test "sparse codec masks retain canonical address order" {
    var addresses: [max_codec_addresses]u8 = undefined;
    const count = collectCodecAddresses((1 << 0) | (1 << 7) | (1 << 14), &addresses);
    try std.testing.expectEqual(@as(u8, 3), count);
    try std.testing.expectEqualSlices(u8, &.{ 0, 7, 14 }, addresses[0..count]);
}

test "multiple audio function groups retain discovery order and capacity errors are visible" {
    var nodes: [max_nodes]u8 = undefined;
    var count: u16 = 0;
    try std.testing.expect(appendAudioFunctionGroup(&nodes, &count, 2));
    try std.testing.expect(appendAudioFunctionGroup(&nodes, &count, 9));
    try std.testing.expectEqualSlices(u8, &.{ 2, 9 }, nodes[0..count]);
    count = max_nodes;
    try std.testing.expect(!appendAudioFunctionGroup(&nodes, &count, 10));
}
