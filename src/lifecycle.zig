const std = @import("std");

/// Resources are ordered by acquisition. Teardown always walks this list in
/// reverse, while the production driver still checks the concrete handles as
/// the final authority for partially completed composite acquisitions.
pub const Resource = enum(u8) {
    pci,
    mmio,
    reset,
    transport,
    discovery,
    route,
    stream_dma,
    position_dma,
    irq,
    backend,
    work,
};

pub const acquisition_order = [_]Resource{
    .pci,
    .mmio,
    .reset,
    .transport,
    .discovery,
    .route,
    .stream_dma,
    .position_dma,
    .irq,
    .backend,
    .work,
};

pub const Ledger = struct {
    owned: u16 = 0,
    acquired_ever: u16 = 0,

    pub fn acquire(self: *Ledger, resource: Resource) void {
        const mask = resourceMask(resource);
        self.owned |= mask;
        self.acquired_ever |= mask;
    }

    pub fn acquireAtomic(self: *Ledger, resource: Resource) void {
        const mask = resourceMask(resource);
        _ = @atomicRmw(u16, &self.owned, .Or, mask, .acq_rel);
        _ = @atomicRmw(u16, &self.acquired_ever, .Or, mask, .acq_rel);
    }

    /// Returns false for an already released resource. This makes repeated
    /// cleanup observable without turning it into a second free operation.
    pub fn release(self: *Ledger, resource: Resource) bool {
        const mask = resourceMask(resource);
        if ((self.owned & mask) == 0) return false;
        self.owned &= ~mask;
        return true;
    }

    pub fn releaseAtomic(self: *Ledger, resource: Resource) bool {
        const mask = resourceMask(resource);
        const previous = @atomicRmw(u16, &self.owned, .And, ~mask, .acq_rel);
        return (previous & mask) != 0;
    }

    pub fn snapshot(self: *const Ledger) u16 {
        return @atomicLoad(u16, &self.owned, .acquire);
    }

    pub fn owns(self: Ledger, resource: Resource) bool {
        return (self.owned & resourceMask(resource)) != 0;
    }

    pub fn empty(self: Ledger) bool {
        return self.owned == 0;
    }

    pub fn nextRelease(self: Ledger) ?Resource {
        var index = acquisition_order.len;
        while (index > 0) {
            index -= 1;
            const resource = acquisition_order[index];
            if (self.owns(resource)) return resource;
        }
        return null;
    }

    pub fn reset(self: *Ledger) void {
        self.* = .{};
    }
};

pub const DrainOutcome = enum {
    idle,
    drained,
    timeout,
    hardware_error,
};

pub const StopDecision = struct {
    force_drop: bool,
    report_failure: bool,
};

/// A failed graceful drain must not retain old PCM or resource ownership.
/// The caller reports the failure, but first performs a forced stop/drop.
pub fn stopDecision(outcome: DrainOutcome) StopDecision {
    return switch (outcome) {
        .idle, .drained => .{ .force_drop = false, .report_failure = false },
        .timeout, .hardware_error => .{ .force_drop = true, .report_failure = true },
    };
}

fn resourceMask(resource: Resource) u16 {
    return @as(u16, 1) << @intCast(@intFromEnum(resource));
}

test "fault after every ownership stage unwinds exactly once in reverse order" {
    var fault_after: usize = 1;
    while (fault_after <= acquisition_order.len) : (fault_after += 1) {
        var ledger = Ledger{};
        for (acquisition_order[0..fault_after]) |resource| ledger.acquire(resource);

        var expected = fault_after;
        while (ledger.nextRelease()) |resource| {
            expected -= 1;
            try std.testing.expectEqual(acquisition_order[expected], resource);
            try std.testing.expect(ledger.release(resource));
            try std.testing.expect(!ledger.release(resource));
        }
        try std.testing.expectEqual(@as(usize, 0), expected);
        try std.testing.expect(ledger.empty());

        // A complete second shutdown remains a no-op.
        try std.testing.expectEqual(@as(?Resource, null), ledger.nextRelease());
        try std.testing.expect(ledger.empty());
    }
}

test "reacquired dynamic work is owned and released as a fresh generation" {
    var ledger = Ledger{};
    ledger.acquire(.backend);
    ledger.acquire(.work);
    try std.testing.expectEqual(Resource.work, ledger.nextRelease().?);
    try std.testing.expect(ledger.release(.work));
    ledger.acquire(.work);
    try std.testing.expect(ledger.release(.work));
    try std.testing.expect(ledger.owns(.backend));
    try std.testing.expect(ledger.release(.backend));
    try std.testing.expect(ledger.empty());
}

test "supported unload and reload start a complete fresh ownership generation" {
    var ledger = Ledger{};
    for (acquisition_order) |resource| ledger.acquire(resource);

    const timed_out = stopDecision(.timeout);
    try std.testing.expect(timed_out.force_drop);
    var stale_pcm = true;
    if (timed_out.force_drop) stale_pcm = false;

    while (ledger.nextRelease()) |resource| try std.testing.expect(ledger.release(resource));
    try std.testing.expect(ledger.empty());
    try std.testing.expect(!stale_pcm);

    // hda_init replaces the prior driver state. Model that generation boundary
    // explicitly and require every resource to be acquirable and releasable
    // again without carrying PCM or ownership from the unloaded generation.
    ledger.reset();
    for (acquisition_order) |resource| ledger.acquire(resource);
    for (acquisition_order) |resource| try std.testing.expect(ledger.owns(resource));
    try std.testing.expect(!stale_pcm);
    while (ledger.nextRelease()) |resource| try std.testing.expect(ledger.release(resource));
    try std.testing.expect(ledger.empty());
}

test "drain timeout and hardware error force stale PCM removal before failure" {
    const drained = stopDecision(.drained);
    try std.testing.expect(!drained.force_drop);
    try std.testing.expect(!drained.report_failure);

    const timeout = stopDecision(.timeout);
    try std.testing.expect(timeout.force_drop);
    try std.testing.expect(timeout.report_failure);

    const hardware_error = stopDecision(.hardware_error);
    try std.testing.expect(hardware_error.force_drop);
    try std.testing.expect(hardware_error.report_failure);
}
