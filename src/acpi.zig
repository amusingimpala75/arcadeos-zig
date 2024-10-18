const std = @import("std");

pub const log = std.log.scoped(.acpi);

const RSDP = @import("acpi/rsdp.zig").RSDP;
const RSDT = @import("acpi/rsdt.zig").RSDT;
const MADT = @import("acpi/madt.zig").MADT;

const Information = struct {
    ioapic_buf: [8]u32 = undefined,
    ioapics: []u32 = &[0]u32{},
};

pub const ACPIError = error{
    MalformedACPI,
};

pub fn getInfo() ACPIError!Information {
    const rsdp = RSDP.get() catch |err| switch (err) {
        error.InvalidRsdp => return ACPIError.MalformedACPI,
        error.RsdpIsExtended => @panic("XSDT is unimplemented"),
    };
    const rsdt = rsdp.getTable();
    if (!rsdt.header.validate())
        return ACPIError.MalformedACPI;
    const madt: *MADT = @ptrCast(rsdt.findTable("APIC") orelse return ACPIError.MalformedACPI);
    var iterator = madt.iterator();

    var info: Information = .{};

    while (iterator.next()) |entry| {
        switch (entry.parse()) {
            .ioapic => |ioapic| {
                if (info.ioapics.len < info.ioapic_buf.len) {
                    info.ioapic_buf[info.ioapics.len] = ioapic.addr;
                    info.ioapics = info.ioapic_buf[0 .. info.ioapics.len + 1];
                    log.debug("ioapic at {X}", .{ioapic.addr});
                }
            },
            .ioapic_interrupt_override => |override| {
                log.debug(
                    "irq override: {} {} {}",
                    .{
                        override.irq_source,
                        override.bus_source,
                        override.global_source_interrupt,
                    },
                );
            },
            else => {},
        }
    }

    return info;
}
