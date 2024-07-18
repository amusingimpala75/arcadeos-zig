const std = @import("std");

const arch = @import("arch.zig");

const Information = struct {
    ioapic_buf: [8]u32 = undefined,
    ioapics: []u32 = &[0]u32{},
};

pub fn getInfo() !Information {
    const rsdp = try RSDP.get();
    const rsdt = rsdp.getTable();
    if (!rsdt.header.validate())
        return error.InvalidRsdt;
    const madt: *MADT = @ptrCast(rsdt.findTable("APIC") orelse return error.MadtMissing);
    var entry: *MADT.EntryHeader = &madt.first_entry;

    var info: Information = .{};

    while (true) {
        switch (entry.parse()) {
            .ioapic => |ioapic| {
                if (info.ioapics.len < info.ioapic_buf.len) {
                    info.ioapic_buf[info.ioapics.len] = ioapic.addr;
                    info.ioapics = info.ioapic_buf[0 .. info.ioapics.len + 1];
                }
            },
            else => {},
        }
        entry = madt.nextEntry(entry) orelse break;
    }

    return info;
}

const RSDP = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oemid: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_addr: u32 align(1),

    fn get() !*RSDP {
        var rsdp: *RSDP = @alignCast(@ptrCast(arch.bootloader_info.rsdt_phys_addr));
        if (!rsdp.validateRsdp())
            return error.InvalidRsdp;
        if (rsdp.revision > 0)
            return error.RsdpIsExtended;
        return rsdp;
    }

    fn getTable(self: *RSDP) *RSDT {
        const addr = self.rsdt_addr;
        return @ptrFromInt(addr);
    }

    fn validateRsdp(self: *RSDP) bool {
        const bytes: *[20]u8 = @ptrCast(self);
        var sum: u8 = 0;
        for (bytes) |byte| {
            sum, _ = @addWithOverflow(byte, sum);
        }
        return sum == 0;
    }

    comptime {
        std.debug.assert(@sizeOf(RSDP) == 20 * @sizeOf(u8));
    }
};

const SDTHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),

    fn validate(self: *SDTHeader) bool {
        const bytes: []u8 = @as([*]u8, @ptrCast(self))[0..self.length];
        var sum: u8 = 0;
        for (bytes) |byte| {
            sum, _ = @addWithOverflow(byte, sum);
        }
        return sum == 0;
    }

    comptime {
        std.debug.assert(@sizeOf(SDTHeader) == 36 * @sizeOf(u8));
    }
};

const RSDT = extern struct {
    header: SDTHeader align(1),
    first_other_table: u32 align(1),

    fn findTable(self: *RSDT, sig: *const [4]u8) ?*SDTHeader {
        const table_count = (self.header.length - @sizeOf(SDTHeader)) / 4;
        const table = for (self.getOtherTables()[0..table_count]) |addr| {
            const ptr: *SDTHeader = @ptrFromInt(addr);
            if (ptr.validate() and
                std.mem.eql(u8, &ptr.signature, sig))
                break ptr;
        } else null;
        return table;
    }

    fn getOtherTables(self: *RSDT) []align(1) u32 {
        const tmp: [*]align(1) u32 = @ptrCast(&self.first_other_table);
        return tmp[0 .. (self.header.length - @sizeOf(SDTHeader)) / 4];
    }

    comptime {
        std.debug.assert(@sizeOf(RSDT) == 40 * @sizeOf(u8));
    }
};

const MADT = extern struct {
    header: SDTHeader align(1),
    lapic_addr: u32 align(1),
    flags: u32 align(1),
    first_entry: EntryHeader align(1),

    fn nextEntry(self: *MADT, prev: *EntryHeader) ?*EntryHeader {
        const next = @intFromPtr(prev) + prev.length;
        if (next >= @intFromPtr(self) + self.header.length) {
            return null;
        }
        return @ptrFromInt(next);
    }

    const Entry = union(enum) {
        lapic: *LAPIC,
        ioapic: *IOAPIC,
        ioapic_interrupt_override: *EntryHeader,
        ioapic_nmi_source: *EntryHeader,
        lapic_nmi: *EntryHeader,
        lapic_addr_override: *EntryHeader,
        x2apic: *EntryHeader,
    };

    const EntryHeader = extern struct {
        type: u8 align(1),
        length: u8 align(1),

        fn parse(self: *EntryHeader) Entry {
            return switch (self.type) {
                0 => .{ .lapic = @ptrCast(self) },
                1 => .{ .ioapic = @ptrCast(self) },
                2 => .{ .ioapic_interrupt_override = @ptrCast(self) },
                3 => .{ .ioapic_nmi_source = @ptrCast(self) },
                4 => .{ .lapic_nmi = @ptrCast(self) },
                5 => .{ .lapic_addr_override = @ptrCast(self) },
                9 => .{ .x2apic = @ptrCast(self) },
                else => unreachable,
            };
        }
    };

    const LAPIC = extern struct {
        header: EntryHeader align(1),
        processor_id: u8 align(1),
        id: u8 align(1),
        flags: u32 align(1),
    };

    const IOAPIC = extern struct {
        header: EntryHeader align(1),
        id: u8 align(1),
        reserved: u8 align(1),
        addr: u32 align(1),
        interrupt_base: u32 align(1),
    };
};
