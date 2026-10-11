const std = @import("std");

pub const nvidia_vendor: u16 = 0x10de;
const legacy_offset: u16 = 0x4c;
const legacy_mask: u32 = 0x000f_0101;
const no_snoop: u32 = 0x0800;

// These are PCI configuration fields, NOT the HDA MMIO registers at 0x4c.
// Old NVIDIA PCI HDA uses stream/transport snoop bits (Linux azx_init_pci).
// PCIe functions instead expose Device Control.NoSnoop: clear permission for
// noncoherent transactions when all driver DMA uses normal cached RAM.
// Modern NVIDIA GPUs need not implement the old vendor snoop registers.

/// Owned with the PCI controller. Enable after reset, before starting DMA;
/// restore only after stream, position and command DMA stop. Unconfirmed
/// writes retain the original bits and register identity for cleanup/retry.
pub const Configuration = struct {
    offset: u16 = legacy_offset,
    mask: u32 = legacy_mask,
    required: u32 = legacy_mask,
    write_mask: u32 = 0xffff_ffff,
    original: ?u32 = null,
    observed: ?u32 = null,
    restore_pending: bool = false,

    pub fn enable(self: *Configuration, vendor: u16, io: anytype) bool {
        if (vendor != nvidia_vendor) return true;
        if (self.original != null or !self.selectRegister(io)) return false;
        const before = io.read(self.offset);
        if (before == 0xffff_ffff) return false;
        self.original = before;
        self.observed = before;
        if (before & self.mask == self.required) return true;
        self.restore_pending = true;
        const wanted = (before & ~self.mask) | self.required;
        if (!io.write(self.offset, wanted & self.write_mask)) return false;
        const after = io.read(self.offset);
        self.observed = if (after == 0xffff_ffff) null else after;
        return self.observed != null and after & self.mask == self.required;
    }

    pub fn restore(self: *Configuration, io: anytype) bool {
        if (!self.restore_pending) return true;
        const original = self.original orelse return false;
        const current = io.read(self.offset);
        if (current == 0xffff_ffff) return false;
        // Only owned bits come from the snapshot. Device Status is W1C and
        // Device Control bit 15 initiates FLR: neither may be echoed in a write.
        const restored = (current & ~self.mask) | (original & self.mask);
        if (restored != current and !io.write(self.offset, restored & self.write_mask)) return false;
        const after = io.read(self.offset);
        self.observed = if (after == 0xffff_ffff) null else after;
        if (self.observed == null or after & self.mask != original & self.mask) return false;
        self.restore_pending = false;
        return true;
    }

    fn selectRegister(self: *Configuration, io: anytype) bool {
        const status = io.read(4);
        if (status == 0xffff_ffff) return false;
        if (status & (1 << 20) == 0) return true;
        const pointer = io.read(0x34);
        if (pointer == 0xffff_ffff) return false;
        var cap: u16 = @as(u8, @truncate(pointer));
        if (cap == 0) return false;
        var visited: u64 = 0;
        while (cap != 0) {
            if (cap < 0x40 or cap > 0xfc or cap & 3 != 0) return false;
            const bit = @as(u64, 1) << @as(u6, @intCast(cap / 4));
            if (visited & bit != 0) return false;
            visited |= bit;
            const header = io.read(cap);
            if (header == 0xffff_ffff) return false;
            if (@as(u8, @truncate(header)) == 0x10) {
                const kind = (header >> 20) & 0xf;
                if (cap > 0xf4 or (header >> 16) & 0xf == 0 or
                    (kind != 0 and kind != 1 and kind != 9)) return false;
                self.offset = cap + 8;
                self.mask = no_snoop;
                self.required = 0;
                self.write_mask = 0x7fff;
                return true;
            }
            cap = @as(u8, @truncate(header >> 8));
        }
        return true;
    }
};

const TestIo = struct {
    values: [64]u32 = .{0} ** 64,
    writes: usize = 0,
    inaccessible: bool = false,
    ignore_write: bool = false,
    fail_after_write: bool = false,
    device_control: ?u16 = null,
    last_write: u32 = 0,

    fn pci(before: u32) TestIo {
        var io: TestIo = .{};
        io.values[legacy_offset / 4] = before;
        return io;
    }

    fn pcie(before: u32) TestIo {
        var io: TestIo = .{ .device_control = 0x68 };
        io.values[4 / 4] = 1 << 20;
        io.values[0x34 / 4] = 0x60;
        io.values[0x60 / 4] = 0x0002_0010;
        io.values[0x68 / 4] = before;
        return io;
    }

    fn read(self: *const TestIo, offset: u16) u32 {
        return if (self.inaccessible) 0xffff_ffff else self.values[offset / 4];
    }

    fn write(self: *TestIo, offset: u16, value: u32) bool {
        self.writes += 1;
        self.last_write = value;
        if (!self.ignore_write) {
            self.values[offset / 4] = if (self.device_control == offset)
                (self.values[offset / 4] & 0xffff_0000 & ~value) | (value & 0xffff)
            else value;
        }
        return !self.fail_after_write;
    }
};

test "PCIe No Snoop is disabled without changing status or legacy registers and restored exactly" {
    var config: Configuration = .{};
    var io = TestIo.pcie(0x0009_2930);
    try std.testing.expect(config.enable(nvidia_vendor, &io));
    try std.testing.expectEqual(@as(u16, 0x68), config.offset);
    try std.testing.expectEqual(@as(u32, 0x0009_2130), io.read(0x68));
    try std.testing.expectEqual(@as(u32, 0), io.read(legacy_offset));
    try std.testing.expectEqual(@as(u32, 0), io.last_write & 0xffff_8000);
    io.values[0x68 / 4] ^= 0x100;
    try std.testing.expect(config.restore(&io));
    try std.testing.expectEqual(@as(u32, 0x0009_2830), io.read(0x68));
    try std.testing.expectEqual(@as(u32, 0), io.last_write & 0xffff_8000);
}

test "legacy NVIDIA coherent DMA preserves unrelated live configuration" {
    for ([_]u32{ 0, 0x1234_56a8, 0xabf0_0101 }) |before| {
        var config: Configuration = .{};
        var io = TestIo.pci(before);
        try std.testing.expect(config.enable(nvidia_vendor, &io));
        try std.testing.expectEqual(before & ~legacy_mask, io.read(legacy_offset) & ~legacy_mask);
        try std.testing.expectEqual(legacy_mask, io.read(legacy_offset) & legacy_mask);
        try std.testing.expect(config.restore_pending);
        io.values[legacy_offset / 4] ^= 0x8000_0080;
        try std.testing.expect(config.restore(&io));
        try std.testing.expectEqual(before ^ 0x8000_0080, io.read(legacy_offset));
        try std.testing.expect(!config.restore_pending);
        try std.testing.expect(config.restore(&io));
        try std.testing.expectEqual(@as(usize, 2), io.writes);
    }
}

test "other vendors and already coherent PCI or PCIe need no configuration ownership" {
    var other: Configuration = .{};
    var inaccessible: TestIo = .{ .inaccessible = true };
    try std.testing.expect(other.enable(0x8086, &inaccessible));
    try std.testing.expect(other.restore(&inaccessible));
    try std.testing.expectEqual(@as(usize, 0), inaccessible.writes);
    for ([_]TestIo{ TestIo.pci(0x120f_0101), TestIo.pcie(0x0009_2130) }) |initial| {
        var ready: Configuration = .{};
        var io = initial;
        try std.testing.expect(ready.enable(nvidia_vendor, &io));
        try std.testing.expect(ready.restore(&io));
        try std.testing.expect(!ready.restore_pending);
        try std.testing.expectEqual(@as(usize, 0), io.writes);
    }
}

test "unavailable or malformed PCI capability chains cannot admit DMA or configuration writes" {
    for ([_]u32{ 0x0002_6011, 0x0002_6311, 0x0042_0010, 0xffff_ffff }) |bad| {
        var config: Configuration = .{};
        var io = TestIo.pcie(0x0009_2930);
        io.values[0x60 / 4] = bad;
        try std.testing.expect(!config.enable(nvidia_vendor, &io));
        try std.testing.expect(config.restore(&io));
        try std.testing.expectEqual(@as(usize, 0), io.writes);
    }
    var config: Configuration = .{};
    var io: TestIo = .{ .inaccessible = true };
    try std.testing.expect(!config.enable(nvidia_vendor, &io));
    try std.testing.expect(config.restore(&io));
}

test "unacknowledged or ignored writes retain cleanup and never admit DMA" {
    for ([_]TestIo{ TestIo.pci(0), TestIo.pcie(0x0009_2930) }) |initial| {
        var config: Configuration = .{};
        var io = initial;
        io.fail_after_write = true;
        try std.testing.expect(!config.enable(nvidia_vendor, &io));
        try std.testing.expect(config.restore_pending);
        try std.testing.expect(!config.enable(nvidia_vendor, &io));
        try std.testing.expect(!config.restore(&io));
        try std.testing.expect(config.restore_pending);
        io.fail_after_write = false;
        try std.testing.expect(config.restore(&io));
        try std.testing.expectEqual(initial.read(config.offset), io.read(config.offset));
        var ignored: Configuration = .{};
        io.ignore_write = true;
        try std.testing.expect(!ignored.enable(nvidia_vendor, &io));
        try std.testing.expect(ignored.restore_pending);
        try std.testing.expect(ignored.restore(&io));
    }
}

test "restoration retains ownership until exact readback succeeds" {
    for ([_]TestIo{ TestIo.pci(0), TestIo.pcie(0x0009_2930) }) |initial| {
        var config: Configuration = .{};
        var io = initial;
        try std.testing.expect(config.enable(nvidia_vendor, &io));
        io.inaccessible = true;
        try std.testing.expect(!config.restore(&io));
        io.inaccessible = false;
        io.ignore_write = true;
        try std.testing.expect(!config.restore(&io));
        try std.testing.expect(config.restore_pending);
        io.ignore_write = false;
        try std.testing.expect(config.restore(&io));
        try std.testing.expectEqual(initial.read(config.offset), io.read(config.offset));
    }
}
