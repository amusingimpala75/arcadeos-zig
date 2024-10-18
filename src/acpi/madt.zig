const TableHeader = @import("TableHeader.zig").TableHeader;

pub const MADT = extern struct {
    header: TableHeader align(1),
    lapic_addr: u32 align(1),
    flags: u32 align(1),
    first_entry: EntryHeader align(1),

    pub fn iterator(self: *MADT) Iterator {
        return .{ .madt = self, .current = &self.first_entry };
    }

    pub const Iterator = struct {
        madt: *MADT,
        current: *EntryHeader,

        pub fn next(self: *Iterator) ?*EntryHeader {
            const cur_addr = @intFromPtr(self.current);

            if (!self.hasNext()) {
                return null;
            }

            self.current = @ptrFromInt(cur_addr + self.current.length);
            return @ptrFromInt(cur_addr);
        }

        pub fn hasNext(self: *Iterator) bool {
            return @intFromPtr(self.current) < @intFromPtr(self.madt) + self.madt.header.length;
        }
    };

    const Entry = union(enum) {
        lapic: *LAPIC,
        ioapic: *IOAPIC,
        ioapic_interrupt_override: *IOAPICInterruptOverride,
        ioapic_nmi_source: *EntryHeader,
        lapic_nmi: *EntryHeader,
        lapic_addr_override: *EntryHeader,
        x2apic: *EntryHeader,
    };

    pub const EntryHeader = extern struct {
        type: u8 align(1),
        length: u8 align(1),

        pub fn parse(self: *EntryHeader) Entry {
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

    const IOAPICInterruptOverride = extern struct {
        header: EntryHeader align(1),
        bus_source: u8 align(1),
        irq_source: u8 align(1),
        global_source_interrupt: u32 align(1),
        flags: Flags align(1),
    };

    const Flags = packed struct(u16) {
        _backing: u16,

        const Active = enum {
            low,
            high,
        };

        const Trigger = enum {
            level,
            edge,
        };

        fn trigger(self: Flags) Trigger {
            return if (self.backing & 8)
                .level
            else
                .edge;
        }

        fn active(self: Flags) Active {
            return if (self.backing & 2)
                .low
            else
                .high;
        }
    };
};
