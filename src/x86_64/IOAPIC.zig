const IOAPIC = @This();
const std = @import("std");

const log = std.log.scoped(.ioapic);

addr: usize,
id: u32,
count: u8,
version: u8,

pub const RedirectionEntry = struct {
    vector: u8,
    del_mode: DeliveryMode,
    dest_mode: DestiniationMode,
    waiting_on_lapic: bool,
    active_low: bool = false,
    remote_irr: bool, // TODO what is this?
    trigger_level: bool,
    mask: bool,
    destination: u8,

    pub const DeliveryMode = enum(u3) {
        fixed = 0b000,
        lowest_priority = 0b001,
        smi = 0b010,
        nmi = 0b100,
        init = 0b101,
        extinit = 0b111,
    };

    pub const DestiniationMode = enum(u1) {
        physical = 0,
        logical = 1,
    };

    // TODO there has to be a better way to do this.
    pub fn lowerBytes(self: RedirectionEntry) u32 {
        const mask: u32 = if (self.mask) 1 else 0;
        const trig_lev: u32 = if (self.trigger_level) 1 else 0;
        const rem_irr: u32 = if (self.remote_irr) 1 else 0;
        const act_low: u32 = if (self.active_low) 1 else 0;
        const wait: u32 = if (self.waiting_on_lapic) 1 else 0;
        const dest_mode: u32 = @intFromEnum(self.dest_mode);
        const del_mode: u32 = @intFromEnum(self.del_mode);
        const vector: u32 = self.vector;

        return mask << 16 |
            trig_lev << 15 |
            rem_irr << 14 |
            act_low << 13 |
            wait << 12 |
            dest_mode << 11 |
            del_mode << 8 |
            vector;
    }

    pub fn upperBytes(self: RedirectionEntry) u32 {
        const val: u32 = self.destination;
        return val << (56 - 32);
    }
};

const PageTable = @import("../paging.zig").PageTable;

// TODO: is this address vaddr or paddr?
pub fn init(addr: usize) IOAPIC {
    PageTable.pml4Recurse().map(addr, addr, .kernel_rw) catch @panic("cannot reserve ioapic page");

    const reg1 = read(addr, 1);

    return .{
        .addr = addr,
        .id = read(addr, 0),
        .version = @truncate(reg1),
        .count = @truncate(reg1 >> 16),
    };
}

pub fn configureVector(self: IOAPIC, idx: u32, entry: RedirectionEntry) void {
    if (idx >= self.count) {
        log.err("Index {} out of bounds for length {}", .{ idx, self.count });
        @panic("IOAPIC vector out of bounds");
    }

    const reg = 0x10 + 2 * idx;

    write(self.addr, reg, entry.lowerBytes());

    write(self.addr, reg + 1, entry.upperBytes());
}

fn read(addr: usize, idx: u32) u32 {
    const sel: *volatile u32 = @ptrFromInt(addr);
    const win: *volatile u32 = @ptrFromInt(addr + 0x10);
    sel.* = idx;
    return win.*;
}

fn write(addr: usize, idx: u32, val: u32) void {
    const sel: *volatile u32 = @ptrFromInt(addr);
    const win: *volatile u32 = @ptrFromInt(addr + 0x10);
    sel.* = idx;
    win.* = val;
}
