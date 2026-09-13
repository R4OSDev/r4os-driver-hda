const std = @import("std");

pub const Finish = enum {
    stop,
    resubmit,
};

pub fn maySchedule(shutting_down: *const bool, synchronous_stop: *const bool) bool {
    return !@atomicLoad(bool, shutting_down, .acquire) and
        !@atomicLoad(bool, synchronous_stop, .acquire);
}

/// Releases the current worker's pending claim after exactly one bounded pass.
/// An unfinished pass or changed generation asks for a successor; an IRQ
/// racing after the release can claim that successor itself.
/// Synchronous stop owns progress until DMA stops, so neither an IRQ nor a
/// contended worker may enqueue a competing successor during that interval.
pub fn finishPass(pending: *bool, generation: *u64, observed_generation: u64, shutting_down: *bool, synchronous_stop: *bool, completed: bool) Finish {
    @atomicStore(bool, pending, false, .release);
    if (!maySchedule(shutting_down, synchronous_stop)) return .stop;
    if (!completed) return .resubmit;
    if (@atomicLoad(u64, generation, .acquire) == observed_generation) return .stop;
    return .resubmit;
}

test "finish pass preserves changed generation ownership" {
    var pending = true;
    var generation: u64 = 7;
    var shutting_down = false;
    var synchronous_stop = false;

    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, true));
    try std.testing.expect(!pending);

    pending = true;
    try std.testing.expectEqual(Finish.resubmit, finishPass(&pending, &generation, generation, &shutting_down, &synchronous_stop, false));
    try std.testing.expect(!pending);

    pending = true;
    generation = 8;
    try std.testing.expectEqual(Finish.resubmit, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, true));
    try std.testing.expect(!pending);

    // Simulate an IRQ claiming the successor after this pass released it.
    try std.testing.expect(!@atomicRmw(bool, &pending, .Xchg, true, .acq_rel));
    try std.testing.expect(pending);

    // Drain holds the stream lock across waits and consumes DMA progress
    // itself. A failed worker pass and fresh IRQs must not spin a successor.
    synchronous_stop = true;
    try std.testing.expect(!maySchedule(&shutting_down, &synchronous_stop));
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, false));
    try std.testing.expect(!pending);
    generation += 1;
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, true));
    synchronous_stop = false;
    try std.testing.expect(maySchedule(&shutting_down, &synchronous_stop));
    try std.testing.expectEqual(Finish.resubmit, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, false));

    shutting_down = true;
    try std.testing.expect(!maySchedule(&shutting_down, &synchronous_stop));
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, true));
    try std.testing.expect(!pending);
}
