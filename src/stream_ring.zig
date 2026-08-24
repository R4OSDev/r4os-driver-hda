pub const maximum_periods: usize = 256;

pub fn readyToStart(queued_periods: usize, prefill_periods: usize, draining: bool) bool {
    const minimum = if (draining) @as(usize, 1) else prefill_periods;
    return queued_periods >= minimum;
}

pub const ByteQueue = struct {
    read_pos: usize = 0,
    write_pos: usize = 0,
    used: usize = 0,

    pub fn clear(self: *ByteQueue) void {
        self.* = .{};
    }

    pub fn free(self: *const ByteQueue, storage: []const u8) usize {
        return storage.len - self.used;
    }

    pub fn writeAll(self: *ByteQueue, storage: []u8, input: []const u8) bool {
        if (input.len > self.free(storage)) return false;
        var offset: usize = 0;
        while (offset < input.len) {
            const contiguous = @min(input.len - offset, storage.len - self.write_pos);
            @memcpy(storage[self.write_pos .. self.write_pos + contiguous], input[offset .. offset + contiguous]);
            self.write_pos = (self.write_pos + contiguous) % storage.len;
            self.used += contiguous;
            offset += contiguous;
        }
        return true;
    }

    pub fn readExact(self: *ByteQueue, storage: []const u8, output: []u8) bool {
        if (output.len > self.used) return false;
        var offset: usize = 0;
        while (offset < output.len) {
            const contiguous = @min(output.len - offset, storage.len - self.read_pos);
            @memcpy(output[offset .. offset + contiguous], storage[self.read_pos .. self.read_pos + contiguous]);
            self.read_pos = (self.read_pos + contiguous) % storage.len;
            self.used -= contiguous;
            offset += contiguous;
        }
        return true;
    }

    pub fn readAvailable(self: *ByteQueue, storage: []const u8, output: []u8) usize {
        const count = @min(output.len, self.used);
        if (count == 0) return 0;
        _ = self.readExact(storage, output[0..count]);
        return count;
    }
};

pub const Advance = struct {
    periods: usize = 0,
    missing: usize = 0,
};

pub const PeriodBook = struct {
    count: usize = 0,
    producer: usize = 0,
    current: usize = 0,
    queued: usize = 0,
    running: bool = false,
    ready: [maximum_periods]bool = .{false} ** maximum_periods,

    pub fn init(count: usize) PeriodBook {
        return .{ .count = if (count <= maximum_periods) count else 0 };
    }

    pub fn reset(self: *PeriodBook) void {
        const count = self.count;
        self.* = .{ .count = count };
    }

    pub fn nextWritable(self: *PeriodBook) ?usize {
        if (self.count < 2) return null;
        var attempts: usize = 0;
        while (attempts < self.count) : (attempts += 1) {
            const slot = self.producer;
            if ((!self.running or slot != self.current) and !self.ready[slot]) return slot;
            self.producer = (self.producer + 1) % self.count;
        }
        return null;
    }

    pub fn commit(self: *PeriodBook, slot: usize) bool {
        if (slot >= self.count or self.ready[slot]) return false;
        if (self.running and slot == self.current) return false;
        self.ready[slot] = true;
        self.queued += 1;
        self.producer = (slot + 1) % self.count;
        return true;
    }

    pub fn start(self: *PeriodBook, current: usize) bool {
        if (self.running or current >= self.count or !self.ready[current]) return false;
        self.current = current;
        self.running = true;
        return true;
    }

    pub fn advance(self: *PeriodBook, current: usize) Advance {
        if (!self.running or current >= self.count or current == self.current) return .{};
        var result: Advance = .{};
        var cursor = self.current;
        while (cursor != current and result.periods < self.count) {
            if (self.ready[cursor]) {
                self.ready[cursor] = false;
                self.queued -= 1;
            }
            cursor = (cursor + 1) % self.count;
            result.periods += 1;
            if (!self.ready[cursor]) result.missing += 1;
        }
        self.current = current;
        if (result.missing != 0) self.producer = (current + 1) % self.count;
        return result;
    }

    pub fn expireWindow(self: *PeriodBook, current: usize) usize {
        if (!self.running or current >= self.count) return 0;
        const expired = self.queued;
        var index: usize = 0;
        while (index < self.count) : (index += 1) self.ready[index] = false;
        self.current = current;
        self.producer = (current + 1) % self.count;
        self.queued = 0;
        return expired;
    }
};

test "byte queue preserves wrapped writes" {
    const std = @import("std");
    var storage: [12]u8 = undefined;
    var queue: ByteQueue = .{};
    try std.testing.expect(queue.writeAll(&storage, "abcdefgh"));
    var first: [6]u8 = undefined;
    try std.testing.expect(queue.readExact(&storage, &first));
    try std.testing.expectEqualStrings("abcdef", &first);
    try std.testing.expect(queue.writeAll(&storage, "ijklmnop"));
    var remaining: [10]u8 = undefined;
    try std.testing.expect(queue.readExact(&storage, &remaining));
    try std.testing.expectEqualStrings("ghijklmnop", &remaining);
    try std.testing.expectEqual(@as(usize, 0), queue.used);
}

test "byte queue rejects a partial write" {
    const std = @import("std");
    var storage: [4]u8 = undefined;
    var queue: ByteQueue = .{};
    try std.testing.expect(!queue.writeAll(&storage, "12345"));
    try std.testing.expectEqual(@as(usize, 0), queue.used);
}

test "playback starts after low-latency prefill or one draining period" {
    const std = @import("std");
    try std.testing.expect(!readyToStart(0, 2, false));
    try std.testing.expect(!readyToStart(1, 2, false));
    try std.testing.expect(readyToStart(2, 2, false));
    try std.testing.expect(!readyToStart(0, 2, true));
    try std.testing.expect(readyToStart(1, 2, true));
}

test "period book keeps producer off the active hardware period" {
    const std = @import("std");
    var book = PeriodBook.init(4);
    try std.testing.expect(book.commit(book.nextWritable().?));
    try std.testing.expect(book.commit(book.nextWritable().?));
    try std.testing.expect(book.start(0));
    try std.testing.expectEqual(@as(usize, 2), book.queued);

    const first = book.advance(1);
    try std.testing.expectEqual(@as(usize, 1), first.periods);
    try std.testing.expectEqual(@as(usize, 0), first.missing);
    try std.testing.expectEqual(@as(usize, 1), book.queued);
    try std.testing.expectEqual(@as(usize, 2), book.nextWritable().?);
    try std.testing.expect(book.commit(2));

    const second = book.advance(2);
    try std.testing.expectEqual(@as(usize, 0), second.missing);
    try std.testing.expect(!book.commit(2));
}

test "period book reports an unfilled period and recovers ahead" {
    const std = @import("std");
    var book = PeriodBook.init(4);
    try std.testing.expect(book.commit(0));
    try std.testing.expect(book.start(0));
    const gap = book.advance(1);
    try std.testing.expectEqual(@as(usize, 1), gap.missing);
    try std.testing.expectEqual(@as(usize, 0), book.queued);
    try std.testing.expectEqual(@as(usize, 2), book.nextWritable().?);
    try std.testing.expect(book.commit(2));
    const recovered = book.advance(2);
    try std.testing.expectEqual(@as(usize, 0), recovered.missing);

    book.reset();
    try std.testing.expect(book.commit(0));
    try std.testing.expect(book.commit(1));
    try std.testing.expect(book.start(0));
    _ = book.advance(1);
    const delayed = book.advance(3);
    try std.testing.expectEqual(@as(usize, 2), delayed.missing);
    try std.testing.expectEqual(@as(usize, 0), book.nextWritable().?);
}

test "period book reports a wraparound gap instead of replaying stale data" {
    const std = @import("std");
    var book = PeriodBook.init(4);
    try std.testing.expect(book.commit(0));
    try std.testing.expect(book.commit(1));
    try std.testing.expect(book.commit(2));
    try std.testing.expect(book.commit(3));
    try std.testing.expect(book.start(0));
    _ = book.advance(1);
    _ = book.advance(2);
    _ = book.advance(3);
    const wrapped = book.advance(0);
    try std.testing.expectEqual(@as(usize, 1), wrapped.missing);
    try std.testing.expectEqual(@as(usize, 0), book.queued);
    try std.testing.expectEqual(@as(usize, 1), book.nextWritable().?);

    book.reset();
    try std.testing.expect(book.commit(0));
    try std.testing.expect(book.commit(1));
    try std.testing.expect(book.commit(2));
    try std.testing.expect(book.commit(3));
    try std.testing.expect(book.start(0));
    try std.testing.expectEqual(@as(usize, 4), book.expireWindow(0));
    try std.testing.expectEqual(@as(usize, 0), book.queued);
    try std.testing.expectEqual(@as(usize, 1), book.nextWritable().?);
}
