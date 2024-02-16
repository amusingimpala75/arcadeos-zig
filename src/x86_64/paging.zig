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
    hhdm_start = blk: {
        if (hhdm_start_request.response) |response| {
            break :blk response.offset;
        } else {
            @panic("Could not find where higher half starts");
        }
    };

    kernel.terminal.print("kernel at 0x{X} => 0x{X}\n", .{
        kernel_loc_req.response.?.physical_base,
        kernel_loc_req.response.?.virtual_base,
    });

    kernel.terminal.print(
        "Higher half addr start: 0x{X}\n",
        .{hhdm_start},
    );

    physical_mem_manager = PhysicalMemoryManager.setupPhysicalMemoryManager() catch |err| {
        if (err == error.LimineMemMapMissing) {
            @panic("limine did not provide a memory map");
        } else if (err == error.NotEnoughPhysicalMemory) {
            @panic("Not enough physical memory to setup physical memory manager, and so therefore also to run");
        } else {
            @panic("Could not setup physical memory manager");
        }
    };

    const pml4 = PageTable.alloc(physical_mem_manager);
    kernel.main_serial.print("new pml4 at 0x{X}\n", .{pml4.physicalAddr()});
    pml4.initPML4();

    kernel.main_serial.print("hhdm starts at 0x{X}\n", .{hhdm_start});
    kernel.main_serial.print("kernel start..length: 0x{X}..0x{X}\n", .{ kernel_loc_req.response.?.physical_base, physical_mem_manager.klen });

    kernel.terminal.print("font location: 0x{X}\n", .{@intFromPtr(@import("../fonts/Font.zig").fonts[0].bytes.ptr)});

    // Map the kernel as well again to the addr (> 0xFFFFFFFF80000000) provided by the bootloader
    map(
        kernel_loc_req.response.?.physical_base,
        kernel_loc_req.response.?.virtual_base,
        physical_mem_manager.klen,
        physical_mem_manager,
        pml4,
    );

    // Map the stack (may not be 4096-aligned)
    // Stack grows down (you would not believe how many hours it took
    // to notice the bug where I had it mapping the pages above, rather than below)
    {
        const aligned = kernel.stack_start & ((@as(usize, 1) << 12) - 1) == 0;
        const stack_virt_start = (kernel.stack_start - kernel.stack_req.stack_size) & ~((@as(usize, 1) << 12) - 1);
        const stack_phys_start = if (stack_virt_start < hhdm_start) stack_virt_start else stack_virt_start - hhdm_start;
        map(
            stack_phys_start,
            stack_virt_start,
            if (aligned) kernel.stack_req.stack_size else kernel.stack_req.stack_size + page_size,
            physical_mem_manager,
            pml4,
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

        map(
            fb_phys_addr,
            fb_virt_addr,
            kernel.main_framebuffer.height() * kernel.main_framebuffer.width() * (kernel.main_framebuffer.bpp / 8),
            physical_mem_manager,
            pml4,
        );
    }

    for (pml4.entries) |entry4| {
        if (entry4.present) {
            kernel.main_serial.print("0x{X}\n", .{entry4.physical_addr_page});
        }
    }

    pml4.load();

    kernel.main_framebuffer.clear();
    kernel.terminal.print("successfully transitioned to our paging\n", .{});
    kernel.terminal.print("foo: 0x{X}\n", .{blk: {
        const new_pml4 = PageTable.pml4Recurse();
        const entry = new_pml4.entries[254];
        break :blk entry.physical_addr_page;
    }});
    // TODO re-write map/unmap/resolve code
    asm volatile ("hlt");
}

/// Do not call after initial setup; see PageTable.map instead
/// Maps a `len` length block of bytes at `virt` to `phys`.
/// Needs the physical memory allocator and pml4 page table
fn map(phys: usize, virt: usize, len: usize, pmm: *PhysicalMemoryManager, pml4: *PageTable) void {
    var i: usize = 0;
    while (i < len) : (i += page_size) {
        const vaddr = virt + i;
        const pml4_offset: u9 = @truncate(vaddr >> 39);
        const pml3_offset: u9 = @truncate(vaddr >> 30);
        const pml2_offset: u9 = @truncate(vaddr >> 21);
        const pml1_offset: u9 = @truncate(vaddr >> 12);

        const pml3: *PageTable = if (pml4.entries[pml4_offset].present)
            @ptrFromInt((pml4.entries[pml4_offset].physical_addr_page << 12) + hhdm_start)
        else blk: {
            const val = PageTable.alloc(pmm);
            pml4.entries[pml4_offset].setAsKernelRWX(val.physicalAddr());
            break :blk val;
        };

        const pml2: *PageTable = if (pml3.entries[pml3_offset].present)
            @ptrFromInt((pml3.entries[pml3_offset].physical_addr_page << 12) + hhdm_start)
        else blk: {
            const val = PageTable.alloc(pmm);
            pml3.entries[pml3_offset].setAsKernelRWX(val.physicalAddr());
            break :blk val;
        };

        const pml1: *PageTable = if (pml2.entries[pml2_offset].present)
            @ptrFromInt((pml2.entries[pml2_offset].physical_addr_page << 12) + hhdm_start)
        else blk: {
            const val = PageTable.alloc(pmm);
            pml2.entries[pml2_offset].setAsKernelRWX(val.physicalAddr());
            break :blk val;
        };

        pml1.entries[pml1_offset].setAsKernelRWX(phys + i);
    }
    //kernel.terminal.print("mapped 0x{X} through 0x{X} starting at 0x{X} ({} blocks)\n", .{ virt, virt + i, phys, @divTrunc(len, page_size) });
}

const page_size = 4096;

/// Limine loads us at or above 0xFFFFFFFF80000000,
/// so we reserve the entry just below that respective pml4 entry
/// for the recursive page table mapping scheme.
const recurse: u9 = @as(u9, @truncate(0xffffffff80000000 >> 39)) - 1;

pub const PageTable = struct {
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

            self.present = true;
            self.writable = true;
            self.user_accessible = false;
            self.write_through_cache = true;
            self.disable_cache = true;
            self.large_page = false;
            self.global = false;
            self.physical_addr_page = @truncate(phys_addr >> 12);
            self.no_execute = false;
        }

        comptime {
            std.debug.assert(@sizeOf(Entry) == @sizeOf(u64));
            std.debug.assert(@bitSizeOf(Entry) == @bitSizeOf(u64));
        }
    };

    entries: [512]Entry,

    pub fn physicalAddr(self: *PageTable) u52 {
        return @truncate(@intFromPtr(self) - hhdm_start);
    }

    /// Must only be called on PML4 PageTable
    /// Loads this PageTable into CR3
    pub fn load(self: *PageTable) void {
        // Get our addres fromm our recursive entry
        const phys_addr = @as(usize, @intCast(self.entries[recurse].physical_addr_page)) << 12;
        // Retrive the old value of cr3
        const old_cr3 = blk: {
            var val: usize = 0;
            asm volatile (
                \\mov %cr3, %[addr]
                : [addr] "={rax}" (val),
            );
            break :blk val;
        };
        // Preserve the lower 12 bits of the old cr3
        const new_cr3 = phys_addr | (old_cr3 & 0b111111111111);
        // Load this into the cr3 register
        asm volatile (
            \\mov %[addr], %cr3
            :
            : [addr] "rax" (new_cr3),
        );
    }

    pub fn alloc(pmm: *PhysicalMemoryManager) *PageTable {
        const blk = pmm.allocBlocks(0) catch {
            @panic("Could not allocate space for page table");
        };

        // The pmm returns the physical addr of the block,
        // so we need to add the hhdm start
        var self: *PageTable = @ptrFromInt((blk << 12) + hhdm_start);

        var default_entry = Entry{
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

        for (&self.entries) |*entry| {
            entry.* = default_entry;
        }

        return self;
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
        kernel.terminal.print("0x{X}\n", .{addr});
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

    //    pub fn resolve(virt: anytype) !usize {
    //        const vaddr: usize = @intFromPtr(virt);
    //
    //        const pml4_offset = vaddr >> 39;
    //        const pml3_offset = vaddr >> 30 & recurse;
    //        const pml2_offset = vaddr >> 21 & recurse;
    //        const pml1_offset = vaddr >> 12 & recurse;
    //        const page_offset = vaddr & 4095;
    //
    //        {
    //            const pml4: *PageTable = pml4_recurse();
    //            const entry = &pml4.entries[pml4_offset].pml_entry;
    //            if (!entry.present) {
    //                return error.Unmapped;
    //            }
    //        }
    //
    //        {
    //            const pml3: *PageTable = pml3_recurse(pml4_offset);
    //            const entry = &pml3.entries[pml3_offset];
    //            if (!entry.present) {
    //                return error.Unmapped;
    //            }
    //            if (entry.large_page) {
    //                const addr: usize = @intCast(entry.physical_addr_page);
    //                return addr << 30 |
    //                    (vaddr & ((@as(usize, 1) << 30) - 1));
    //            }
    //        }
    //
    //        {
    //            const pml2: *PageTable = pml2_recurse(pml4_offset, pml3_offset);
    //            const entry = &pml2.entries[pml2_offset];
    //            if (!entry.present) {
    //                return error.Unmapped;
    //            }
    //            if (entry.large_page) {
    //                const addr: usize = @intCast(entry.physical_addr_page);
    //                return addr << 21 |
    //                    (vaddr & ((@as(usize, 1) << 21) - 1));
    //            }
    //        }
    //
    //        {
    //            const pml1: *PageTable = pml1_recurse(pml4_offset, pml3_offset, pml2_offset);
    //            const entry = &pml1.entries[pml1_offset];
    //            if (!entry.present) {
    //                return error.Unmapped;
    //            }
    //            const addr: usize = @intCast(entry.physical_addr_page);
    //            return addr << 12 | page_offset;
    //        }
    //    }
    //
    //    // Requires page mapping to be already set up
    //    pub fn map(addr: usize, entry: Entry) !void {
    //        if (true)
    //            unreachable; // TODO rewrite
    //        const pml4_offset = addr >> 39;
    //        const pml3_offset = addr >> 30 & recurse;
    //        const pml2_offset = addr >> 21 & recurse;
    //        const pml1_offset = addr >> 12 & recurse;
    //
    //        const pml4: *PageTable = pml4_recurse();
    //
    //        if (!pml4.entries[pml4_offset].present) {
    //            const block = try physical_mem_manager.allocBlocks(0);
    //            const pml_entry = Entry{
    //                .present = true,
    //                .writable = true,
    //                .user_accessible = false,
    //                .write_through_cache = false,
    //                .large_page = false,
    //                .addr = block,
    //                .no_execute = true,
    //            };
    //            pml4.entries[pml4_offset] = pml_entry;
    //            const table: *PageTable = pml3_recurse(pml4_offset);
    //            table[recurse] = pml_entry;
    //        }
    //
    //        const pml3: *PageTable = pml3_recurse(pml4_offset);
    //
    //        if (!pml3.entries[pml3_offset].present) {
    //            const block = try physical_mem_manager.allocBlocks(0);
    //            const pml_entry = Entry{
    //                .present = true,
    //                .writable = true,
    //                .user_accessible = false,
    //                .write_through_cache = false,
    //                .large_page = false,
    //                .addr = block,
    //                .no_execute = true,
    //            };
    //            pml3.entries[pml3_offset] = pml_entry;
    //            const table: *PageTable = pml2_recurse(pml4_offset, pml3_offset);
    //            table[recurse] = pml_entry;
    //        }
    //
    //        const pml2: *PageTable = pml2_recurse(pml4_offset, pml3_offset);
    //
    //        if (!pml2.entries[pml2_offset].present) {
    //            const block = try physical_mem_manager.allocBlocks(0);
    //            const pml_entry = Entry{
    //                .present = true,
    //                .writable = true,
    //                .user_accessible = false,
    //                .write_through_cache = false,
    //                .large_page = false,
    //                .addr = block,
    //                .no_execute = true,
    //            };
    //            pml2.entries[pml2_offset] = pml_entry;
    //            const table: *PageTable = pml1_recurse(pml4_offset, pml3_offset, pml2_offset);
    //            table[recurse] = pml_entry;
    //        }
    //
    //        const pml1: *PageTable = pml1_recurse(pml4_offset, pml3_offset, pml2_offset);
    //        if (pml1.entries[pml1_offset].present) {
    //            return error.AlreadyMapped;
    //        }
    //        pml1.entries[pml1_offset] = entry;
    //    }
    //
    //    pub fn unmap(addr: usize) !void {
    //        // ensure the address is mapped
    //        _ = try PageTable.resolve(addr);
    //        const pml4_offset = addr >> 39;
    //        const pml3_offset = addr >> 30 & recurse;
    //        const pml2_offset = addr >> 21 & recurse;
    //        const pml1_offset = addr >> 12 & recurse;
    //
    //        // Remove the mapping from PML1
    //        // if the mapping was the last one, free this PML1
    //        // and remove it from PML2, continuing recursively
    //        {
    //            const pml1 = pml1_recurse(pml4_offset, pml3_offset, pml2_offset);
    //            pml1.entries[pml1_offset].pml_entry.present = false;
    //
    //            var found = false;
    //            for (0..recurse) |i| {
    //                if (pml1.entries[i].present) {
    //                    found = true;
    //                    break;
    //                }
    //            }
    //            if (found) {
    //                return;
    //            }
    //            physical_mem_manager.freeBlock(pml1.entries[recurse].pml_entry.addr);
    //        }
    //
    //        {
    //            const pml2 = pml2_recurse(pml4_offset, pml3_offset);
    //            pml2.entries[pml2_offset].pml_entry.present = false;
    //
    //            var found = false;
    //            for (0..recurse) |i| {
    //                if (pml2.entries[i].present) {
    //                    found = true;
    //                    break;
    //                }
    //            }
    //            if (found) {
    //                return;
    //            }
    //            physical_mem_manager.freeBlock(pml2.entries[recurse].pml_entry.addr);
    //        }
    //
    //        {
    //            const pml3 = pml3_recurse(pml4_offset);
    //            pml3.entries[pml3_offset].pml_entry.present = false;
    //
    //            var found = false;
    //            for (0..recurse) |i| {
    //                if (pml3.entries[i].present) {
    //                    found = true;
    //                    break;
    //                }
    //            }
    //            if (found) {
    //                return;
    //            }
    //            physical_mem_manager.freeBlock(pml3.entries[recurse].pml_entry.addr);
    //        }
    //
    //        {
    //            const pml4 = pml4_recurse();
    //            pml4.entires[pml4_offset].pml_entry.present = false;
    //        }
    //    }
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
    // debug location of rsp
    {
        var val: usize = 0;
        asm volatile (
            \\mov %rsp, %[addr]
            : [addr] "={rax}" (val),
        );
        kernel.main_serial.print("rsp is 0x{X} lower than start\n", .{kernel.stack_start - val});
    }
    var cr2 = blk: {
        var val: usize = 0;
        asm volatile (
            \\mov %cr2, %[addr]
            : [addr] "={rax}" (val),
        );
        break :blk val;
    };
    kernel.main_serial.print("page fault at 0x{X} because 0x{X}!\n", .{ cr2, isf.err });
    // TODO why is this crashing?
    var msg = std.fmt.bufPrintZ(&handler_buf, handler_fmt, .{ isf.err, cr2, isf }) catch {
        @panic("Page fault, but could not format the crash message!");
    };
    @panic(msg);
}

pub fn installPageFaultHandler() void {
    IDT.setGate(@intCast(14), &pageFaultHandler, 0x8F);
}
