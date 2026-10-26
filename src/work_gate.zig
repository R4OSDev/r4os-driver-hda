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
/// A changed generation asks for a successor; an IRQ
/// racing after the release can claim that successor itself.
/// Synchronous stop owns progress until DMA stops, so neither an IRQ nor a
/// contended worker may enqueue a competing successor during that interval.
pub fn finishPass(pending: *bool, generation: *u64, observed_generation: u64, shutting_down: *bool, synchronous_stop: *bool, completed: bool) Finish {
    @atomicStore(bool, pending, false, .release);
    if (!maySchedule(shutting_down, synchronous_stop)) return .stop;
    if (!completed) return .stop;
    if (@atomicLoad(u64, generation, .acquire) == observed_generation) return .stop;
    return .resubmit;
}

/// The waiter is installed before dropping pending. An unlock that encounters
/// pending still set leaves the waiter intact; the final owner recheck closes
/// the unlock-before-pending-release race. There is no retry without an actual
/// owner release or IRQ generation change.
pub fn parkContended(pending: *bool, waiting: *bool, owner: *const bool, generation: *const u64, observed: u64, shutting_down: *const bool, synchronous_stop: *const bool) Finish {
    @atomicStore(bool, waiting, true, .release);
    @atomicStore(bool, pending, false, .release);
    if (!maySchedule(shutting_down, synchronous_stop)) return .stop;
    if (!@atomicLoad(bool, owner, .acquire) or @atomicLoad(u64, generation, .acquire) != observed)
        return .resubmit;
    return .stop;
}

test "finish pass preserves changed generation ownership" {
    var pending = true;
    var generation: u64 = 7;
    var shutting_down = false;
    var synchronous_stop = false;

    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, true));
    try std.testing.expect(!pending);

    pending = true;
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, generation, &shutting_down, &synchronous_stop, false));
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
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, false));

    shutting_down = true;
    try std.testing.expect(!maySchedule(&shutting_down, &synchronous_stop));
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 7, &shutting_down, &synchronous_stop, true));
    try std.testing.expect(!pending);
}

test "contended refill parks and closes unlock IRQ and stop races" {
    var pending = true;
    var waiting = false;
    var owner = true;
    var generation: u64 = 7;
    var shutdown = false;
    var stop = false;
    try std.testing.expectEqual(Finish.stop, parkContended(&pending, &waiting, &owner, &generation, 7, &shutdown, &stop));
    try std.testing.expect(!pending and waiting);
    // Arbitrarily many observations of the same held owner admit no successor.
    for (0..100) |_| {
        pending = true;
        try std.testing.expectEqual(Finish.stop, parkContended(&pending, &waiting, &owner, &generation, 7, &shutdown, &stop));
    }
    // Unlock before pending release is caught even if another unlock attempt
    // previously found pending claimed. A fresh IRQ is independently progress.
    owner = false;
    pending = true;
    try std.testing.expectEqual(Finish.resubmit, parkContended(&pending, &waiting, &owner, &generation, 7, &shutdown, &stop));
    owner = true;
    generation = 8;
    pending = true;
    try std.testing.expectEqual(Finish.resubmit, parkContended(&pending, &waiting, &owner, &generation, 7, &shutdown, &stop));
    stop = true;
    try std.testing.expectEqual(Finish.stop, parkContended(&pending, &waiting, &owner, &generation, 7, &shutdown, &stop));
    stop = false;
    shutdown = true;
    try std.testing.expectEqual(Finish.stop, parkContended(&pending, &waiting, &owner, &generation, 7, &shutdown, &stop));
}
