const std = @import("std");

/// Monotone timeout predicate shared by controller reset and command waits.
/// Saturating subtraction also keeps a stale or regressed observation from
/// being misclassified as an elapsed deadline.
pub fn expired(start_tick: u64, now_tick: u64, span_ticks: u64) bool {
    return now_tick -| start_tick >= span_ticks;
}

pub const Phase = enum {
    quiesce,
    assert_reset,
    hold_reset,
    release_reset,
    wait_codecs,
    ready,
    failed,
};

pub const Observation = struct {
    command_dma_stopped: bool = false,
    crst: bool = false,
    low_hold_elapsed: bool = false,
    codec_mask: u16 = 0,
    timed_out: bool = false,
};

/// Pure reset-lifecycle model used to keep the production sequence explicit:
/// command DMA is stopped even for a firmware-initialized controller, CRST is
/// asserted low, held, released and only then may STATESTS complete discovery.
pub fn advance(phase: Phase, observation: Observation) Phase {
    if (phase == .ready or phase == .failed) return phase;
    if (observation.timed_out) return .failed;
    return switch (phase) {
        .quiesce => if (observation.command_dma_stopped) .assert_reset else .quiesce,
        .assert_reset => if (!observation.crst) .hold_reset else .assert_reset,
        .hold_reset => if (observation.low_hold_elapsed) .release_reset else .hold_reset,
        .release_reset => if (observation.crst) .wait_codecs else .release_reset,
        .wait_codecs => if ((observation.codec_mask & 0x7FFF) != 0) .ready else .wait_codecs,
        .ready, .failed => unreachable,
    };
}

test "firmware-initialized controller still follows the complete reset lifecycle" {
    var phase: Phase = .quiesce;
    phase = advance(phase, .{ .command_dma_stopped = true, .crst = true });
    try std.testing.expectEqual(Phase.assert_reset, phase);
    phase = advance(phase, .{ .crst = false });
    try std.testing.expectEqual(Phase.hold_reset, phase);
    phase = advance(phase, .{ .low_hold_elapsed = true });
    try std.testing.expectEqual(Phase.release_reset, phase);
    phase = advance(phase, .{ .crst = true });
    try std.testing.expectEqual(Phase.wait_codecs, phase);
    phase = advance(phase, .{ .codec_mask = 0x0002 });
    try std.testing.expectEqual(Phase.ready, phase);
}

test "every blocked reset phase fails on its monotone timeout" {
    const blocked = [_]Phase{ .quiesce, .assert_reset, .hold_reset, .release_reset, .wait_codecs };
    for (blocked) |phase| try std.testing.expectEqual(Phase.failed, advance(phase, .{ .timed_out = true }));
}

test "timeout boundary and regressed observation are deterministic" {
    try std.testing.expect(!expired(100, 109, 10));
    try std.testing.expect(expired(100, 110, 10));
    try std.testing.expect(!expired(100, 99, 10));
}
