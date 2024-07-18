const std = @import("std");

const log = std.log.scoped(.paging);

const IDT = @import("x86_64/IDT.zig");
const PhysicalMemoryManager = @import("PhysicalMemoryManager.zig");
const kernel = @import("kernel.zig");
const handler = @import("paging/handler.zig");

pub const PageTable = @import("paging/PageTable.zig");

pub fn initKernelPaging() void {
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
    log.info("kernel vaddr at {X}", .{kernel.arch.bootloader_info.kernel_vstart});

    // Map the kernel as well again to the addr (> 0xFFFFFFFF80000000) provided by the bootloader
    try pml4.mapAll(
        kernel.arch.bootloader_info.kernel_vstart,
        kernel.arch.bootloader_info.kernel_pstart,
        kernel.arch.bootloader_info.kernel_length,
    );

    // Map the stack (may not be 4096-aligned)
    // Stack grows down (you would not believe how many hours it took
    // to notice the bug where I had it mapping the pages above, rather than below)
    {
        const aligned = kernel.arch.getStackStart() & ((@as(usize, 1) << 12) - 1) == 0;
        const stack_size = kernel.arch.bootloader_info.stack_size;
        const stack_virt_start = (kernel.arch.getStackStart() - stack_size) & ~((@as(usize, 1) << 12) - 1);
        const stack_phys_start = if (stack_virt_start < kernel.arch.bootloader_info.hhdm_start) stack_virt_start else stack_virt_start - kernel.arch.bootloader_info.hhdm_start;
        try pml4.mapAll(
            stack_virt_start,
            stack_phys_start,
            if (aligned) stack_size else stack_size + page_size,
        );
    }

    // Map the framebuffer
    {
        const fb_virt_addr = @intFromPtr(kernel.main_framebuffer.addr.ptr);
        // TODO convert manual resolution into a function
        const fb_phys_addr = blk: {
            const pml4_offset: u9 = @truncate(fb_virt_addr >> 39);
            const pml3_offset: u9 = @truncate(fb_virt_addr >> 30);
            const pml2_offset: u9 = @truncate(fb_virt_addr >> 21);
            const pml1_offset: u9 = @truncate(fb_virt_addr >> 12);

            const old_pml4: *PageTable = @ptrFromInt(kernel.arch.assembly.getPageTablePhysAddr());
            const pml3: *PageTable = @ptrFromInt((old_pml4.entries[pml4_offset].physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start);
            const pml2: *PageTable = @ptrFromInt((pml3.entries[pml3_offset].physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start);
            const pml1: *PageTable = @ptrFromInt((pml2.entries[pml2_offset].physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start);

            break :blk @as(usize, @intCast(pml1.entries[pml1_offset].physical_addr_page)) << 12;
        };

        try pml4.mapAll(
            fb_virt_addr,
            fb_phys_addr,
            kernel.main_framebuffer.width * kernel.main_framebuffer.height * (kernel.main_framebuffer.bpp / 8),
        );
    }

    // Map the physical memory manager
    {
        const pmm_virt = @intFromPtr(PhysicalMemoryManager.instance);
        const pmm_phys = if (pmm_virt > kernel.arch.bootloader_info.hhdm_start) pmm_virt - kernel.arch.bootloader_info.hhdm_start else pmm_virt;
        try pml4.mapAll(
            pmm_virt,
            pmm_phys,
            PhysicalMemoryManager.instance.byteSize(),
        );
    }

    // Map the kernel elf file for debugging
    {
        const elf_virt = kernel.arch.bootloader_info.kernel_elf_pstart + kernel.arch.bootloader_info.hhdm_start;
        const elf_phys = kernel.arch.bootloader_info.kernel_elf_pstart;
        try pml4.mapAll(
            elf_virt,
            elf_phys,
            kernel.arch.bootloader_info.kernel_elf_len,
        );
    }
}

pub const page_size = 4096;

pub const installPageFaultHandler = handler.installPageFaultHandler;
