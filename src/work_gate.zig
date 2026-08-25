const std = @import("std");

pub const Finish = enum {
    stop,
    resubmit,
};

/// Releases the current worker's pending claim after exactly one bounded pass.
/// A changed generation asks the caller for a successor submission; an IRQ
/// racing after the release can claim that successor itself.
pub fn finishPass(pending: *bool, generation: *u64, observed_generation: u64, shutting_down: *bool) Finish {
    @atomicStore(bool, pending, false, .release);
    if (@atomicLoad(bool, shutting_down, .acquire)) return .stop;
    if (@atomicLoad(u64, generation, .acquire) == observed_generation) return .stop;
    return .resubmit;
}

test "finish pass preserves changed generation ownership" {
    var pending = true;
    var generation: u64 = 7;
    var shutting_down = false;

    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down));
    try std.testing.expect(!pending);

    pending = true;
    generation = 8;
    try std.testing.expectEqual(Finish.resubmit, finishPass(&pending, &generation, 7, &shutting_down));
    try std.testing.expect(!pending);

    // Simulate an IRQ claiming the successor after this pass released it.
    try std.testing.expect(!@atomicRmw(bool, &pending, .Xchg, true, .acq_rel));
    try std.testing.expect(pending);

    shutting_down = true;
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down));
    try std.testing.expect(!pending);
}
