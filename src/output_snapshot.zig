const std = @import("std");
const hdmi = @import("hdmi.zig");

pub const capacity = 32;

/// Actual publication/route transition identity. Exhaustion is terminal for
/// catalog capture; an old generation is never reused after an ABA change.
pub const CatalogEpoch = struct {
    value: u64 = 1,
    pub fn advance(self: *CatalogEpoch) void {
        var observed = @atomicLoad(u64, &self.value, .acquire);
        while (observed != std.math.maxInt(u64)) {
            observed = @cmpxchgWeak(u64, &self.value, observed, observed + 1, .acq_rel, .acquire) orelse return;
        }
    }
    pub fn current(self: *const CatalogEpoch) ?u64 {
        const value = @atomicLoad(u64, &self.value, .acquire);
        return if (value == std.math.maxInt(u64)) null else value;
    }
};

/// Codec control owns observations. Only a complete checked value is copied
/// into the published catalog under the stream owner. Keeping raw evidence
/// separate prevents one ambiguous pin's publication from erasing the other.
pub const Snapshot = struct {
    sinks: [capacity]hdmi.Sink = .{hdmi.Sink{}} ** capacity,
    generation: u64 = 1,

    pub fn observe(self: *Snapshot, index: usize, sink: hdmi.Sink) void {
        std.debug.assert(index < capacity);
        self.sinks[index] = sink;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }

    pub fn checked(self: *const Snapshot, index: usize, count: usize) hdmi.Sink {
        std.debug.assert(index < count and count <= capacity);
        var sink = self.sinks[index];
        if (sink.availability != .ready) return sink;
        for (self.sinks[0..count], 0..) |other, i| {
            if (i != index and other.availability == .ready and hdmi.sameDisplayPort(sink, other)) {
                sink.availability = .invalid_eld;
                break;
            }
        }
        return sink;
    }
};

pub fn invalidates(selected: hdmi.Sink, observed: hdmi.Sink) bool {
    return observed.availability != .ready or !hdmi.sameReceiver(selected, observed);
}

test "publication rejects stale receiver and every display identity generation" {
    const selected = hdmi.Sink{ .availability = .ready, .eld_fingerprint = 17, .display_source = 2, .display_receiver_sequence = 3, .display_revision = 4, .display_adapter = 5, .display_connector = 6, .display_head = 7, .display_device_entry = 8 };
    try std.testing.expect(!invalidates(selected, selected));
    inline for (.{ "eld_fingerprint", "display_source", "display_receiver_sequence", "display_revision", "display_adapter", "display_connector", "display_head", "display_device_entry" }) |field| {
        var changed = selected;
        @field(changed, field) += 1;
        try std.testing.expect(invalidates(selected, changed));
    }
    var changed = selected;
    changed.port_id[0] = 1;
    try std.testing.expect(invalidates(selected, changed));
    inline for (.{ hdmi.Availability.absent, .waiting_for_eld, .invalid_eld, .unsupported }) |availability| {
        changed = selected;
        changed.availability = availability;
        try std.testing.expect(invalidates(selected, changed));
    }
}

test "ambiguous pins retain raw evidence until the conflicting pin really changes" {
    var epoch: CatalogEpoch = .{};
    try std.testing.expectEqual(@as(u64, 1), epoch.current().?);
    epoch.advance();
    epoch.advance(); // A -> B -> A still has a different publication identity.
    try std.testing.expectEqual(@as(u64, 3), epoch.current().?);
    epoch.value = std.math.maxInt(u64) - 1;
    epoch.advance();
    epoch.advance();
    try std.testing.expectEqual(null, epoch.current());
    var snapshot = Snapshot{};
    const ready = hdmi.Sink{ .availability = .ready, .display_source = 2, .display_connector = 3 };
    snapshot.observe(0, ready);
    snapshot.observe(1, ready);
    try std.testing.expectEqual(hdmi.Availability.invalid_eld, snapshot.checked(0, 2).availability);
    try std.testing.expectEqual(hdmi.Availability.invalid_eld, snapshot.checked(1, 2).availability);
    snapshot.observe(0, ready);
    try std.testing.expectEqual(hdmi.Availability.invalid_eld, snapshot.checked(0, 2).availability);
    snapshot.observe(1, .{ .availability = .absent });
    try std.testing.expectEqual(hdmi.Availability.ready, snapshot.checked(0, 2).availability);
    snapshot.generation = ~@as(u64, 0);
    snapshot.observe(1, .{ .availability = .invalid_eld });
    try std.testing.expectEqual(@as(u64, 1), snapshot.generation);
}
