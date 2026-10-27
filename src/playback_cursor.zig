const std = @import("std");

pub const capacity = 64;
pub const period_frames = 480;

pub const Epoch = struct {
    output: u64 = 1,
    reset: u64 = 1,
    accepted: u64 = 0,
    submitted: u64 = 0,
    consumed: u64 = 0,
};

const Mark = struct {
    first: u64 = 0,
    frames: u16 = 0,
    valid: bool = false,
};

/// Logical 48-kHz PCM sequence, distinct from physical ring byte position.
/// Padding, postroll and carrier silence never acquire a PCM sequence number.
/// All mutation belongs to the existing HDA stream owner.
pub const Cursor = struct {
    current: Epoch = .{},
    previous: Epoch = .{},
    previous_valid: bool = false,
    available: bool = true,
    slots: [capacity]Mark = .{Mark{}} ** capacity,

    pub fn accept(self: *Cursor, frames: u64) bool {
        const next = std.math.add(u64, self.current.accepted, frames) catch {
            self.available = false;
            return false;
        };
        self.current.accepted = next;
        return true;
    }

    pub fn submit(self: *Cursor, slot: usize, frames: usize) bool {
        if (slot >= capacity or frames == 0 or frames > period_frames or self.slots[slot].valid)
            return false;
        const next = std.math.add(u64, self.current.submitted, frames) catch return false;
        if (next > self.current.accepted) return false;
        self.slots[slot] = .{ .first = self.current.submitted, .frames = @intCast(frames), .valid = true };
        self.current.submitted = next;
        return true;
    }

    pub fn silence(self: *Cursor, slot: usize) void {
        std.debug.assert(slot < capacity and !self.slots[slot].valid);
        self.slots[slot] = .{};
    }

    fn consume(self: *Cursor, slot: usize, frames: usize, retired: bool) void {
        const mark = &self.slots[slot];
        if (!mark.valid) return;
        const through = mark.first + @min(frames, mark.frames);
        self.current.consumed = @max(self.current.consumed, through);
        std.debug.assert(self.current.consumed <= self.current.submitted);
        if (retired) mark.* = .{};
    }

    /// Called only after the physical position owner validated movement.
    /// Observe a partial active period as well as all fully retired periods.
    pub fn observe(self: *Cursor, old_slot: usize, retired_periods: usize, active_slot: usize, offset_frames: usize) void {
        std.debug.assert(old_slot < capacity and active_slot < capacity and retired_periods <= capacity);
        for (0..retired_periods) |i| self.consume((old_slot + i) % capacity, period_frames, true);
        self.consume(active_slot, @min(offset_frames, period_frames), false);
    }

    /// Hardware quiescence/reset retires the old epoch. One last nonempty
    /// epoch lets its kernel owner distinguish consumed data from lost tail.
    /// Further resets cannot turn an older cursor into current progress.
    pub fn reset(self: *Cursor) void {
        if (self.current.accepted != 0) {
            self.previous = self.current;
            self.previous_valid = true;
        }
        const next = std.math.add(u64, self.current.reset, 1) catch {
            self.available = false;
            return;
        };
        self.current = .{ .output = self.current.output, .reset = next };
        self.slots = .{Mark{}} ** capacity;
    }

    pub fn changeOutput(self: *Cursor) void {
        // The caller has quiesced the route, including an already parked
        // descriptor that needed no additional physical reset.
        if (self.current.accepted != 0 or self.current.submitted != 0) self.reset();
        const next = std.math.add(u64, self.current.output, 1) catch {
            self.available = false;
            return;
        };
        std.debug.assert(self.current.accepted == 0 and self.current.submitted == 0);
        self.current.output = next;
    }

    pub fn clearIdle(self: *Cursor) void {
        std.debug.assert(self.current.accepted == self.current.consumed);
        self.slots = .{Mark{}} ** capacity;
    }
};

test "partial PCM consumption excludes padding postroll and carrier at every wrap" {
    for (0..capacity) |base| {
        var cursor = Cursor{};
        const second = (base + 1) % capacity;
        const tail = (base + 2) % capacity;
        const postroll = (base + 3) % capacity;
        try std.testing.expect(cursor.accept(480 + 480 + 17));
        try std.testing.expect(cursor.submit(base, 480));
        try std.testing.expect(cursor.submit(second, 480));
        try std.testing.expect(cursor.submit(tail, 17));
        cursor.silence(postroll);
        cursor.observe(base, 0, base, 239);
        try std.testing.expectEqual(@as(u64, 239), cursor.current.consumed);
        cursor.observe(base, 1, second, 120);
        try std.testing.expectEqual(@as(u64, 600), cursor.current.consumed);
        cursor.observe(second, 1, tail, 400);
        try std.testing.expectEqual(@as(u64, 977), cursor.current.consumed);
        cursor.observe(tail, 1, postroll, 300);
        try std.testing.expectEqual(@as(u64, 977), cursor.current.consumed);
        cursor.observe(postroll, capacity, postroll, 479);
        try std.testing.expectEqual(@as(u64, 977), cursor.current.consumed);
    }
}

test "reset and route generations retain only the exact retired PCM epoch" {
    var cursor = Cursor{};
    try std.testing.expect(cursor.accept(960));
    try std.testing.expect(cursor.submit(0, 480));
    try std.testing.expect(cursor.submit(1, 480));
    cursor.observe(0, 0, 0, 240);
    cursor.reset();
    try std.testing.expectEqual(Epoch{ .output = 1, .reset = 1, .accepted = 960, .submitted = 960, .consumed = 240 }, cursor.previous);
    cursor.changeOutput();
    try std.testing.expectEqual(@as(u64, 0), cursor.current.consumed);
    try std.testing.expectEqual(@as(u64, 2), cursor.current.output);
    cursor.reset(); // Empty descriptor reset must not erase that last receipt.
    try std.testing.expectEqual(@as(u64, 240), cursor.previous.consumed);
    try std.testing.expect(cursor.accept(33));
    try std.testing.expect(cursor.submit(7, 33));
    cursor.observe(7, 0, 7, 17);
    try std.testing.expectEqual(@as(u64, 17), cursor.current.consumed);
    cursor.reset();
    try std.testing.expectEqual(@as(u64, 2), cursor.previous.output);
    try std.testing.expectEqual(@as(u64, 3), cursor.previous.reset);
    try std.testing.expectEqual(@as(u64, 17), cursor.previous.consumed);
    cursor.current.accepted = ~@as(u64, 0);
    try std.testing.expect(!cursor.accept(1));
    try std.testing.expect(!cursor.available);
}
