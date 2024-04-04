const std = @import("std");

const limine = @import("limine");

const IDT = @import("IDT.zig");
const kernel = @import("../kernel.zig");
const PhysicalMemoryManager = @import("PhysicalMemoryManager.zig");

var physical_mem_manager: *PhysicalMemoryManager = undefined;

export var hhdm_start_request = limine.HhdmRequest{};
var hhdm_start: usize = 0;

export var kernel_loc_req = limine.KernelAddressRequest{};

pub fn initKernelPaging() void {
    hhdm_start = (hhdm_start_request.response orelse @panic("Could not find where HHDM begins")).offset;

    physical_mem_manager = PhysicalMemoryManager.setupPhysicalMemoryManager(hhdm_start, false) catch |err| {
        if (err == error.LimineMemMapMissing) {
            @panic("Limine did not provide a memory map, maybe try rebooting?");
        } else if (err == error.NotEnoughPhysicalMemory) {
            @panic("Not enough physical memory to run ArcadeOS on this system");
        } else {
            unreachable; // there shouldn't be any other errors?
        }
    };

    {
        const pml4 = PageTable.alloc() catch {
            @panic("PMM out of memory for page table allocations!");
        };
        pml4.initPML4();

        mapNecessaryBeforeLoad(pml4) catch {
            @panic("Error mapping necessary parts prior to loading kernel page table");
        };

        pml4.load();
    }
}

fn mapNecessaryBeforeLoad(pml4: *PageTable) !void {
    const kernel_location = kernel_loc_req.response orelse @panic("bootloader did not provide kernel location");

    // Map the kernel as well again to the addr (> 0xFFFFFFFF80000000) provided by the bootloader
    try pml4.mapAll(
        kernel_location.virtual_base,
        kernel_location.physical_base,
        physical_mem_manager.klen,
    );

    // Map the stack (may not be 4096-aligned)
    // Stack grows down (you would not believe how many hours it took
    // to notice the bug where I had it mapping the pages above, rather than below)
    {
        const aligned = kernel.stack_start & ((@as(usize, 1) << 12) - 1) == 0;
        const stack_virt_start = (kernel.stack_start - kernel.stack_req.stack_size) & ~((@as(usize, 1) << 12) - 1);
        const stack_phys_start = if (stack_virt_start < hhdm_start) stack_virt_start else stack_virt_start - hhdm_start;
        try pml4.mapAll(
            stack_virt_start,
            stack_phys_start,
            if (aligned) kernel.stack_req.stack_size else kernel.stack_req.stack_size + page_size,
        );
    }

    // Map the framebuffer
    {
        const fb_virt_addr = @intFromPtr(kernel.main_framebuffer.addr.ptr);
        const fb_phys_addr = blk: {
            const pml4_offset: u9 = @truncate(fb_virt_addr >> 39);
            const pml3_offset: u9 = @truncate(fb_virt_addr >> 30);
            const pml2_offset: u9 = @truncate(fb_virt_addr >> 21);
            const pml1_offset: u9 = @truncate(fb_virt_addr >> 12);

            const old_pml4: *PageTable = blk1: {
                var val: usize = 0;
                asm volatile ("mov %cr3, %[addr]"
                    : [addr] "={rax}" (val),
                );
                break :blk1 @ptrFromInt(val);
            };
            const pml3: *PageTable = @ptrFromInt((old_pml4.entries[pml4_offset].physical_addr_page << 12) + hhdm_start);
            const pml2: *PageTable = @ptrFromInt((pml3.entries[pml3_offset].physical_addr_page << 12) + hhdm_start);
            const pml1: *PageTable = @ptrFromInt((pml2.entries[pml2_offset].physical_addr_page << 12) + hhdm_start);

            break :blk @as(usize, @intCast(pml1.entries[pml1_offset].physical_addr_page)) << 12;
        };

        try pml4.mapAll(
            fb_virt_addr,
            fb_phys_addr,
            kernel.main_framebuffer.height() * kernel.main_framebuffer.width() * (kernel.main_framebuffer.bpp / 8),
        );
    }

    // Map the physical memory manager
    {
        const pmm_virt = @intFromPtr(physical_mem_manager);
        const pmm_phys = if (pmm_virt > hhdm_start) pmm_virt - hhdm_start else pmm_virt;
        try pml4.mapAll(
            pmm_virt,
            pmm_phys,
            physical_mem_manager.byteSize(),
        );
    }
}

const page_size = 4096;

pub const PageTable = struct {
    /// Limine loads us at or above 0xFFFFFFFF80000000,
    /// so we reserve the entry just below that respective pml4 entry
    /// for the recursive page table mapping scheme.
    const recurse: u9 = @as(u9, @truncate(0xffffffff80000000 >> 39)) - 1;

    const offset_bitmask = (1 << 9) - 1; // 511

    pub const Entry = packed struct {
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

        pub fn setAsKernelRWX(self: *Entry, phys_addr: usize) void {
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

        pub fn setAsUnavailable(self: *Entry) void {
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

        comptime {
            std.debug.assert(@sizeOf(Entry) == @sizeOf(u64));
            std.debug.assert(@bitSizeOf(Entry) == @bitSizeOf(u64));
        }
    };

    entries: [512]Entry,

    pub fn physicalAddr(self: *PageTable) u52 {
        if (self == PageTable.pml4Recurse()) {
            return @intCast(self.entries[recurse].physical_addr_page << 12);
        }
        return @truncate(@intFromPtr(self) - hhdm_start);
    }

    fn getCr3() usize {
        var val: usize = 0;
        asm volatile (
            \\mov %cr3, %[addr]
            : [addr] "={rax}" (val),
        );
        return val;
    }

    /// Must only be called on PML4 PageTable
    /// Loads this PageTable into CR3
    pub fn load(self: *PageTable) void {
        // Get our addres fromm our recursive entry
        const phys_addr = @as(usize, @intCast(self.entries[recurse].physical_addr_page)) << 12;
        // Retrive the old value of cr3
        const old_cr3 = getCr3();
        // Preserve the lower 12 bits of the old cr3
        const new_cr3 = phys_addr | (old_cr3 & 0b111111111111);
        // Load this into the cr3 register
        asm volatile (
            \\mov %[addr], %cr3
            :
            : [addr] "rax" (new_cr3),
        );
    }

    pub fn alloc() !*PageTable {
        const blk = try physical_mem_manager.allocBlocks(0);

        // The pmm returns the physical addr of the block,
        // so we need to add the hhdm start
        var self: *PageTable = @ptrFromInt((blk << 12) + hhdm_start);

        self.init();

        return self;
    }

    pub fn init(self: *PageTable) void {
        for (&self.entries) |*entry| {
            entry.setAsUnavailable();
        }
    }

    fn allocNoInit() !*PageTable {
        const blk = try physical_mem_manager.allocBlocks(0);
        var self: *PageTable = @ptrFromInt((blk << 12) + hhdm_start);
        return self;
    }

    fn isLoaded(self: *PageTable) bool {
        const bitmask: usize = ~@as(usize, 0b111111111111);
        return getCr3() & bitmask == self.physicalAddr();
    }

    pub fn initPML4(self: *PageTable) void {
        self.entries[recurse].setAsKernelRWX(self.physicalAddr());
    }

    fn pml4Recurse() *PageTable {
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

    pub fn mapAll(pml4: *PageTable, vaddr: usize, paddr: usize, len: usize) !void {
        var i: usize = 0;
        while (i < len) : (i += page_size) {
            try pml4.map(vaddr + i, paddr + i);
        }
    }

    /// Do not call after initial setup; see PageTable.map instead
    /// Maps a `len` length block of bytes at `virt` to `phys`.
    /// Needs the physical memory allocator and pml4 page table
    fn mapUnloaded(pml4: *PageTable, vaddr: usize, paddr: usize) !void {
        const pml4_offset: u9 = @truncate(vaddr >> 39);
        const pml3_offset: u9 = @truncate(vaddr >> 30);
        const pml2_offset: u9 = @truncate(vaddr >> 21);
        const pml1_offset: u9 = @truncate(vaddr >> 12);

        const pml3: *PageTable = if (pml4.entries[pml4_offset].present)
            @ptrFromInt((pml4.entries[pml4_offset].physical_addr_page << 12) + hhdm_start)
        else blk: {
            const val = try PageTable.alloc();
            pml4.entries[pml4_offset].setAsKernelRWX(val.physicalAddr());
            break :blk val;
        };

        const pml2: *PageTable = if (pml3.entries[pml3_offset].present)
            @ptrFromInt((pml3.entries[pml3_offset].physical_addr_page << 12) + hhdm_start)
        else blk: {
            const val = try PageTable.alloc();
            pml3.entries[pml3_offset].setAsKernelRWX(val.physicalAddr());
            break :blk val;
        };

        const pml1: *PageTable = if (pml2.entries[pml2_offset].present)
            @ptrFromInt((pml2.entries[pml2_offset].physical_addr_page << 12) + hhdm_start)
        else blk: {
            const val = try PageTable.alloc();
            pml2.entries[pml2_offset].setAsKernelRWX(val.physicalAddr());
            break :blk val;
        };

        pml1.entries[pml1_offset].setAsKernelRWX(paddr);
    }

    // Requires page mapping to be already set up
    // TODO support large pages and caller-defined entry configuration
    pub fn map(pml4: *PageTable, vaddr: usize, paddr: usize) !void {
        if (!pml4.isLoaded()) {
            try pml4.mapUnloaded(vaddr, paddr);
            return;
        }
        defer pml4.load(); // always reload CR3 until targeted TLB flushing is implemented

        const pml4_offset = vaddr >> 39 & offset_bitmask;
        const pml3_offset = vaddr >> 30 & offset_bitmask;
        const pml2_offset = vaddr >> 21 & offset_bitmask;
        const pml1_offset = vaddr >> 12 & offset_bitmask;

        if (!pml4.entries[pml4_offset].present) {
            const t = try PageTable.allocNoInit();
            pml4.entries[pml4_offset].setAsKernelRWX(t.physicalAddr());
            pml3Recurse(pml4_offset).init();
        }

        const pml3: *PageTable = pml3Recurse(pml4_offset);

        if (!pml3.entries[pml3_offset].present) {
            const t = try PageTable.allocNoInit();
            pml3.entries[pml3_offset].setAsKernelRWX(t.physicalAddr());
            pml2Recurse(pml4_offset, pml3_offset).init();
        }

        const pml2: *PageTable = pml2Recurse(pml4_offset, pml3_offset);

        if (!pml2.entries[pml2_offset].present) {
            const t = try PageTable.allocNoInit();
            pml2.entries[pml2_offset].setAsKernelRWX(t.physicalAddr());
            pml1Recurse(pml4_offset, pml3_offset, pml2_offset).init();
        }

        const pml1: *PageTable = pml1Recurse(pml4_offset, pml3_offset, pml2_offset);
        if (pml1.entries[pml1_offset].present) {
            return error.AlreadyMapped;
        }
        pml1.entries[pml1_offset].setAsKernelRWX(paddr);
    }

    // TODO unmapUnloaded
    pub fn unmap(pml4: *PageTable, addr: usize) !void {
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
        {
            const pml1 = pml1Recurse(pml4_offset, pml3_offset, pml2_offset);
            pml1.entries[pml1_offset].setAsUnavailable();

            for (0..recurse) |i| {
                if (pml1.entries[i].present) {
                    return;
                }
            }
        }

        {
            const pml2 = pml2Recurse(pml4_offset, pml3_offset);
            try physical_mem_manager.freeBlock(pml2.entries[pml2_offset].physical_addr_page);
            pml2.entries[pml2_offset].setAsUnavailable();

            for (0..recurse) |i| {
                if (pml2.entries[i].present) {
                    return;
                }
            }
        }

        {
            const pml3 = pml3Recurse(pml4_offset);
            try physical_mem_manager.freeBlock(pml3.entries[pml3_offset].physical_addr_page);
            pml3.entries[pml3_offset].setAsUnavailable();

            for (0..recurse) |i| {
                if (pml3.entries[i].present) {
                    return;
                }
            }
        }

        {
            try physical_mem_manager.freeBlock(pml4.entries[pml4_offset].physical_addr_page);
            pml4.entries[pml4_offset].setAsUnavailable();
        }
    }

    comptime {
        std.debug.assert(@sizeOf(PageTable) == page_size * @sizeOf(u8));
        std.debug.assert(@bitSizeOf(PageTable) == page_size * @bitSizeOf(u8));
    }
};

const handler_fmt =
    \\Page Fault!
    \\  reason: 0x{X}
    \\  addr: 0x{X}
    \\  ISF:
    \\{}
;

var handler_buf: [handler_fmt.len + @sizeOf(IDT.ISF) * 8:0]u8 = undefined;

fn pageFaultHandler(isf: *IDT.ISF) void {
    var cr2 = blk: {
        var val: usize = 0;
        asm volatile (
            \\mov %cr2, %[addr]
            : [addr] "={rax}" (val),
        );
        break :blk val;
    };
    kernel.main_serial.print("page fault at 0x{X} because 0x{X}!\n", .{ cr2, isf.err });
    var msg = std.fmt.bufPrintZ(&handler_buf, handler_fmt, .{ isf.err, cr2, isf }) catch {
        @panic("Page fault, but could not format the crash message!");
    };
    @panic(msg);
}

pub fn installPageFaultHandler() void {
    IDT.setGate(@intCast(14), &pageFaultHandler, 0x8F);
}
