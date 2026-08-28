const std = @import("std");

/// Bounded evidence collected while probing one PCI HDA function.  The
/// policy deliberately does not contain vendor IDs: a controller is useful
/// because it exposes a complete, commandable analog output inventory, not
/// because its PCI function happened to be enumerated first.
pub const Evidence = struct {
    inventory_index: u32 = 0,
    transport_ready: bool = false,
    discovery_complete: bool = false,
    codec_count: u8 = 0,
    output_converters: u16 = 0,
    analog_output_pins: u16 = 0,
    digital_output_pins: u16 = 0,
    route_ready: bool = false,

    pub fn viable(self: Evidence) bool {
        return self.transport_ready and
            self.discovery_complete and
            self.codec_count != 0 and
            self.output_converters != 0 and
            self.analog_output_pins != 0 and
            self.route_ready;
    }
};

/// Prefer the candidate with the strongest analog evidence.  Ties retain
/// the canonical PCI inventory order so selection remains deterministic.
pub fn prefer(candidate: Evidence, current: ?Evidence) bool {
    if (!candidate.viable()) return false;
    const best = current orelse return true;
    if (!best.viable()) return true;
    if (candidate.analog_output_pins != best.analog_output_pins) {
        return candidate.analog_output_pins > best.analog_output_pins;
    }
    if (candidate.output_converters != best.output_converters) {
        return candidate.output_converters > best.output_converters;
    }
    if (candidate.codec_count != best.codec_count) {
        return candidate.codec_count > best.codec_count;
    }
    return candidate.inventory_index < best.inventory_index;
}

pub fn select(evidence: []const Evidence) ?usize {
    var best_index: ?usize = null;
    var best: ?Evidence = null;
    for (evidence, 0..) |candidate, index| {
        if (!prefer(candidate, best)) continue;
        best = candidate;
        best_index = index;
    }
    return best_index;
}

test "later analog controller wins over first HDMI-only function" {
    const candidates = [_]Evidence{
        .{
            .inventory_index = 3,
            .transport_ready = true,
            .discovery_complete = true,
            .codec_count = 1,
            .output_converters = 1,
            .digital_output_pins = 3,
        },
        .{
            .inventory_index = 7,
            .transport_ready = true,
            .discovery_complete = true,
            .codec_count = 1,
            .output_converters = 2,
            .analog_output_pins = 2,
            .route_ready = true,
        },
    };
    try std.testing.expectEqual(@as(?usize, 1), select(&candidates));
}

test "Lenovo L340 dual-controller identities select the later analog function" {
    const PciCandidate = struct {
        vendor_id: u16,
        device_id: u16,
        evidence: Evidence,
    };
    const lenovo = [_]PciCandidate{
        .{
            .vendor_id = 0x1002,
            .device_id = 0x15DE,
            .evidence = .{ .inventory_index = 3, .transport_ready = true, .discovery_complete = true, .codec_count = 1, .output_converters = 1, .digital_output_pins = 3 },
        },
        .{
            .vendor_id = 0x1022,
            .device_id = 0x15E3,
            .evidence = .{ .inventory_index = 7, .transport_ready = true, .discovery_complete = true, .codec_count = 1, .output_converters = 2, .analog_output_pins = 2, .route_ready = true },
        },
    };
    const evidence = [_]Evidence{ lenovo[0].evidence, lenovo[1].evidence };
    const selected = select(&evidence).?;
    try std.testing.expectEqual(@as(usize, 1), selected);
    try std.testing.expectEqual(@as(u16, 0x1022), lenovo[selected].vendor_id);
    try std.testing.expectEqual(@as(u16, 0x15E3), lenovo[selected].device_id);
}

test "incomplete or uncommandable candidates fail closed" {
    const candidates = [_]Evidence{
        .{ .inventory_index = 1, .discovery_complete = true, .codec_count = 1, .output_converters = 1, .analog_output_pins = 1, .route_ready = true },
        .{ .inventory_index = 2, .transport_ready = true, .codec_count = 1, .output_converters = 1, .analog_output_pins = 1, .route_ready = true },
        .{ .inventory_index = 3, .transport_ready = true, .discovery_complete = true, .codec_count = 1, .digital_output_pins = 1 },
    };
    try std.testing.expectEqual(@as(?usize, null), select(&candidates));
}

test "analog inventory without a proven route is not viable" {
    const candidate = Evidence{
        .inventory_index = 1,
        .transport_ready = true,
        .discovery_complete = true,
        .codec_count = 1,
        .output_converters = 2,
        .analog_output_pins = 2,
    };
    try std.testing.expect(!candidate.viable());
}

test "ties keep canonical inventory order" {
    const candidates = [_]Evidence{
        .{ .inventory_index = 9, .transport_ready = true, .discovery_complete = true, .codec_count = 1, .output_converters = 1, .analog_output_pins = 1, .route_ready = true },
        .{ .inventory_index = 4, .transport_ready = true, .discovery_complete = true, .codec_count = 1, .output_converters = 1, .analog_output_pins = 1, .route_ready = true },
    };
    try std.testing.expectEqual(@as(?usize, 1), select(&candidates));
}
