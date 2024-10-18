const std = @import("std");

pub const TableHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),

    pub fn validate(self: *TableHeader) bool {
        const bytes: []u8 = @as([*]u8, @ptrCast(self))[0..self.length];
        var sum: u8 = 0;
        for (bytes) |byte| {
            sum, _ = @addWithOverflow(byte, sum);
        }
        return sum == 0;
    }

    comptime {
        std.debug.assert(@sizeOf(TableHeader) == 36 * @sizeOf(u8));
    }
};
