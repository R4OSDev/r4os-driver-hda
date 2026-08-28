const std = @import("std");

pub const bcis: u8 = 0x04;
pub const fifoe: u8 = 0x08;
pub const dese: u8 = 0x10;
pub const clear_mask: u8 = bcis | fifoe | dese;

pub const StatusEvent = struct {
    acknowledge: u8 = 0,
    completion: bool = false,
    fifo_error: bool = false,
    descriptor_error: bool = false,

    pub fn needsRecovery(self: StatusEvent) bool {
        return self.fifo_error or self.descriptor_error;
    }

    pub fn recoveryBits(self: StatusEvent) u8 {
        return self.acknowledge & (fifoe | dese);
    }
};

pub fn decodeStatus(status: u8) StatusEvent {
    const acknowledged = status & clear_mask;
    return .{
        .acknowledge = acknowledged,
        .completion = (acknowledged & bcis) != 0,
        .fifo_error = (acknowledged & fifoe) != 0,
        .descriptor_error = (acknowledged & dese) != 0,
    };
}

pub const Counters = struct {
    completions: u64 = 0,
    fifo_errors: u64 = 0,
    descriptor_errors: u64 = 0,
    recoveries_requested: u64 = 0,

    pub fn consume(self: *Counters, event: StatusEvent) void {
        self.completions += @intFromBool(event.completion);
        self.fifo_errors += @intFromBool(event.fifo_error);
        self.descriptor_errors += @intFromBool(event.descriptor_error);
        self.recoveries_requested += @intFromBool(event.needsRecovery());
    }
};

/// PCI config provides the only accepted legacy route evidence: a legal
/// interrupt pin and a representable line.  No neighboring GSI is inferred.
pub fn exactIntxRoute(line: u8, pin: u8) ?u8 {
    if (line >= 32 or pin < 1 or pin > 4) return null;
    return line;
}

pub const RecoveryLatch = struct {
    bits: u8 = 0,

    pub fn note(self: *RecoveryLatch, event: StatusEvent) void {
        const causes = event.recoveryBits();
        if (causes != 0) _ = @atomicRmw(u8, &self.bits, .Or, causes, .acq_rel);
    }

    pub fn take(self: *RecoveryLatch) u8 {
        return @atomicRmw(u8, &self.bits, .Xchg, 0, .acq_rel);
    }
};

pub const ReapContext = enum(u8) {
    irq,
    worker,
    task,
};

/// Completion APIs are never entered from IRQ context and only one worker or
/// task may inspect/release stored handles at a time.
pub const ReapGate = struct {
    owned: bool = false,

    pub fn tryClaim(self: *ReapGate, context: ReapContext) bool {
        if (context == .irq) return false;
        return !@atomicRmw(bool, &self.owned, .Xchg, true, .acq_rel);
    }

    pub fn release(self: *ReapGate) void {
        @atomicStore(bool, &self.owned, false, .release);
    }
};

test "status is acknowledged and counted exactly once with both errors recovering" {
    const event = decodeStatus(bcis | fifoe | dese | 0x80);
    try std.testing.expectEqual(clear_mask, event.acknowledge);
    try std.testing.expect(event.needsRecovery());
    try std.testing.expectEqual(fifoe | dese, event.recoveryBits());
    var counters = Counters{};
    counters.consume(event);
    try std.testing.expectEqual(@as(u64, 1), counters.completions);
    try std.testing.expectEqual(@as(u64, 1), counters.fifo_errors);
    try std.testing.expectEqual(@as(u64, 1), counters.descriptor_errors);
    try std.testing.expectEqual(@as(u64, 1), counters.recoveries_requested);
}

test "INTx requires exact PCI line and pin evidence" {
    try std.testing.expectEqual(@as(?u8, 17), exactIntxRoute(17, 1));
    try std.testing.expectEqual(@as(?u8, null), exactIntxRoute(0xff, 1));
    try std.testing.expectEqual(@as(?u8, null), exactIntxRoute(17, 0));
    try std.testing.expectEqual(@as(?u8, null), exactIntxRoute(32, 2));
}

test "completion reaping excludes IRQ and serializes worker with task" {
    var gate = ReapGate{};
    try std.testing.expect(!gate.tryClaim(.irq));
    try std.testing.expect(gate.tryClaim(.worker));
    try std.testing.expect(!gate.tryClaim(.task));
    gate.release();
    try std.testing.expect(gate.tryClaim(.task));
    gate.release();
}

test "recovery latch neither duplicates nor loses a racing later error" {
    var latch = RecoveryLatch{};
    latch.note(decodeStatus(fifoe));
    try std.testing.expectEqual(fifoe, latch.take());
    latch.note(decodeStatus(dese));
    try std.testing.expectEqual(dese, latch.take());
    try std.testing.expectEqual(@as(u8, 0), latch.take());
}
