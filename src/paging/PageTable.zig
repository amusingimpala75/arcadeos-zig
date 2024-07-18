const std = @import("std");

const kernel = @import("../kernel.zig");
const paging = @import("../paging.zig");
const PhysicalMemoryManager = @import("../PhysicalMemoryManager.zig");

const PageTable = @This();

/// Limine loads us at or above 0xFFFFFFFF80000000,
/// so we reserve the entry just below that respective pml4 entry
/// for the recursive page table mapping scheme.
const recurse: u9 = @as(u9, @truncate(0xffffffff80000000 >> 39)) - 1;

const offset_bitmask = (1 << 9) - 1; // 511

pub const PageAccess = enum {
    kernel_r,
    kernel_rw,
    kernel_rx,
    kernel_rwx, // TODO: remove this once the linker.ld
    // actually works for storing the location of the segments
    // and not just defaulting to 0.
};

pub const Entry = packed struct(u64) {
    present: bool,
    writable: bool,
    user_accessible: bool,
    write_through_cache: bool,
    disable_cache: bool,
    accessed: bool = false, // whether page read from  | set by the CPU,
    dirty: bool = false, // whether page written to    | cleared by the kernel
    large_page: bool,
    global: bool, // skip TLB flush on write to CR3; unused except on last level
    available1: u3 = 0,
    physical_addr_page: u36, // phys_addr >> 12
    reserved1: u4 = 0,
    available2: u11 = 0,
    no_execute: bool,

    fn setAsKernelRWX(self: *Entry, phys_addr: usize) void {
        if (phys_addr & (@as(usize, 1) << 12) - 1 != 0) {
            @panic("phys_addr is not 4096 aligned");
        }

        self.* = Entry{
            .present = true,
            .writable = true,
            .user_accessible = false,
            .write_through_cache = true,
            .disable_cache = true,
            .large_page = false,
            .global = false,
            .physical_addr_page = @truncate(phys_addr >> 12),
            .no_execute = false,
        };
    }

    fn setAsKernelR(self: *Entry, phys_addr: usize) void {
        if (phys_addr & (@as(usize, 1) << 12) - 1 != 0) {
            @panic("phys_addr is not 4096 aligned");
        }

        self.* = Entry{
            .present = true,
            .writable = false,
            .user_accessible = false,
            .write_through_cache = true,
            .disable_cache = true,
            .large_page = false,
            .global = false,
            .physical_addr_page = @truncate(phys_addr >> 12),
            .no_execute = true,
        };
    }

    fn setAsKernelRX(self: *Entry, phys_addr: usize) void {
        if (phys_addr & (@as(usize, 1) << 12) - 1 != 0) {
            @panic("phys_addr is not 4096 aligned");
        }

        self.* = Entry{
            .present = true,
            .writable = false,
            .user_accessible = false,
            .write_through_cache = true,
            .disable_cache = true,
            .large_page = false,
            .global = false,
            .physical_addr_page = @truncate(phys_addr >> 12),
            .no_execute = false,
        };
    }

    fn setAsKernelRW(self: *Entry, phys_addr: usize) void {
        if (phys_addr & (@as(usize, 1) << 12) - 1 != 0) {
            @panic("phys_addr is not 4096 aligned");
        }

        self.* = Entry{
            .present = true,
            .writable = true,
            .user_accessible = false,
            .write_through_cache = true,
            .disable_cache = true,
            .large_page = false,
            .global = false,
            .physical_addr_page = @truncate(phys_addr >> 12),
            .no_execute = true,
        };
    }

    fn setAsUnavailable(self: *Entry) void {
        self.* = Entry{
            .present = false,
            .writable = false,
            .user_accessible = false,
            .write_through_cache = true,
            .disable_cache = true,
            .large_page = false,
            .global = false,
            .physical_addr_page = 0xdeadbeef,
            .no_execute = true,
        };
    }
};

entries: [512]Entry,

pub fn physicalAddr(self: *PageTable) u52 {
    if (self == PageTable.pml4Recurse()) {
        return @intCast(self.entries[recurse].physical_addr_page << 12);
    }
    return @truncate(@intFromPtr(self) - kernel.arch.bootloader_info.hhdm_start);
}

/// Must only be called on PML4 PageTable
/// Loads this PageTable into CR3
pub fn load(self: *PageTable) void {
    // Get our addres fromm our recursive entry
    const phys_addr = @as(usize, @intCast(self.entries[recurse].physical_addr_page)) << 12;
    kernel.arch.assembly.setPageTablePhysAddr(phys_addr);
}

pub fn alloc() !*PageTable {
    const blk = try PhysicalMemoryManager.instance.allocBlocks(0);

    // The pmm returns the physical addr of the block,
    // so we need to add the hhdm start
    return @ptrFromInt((blk << 12) + kernel.arch.bootloader_info.hhdm_start);
}

pub fn init(self: *PageTable) void {
    for (&self.entries) |*entry| {
        entry.setAsUnavailable();
    }
}

fn isLoaded(self: *PageTable) bool {
    return kernel.arch.assembly.getPageTablePhysAddr() == self.physicalAddr();
}

pub fn initPML4(self: *PageTable) void {
    self.entries[recurse].setAsKernelRWX(self.physicalAddr());
}

pub fn pml4Recurse() *PageTable {
    const addr =
        0xFFFF_0000_0000_0000 |
        @as(usize, @intCast(recurse)) << 39 |
        @as(usize, @intCast(recurse)) << 30 |
        @as(usize, @intCast(recurse)) << 21 |
        @as(usize, @intCast(recurse)) << 12;
    return @ptrFromInt(addr);
}

fn pml3Recurse(pml4_offset: usize) *PageTable {
    const addr =
        (0xFFFF_0000_0000_0000 |
        @as(usize, @intCast(recurse)) << 39 |
        @as(usize, @intCast(recurse)) << 30 |
        @as(usize, @intCast(recurse)) << 21) + 0x1000 * pml4_offset;
    return @ptrFromInt(addr);
}

fn pml2Recurse(pml4_offset: usize, pml3_offset: usize) *PageTable {
    const addr =
        (0xFFFF_0000_0000_0000 |
        @as(usize, @intCast(recurse)) << 39 |
        @as(usize, @intCast(recurse)) << 30) + 0x20_0000 * pml4_offset + 0x1000 * pml3_offset;
    return @ptrFromInt(addr);
}

fn pml1Recurse(pml4_offset: usize, pml3_offset: usize, pml2_offset: usize) *PageTable {
    const addr =
        (0xFFFF_0000_0000_0000 |
        @as(usize, @intCast(recurse)) << 39) + 0x4000_0000 * pml4_offset + 0x20_0000 * pml3_offset + 0x1000 * pml2_offset;
    return @ptrFromInt(addr);
}

// TODO: support large pages by returning early
// TODO: resolveUnloaded
pub fn resolve(vaddr: usize) !usize {
    const pml4_offset = vaddr >> 39 & offset_bitmask;
    const pml3_offset = vaddr >> 30 & offset_bitmask;
    const pml2_offset = vaddr >> 21 & offset_bitmask;
    const pml1_offset = vaddr >> 12 & offset_bitmask;
    const page_offset = vaddr & 4095;

    {
        const pml4: *PageTable = pml4Recurse();
        if (!pml4.entries[pml4_offset].present) {
            return error.Unmapped;
        }
    }

    {
        const pml3: *PageTable = pml3Recurse(pml4_offset);
        if (!pml3.entries[pml3_offset].present) {
            return error.Unmapped;
        }
    }

    {
        const pml2: *PageTable = pml2Recurse(pml4_offset, pml3_offset);
        if (!pml2.entries[pml2_offset].present) {
            return error.Unmapped;
        }
    }

    {
        const pml1: *PageTable = pml1Recurse(pml4_offset, pml3_offset, pml2_offset);
        const entry = &pml1.entries[pml1_offset];
        if (!entry.present) {
            return error.Unmapped;
        }
        const addr: usize = @intCast(entry.physical_addr_page);
        return addr << 12 | page_offset;
    }
}

pub fn mapAll(pml4: *PageTable, vaddr: usize, paddr: usize, len: usize, access: PageAccess) !void {
    var i: usize = 0;
    while (i < len) : (i += paging.page_size) {
        try pml4.map(vaddr + i, paddr + i, access);
    }
}

/// Do not call after initial setup; see PageTable.map instead
/// Maps a `len` length block of bytes at `virt` to `phys`.
/// Needs the physical memory allocator and pml4 page table
fn mapUnloaded(pml4: *PageTable, vaddr: usize, paddr: usize, access: PageAccess) !void {
    const pml4_offset: u9 = @truncate(vaddr >> 39);
    const pml3_offset: u9 = @truncate(vaddr >> 30);
    const pml2_offset: u9 = @truncate(vaddr >> 21);
    const pml1_offset: u9 = @truncate(vaddr >> 12);

    const pml3: *PageTable = if (pml4.entries[pml4_offset].present)
        @ptrFromInt((pml4.entries[pml4_offset].physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start)
    else blk: {
        const val = try PageTable.alloc();
        val.init();
        pml4.entries[pml4_offset].setAsKernelRWX(val.physicalAddr());
        break :blk val;
    };

    const pml2: *PageTable = if (pml3.entries[pml3_offset].present)
        @ptrFromInt((pml3.entries[pml3_offset].physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start)
    else blk: {
        const val = try PageTable.alloc();
        val.init();
        pml3.entries[pml3_offset].setAsKernelRWX(val.physicalAddr());
        break :blk val;
    };

    const pml1: *PageTable = if (pml2.entries[pml2_offset].present)
        @ptrFromInt((pml2.entries[pml2_offset].physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start)
    else blk: {
        const val = try PageTable.alloc();
        val.init();
        pml2.entries[pml2_offset].setAsKernelRWX(val.physicalAddr());
        break :blk val;
    };

    if (pml1.entries[pml1_offset].present) {
        return error.AlreadyMapped;
    }

    switch (access) {
        .kernel_r => pml1.entries[pml1_offset].setAsKernelR(paddr),
        .kernel_rw => pml1.entries[pml1_offset].setAsKernelRW(paddr),
        .kernel_rx => pml1.entries[pml1_offset].setAsKernelRX(paddr),
        .kernel_rwx => pml1.entries[pml1_offset].setAsKernelRWX(paddr),
    }
}

// TODO: support large pages and caller-defined entry configuration
pub fn map(pml4: *PageTable, vaddr: usize, paddr: usize, access: PageAccess) !void {
    if (!pml4.isLoaded()) {
        try pml4.mapUnloaded(vaddr, paddr, access);
        return;
    }
    defer pml4.load(); // always reload CR3 until targeted TLB flushing is implemented

    const pml4_offset = vaddr >> 39 & offset_bitmask;
    const pml3_offset = vaddr >> 30 & offset_bitmask;
    const pml2_offset = vaddr >> 21 & offset_bitmask;
    const pml1_offset = vaddr >> 12 & offset_bitmask;

    if (!pml4.entries[pml4_offset].present) {
        const t = try PageTable.alloc();
        pml4.entries[pml4_offset].setAsKernelRWX(t.physicalAddr());
        pml3Recurse(pml4_offset).init();
    }

    const pml3: *PageTable = pml3Recurse(pml4_offset);

    if (!pml3.entries[pml3_offset].present) {
        const t = try PageTable.alloc();
        pml3.entries[pml3_offset].setAsKernelRWX(t.physicalAddr());
        pml2Recurse(pml4_offset, pml3_offset).init();
    }

    const pml2: *PageTable = pml2Recurse(pml4_offset, pml3_offset);

    if (!pml2.entries[pml2_offset].present) {
        const t = try PageTable.alloc();
        pml2.entries[pml2_offset].setAsKernelRWX(t.physicalAddr());
        pml1Recurse(pml4_offset, pml3_offset, pml2_offset).init();
    }

    const pml1: *PageTable = pml1Recurse(pml4_offset, pml3_offset, pml2_offset);
    if (pml1.entries[pml1_offset].present) {
        return error.AlreadyMapped;
    }
    pml1.entries[pml1_offset].setAsKernelRWX(paddr);
    switch (access) {
        .kernel_r => pml1.entries[pml1_offset].setAsKernelR(paddr),
        .kernel_rw => pml1.entries[pml1_offset].setAsKernelRW(paddr),
        .kernel_rx => pml1.entries[pml1_offset].setAsKernelRX(paddr),
        .kernel_rwx => pml1.entries[pml1_offset].setAsKernelRWX(paddr),
    }
}

pub fn hhdmap(pml4: *PageTable, addr: usize, access: PageAccess) !usize {
    try pml4.map(addr + kernel.arch.bootloader_info.hhdm_start, addr, access);
    return addr + kernel.arch.bootloader_info.hhdm_start;
}

// TODO: unmapUnloaded
pub fn unmap(pml4: *PageTable, addr: usize) !usize {
    // ensure the address is mapped
    _ = try PageTable.resolve(addr);
    defer pml4.load(); // always reload CR3 until targeted TLB flushing is implemented
    const pml4_offset = addr >> 39;
    const pml3_offset = addr >> 30 & recurse;
    const pml2_offset = addr >> 21 & recurse;
    const pml1_offset = addr >> 12 & recurse;

    // Remove the mapping from PML1
    // if this was not the last mapping in the PML1, return
    // otherwise, free the PML1, set its entry in the PML2 to be
    // not present, and check again at this level, continuing up to PML4
    const block = blk: {
        const pml1 = pml1Recurse(pml4_offset, pml3_offset, pml2_offset);
        const val = pml1.entries[pml1_offset].physical_addr_page;
        pml1.entries[pml1_offset].setAsUnavailable();

        for (0..recurse) |i| {
            if (pml1.entries[i].present) {
                return val;
            }
        }
        break :blk val;
    };

    {
        const pml2 = pml2Recurse(pml4_offset, pml3_offset);
        try PhysicalMemoryManager.instance.freeBlock(pml2.entries[pml2_offset].physical_addr_page);
        pml2.entries[pml2_offset].setAsUnavailable();

        for (0..recurse) |i| {
            if (pml2.entries[i].present) {
                return block;
            }
        }
    }

    {
        const pml3 = pml3Recurse(pml4_offset);
        try PhysicalMemoryManager.instance.freeBlock(pml3.entries[pml3_offset].physical_addr_page);
        pml3.entries[pml3_offset].setAsUnavailable();

        for (0..recurse) |i| {
            if (pml3.entries[i].present) {
                return block;
            }
        }
    }

    {
        try PhysicalMemoryManager.instance.freeBlock(pml4.entries[pml4_offset].physical_addr_page);
        pml4.entries[pml4_offset].setAsUnavailable();
    }
    return block;
}

pub fn allocPage(self: *PageTable, access: PageAccess) !*align(paging.page_size) anyopaque {
    const blk = try PhysicalMemoryManager.instance.allocBlocks(1);
    errdefer PhysicalMemoryManager.instance.freeBlock(blk) catch unreachable;
    return @ptrFromInt(try self.hhdmap(blk << 12, access));
}

pub fn freePage(self: *PageTable, page: *anyopaque) !void {
    const addr = @intFromPtr(page);
    if (addr % paging.page_size != 0) {
        return error.Unaligned;
    }
    const blk = try self.unmap(addr);
    try PhysicalMemoryManager.instance.freeBlocks(blk);
}

comptime {
    std.debug.assert(@sizeOf(PageTable) == paging.page_size * @sizeOf(u8));
    std.debug.assert(@bitSizeOf(PageTable) == paging.page_size * @bitSizeOf(u8));
}
