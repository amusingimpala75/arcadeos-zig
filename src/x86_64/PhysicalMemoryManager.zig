const std = @import("std");
const limine = @import("limine");

const log = std.log.scoped(.physical_mem_manager);

const kernel = @import("../kernel.zig");

const PhysicalMemoryManager = @This();

export var mem_map_request = limine.MemoryMapRequest{};
const block_size = 4096;

//8 levels:
// requires 3 bits (4 bits per block when including the free bit)
// 4K -> 512K

const max_order = 7;

/// Stores data about a block, specifically whether it is free, and what level (2 ^ n blocks large) is it
const BlockEntry = packed struct {
    level: u3,
    free: bool,
};

/// Group of `BlockEntry`s. I still have to double check if it is necessary
/// in order to cram two `BlockEntry`s per byte in an array.
const BlockEntryPair = packed struct(u8) {
    l: BlockEntry,
    r: BlockEntry,
};

/// Since `BlockEntry`s can be in the left or right half of a byte, Zig wanted me to
/// distinguish both of those when working with pointer to `BlockEntry`s. So we get this.
const BlockEntryUnion = union(enum) {
    l: *align(1:0:1) BlockEntry,
    r: *align(1:4:1) BlockEntry,

    fn level(self: BlockEntryUnion) u3 {
        if (self == .l) {
            return self.l.level;
        }
        return self.r.level;
    }

    fn setLevel(self: BlockEntryUnion, o: u3) void {
        if (self == .l) {
            self.l.level = o;
        } else {
            self.r.level = o;
        }
    }

    fn free(self: BlockEntryUnion) bool {
        if (self == .l) {
            return self.l.free;
        }
        return self.r.free;
    }

    fn setFree(self: BlockEntryUnion, f: bool) void {
        if (self == .l) {
            self.l.free = f;
        } else {
            self.r.free = f;
        }
    }
};

const FreeList = std.SinglyLinkedList(usize);

/// O(1) lookup of block size / free status
block_map: []BlockEntryPair,
free_lists: [max_order + 1]FreeList,
/// Free list nodes. Since this has to be done without an external
/// mem manager, we just make a pool of the free list nodes here,
/// as it's own linked list.
free_list_nodes: FreeList,
/// Number of blocks managed by the PMM
block_count: usize,
/// Size of the kernel
/// TODO:
/// This should probably be elsewhere, but for now
/// here it is since this is a place that we loop over the
/// limine memmap
klen: usize,

comptime {
    // PMM is not allowed to be larger than one block
    std.debug.assert(@sizeOf(PhysicalMemoryManager) <= block_size);
}

/// Sets up a PMM at the virtual address `addr`, which for our purposes is either going to be
/// in the lower half direct map (virt = phys) or the higher half direct map (virt = phys + HHDM_START).
/// The PMM sits in it's own page, immediately followed by blocks for the `block_map` (padded out to the end
/// of the block), finally ending with blocks for the free list nodes (also padded out to the end of the block).
fn initAt(addr: usize, block_count: usize, klen: usize) *PhysicalMemoryManager {
    var self: *PhysicalMemoryManager = @ptrFromInt(addr);
    self.block_count = block_count;
    self.klen = klen;

    // Half as many block pairs as blocks, unless odd in which case +1
    const pair_len = divCeil(block_count, 2);

    self.block_map = @as(
        [*]BlockEntryPair,
        @ptrFromInt(addr + block_size),
        // Skip the first block as that is the location of the main
        // PMM data structure.
    )[0..pair_len];

    // Initialize these free lists empty
    for (0..self.free_lists.len) |i| {
        self.free_lists[i] = .{};
    }
    self.free_list_nodes = .{};

    // Find the last entry of the block pairs, go just past that,
    // round up to the next block, and set that as the free_nodes
    const free_nodes = @as([*]FreeList.Node, @ptrFromInt(blk: {
        const last_block_pair = @intFromPtr(&self.block_map[pair_len - 1]);
        const next_unused_mem = last_block_pair + @sizeOf(BlockEntryPair);
        break :blk divCeil(next_unused_mem, block_size) * block_size;
    }))[0..pair_len];

    // Initially set all free list nodes as extra storage, to be grabbed during
    // `setupBuddies`
    for (free_nodes) |*node| {
        self.free_list_nodes.prepend(node);
    }

    // Actually register all of the `BlockEntryPair`s and `FreeList`s
    self.setupBuddies(max_order, 0, block_count);

    return self;
}

/// Returns the size, in bytes, that the PMM and it's associated data structures
/// (ie. pair map and free lists) require.
pub fn byteSize(self: PhysicalMemoryManager) usize {
    const ramSize = self.block_count * block_size;
    const selfBlockSize = pmmBlockSize(ramSize);
    const selfByteSize = selfBlockSize * block_size;
    return selfByteSize;
}

// Requires the free list nodes to be set up first
fn setupBuddies(self: *PhysicalMemoryManager, order: u3, start: usize, end: usize) void {
    const step: usize = @as(usize, 1) << order;
    var idx = start;
    // TODO: I'm not feeling great about this <=, I need to think through it to be sure what I'm doing is correct
    while (idx + step <= end) : (idx += step) {
        for (0..step) |i| {
            var blk = self.getBlock(idx + i);
            blk.setFree(true);
            blk.setLevel(order);
        }
        var node = self.free_list_nodes.popFirst().?;
        node.data = idx;
        self.free_lists[order].prepend(node);
    }

    if (order > 0) {
        @call(.always_tail, setupBuddies, .{ self, order - 1, idx, end });
    }
}

// Merge the block at <block> with it's buddy if possible (ie. same order and free),
// repeating as many times as possible
fn mergeBlocks(self: *PhysicalMemoryManager, block: usize) void {
    // get the left and right indices of the buddies
    const order = self.getBlock(block).level();
    const order_shifted = @as(usize, 1) << order;
    const left: usize = blk: {
        if (block & order_shifted == 0) {
            break :blk block;
        }
        break :blk block - order_shifted;
    };
    const right: usize = blk: {
        if (block & order_shifted == 0) {
            break :blk block + order_shifted;
        }
        break :blk block;
    };

    // Get the corresponding BlockEntries
    const lb = self.getBlock(left);
    const rb = self.getBlock(right);

    // Ensure that both blocks are free and of the same order
    // b/c if left and right are free, but right was divided further,
    // you don't want to combine those blocks
    if (lb.level() != rb.level() or !lb.free() or !rb.free()) {
        return;
    }

    // Free the list node for the right block
    //
    // First check the beginning of the list, popping it and prepending it to the
    // free list, otherwise
    // go through the list checking if the next is the correct one,
    // and removing it from the list if it is while prepending it to the free list
    {
        var prev_node = self.free_lists[rb.level()].first;
        if (prev_node != null and prev_node.?.data == right) {
            self.free_list_nodes.prepend(self.free_lists[rb.level()].popFirst().?);
        } else {
            while (prev_node) |n| {
                if (n.next) |next| {
                    if (next.data == right) {
                        n.next = next.next;
                        self.free_list_nodes.prepend(next);
                        break;
                    }
                }
                prev_node = n.next;
            }
        }
    }

    // Remove the list node for the left block and add it to the front
    // of the higher order list
    {
        var prev_node = self.free_lists[lb.level()].first;
        if (prev_node != null and prev_node.?.data == left) {
            self.free_lists[lb.level() + 1].prepend(self.free_lists[lb.level()].popFirst().?);
        } else {
            while (prev_node) |n| {
                if (n.next) |next| {
                    if (next.data == left) {
                        n.next = next.next;
                        self.free_lists[lb.level() + 1].prepend(next);
                        break;
                    }
                }
                prev_node = n.next;
            }
        }
    }

    // Increase the order of the block
    for (0..@as(usize, 1) << (order + 1)) |i| {
        self.getBlock(left + i).setLevel(order + 1);
    }

    // If we are not at the max order already,
    // try doing a merge at the higher order.
    // We can do this as a tail call
    if (lb.level() < max_order) {
        @call(.always_tail, mergeBlocks, .{ self, left });
    }
}

pub fn freeBlock(self: *PhysicalMemoryManager, block: usize) !void {
    if (block >= self.block_count) {
        return error.NotManaged;
    }
    // Mark the BlockEntry as free
    self.getBlock(block).setFree(true);

    // Add it back to the order's free list for merge processing
    const node = self.free_list_nodes.popFirst().?;
    node.data = block;
    self.free_lists[self.getBlock(block).level()].prepend(node);

    // Try merging the block with it's buddy (recursively)
    self.mergeBlocks(block);
}

// Assumes that the block in which <block> resides is being managed in a free list
fn splitBlockDownTo(self: *PhysicalMemoryManager, block: usize, down_to: u3) void {
    // Check that the block is in fact larger than the requested size
    const order = self.getBlock(block).level();
    if (order <= down_to) {
        return;
    }

    // Get the order-aligned block in which <block> resides
    const idx = @divTrunc(block, @as(usize, 1) << order) * (@as(usize, 1) << order);

    // Remove its node from the respective free list
    var node = self.free_lists[order].first;
    if (node != null and node.?.data == idx) {
        node = self.free_lists[order].popFirst();
    } else {
        while (node) |n| {
            if (n.next) |next| {
                if (next.data == idx) {
                    n.next = next.next;
                    node = next;
                    break;
                }
            }
            node = n.next;
        }
    }

    if (node == null or node.?.data != idx) {
        @panic("Free node for item in heap not found in its order's list");
    }

    // get the right node as well
    var node_right = self.free_list_nodes.popFirst().?;
    node_right.data = idx + (@as(usize, 1) << (order - 1));

    // decrease the order counters
    for (0..@as(usize, 1) << (order - 1)) |i| {
        self.getBlock(node.?.data + i).setLevel(order - 1);
    }
    for (0..@as(usize, 1) << (order - 1)) |i| {
        self.getBlock(node_right.data + i).setLevel(order - 1);
    }

    // prepend the free nodes
    self.free_lists[order - 1].prepend(node.?);
    self.free_lists[order - 1].prepend(node_right);

    // if the block is in the left,
    // store the right and try splitting the left
    // otherwise store the left and try splitting the right
    @call(.always_tail, splitBlockDownTo, .{ self, block, down_to });
}

pub fn allocBlocks(self: *PhysicalMemoryManager, order: u3) !usize {
    // look for free block in order <order>
    // if one exists, pop it and return it
    // otherwise, check for one of a larger size and split it down
    log.debug(
        \\starting allocation of block of order {}
        \\state:
        \\{}
        \\
    , .{ order, self });
    defer log.debug(
        \\allocation done
        \\state:
        \\{}
        \\
    , .{self});

    if (self.free_lists[order].first) |_| {
        const node = self.free_lists[order].popFirst().?;
        const ret = node.data;
        self.free_list_nodes.prepend(node);
        log.debug("returning: 0x{X}\n", .{ret});
        // TODO zero the page
        return ret;
    } else {
        for (order + 1..max_order + 1) |i| {
            if (self.free_lists[i].first) |blk| {
                const block = blk.data;
                self.splitBlockDownTo(block, order);
                const node = self.free_lists[order].popFirst().?;
                const ret = node.data;
                self.free_list_nodes.prepend(node);
                log.debug("returning: 0x{X}\n", .{ret});
                // TODO zero the page
                return ret;
            }
        }
    }
    return error.OutOfMemory;
}

fn allocBlocksAt(self: *PhysicalMemoryManager, block: usize, order: u3) !void {
    if (block >= self.block_count) {
        return error.NotManaged;
    }
    // check if the block is at the required level
    // if so, remove it thusly. Otherwise, set it split it down to the correct size
    var b = self.getBlock(block);
    if (!b.free()) {
        return error.AlreadyAllocated;
    }
    if (b.level() != order) {
        self.splitBlockDownTo(block, order);
    }

    var prev = self.free_lists[order].first;
    if (prev.?.data == block) {
        self.free_list_nodes.prepend(self.free_lists[order].popFirst().?);
    } else {
        while (prev) |n| {
            if (n.next) |next| {
                if (next.data == block) {
                    n.next = next.next;
                    self.free_list_nodes.prepend(next);
                }
            }
            prev = n.next;
        }
    }

    b.setFree(false);
}

/// Return the BlockEntry at index <block>
fn getBlock(self: *PhysicalMemoryManager, block: usize) BlockEntryUnion {
    const pair = &self.block_map[block >> 1];
    if (block & 1 == 0) {
        return BlockEntryUnion{ .l = &pair.l };
    }
    return BlockEntryUnion{ .r = &pair.r };
}

fn blockFromAddr(addr: usize) usize {
    return addr / block_size;
}

fn divCeil(l: usize, r: usize) usize {
    return if (l % r == 0) l / r else l / r + 1;
}

fn blockSizeOf(size: usize) usize {
    return divCeil(size, block_size);
}

// just for debugging purposes
pub fn format(self: *const PhysicalMemoryManager, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    std.fmt.format(writer, "blocks managed: {}\n", .{self.block_count}) catch {};
    for (self.free_lists, 0..) |list, i| {
        var val = list.first;
        std.fmt.format(writer, "order {}:", .{i}) catch {};
        for (0..10) |_| {
            if (val == null) {
                break;
            }
            std.fmt.format(writer, " {}", .{val.?.data}) catch {};
            val = val.?.next;
        }
        if (i < self.free_lists.len - 1) {
            std.fmt.format(writer, "\n", .{}) catch {};
        }
    }
}

/// Returns the size of a PMM managing `memSize` bytes of RAM.
fn pmmBlockSize(mem_size: usize) usize {
    const block_count = divCeil(mem_size, block_size);
    // pairCount == numberOfBytes for storing block metadata
    const pair_count = divCeil(block_count, 2);
    const pair_byte_count = pair_count * @sizeOf(BlockEntryPair); // Should be equivalent to = pairCount

    const free_node_count = pair_count; // We should never need more than blockCount / 2 (+1 if odd) free list nodes
    const free_node_byte_count = free_node_count * @sizeOf(FreeList.Node);

    return blockSizeOf(@sizeOf(PhysicalMemoryManager)) + blockSizeOf(pair_byte_count) + blockSizeOf(free_node_byte_count);
}

/// Set up the PMM, returning it not success or otherwise an error
pub fn setupPhysicalMemoryManager(hhdm_start: usize) !*PhysicalMemoryManager {
    const response = mem_map_request.response orelse return error.LimineMemMapMissing;
    // Print out all of the mem map entries
    for (response.entries()) |entry| {
        log.debug("{} {} {}\n", .{
            entry.kind,
            entry.base >> 12,
            entry.length >> 12,
        });
    }

    var klen: usize = 0;
    const map_entries = response.entries();
    // Find the highest address that isn't reserved, bad, or framebuffer
    // At this point we assume that it is the upper limit of RAM,
    // although this is an assumption that may need revisiting
    const highest_addr = blk: {
        var most: usize = 0;
        for (map_entries) |entry| {
            // If the mem is of a valid type and ends past the
            // current furthest mem, update the end-of-mem value.
            if (entry.kind != limine.MemoryMapEntryType.reserved and
                entry.kind != limine.MemoryMapEntryType.bad_memory and
                entry.kind != limine.MemoryMapEntryType.framebuffer and
                entry.base + entry.length > most)
            {
                most = entry.base + entry.length;
            }
            // Also we're keeping track of the klen, as limine only gives us
            // kstart phys and virt in the KernelAddressRequest
            if (entry.kind == limine.MemoryMapEntryType.kernel_and_modules) {
                if (klen != 0) {
                    log.warn("duplicate kernel memmap entries: {X} and {X}", .{ klen, entry.length });
                    klen = @max(klen, entry.length);
                } else {
                    klen = entry.length;
                }
            }
        }
        break :blk most;
    };

    // Require the selected address to be block / page -aligned
    if (highest_addr % block_size != 0) {
        @panic("RAM size not block size-aligned!");
    }

    const pmm_block_size = pmmBlockSize(highest_addr);
    const block_count = highest_addr / block_size;

    const pmm: *PhysicalMemoryManager = for (map_entries) |entry| {
        // TODO add support for acpi_reclaimable
        // and bootloader_reclaimable
        // also below

        // Look for usable memory that is large enough to house the PMM,
        // first fit approach
        if (entry.kind == limine.MemoryMapEntryType.usable and
            blockFromAddr(entry.length) > pmm_block_size)
        {
            break PhysicalMemoryManager.initAt(
                hhdm_start + entry.base,
                block_count,
                klen,
            );
        }
    } else return error.NotEnoughPhysicalMemory;

    // map the entries that from limine
    for (map_entries) |entry| {
        if (entry.kind != limine.MemoryMapEntryType.usable) {
            for (blockFromAddr(entry.base)..blockFromAddr(entry.base + entry.length)) |i| {
                if (i >= block_count) {
                    break;
                }
                pmm.allocBlocksAt(i, 0) catch |err| {
                    switch (err) {
                        error.NotManaged => log.err("{X} is not within the management bounds\n", .{i}),
                        error.AlreadyAllocated => log.err("{X} has already been marked as unusable\n", .{i}),
                    }
                    @panic("error marking reserved pages as in use");
                };
            }
        }
    }

    // TODO: is this necessary?
    pmm.allocBlocksAt(0, 0) catch |err| switch (err) {
        error.AlreadyAllocated => {
            log.err("the bottom page has already been marked as in use", .{});
            @panic("error marking bottom page as unusable");
        },
        error.NotManaged => unreachable,
    };

    log.debug("pmm at 0x{X}, len 0x{X}\n", .{ @intFromPtr(pmm), pmm_block_size });

    const pmm_paddr = @intFromPtr(pmm) - hhdm_start;
    // map this as well
    for (blockFromAddr(pmm_paddr)..blockFromAddr(pmm_paddr) + pmm_block_size) |i| {
        pmm.allocBlocksAt(i, 0) catch {
            @panic("error mapping allocator's pages as in use");
        };
    }

    return pmm;
}
