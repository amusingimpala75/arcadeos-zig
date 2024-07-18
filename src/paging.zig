//! paging.zig provides an interface for requesting regions to be mapped
//! during paging set up. It also provides access to modifying the
//! page tables

const std = @import("std");

const log = std.log.scoped(.paging);

const kernel = @import("kernel.zig");
pub const handler = @import("paging/handler.zig");

pub const PageTable = @import("paging/PageTable.zig");

/// Resolves a virtual address assuming that
/// the limine direct mappings are available
/// (so that we can directly access the page tables)
fn resolvePreLoading(vaddr: usize) !usize {
    const pml4_offset: u9 = @truncate(vaddr >> 39);
    const pml3_offset: u9 = @truncate(vaddr >> 30);
    const pml2_offset: u9 = @truncate(vaddr >> 21);
    const pml1_offset: u9 = @truncate(vaddr >> 12);

    const old_pml4: *PageTable = @ptrFromInt(kernel.arch.assembly.getPageTablePhysAddr());
    const pml4_entry = old_pml4.entries[pml4_offset];
    if (!pml4_entry.present)
        return error.Unmapped;
    const pml3: *PageTable = @ptrFromInt((pml4_entry.physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start);
    const pml3_entry = pml3.entries[pml3_offset];
    if (!pml3_entry.present)
        return error.Unmapped;
    const pml2: *PageTable = @ptrFromInt((pml3_entry.physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start);
    const pml2_entry = pml2.entries[pml2_offset];
    if (!pml2_entry.present)
        return error.Unmapped;
    const pml1: *PageTable = @ptrFromInt((pml2_entry.physical_addr_page << 12) + kernel.arch.bootloader_info.hhdm_start);
    const pml1_entry = pml1.entries[pml1_offset];
    if (!pml1_entry.present)
        return error.Unmapped;

    return @as(usize, @intCast(pml1_entry.physical_addr_page)) << 12;
}

/// represents the state of the paging,
/// if bootloader paging is enabled
/// or the kernel's instead
var bootloader_paging = true;

/// resolves a virtual address, either using the
/// limine based scheme or the kernel recursive
/// scheme, depending on if kernel paging
/// has been enabled yet
pub fn resolve(vaddr: usize) !usize {
    return try if (bootloader_paging)
        resolvePreLoading(vaddr)
    else
        PageTable.resolve(vaddr);
}

/// Initializies kernel paging,
/// mapping the request segments first.
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
        bootloader_paging = false;
    }
}

/// Delineates a request for mapping
pub const MapRequest = struct {
    /// The physical address of the region to be mapped
    physical_addr: usize,
    /// The virtual address of the region to be mapped
    virtual_addr: usize,
    /// the length of the region being mapped
    len: usize,
    /// the priveleges/access of the region being mapped
    access: PageTable.PageAccess,
};

var map_reqs: [20]?MapRequest = [1]?MapRequest{null} ** 20;

/// requests that a region be mapped before enabling kernel paging
pub fn addInitialMapping(request: MapRequest) void {
    for (&map_reqs) |*req| {
        if (req.* == null) {
            req.* = request;
            return;
        }
    }
    @panic("you need to increase the buffer for the page mapping requests");
}

/// maps the requisite pages prior to enabling kernel paging
fn mapNecessaryBeforeLoad(pml4: *PageTable) !void {
    log.info("kernel vaddr at {X}", .{kernel.arch.bootloader_info.kernel_vstart});

    // Map the kernel as well again to the addr (> 0xFFFFFFFF80000000) provided by the bootloader
    try pml4.mapAll(
        kernel.arch.bootloader_info.kernel_vstart,
        kernel.arch.bootloader_info.kernel_pstart,
        kernel.arch.bootloader_info.kernel_length,
        .kernel_rwx,
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
            .kernel_rw,
        );
    }

    // map the other requested sections
    for (map_reqs) |req| {
        if (req) |request| {
            try pml4.mapAll(
                request.virtual_addr,
                request.physical_addr,
                request.len,
                request.access,
            );
        } else {
            break;
        }
    }
}

pub const page_size: usize = 4096;
