const std = @import("std");

const TableHeader = @import("TableHeader.zig").TableHeader;

pub const RSDT = extern struct {
    header: TableHeader align(1),
    first_other_table: u32 align(1),

    pub fn findTable(self: *RSDT, sig: *const [4]u8) ?*TableHeader {
        const table_count = (self.header.length - @sizeOf(TableHeader)) / 4;
        const table = for (self.getOtherTables()[0..table_count]) |addr| {
            const ptr: *TableHeader = @ptrFromInt(addr);
            if (ptr.validate() and
                std.mem.eql(u8, &ptr.signature, sig))
                break ptr;
        } else null;
        return table;
    }

    fn getOtherTables(self: *RSDT) []align(1) u32 {
        const tmp: [*]align(1) u32 = @ptrCast(&self.first_other_table);
        return tmp[0 .. (self.header.length - @sizeOf(TableHeader)) / 4];
    }

    comptime {
        std.debug.assert(@sizeOf(RSDT) == 40 * @sizeOf(u8));
    }
};
