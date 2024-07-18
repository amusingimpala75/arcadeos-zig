//! heap.zig manages allocating to the heap
//! the current interfaces are the Slab allocator

const std = @import("std");

const paging = @import("paging.zig");

/// Creates a slab of a given type
/// the slab automatically expands as necessary,
/// and does not need fully contiguous memory
///
/// This is not a great design, as fragmentation
/// due to many allocations will cause the newer allocations
/// to be rather slow. We can re-write it as a slub.
pub fn Slab(comptime T: type) type {
    return struct {
        const This = @This();
        const LinkedList = std.SinglyLinkedList(Page);

        head: *Page,

        /// Initializes the slab with one page of storage
        pub fn init(self: *This) !void {
            try self.newPage();
        }

        /// allocate an instance, erroring if new pages were
        /// needed but could not be allocated
        pub fn create(self: *This) !*T {
            const page: *Page = blk: {
                var p: ?*Page = self.head;

                // try checking all of the existing pages for
                // free entries
                while (p) |page| : (p = p.metadata.next) {
                    for (page.metadata.free_map) |b| {
                        if (!b.full()) {
                            break :blk page;
                        }
                    }
                }

                // otherwise, allocate a new page
                try self.newPage();
                break :blk self.head;
            };
            return page.use(page.findFirst().?);
        }

        /// Frees an object allocated on the slab
        pub fn destroy(self: *This, obj: *T) void {
            // TODO proper bounds checking
            _ = self; // autofix
            const obj_addr = @intFromPtr(obj);
            const page: *Page = @ptrFromInt(obj_addr & ~paging.page_size);
            page.release(obj);
        }

        /// Allocates a new page for the slab, prepending it to the list
        /// to ensure that it is available immediately
        fn newPage(self: *This) !void {
            const page: *Page = @alignCast(@ptrCast(try paging.PageTable.pml4Recurse().allocPage()));
            page.* = Page{};
            page.metadata.next = self.head;
            self.head = page;
            for (0..self.head.items.len) |i| {
                self.head.release(&self.head.items[i]);
            }
        }

        /// Represents a page of the items. It keeps track of its
        /// own metadata.
        const Page = struct {
            const item_count = (paging.page_size - @sizeOf(Metadata)) / @sizeOf(T);

            items: [item_count]T = undefined,
            metadata: Metadata = Metadata{},

            /// Metadata for tracking which objects are free in this page,
            /// as well as the next item in the list
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

            /// checks if there are any available entries in this page
            pub fn full(self: *const Metadata) bool {
                return for (self.free_map) |byte| {
                    if (byte != 0) {
                        break false;
                    }
                } else true;
            }

            /// Gets the index of the first available item
            pub fn findFirst(self: *Page) ?u12 {
                for (self.metadata.free_map, 0..) |b, i| {
                    if (b != 0) {
                        return @intCast((i * 8) + @ctz(b));
                    }
                }
                return null;
            }

            /// mark the item as unusable
            fn use(self: *Page, idx: u12) *T {
                self.metadata.free_map[idx / 8] &= ~(@as(u8, @intCast(1)) << @intCast(idx % 8));
                return &self.items[idx];
            }

            /// mark the item as usable
            /// also zeros the item
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
