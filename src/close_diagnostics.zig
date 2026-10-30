//! Explicit task-context diagnostics. No background task or normal-close work.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Semaphores = @typeInfo(@TypeOf(@as(*const r4os.r4dev.DriverContext, undefined).semaphores())).optional.child;

pub const max_body_bytes = 512;
pub const max_lines = 32;
pub const fragment_bytes = 72;

/// The existing kernel semaphore supplies both a serial diagnostic permit and
/// the authenticated loaded-driver epoch. Allocation is lazy: R4D Init need
/// not be a context in which allocating a sleeping primitive is admissible.
pub const Owner = struct {
    requested: bool = false,
    initialization: u8 = 0,
    semaphores: ?Semaphores = null,
    handle: u64 = 0,
    epoch: u64 = 0,
    sequence: u64 = 0,

    pub fn configure(self: *Owner, requested: bool) void {
        @atomicStore(bool, &self.requested, requested, .release);
    }

    pub fn enabled(self: *const Owner) bool {
        return @atomicLoad(bool, &self.requested, .acquire);
    }

    fn ensure(self: *Owner, ctx: anytype, timeout: u64) bool {
        const until = ctx.tickCount() +| timeout;
        while (true) {
            switch (@atomicLoad(u8, &self.initialization, .acquire)) {
                2 => return true,
                0 => {
                    if (@cmpxchgStrong(u8, &self.initialization, 0, 1, .acq_rel, .acquire) != null) continue;
                    const api = ctx.semaphores() orelse {
                        @atomicStore(u8, &self.initialization, 0, .release);
                        return false;
                    };
                    var handle: u64 = 0;
                    if (api.create(1, 1, &handle) != 0 or handle == 0) {
                        @atomicStore(u8, &self.initialization, 0, .release);
                        return false;
                    }
                    var status: a.DriverSemaphoreStatus = .{};
                    if (api.status(handle, &status) != 0 or !validStatus(status, handle, null) or status.available != 1) {
                        _ = api.destroy(handle);
                        @atomicStore(u8, &self.initialization, 0, .release);
                        return false;
                    }
                    self.semaphores = api;
                    self.handle = handle;
                    self.epoch = status.owner_epoch;
                    @atomicStore(u8, &self.initialization, 2, .release);
                    return true;
                },
                else => {
                    if (ctx.tickCount() >= until) return false;
                    ctx.waitTicks(1);
                },
            }
        }
    }

    pub fn begin(self: *Owner, ctx: anytype, timeout: u64) ?Ticket {
        if (!self.enabled()) return null;
        if (!self.ensure(ctx, timeout)) {
            ctx.logWarn("HDA.DIAG requested details unavailable: owner initialization");
            return null;
        }
        const api = &self.semaphores.?;
        if (api.acquire(self.handle, timeout) != 0) {
            ctx.logWarn("HDA.DIAG requested details unavailable: diagnostic permit");
            return null;
        }
        var status: a.DriverSemaphoreStatus = .{};
        if (api.status(self.handle, &status) != 0 or !validStatus(status, self.handle, self.epoch) or status.available != 0) {
            _ = api.release(self.handle);
            ctx.logWarn("HDA.DIAG requested details unavailable: driver epoch");
            return null;
        }
        self.sequence = std.math.add(u64, self.sequence, 1) catch {
            _ = api.release(self.handle);
            ctx.logWarn("HDA.DIAG requested details unavailable: sequence exhausted");
            return null;
        };
        return .{ .owner = self, .handle = self.handle, .epoch = self.epoch, .sequence = self.sequence };
    }

    /// Called only after the driver's callbacks and hardware owners quiesce.
    pub fn close(self: *Owner, ctx: anytype) bool {
        if (@atomicLoad(u8, &self.initialization, .acquire) == 1) return false;
        if (self.handle != 0 and self.semaphores.?.destroy(self.handle) != 0) {
            ctx.logWarn("HDA.DIAG diagnostic permit destruction failed");
            return false;
        }
        self.* = .{};
        return true;
    }
};

fn validStatus(status: a.DriverSemaphoreStatus, handle: u64, epoch: ?u64) bool {
    return status.version == 1 and status.size == @sizeOf(a.DriverSemaphoreStatus) and
        status.handle == handle and status.owner_epoch != 0 and status.maximum == 1 and
        (epoch == null or status.owner_epoch == epoch.?);
}

pub const Ticket = struct {
    owner: *Owner,
    handle: u64,
    epoch: u64,
    sequence: u64,

    pub fn release(self: Ticket, ctx: anytype) bool {
        if (self.owner.semaphores.?.release(self.handle) != 0) {
            ctx.logWarn("HDA.DIAG diagnostic permit release failed");
            return false;
        }
        return true;
    }
};

pub const Identity = struct {
    output: u64,
    reset: u64,
    pci: u32,
    tick: u64 = 0,
};

/// Every bounded LogService fragment carries the complete epoch/sequence key.
/// The consumer checks all parts and the terminal counts before accepting it.
/// Only immutable copied values reach this emitter, never live HDA State.
pub fn Emitter(comptime Context: type) type {
    return struct {
        const Self = @This();
        ctx: *const Context,
        epoch: u64,
        sequence: u64,
        lines: usize = 0,
        parts: usize = 0,
        failed: bool = false,

        pub fn begin(ctx: *const Context, ticket: Ticket, identity: Identity, phase: []const u8) Self {
            var self = Self{ .ctx = ctx, .epoch = ticket.epoch, .sequence = ticket.sequence };
            var line: [a.log_service_text_bytes:0]u8 = undefined;
            const text = std.fmt.bufPrintZ(&line, "HDA.SNAP begin v=1 e={x:0>16} s={x:0>16} h={x:0>16} o={x:0>16} r={x:0>16} pci={x:0>6} phase={s}", .{ ticket.epoch, ticket.sequence, ticket.handle, identity.output, identity.reset, identity.pci, phase }) catch {
                self.failed = true;
                return self;
            };
            ctx.logInfo(text);
            const time = std.fmt.bufPrintZ(&line, "HDA.SNAP time v=1 e={x:0>16} s={x:0>16} t={x:0>16}", .{ ticket.epoch, ticket.sequence, identity.tick }) catch {
                self.failed = true;
                return self;
            };
            ctx.logInfo(time);
            return self;
        }

        pub fn logInfo(self: *Self, text: [*:0]const u8) void {
            const body = std.mem.span(text);
            if (body.len == 0 or body.len >= max_body_bytes or self.lines == max_lines) {
                self.failed = true;
                return;
            }
            const total = (body.len + fragment_bytes - 1) / fragment_bytes;
            var offset: usize = 0;
            var part: usize = 0;
            while (offset < body.len) : (part += 1) {
                const end = @min(body.len, offset + fragment_bytes);
                var line: [a.log_service_text_bytes:0]u8 = undefined;
                const value = std.fmt.bufPrintZ(&line, "HDA.DET v=1 e={x:0>16} s={x:0>16} l={d} b={d} p={d}/{d} {s}", .{ self.epoch, self.sequence, self.lines, body.len, part, total, body[offset..end] }) catch {
                    self.failed = true;
                    return;
                };
                self.ctx.logInfo(value);
                self.parts += 1;
                offset = end;
            }
            self.lines += 1;
        }

        pub fn finish(self: *Self) bool {
            var line: [a.log_service_text_bytes:0]u8 = undefined;
            const text = std.fmt.bufPrintZ(&line, "HDA.SNAP end v=1 e={x:0>16} s={x:0>16} lines={d} parts={d} ok={d}", .{ self.epoch, self.sequence, self.lines, self.parts, @intFromBool(!self.failed and self.lines != 0) }) catch return false;
            self.ctx.logInfo(text);
            return !self.failed and self.lines != 0;
        }
    };
}

const Probe = struct {
    var queries: usize = 0;
    var creates: usize = 0;
    var destroys: usize = 0;
    var warnings: usize = 0;
    var ticks: u64 = 0;
    var permits: u32 = 0;
    var bad_epoch = false;
    var bad_handle = false;
    var refuse_create = false;
    var count: usize = 0;
    var lines: [64][a.log_service_text_bytes]u8 = undefined;
    var lengths: [64]usize = undefined;
    const handle: u64 = 0xf123456789abcdef;
    const epoch: u64 = 0xa123456789abcdef;
    fn reset() void {
        queries = 0;
        creates = 0;
        destroys = 0;
        warnings = 0;
        ticks = 0;
        permits = 0;
        bad_epoch = false;
        bad_handle = false;
        refuse_create = false;
        count = 0;
    }
    fn create(initial: u32, maximum: u32, out: *u64) callconv(.c) i32 {
        creates += 1;
        if (refuse_create or maximum != 1) return a.driver_semaphore_error_busy;
        permits = initial;
        out.* = handle;
        return 0;
    }
    fn acquire(key: u64, _: u64) callconv(.c) i32 {
        if (key != handle or permits == 0) return a.driver_semaphore_error_busy;
        permits -= 1;
        return 0;
    }
    fn release(key: u64) callconv(.c) i32 {
        if (key != handle or permits != 0) return a.driver_semaphore_error_overflow;
        permits += 1;
        return 0;
    }
    fn destroy(key: u64) callconv(.c) i32 {
        if (key != handle or permits != 1) return a.driver_semaphore_error_busy;
        destroys += 1;
        permits = 0;
        return 0;
    }
    fn status(key: u64, out: *a.DriverSemaphoreStatus) callconv(.c) i32 {
        out.* = .{ .handle = if (bad_handle) key +% 1 else key, .owner_epoch = if (bad_epoch) epoch +% 1 else epoch, .available = permits, .maximum = 1 };
        return 0;
    }
    fn semaphores(_: *const Probe) ?Semaphores {
        queries += 1;
        return .{ .table = .{ .create = @intFromPtr(&create), .acquire = @intFromPtr(&acquire), .release = @intFromPtr(&release), .destroy = @intFromPtr(&destroy), .status = @intFromPtr(&status) } };
    }
    fn tickCount(_: *const Probe) u64 {
        return ticks;
    }
    fn waitTicks(_: *const Probe, amount: u64) void {
        ticks += amount;
    }
    fn logWarn(_: *const Probe, _: [*:0]const u8) void {
        warnings += 1;
    }
    fn logInfo(_: *const Probe, text: [*:0]const u8) void {
        const body = std.mem.span(text);
        std.debug.assert(count < lines.len and body.len < a.log_service_text_bytes);
        @memcpy(lines[count][0..body.len], body);
        lengths[count] = body.len;
        count += 1;
    }
    fn line(index: usize) []const u8 {
        return lines[index][0..lengths[index]];
    }
};

test "disabled close details create no resource query allocation text or diagnostic sequence" {
    Probe.reset();
    const ctx = Probe{};
    var owner = Owner{};
    try std.testing.expect(owner.begin(&ctx, 3) == null);
    try std.testing.expectEqual(@as(usize, 0), Probe.queries + Probe.creates + Probe.count + Probe.warnings);
    try std.testing.expectEqual(@as(u64, 0), owner.sequence);
    try std.testing.expect(owner.close(&ctx));
    try std.testing.expectEqual(@as(usize, 0), Probe.destroys);
}

test "requested details use a real typed owner epoch and release the exact serial permit" {
    Probe.reset();
    const ctx = Probe{};
    var owner = Owner{};
    owner.configure(true);
    const first = owner.begin(&ctx, 3).?;
    try std.testing.expectEqual(Probe.epoch, first.epoch);
    try std.testing.expectEqual(Probe.handle, first.handle);
    try std.testing.expectEqual(@as(u64, 1), first.sequence);
    try std.testing.expect(owner.begin(&ctx, 0) == null);
    try std.testing.expect(first.release(&ctx));
    const second = owner.begin(&ctx, 3).?;
    try std.testing.expectEqual(@as(u64, 2), second.sequence);
    try std.testing.expectEqual(@as(usize, 1), Probe.creates);
    try std.testing.expect(second.release(&ctx));
    try std.testing.expect(owner.close(&ctx));
    try std.testing.expectEqual(@as(usize, 1), Probe.destroys);
}

test "wrong handles changed epochs and refused initialization never authorize a snapshot" {
    Probe.reset();
    const ctx = Probe{};
    var owner = Owner{};
    owner.configure(true);
    Probe.refuse_create = true;
    try std.testing.expect(owner.begin(&ctx, 3) == null);
    Probe.refuse_create = false;
    Probe.bad_handle = true;
    try std.testing.expect(owner.begin(&ctx, 3) == null);
    Probe.bad_handle = false;
    const first = owner.begin(&ctx, 3).?;
    try std.testing.expect(first.release(&ctx));
    Probe.bad_epoch = true;
    try std.testing.expect(owner.begin(&ctx, 3) == null);
    try std.testing.expectEqual(@as(u32, 1), Probe.permits);
    try std.testing.expectEqual(@as(u64, 1), owner.sequence);
    Probe.bad_epoch = false;
    owner.sequence = std.math.maxInt(u64);
    try std.testing.expect(owner.begin(&ctx, 3) == null);
    try std.testing.expectEqual(@as(u32, 1), Probe.permits);
    try std.testing.expect(owner.close(&ctx));
}

test "complete detail fragments preserve full sixty four bit keys and every original byte" {
    Probe.reset();
    const ctx = Probe{};
    var owner = Owner{};
    owner.configure(true);
    const ticket = owner.begin(&ctx, 3).?;
    defer _ = ticket.release(&ctx);
    var emitter = Emitter(Probe).begin(&ctx, ticket, .{ .output = std.math.maxInt(u64), .reset = std.math.maxInt(u64), .pci = 0xffffff }, "shutdown");
    var body: [max_body_bytes - 1:0]u8 = undefined;
    for (body[0..], 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));
    body[body.len] = 0;
    emitter.logInfo(&body);
    try std.testing.expect(emitter.finish());
    try std.testing.expect(std.mem.indexOf(u8, Probe.line(0), "e=a123456789abcdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, Probe.line(0), "o=ffffffffffffffff") != null);
    var restored: [max_body_bytes]u8 = undefined;
    var used: usize = 0;
    for (2..Probe.count - 1) |i| {
        const line = Probe.line(i);
        const part = std.mem.indexOf(u8, line, " p=").?;
        const start = std.mem.indexOfScalarPos(u8, line, part + 3, ' ').? + 1;
        @memcpy(restored[used..][0 .. line.len - start], line[start..]);
        used += line.len - start;
    }
    try std.testing.expectEqualSlices(u8, &body, restored[0..used]);
    try std.testing.expect(std.mem.endsWith(u8, Probe.line(Probe.count - 1), "lines=1 parts=8 ok=1"));
}

test "overflow and empty detail bodies cannot emit a complete receipt" {
    Probe.reset();
    const ctx = Probe{};
    var owner = Owner{};
    owner.configure(true);
    const ticket = owner.begin(&ctx, 3).?;
    defer _ = ticket.release(&ctx);
    var emitter = Emitter(Probe).begin(&ctx, ticket, .{ .output = 1, .reset = 1, .pci = 0 }, "close");
    const body = [_:0]u8{'x'} ** max_body_bytes;
    emitter.logInfo(&body);
    try std.testing.expect(!emitter.finish());
    try std.testing.expect(std.mem.endsWith(u8, Probe.line(Probe.count - 1), "lines=0 parts=0 ok=0"));
}
