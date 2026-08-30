const std = @import("std");

pub const max_stream_descriptors: u8 = 30;

pub const DescriptorKind = enum(u8) {
    output,
    bidirectional,
};

pub const DescriptorSelection = struct {
    index: u8,
    total: u8,
    kind: DescriptorKind,
};

pub const PositionLayout = struct {
    bytes: u32,
    entry_offset: u16,
    lower_base: u32,
    upper_base: u32,
};

pub fn positionLayout(total: u8, index: u8, physical: u64, allocated_bytes: u32, dma_64bit: bool) ?PositionLayout {
    if (total == 0 or total > max_stream_descriptors or index >= total or physical == 0 or (physical & 0x7f) != 0) return null;
    const bytes: u32 = @as(u32, total) * 8;
    const span: u64 = @as(u64, bytes) - 1;
    if (allocated_bytes < bytes or physical > std.math.maxInt(u64) - span) return null;
    const last = physical + span;
    if (!dma_64bit and last > std.math.maxInt(u32)) return null;
    return .{
        .bytes = bytes,
        .entry_offset = @as(u16, index) * 8,
        .lower_base = @as(u32, @truncate(physical)) & 0xffff_ff80,
        .upper_base = @truncate(physical >> 32),
    };
}

/// HDA orders input, output and bidirectional descriptors in that order.
/// Prefer a dedicated output descriptor and use a bidirectional descriptor
/// only when its direction bit can make it an output stream.
pub fn selectDescriptor(input: u8, output: u8, bidirectional: u8, route_ready: bool, format_ready: bool) ?DescriptorSelection {
    if (!route_ready or !format_ready) return null;
    const total_wide: u16 = @as(u16, input) + output + bidirectional;
    if (total_wide == 0 or total_wide > max_stream_descriptors) return null;
    const total: u8 = @intCast(total_wide);
    if (output != 0) {
        if (input >= total) return null;
        return .{ .index = input, .total = total, .kind = .output };
    }
    if (bidirectional != 0) {
        const index_wide: u16 = @as(u16, input) + output;
        if (index_wide >= total) return null;
        return .{ .index = @intCast(index_wide), .total = total, .kind = .bidirectional };
    }
    return null;
}

pub const PositionSource = enum(u8) {
    dma,
    lpib,
};

pub const PositionDegradation = enum(u8) {
    none,
    dma_unavailable,
    dma_invalid,
    lpib_invalid,
    source_mismatch,
    both_invalid,
};

pub const PositionChoice = struct {
    valid: bool = false,
    position: u32 = 0,
    source: PositionSource = .lpib,
    degradation: PositionDegradation = .none,
};

/// Compact runtime label for the position source actually used after
/// plausibility checks.  A configured DMA buffer is not the same as an
/// active DMA source once repeated disagreement selected the LPIB fallback.
pub fn diagnosticPositionMode(dma_enabled: bool, dma_degraded: bool, source: PositionSource) []const u8 {
    if (!dma_enabled) return "lpib-only";
    if (dma_degraded) return "lpib-fallback";
    return if (source == .dma) "dma+lpib" else "lpib-transient";
}

fn validPosition(position: u32, cbl: u32) bool {
    return cbl != 0 and position < cbl;
}

fn circularDistance(a: u32, b: u32, cbl: u32) u32 {
    const forward = if (a >= b) a - b else cbl - b + a;
    const reverse = if (b >= a) b - a else cbl - a + b;
    return @min(forward, reverse);
}

/// Prefer the DMA position buffer when both sources agree within a bounded
/// read-skew.  Invalid, stale-divergent or explicitly disabled DMA data falls
/// back to LPIB.  Both sources outside CBL are an exact failure.
pub fn choosePosition(dma: ?u32, lpib: u32, cbl: u32, max_skew: u32, force_lpib: bool) PositionChoice {
    const lpib_valid = validPosition(lpib, cbl);
    if (force_lpib or dma == null) {
        if (!lpib_valid) return .{ .degradation = .both_invalid };
        return .{
            .valid = true,
            .position = lpib,
            .source = .lpib,
            .degradation = if (dma == null) .dma_unavailable else .dma_invalid,
        };
    }

    const dma_position = dma.?;
    const dma_valid = validPosition(dma_position, cbl);
    if (!dma_valid and !lpib_valid) return .{ .degradation = .both_invalid };
    if (!dma_valid) return .{ .valid = true, .position = lpib, .source = .lpib, .degradation = .dma_invalid };
    if (!lpib_valid) return .{ .valid = true, .position = dma_position, .source = .dma, .degradation = .lpib_invalid };
    if (circularDistance(dma_position, lpib, cbl) > max_skew) {
        return .{ .valid = true, .position = lpib, .source = .lpib, .degradation = .source_mismatch };
    }
    return .{ .valid = true, .position = dma_position, .source = .dma };
}

pub const ProgressFailure = enum(u8) {
    none,
    invalid_position,
    frozen,
    impossible_jump,
};

pub const Progress = struct {
    failure: ProgressFailure = .none,
    moved: bool = false,
    delta: u32 = 0,
};

pub const ProgressTracker = struct {
    initialized: bool = false,
    last_position: u32 = 0,
    last_observation_tick: u64 = 0,
    last_movement_tick: u64 = 0,

    pub fn reset(self: *ProgressTracker) void {
        self.* = .{};
    }

    /// Repeated observations update only the observation timestamp.  The
    /// freeze deadline is tied exclusively to actual byte movement.
    pub fn observe(self: *ProgressTracker, now: u64, position: u32, cbl: u32, max_advance: u32, freeze_ticks: u64) Progress {
        if (!validPosition(position, cbl)) return .{ .failure = .invalid_position };
        if (!self.initialized) {
            self.initialized = true;
            self.last_position = position;
            self.last_observation_tick = now;
            self.last_movement_tick = now;
            return .{};
        }

        self.last_observation_tick = now;
        const delta = if (position >= self.last_position)
            position - self.last_position
        else
            cbl - self.last_position + position;
        if (delta == 0) {
            if (now -| self.last_movement_tick >= freeze_ticks) return .{ .failure = .frozen };
            return .{};
        }
        if (delta > max_advance) return .{ .failure = .impossible_jump, .delta = delta };
        self.last_position = position;
        self.last_movement_tick = now;
        return .{ .moved = true, .delta = delta };
    }
};

pub fn maxPlausibleAdvance(elapsed_ticks: u64, frequency: u32, bytes_per_second: u32, tolerance: u32, cbl: u32) u32 {
    if (cbl <= 1) return 0;
    if (frequency == 0) return @min(cbl - 1, tolerance);
    const timed: u128 = (@as(u128, elapsed_ticks) * bytes_per_second) / frequency;
    const total: u128 = timed + tolerance;
    return @intCast(@min(@as(u128, cbl - 1), total));
}

test "descriptor selection prefers output then valid bidirectional fallback" {
    try std.testing.expectEqual(DescriptorSelection{ .index = 4, .total = 10, .kind = .output }, selectDescriptor(4, 4, 2, true, true).?);
    try std.testing.expectEqual(DescriptorSelection{ .index = 3, .total = 5, .kind = .bidirectional }, selectDescriptor(3, 0, 2, true, true).?);
    try std.testing.expectEqual(@as(?DescriptorSelection, null), selectDescriptor(3, 0, 0, true, true));
    try std.testing.expectEqual(@as(?DescriptorSelection, null), selectDescriptor(20, 15, 0, true, true));
    try std.testing.expectEqual(@as(?DescriptorSelection, null), selectDescriptor(1, 1, 0, false, true));
    try std.testing.expectEqual(@as(?DescriptorSelection, null), selectDescriptor(1, 1, 0, true, false));
}

test "position buffer layout enforces all index alignment size and address bounds" {
    try std.testing.expectEqual(PositionLayout{ .bytes = 64, .entry_offset = 32, .lower_base = 0x1000, .upper_base = 0 }, positionLayout(8, 4, 0x1000, 64, false).?);
    try std.testing.expectEqual(@as(?PositionLayout, null), positionLayout(31, 0, 0x1000, 248, true));
    try std.testing.expectEqual(@as(?PositionLayout, null), positionLayout(8, 8, 0x1000, 64, true));
    try std.testing.expectEqual(@as(?PositionLayout, null), positionLayout(8, 4, 0x1040, 64, true));
    try std.testing.expectEqual(@as(?PositionLayout, null), positionLayout(8, 4, 0x1000, 63, true));
    try std.testing.expectEqual(@as(?PositionLayout, null), positionLayout(30, 4, 0xffff_ff80, 240, false));
    try std.testing.expect(positionLayout(8, 4, 0x1_0000_0000, 64, true) != null);
}

test "DMA position and LPIB agree across wrap and degrade deterministically" {
    const cbl: u32 = 122_880;
    try std.testing.expectEqual(PositionChoice{ .valid = true, .position = 64, .source = .dma }, choosePosition(64, 96, cbl, 1920, false));
    try std.testing.expectEqual(PositionSource.dma, choosePosition(122_700, 100, cbl, 1920, false).source);
    try std.testing.expectEqual(PositionChoice{ .valid = true, .position = 10_000, .source = .lpib, .degradation = .source_mismatch }, choosePosition(0, 10_000, cbl, 1920, false));
    try std.testing.expectEqual(PositionDegradation.dma_invalid, choosePosition(cbl, 10, cbl, 1920, false).degradation);
    try std.testing.expectEqual(PositionDegradation.both_invalid, choosePosition(cbl, cbl, cbl, 1920, false).degradation);
    try std.testing.expectEqual(PositionDegradation.dma_unavailable, choosePosition(null, 10, cbl, 1920, false).degradation);
}

test "position diagnostic distinguishes configured DMA from active fallback" {
    try std.testing.expectEqualStrings("lpib-only", diagnosticPositionMode(false, false, .lpib));
    try std.testing.expectEqualStrings("dma+lpib", diagnosticPositionMode(true, false, .dma));
    try std.testing.expectEqualStrings("lpib-transient", diagnosticPositionMode(true, false, .lpib));
    try std.testing.expectEqualStrings("lpib-fallback", diagnosticPositionMode(true, true, .lpib));
}

test "status polling cannot mask freeze and wrap is real movement" {
    var tracker = ProgressTracker{};
    _ = tracker.observe(10, 120_000, 122_880, 10_000, 64);
    const wrap = tracker.observe(20, 1_000, 122_880, 10_000, 64);
    try std.testing.expect(wrap.moved);
    try std.testing.expectEqual(@as(u32, 3880), wrap.delta);
    try std.testing.expectEqual(ProgressFailure.none, tracker.observe(40, 1_000, 122_880, 10_000, 64).failure);
    try std.testing.expectEqual(ProgressFailure.frozen, tracker.observe(84, 1_000, 122_880, 10_000, 64).failure);
}

test "impossible jump is rejected without moving the progress baseline" {
    var tracker = ProgressTracker{};
    _ = tracker.observe(1, 100, 10_000, 1000, 100);
    const jump = tracker.observe(2, 9000, 10_000, 1000, 100);
    try std.testing.expectEqual(ProgressFailure.impossible_jump, jump.failure);
    try std.testing.expectEqual(@as(u32, 100), tracker.last_position);
    try std.testing.expectEqual(@as(u32, 200), maxPlausibleAdvance(1, 1000, 100_000, 100, 10_000));
}
