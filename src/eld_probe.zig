//! One codec verb per step. The caller retains this private ELD scratch while
//! dropping its control lock between normal Work turns. Only a full final
//! pin-sense/ELD inspection may become a published sink.
const std = @import("std");
const hdmi = @import("hdmi.zig");

pub const verbs_per_turn = 16;
pub const Probe = struct {
    phase: enum { idle, sense, size, bytes, final_sense, done } = .idle,
    bytes: [hdmi.max_eld_bytes]u8 = undefined,
    size: usize = 0,
    offset: usize = 0,
    deadline: u64 = 0,
    sink: hdmi.Sink = .{},

    pub fn begin(self: *Probe) void {
        self.* = .{ .phase = .sense };
    }
    pub fn reset(self: *Probe) void {
        self.* = .{};
    }
    fn fail(self: *Probe) void {
        self.sink = .{ .availability = .invalid_eld };
        self.phase = .done;
    }
    pub fn step(self: *Probe, reader: anytype) void {
        switch (self.phase) {
            .idle, .done => {},
            .sense => {
                const sense = reader.verb(0xf09, 0) orelse return self.fail();
                if ((sense & (hdmi.sense_present | hdmi.sense_eld_valid)) != (hdmi.sense_present | hdmi.sense_eld_valid)) {
                    self.sink = hdmi.inspect(sense, &.{});
                    self.phase = .done;
                } else self.phase = .size;
            },
            .size => {
                const size = reader.verb(hdmi.get_eld_size, 8) orelse return self.fail();
                if (size < 20 or size > hdmi.max_eld_bytes) return self.fail();
                self.size = size;
                // The same original byte-read deadline spans all turns.
                self.deadline = reader.tick() +| reader.timeoutTicks();
                self.phase = .bytes;
            },
            .bytes => {
                if (reader.tick() >= self.deadline) return self.fail();
                const value = reader.verb(hdmi.get_eld_byte, @intCast(self.offset)) orelse return self.fail();
                if (value & hdmi.eld_byte_valid == 0) return self.fail();
                self.bytes[self.offset] = @truncate(value);
                self.offset += 1;
                if (self.offset == self.size) self.phase = .final_sense;
            },
            .final_sense => {
                const sense = reader.verb(0xf09, 0) orelse return self.fail();
                self.sink = hdmi.inspect(sense, self.bytes[0..self.size]);
                self.phase = .done;
            },
        }
    }
};

const Fixture = struct {
    now: u64 = 1,
    calls: usize = 0,
    sense: u32 = hdmi.sense_present | hdmi.sense_eld_valid,
    eld: [256]u8 = @splat(0),
    size: u32 = 256,
    missing: ?u8 = null,
    pub fn tick(self: *@This()) u64 {
        return self.now;
    }
    pub fn timeoutTicks(_: *@This()) u64 {
        return 100;
    }
    pub fn verb(self: *@This(), command: u16, index: u8) ?u32 {
        self.calls += 1;
        return switch (command) {
            0xf09 => self.sense,
            hdmi.get_eld_size => self.size,
            hdmi.get_eld_byte => if (self.missing == index) null else self.eld[index] | hdmi.eld_byte_valid,
            else => unreachable,
        };
    }
    fn init() @This() {
        var self = @This(){};
        self.eld[0] = 2 << 3;
        self.eld[2] = 63;
        self.eld[5] = 1 << 4;
        self.eld[20] = 0x09;
        self.eld[21] = 4;
        self.eld[22] = 1;
        return self;
    }
};

test "maximum ELD resumes without early publication and matches whole inspection" {
    var input = Fixture.init();
    var probe = Probe{};
    probe.begin();
    var turns: usize = 0;
    while (probe.phase != .done) {
        turns += 1;
        const before = input.calls;
        for (0..verbs_per_turn) |_| {
            if (probe.phase == .done) break;
            probe.step(&input);
        }
        try std.testing.expect(input.calls - before <= verbs_per_turn);
        if (probe.phase != .done) try std.testing.expect(probe.sink.availability != .ready);
    }
    try std.testing.expectEqual(@as(usize, 17), turns);
    try std.testing.expectEqual(@as(usize, 259), input.calls);
    try std.testing.expectEqualDeep(hdmi.inspect(input.sense, &input.eld), probe.sink);
    try std.testing.expectEqual(hdmi.Availability.ready, probe.sink.availability);
}

test "resuming and a delayed worker do not replenish the original deadline" {
    var input = Fixture.init();
    var probe = Probe{};
    probe.begin();
    probe.step(&input);
    probe.step(&input);
    const deadline = probe.deadline;
    for (0..14) |_| probe.step(&input);
    input.now = deadline;
    const calls = input.calls;
    probe.step(&input);
    try std.testing.expectEqual(calls, input.calls);
    try std.testing.expectEqual(deadline, probe.deadline);
    try std.testing.expectEqual(hdmi.Availability.invalid_eld, probe.sink.availability);
    try std.testing.expectEqual(.done, probe.phase);
}

test "missing bytes and a real final unplug cannot publish ready" {
    var input = Fixture.init();
    input.missing = 15;
    var probe = Probe{};
    probe.begin();
    while (probe.phase != .done) probe.step(&input);
    try std.testing.expectEqual(hdmi.Availability.invalid_eld, probe.sink.availability);
    input = Fixture.init();
    probe.begin();
    while (probe.phase != .final_sense) probe.step(&input);
    input.sense = 0;
    probe.step(&input);
    try std.testing.expectEqual(hdmi.Availability.absent, probe.sink.availability);
    probe.reset();
    try std.testing.expectEqual(.idle, probe.phase);
}
