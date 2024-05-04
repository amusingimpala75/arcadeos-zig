const std = @import("std");

const paging = @import("x86_64/paging.zig");

pub fn Slab(comptime T: type) type {
    return struct {
        const This = @This();
        const LinkedList = std.SinglyLinkedList(Page);

        head: *Page,

        pub fn init(self: *This) !void {
            self.head = @alignCast(@ptrCast(try paging.PageTable.pml4Recurse().allocPage()));
            self.head.* = Page{};
            for (0..self.head.items.len) |i| {
                self.head.release(&self.head.items[i]);
            }
        }

        pub fn create(self: *This) !*T {
            const page: *Page = blk: {
                var p = self.head;
                while (true) {
                    for (p.metadata.free_map) |b| {
                        if (b != 0) {
                            break :blk p;
                        }
                    }
                    if (p.metadata.next == null) {
                        try self.newPage();
                        break :blk self.head;
                    }
                    p = p.metadata.next.?;
                }
            };
            return page.use(page.findFirst().?);
        }

        pub fn destroy(self: *This, obj: *T) void {
            // TODO proper bounds checking
            _ = self; // autofix
            const obj_addr = @intFromPtr(obj);
            const page: *Page = @ptrFromInt(obj_addr - (obj_addr % paging.page_size));
            page.release(obj);
        }

        fn newPage(self: *This) !void {
            const page: *Page = @alignCast(@ptrCast(try paging.PageTable.pml4Recurse().allocPage()));
            page.* = Page{};
            page.metadata.next = self.head;
            self.head = page;
            for (0..self.head.items.len) |i| {
                self.head.release(&self.head.items[i]);
            }
        }

        const Page = struct {
            const item_count = (paging.page_size - @sizeOf(Metadata)) / @sizeOf(T);

            items: [item_count]T = [1]T{std.mem.zeroes(T)} ** item_count,
            metadata: Metadata = Metadata{},

            const Metadata = struct {
                const max_count = paging.page_size / @sizeOf(T);

                next: ?*Page = null,
                // 1 means free, 0, means used
                free_map: [max_count / 8]u8 = [1]u8{0} ** (max_count / 8),
                // technically this could be reduced a few
                // but I don't want to figure out the complex
                // logic since reducing the free_map could increase
                // the items which would then increase the free_map
            };

            pub fn findFirst(self: *Page) ?u12 {
                for (self.metadata.free_map, 0..) |b, i| {
                    if (b != 0) {
                        return @intCast((i * 8) + @ctz(b));
                    }
                }
                return null;
            }

            fn use(self: *Page, idx: u12) *T {
                self.metadata.free_map[idx / 8] &= ~(@as(u8, @intCast(1)) << @intCast(idx % 8));
                return &self.items[idx];
            }

            fn release(self: *Page, item: *T) void {
                item.* = std.mem.zeroes(T);
                const idx: u12 = @intCast((@intFromPtr(item) - @intFromPtr(&self.items[0])) / @sizeOf(T));
                self.metadata.free_map[idx / 8] |= (@as(u8, @intCast(1)) << @intCast(idx % 8));
            }

            comptime {
                std.debug.assert(@sizeOf(Page) == paging.page_size);
            }
        };
    };
}
