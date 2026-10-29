//! One drain-progress/retirement step per resident worker turn.
//! Close RPCs only submit/query this work and never wait for DMA or Work.
//! Caller-owned PCM, the absolute drain deadline and actual completion
//! handles survive Busy. An output/reset change never acknowledges old work.
const std = @import("std");

pub const Identity = struct { output: u64, reset: u64 };
pub const Result = enum { pending, complete, changed, drain_timeout, retirement_timeout, failed };
pub const Retirement = enum { pending, complete, failed };
pub const State = struct {
    phase: enum { idle, draining, retiring } = .idle,
    identity: Identity = .{ .output = 0, .reset = 0 },
    started: u64 = 0,
    deadline: u64 = 0,
    tail_flushed: bool = false,
    postroll_remaining: usize = 0,

    pub fn reset(self: *State) void {
        self.* = .{};
    }
    fn reject(self: *State, result: Result) Result {
        self.reset();
        return result;
    }
    pub fn start(self: *State, owner: anytype, drain_ticks: u64, postroll: usize) void {
        self.identity = owner.identity();
        self.started = owner.now();
        self.deadline = self.started +| drain_ticks;
        self.tail_flushed = owner.tailEmpty();
        self.postroll_remaining = postroll;
        self.phase = .draining;
        owner.begin();
    }
    pub fn poll(self: *State, owner: anytype, drain_ticks: u64, retirement_ticks: u64, postroll: usize) Result {
        if (self.phase == .idle) self.start(owner, drain_ticks, postroll);
        if (!std.meta.eql(self.identity, owner.identity())) return self.reject(.changed);
        if (self.phase == .draining) {
            if (owner.now() > self.deadline) return self.reject(.drain_timeout);
            const drained = owner.pump(&self.tail_flushed, &self.postroll_remaining);
            if (!std.meta.eql(self.identity, owner.identity())) return self.reject(.changed);
            if (owner.now() > self.deadline) return self.reject(.drain_timeout);
            if (!drained) return .pending;
            if (!owner.quiet()) return self.reject(.failed);
            // The owner's successful analog stop may reset its descriptor.
            // Only this real, fully drained transition can adopt that epoch.
            self.identity = owner.identity();
            self.phase = .retiring;
            self.deadline = owner.now() +| retirement_ticks;
        }
        if (owner.now() > self.deadline) return self.reject(.retirement_timeout);
        const retired = owner.retire();
        if (!std.meta.eql(self.identity, owner.identity())) return self.reject(.changed);
        if (owner.now() > self.deadline) return self.reject(.retirement_timeout);
        return switch (retired) {
            .pending => .pending,
            .failed => self.reject(.failed),
            .complete => self.reject(.complete),
        };
    }
};

const Fixture = struct {
    tick: u64 = 10,
    epoch: Identity = .{ .output = 2, .reset = 3 },
    pumps: usize = 0,
    begins: usize = 0,
    quiets: usize = 0,
    source_frames: usize = 1440,
    consumed: usize = 0,
    actual_handles: usize = 2,
    retire_calls: usize = 0,
    change_during_pump: bool = false,
    analog: bool = false,
    pub fn identity(self: *@This()) Identity { return self.epoch; }
    pub fn now(self: *@This()) u64 { return self.tick; }
    pub fn tailEmpty(_: *@This()) bool { return true; }
    pub fn begin(self: *@This()) void { self.begins += 1; }
    pub fn pump(self: *@This(), tail: *bool, remaining: *usize) bool {
        self.pumps += 1;
        std.debug.assert(tail.*);
        if (self.change_during_pump) self.epoch.reset += 1;
        if (self.consumed != self.source_frames) return false;
        remaining.* = 0; // actual postroll completion supplied by this owner
        return true;
    }
    pub fn quiet(self: *@This()) bool {
        std.debug.assert(self.consumed == self.source_frames);
        self.quiets += 1;
        if (self.analog) self.epoch.reset += 1;
        return true;
    }
    pub fn retire(self: *@This()) Retirement {
        self.retire_calls += 1;
        return if (self.actual_handles == 0) .complete else .pending;
    }
};

test "busy returns after one turn and never acknowledges PCM or outstanding handles" {
    var state: State = .{};
    var owner: Fixture = .{};
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(@as(usize, 1), owner.pumps);
    try std.testing.expectEqual(@as(usize, 0), owner.quiets);
    const end = state.deadline;
    owner.tick += 95;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(end, state.deadline);
    try std.testing.expectEqual(@as(usize, 1), owner.begins);
    owner.consumed = 1440;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(@as(usize, 1), owner.quiets);
    owner.actual_handles = 1;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    owner.actual_handles = 0;
    try std.testing.expectEqual(Result.complete, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(@as(usize, 1), owner.quiets);
}

test "absolute deadlines do not restart across busy replies or retirement" {
    var state: State = .{};
    var owner: Fixture = .{};
    _ = state.poll(&owner, 400, 100, 3);
    owner.tick = 411;
    try std.testing.expectEqual(Result.drain_timeout, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(@as(usize, 1), owner.pumps);
    try std.testing.expectEqual(@as(usize, 0), owner.quiets);
    owner.consumed = 1440;
    _ = state.poll(&owner, 400, 100, 3);
    const deadline = state.deadline;
    owner.tick += 99;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(deadline, state.deadline);
    owner.tick += 2;
    try std.testing.expectEqual(Result.retirement_timeout, state.poll(&owner, 400, 100, 3));
}

test "foreign output and reset changes reject old work including recovery inside a turn" {
    var state: State = .{};
    var owner: Fixture = .{};
    _ = state.poll(&owner, 400, 100, 3);
    owner.epoch.output += 1;
    try std.testing.expectEqual(Result.changed, state.poll(&owner, 400, 100, 3));
    owner.change_during_pump = true;
    owner.consumed = 1440;
    try std.testing.expectEqual(Result.changed, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(@as(usize, 0), owner.quiets);
    owner.change_during_pump = false;
    owner.analog = true;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(owner.epoch.reset, state.identity.reset);
    owner.epoch.reset += 1;
    try std.testing.expectEqual(Result.changed, state.poll(&owner, 400, 100, 3));
}

test "new PCM cancellation retains source work and starts a distinct close budget" {
    var state: State = .{};
    var owner: Fixture = .{};
    _ = state.poll(&owner, 400, 100, 3);
    state.reset();
    owner.tick += 500;
    owner.source_frames += 480;
    owner.consumed = 1440;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(@as(usize, 0), owner.quiets);
    owner.consumed = 1920;
    owner.actual_handles = 0;
    try std.testing.expectEqual(Result.complete, state.poll(&owner, 400, 100, 3));
}


test "queued worker includes initial queue delay and needs no further client call" {
    var state: State = .{};
    var owner: Fixture = .{};
    state.start(&owner, 400, 3);
    owner.tick += 401;
    try std.testing.expectEqual(Result.drain_timeout, state.poll(&owner, 400, 100, 3));
    try std.testing.expectEqual(@as(usize, 0), owner.pumps);
    state.start(&owner, 400, 3);
    // Only the resident worker advances these turns after client disconnect.
    owner.tick += 10;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    owner.consumed = 1440;
    owner.tick += 10;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 400, 100, 3));
    owner.actual_handles = 0;
    owner.tick += 1;
    try std.testing.expectEqual(Result.complete, state.poll(&owner, 400, 100, 3));
}
