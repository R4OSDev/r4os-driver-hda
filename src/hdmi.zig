const std = @import("std");

// HDA 1.0a digital-display verbs and the ELD/CEA byte formats. These are
// protocol values, independent of a GPU's display-engine register layout.
pub const pin_cap_hdmi: u32 = 1 << 7;
pub const pin_cap_dp: u32 = 1 << 24;
pub const sense_present: u32 = 1 << 31;
pub const sense_eld_valid: u32 = 1 << 30;
pub const eld_byte_valid: u32 = 1 << 31;
pub const get_eld_size: u16 = 0xf2e;
pub const get_eld_byte: u16 = 0xf2f;
pub const max_eld_bytes = 256;

pub const Availability = enum(u8) {
    absent,
    waiting_for_eld,
    invalid_eld,
    unsupported,
    ready,
};

pub const Sink = struct {
    availability: Availability = .absent,
    name: [32]u8 = .{0} ** 32,
    name_len: u8 = 0,
    port_id: [8]u8 = .{0} ** 8,
    display_port: bool = false,
    baseline_bytes: u16 = 0,
    eld_fingerprint: u64 = 0,
    display_source: u64 = 0,
    display_receiver_sequence: u64 = 0,
    display_revision: u64 = 0,
    display_adapter: u32 = 0,
    display_connector: u32 = 0,
    display_head: u32 = 0,
    display_device_entry: u32 = 0,
};

pub fn isDisplayPin(widget_caps: u32, pin_caps: u32) bool {
    return (widget_caps & (1 << 9)) != 0 and
        (pin_caps & (pin_cap_hdmi | pin_cap_dp)) != 0 and
        (pin_caps & (1 << 4)) != 0;
}

/// Require an explicit LPCM SAD for the one supported wire format. A pin
/// count or a valid HDMI video mode alone is no evidence of an audio sink.
pub fn inspect(sense: u32, eld: []const u8) Sink {
    var result = Sink{};
    if ((sense & sense_present) == 0) return result;
    result.availability = .waiting_for_eld;
    if ((sense & sense_eld_valid) == 0) return result;
    result.availability = .invalid_eld;
    if (eld.len < 20 or eld.len > max_eld_bytes or (eld[0] >> 3) != 2) return result;
    const total = 4 + @as(usize, eld[2]) * 4;
    const name_len: usize = eld[4] & 31;
    const sad_count: usize = eld[5] >> 4;
    const connection = (eld[5] >> 2) & 3;
    if (total < 20 or total > eld.len or name_len > 16 or
        20 + name_len + sad_count * 3 > total or connection > 1) return result;
    result.baseline_bytes = @intCast(total);
    result.eld_fingerprint = std.hash.Wyhash.hash(0, eld[0..total]);
    result.display_port = connection == 1;
    @memcpy(&result.port_id, eld[8..16]);
    for (eld[20 .. 20 + name_len], 0..) |c, i| result.name[i] = if (c >= 32 and c < 127) c else '?';
    result.name_len = @intCast(name_len);
    result.availability = .unsupported;
    // This implementation supplies the HDMI Audio InfoFrame. DP uses a
    // different packet header and remains explicitly unavailable here.
    if (result.display_port) return result;
    for (0..sad_count) |i| {
        const sad = eld[20 + name_len + 3 * i ..][0..3];
        const format = (sad[0] >> 3) & 15;
        if (sad[0] & 128 != 0 or format == 0 or sad[1] == 0 or sad[1] & 128 != 0 or
            (format == 1 and (sad[2] & 7 == 0 or sad[2] & 0xf8 != 0))) {
            result.availability = .invalid_eld;
            return result;
        }
        if (((sad[0] >> 3) & 15) == 1 and (sad[0] & 7) >= 1 and
            (sad[1] & 4) != 0 and (sad[2] & 1) != 0)
        {
            result.availability = .ready;
        }
    }
    return result;
}

/// Hardware bytes must match the exact display-owner publication. This
/// never treats a GPU head as an HDA NID, nor a monitor name as an identity.
pub fn associate(sink: Sink, bytes: []const u8, route: anytype, ready: bool) Sink {
    var result = sink;
    if (!ready or route.source.generation == 0 or route.receiver_sequence == 0 or route.revision == 0 or
        route.eld_bytes != bytes.len or bytes.len > route.eld.len or
        !std.mem.eql(u8, &route.port_id, &sink.port_id) or !std.mem.eql(u8, bytes, route.eld[0..bytes.len])) {
        result.availability = .waiting_for_eld;
        return result;
    }
    result.display_source = route.source.generation;
    result.display_receiver_sequence = route.receiver_sequence;
    result.display_revision = route.revision;
    result.display_adapter = route.source.adapter_id;
    result.display_connector = route.connector_id;
    result.display_head = route.head_id;
    result.display_device_entry = route.device_entry;
    return result;
}

pub fn sameReceiver(left: Sink, right: Sink) bool {
    return left.availability == right.availability and left.eld_fingerprint == right.eld_fingerprint and
        std.mem.eql(u8, &left.port_id, &right.port_id) and left.display_source == right.display_source and
        left.display_receiver_sequence == right.display_receiver_sequence and left.display_revision == right.display_revision and
        left.display_adapter == right.display_adapter and left.display_connector == right.display_connector and
        left.display_head == right.display_head and left.display_device_entry == right.display_device_entry;
}
pub fn sameDisplayPort(left: Sink, right: Sink) bool {
    return left.display_source != 0 and left.display_connector != 0 and
        left.display_source == right.display_source and left.display_adapter == right.display_adapter and
        left.display_connector == right.display_connector and std.mem.eql(u8, &left.port_id, &right.port_id);
}

/// Stereo, front-left/front-right; frequency and sample size refer to the
/// PCM stream. The checksum covers the three header and eleven body bytes.
pub fn stereoInfoFrame() [14]u8 {
    var bytes = [_]u8{0} ** 14;
    bytes[0] = 0x84;
    bytes[1] = 1;
    bytes[2] = 10;
    bytes[4] = 1; // channel count minus one
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    bytes[3] = 0 -% sum;
    return bytes;
}

test "HDMI sink requires complete ELD and exact stereo PCM capabilities" {
    const present = sense_present | sense_eld_valid;
    var eld = [_]u8{0} ** 32;
    eld[0] = 2 << 3;
    eld[2] = 7;
    eld[4] = 4;
    eld[5] = 1 << 4;
    @memcpy(eld[20..24], "OSSI");
    @memcpy(eld[24..27], &[_]u8{ 9, 4, 1 });
    try std.testing.expectEqual(Availability.absent, inspect(0, &eld).availability);
    try std.testing.expectEqual(Availability.waiting_for_eld, inspect(sense_present, &eld).availability);
    const sink = inspect(present, &eld);
    try std.testing.expectEqual(Availability.ready, sink.availability);
    try std.testing.expectEqualStrings("OSSI", sink.name[0..sink.name_len]);
    try std.testing.expectEqual(Availability.invalid_eld, inspect(present, eld[0..26]).availability);
    eld[25] = 2; // 44.1 kHz only
    try std.testing.expectEqual(Availability.unsupported, inspect(present, &eld).availability);
    eld[25] = 4;
    eld[26] = 4; // 24-bit only
    try std.testing.expectEqual(Availability.unsupported, inspect(present, &eld).availability);
    eld[26] = 1;
    eld[5] |= 4; // DisplayPort packet format is not HDMI.
    try std.testing.expectEqual(Availability.unsupported, inspect(present, &eld).availability);
    eld[4] = 31;
    try std.testing.expectEqual(Availability.invalid_eld, inspect(present, &eld).availability);
    eld[4] = 4; eld[5] = 2 << 4; eld[2] = 7;
    @memcpy(eld[27..30], &[_]u8{ 0x89, 4, 1 }); // Invalid later SAD must not hide behind the first supported one.
    try std.testing.expectEqual(Availability.invalid_eld, inspect(present, &eld).availability);
    eld[5] = 1 << 4; @memset(eld[27..30], 0);
    const plain = inspect(present, &eld);
    var route = struct {
        source: struct { generation: u64 = 8, adapter_id: u32 = 9 } = .{},
        receiver_sequence: u64 = 2, revision: u64 = 3, connector_id: u32 = 4,
        head_id: u32 = 2, device_entry: u32 = 0, eld_bytes: u32 = 32,
        port_id: [8]u8 = @splat(0), eld: [32]u8,
    }{ .eld = eld };
    const bound = associate(plain, &eld, route, true);
    try std.testing.expect(bound.availability == .ready and bound.display_connector == 4 and bound.display_head == 2 and bound.display_device_entry == 0);
    try std.testing.expect(!sameReceiver(plain, bound));
    try std.testing.expect(associate(plain, &eld, route, false).availability == .waiting_for_eld);
    route.revision += 1;
    const newer = associate(plain, &eld, route, true);
    try std.testing.expect(!sameReceiver(bound, newer) and sameDisplayPort(bound, newer));
    route.eld[25] = 2;
    try std.testing.expect(associate(plain, &eld, route, true).availability == .waiting_for_eld);
}

test "HDMI stereo infoframe carries stereo allocation and valid checksum" {
    const bytes = stereoInfoFrame();
    try std.testing.expectEqual(@as(u8, 1), bytes[4]);
    try std.testing.expectEqual(@as(u8, 0), bytes[7]);
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    try std.testing.expectEqual(@as(u8, 0), sum);
}
