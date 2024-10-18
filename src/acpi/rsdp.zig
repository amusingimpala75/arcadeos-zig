const std = @import("std");

const RSDT = @import("rsdt.zig").RSDT;
const arch = @import("../kernel.zig").arch;

pub const RSDP = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oemid: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_addr: u32 align(1),

    pub fn get() !*RSDP {
        var rsdp: *RSDP = @ptrFromInt(arch.bootloader_info.rsdp_phys_addr + arch.bootloader_info.hhdm_start);
        if (!rsdp.validateRsdp())
            return error.InvalidRsdp;
        if (rsdp.revision > 0)
            return error.RsdpIsExtended;
        return rsdp;
    }

    pub fn getTable(self: *RSDP) *RSDT {
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
