const std = @import("std");

pub const Finish = enum {
    stop,
    reclaimed,
    delegated,
};

/// Releases the current worker's pending claim without losing an IRQ that
/// arrived during its pass. A changed generation is either reclaimed by this
/// worker or already owned by a newly submitted worker.
pub fn finishPass(pending: *bool, generation: *u64, observed_generation: u64, shutting_down: *bool) Finish {
    @atomicStore(bool, pending, false, .release);
    if (@atomicLoad(bool, shutting_down, .acquire)) return .stop;
    if (@atomicLoad(u64, generation, .acquire) == observed_generation) return .stop;
    return claimChanged(pending);
}

pub fn claimChanged(pending: *bool) Finish {
    return if (!@atomicRmw(bool, pending, .Xchg, true, .acq_rel)) .reclaimed else .delegated;
}

test "finish pass preserves changed generation ownership" {
    var pending = true;
    var generation: u64 = 7;
    var shutting_down = false;

    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down));
    try std.testing.expect(!pending);

    pending = true;
    generation = 8;
    try std.testing.expectEqual(Finish.reclaimed, finishPass(&pending, &generation, 7, &shutting_down));
    try std.testing.expect(pending);

    // Simulate the claim point after an IRQ already submitted the successor.
    pending = true;
    try std.testing.expectEqual(Finish.delegated, claimChanged(&pending));
    try std.testing.expect(pending);

    shutting_down = true;
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down));
    try std.testing.expect(!pending);
}
