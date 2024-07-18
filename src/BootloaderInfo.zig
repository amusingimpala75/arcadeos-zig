//! Contains information acquired from the bootloader about
//! the state of the system.
//! Physical Addresses are valid no matter the paging state,
//! but virtual ones will need to be mapped after loading
//! the kernel paging table.

const std = @import("std");

const log = std.log.scoped(.bootloader_info);

const limine = @import("limine");

/// The physical address of the RSDT table
/// The RSDP is not guaranteed to be mapped
rsdp_phys_addr: usize,
/// The virtual address of the start of the kenrel
// TODO: remove when the linker script actually
// lets me point to the various parts of the kernel
kernel_vstart: usize,
/// The physical address of the start of the kernel
kernel_pstart: usize,
/// Length of the kernel executable in memory
kernel_length: usize,
/// Location of the kernel ELF loaded by limine.
/// This is not guaranteed to be mapped
kernel_elf_pstart: usize,
/// Length of the ELF backing the kernel
kernel_elf_len: usize,
/// The highest phsyical address, at least determined
/// by ignoring the memmap entries that are reserved
/// or not backed by physical ram
highest_physical_addr: usize,
/// Description of the physical memory layout
memmap: [20]?MemmapEntry,
/// Start of the higher-half direct map. Limine maps
/// all memory at physical address 0->x to the virtual memory
/// hhdm_start->hhdm_start+x
hhdm_start: usize,
/// A collection of the framebuffers available to the kernel
/// The addresses are not guaranteed to be mapped
framebuffers: [8]?Framebuffer,
/// Size of the stack requested for all cores.
stack_size: usize,

// Limine requests
export var rsdp_req: limine.RsdpRequest = .{};
export var memmap_req: limine.MemoryMapRequest = .{};
export var hhdm_start_req: limine.HhdmRequest = .{};
export var kernel_loc_req: limine.KernelAddressRequest = .{};
export var kernel_file_req: limine.KernelFileRequest = .{};
export var fb_request: limine.FramebufferRequest = .{};
export var stack_req = limine.StackSizeRequest{
    .stack_size = 1 << 16,
};

pub fn init() !@This() {
    // ensure the requests all returned valid responses
    if (stack_req.response == null) {
        return error.LimineMissingStackInfo;
    }
    const rsdt_resp = rsdp_req.response orelse return error.LimineMissingRsdt;
    const hhdm_start_resp = hhdm_start_req.response orelse return error.LimineMissingHhdmStart;
    const kernel_loc_resp = kernel_loc_req.response orelse return error.LimineMissingKernelLocation;
    const kernel_file_resp = kernel_file_req.response orelse return error.LimineMissingKernelElf;
    const framebuffer_resp = fb_request.response orelse return error.LimineMissingFramebuffers;
    const memmap_resp = memmap_req.response orelse return error.LimineMissingMemmap;

    var memmap: [20]?MemmapEntry = [1]?MemmapEntry{null} ** 20;
    var klen: ?usize = null;
    var highest_physical_addr: usize = 0;

    var next_memmap_idx: usize = 0;
    for (memmap_resp.entries_ptr[0..memmap_resp.entry_count]) |entry| {
        if (next_memmap_idx > memmap.len) {
            @panic("too many limine memmap entries");
        }
        // log all fo the entries, just for debugging purposes
        log.debug("{} {} {}", .{
            entry.kind,
            entry.base >> 12,
            entry.length >> 12,
        });
        // Update the length of the kernel
        // Note: limine should never have the kernel
        // loaded into two different locations in memory
        if (entry.kind == limine.MemoryMapEntryType.kernel_and_modules) {
            if (klen != null)
                unreachable;
            klen = entry.length;
        }

        // This is just a heuristic, and as such may be wrong. But as far
        // as I can tell, the only things that exists above the actual
        // RAM are reserved mem, bad mem, and the framebuffer(s)
        if (entry.kind != limine.MemoryMapEntryType.reserved and
            entry.kind != limine.MemoryMapEntryType.bad_memory and
            entry.kind != limine.MemoryMapEntryType.framebuffer and
            entry.base + entry.length > highest_physical_addr)
        {
            highest_physical_addr = entry.base + entry.length;
        }

        memmap[next_memmap_idx] = .{
            .start = entry.base,
            .len = entry.length,
            // Technically, other types of memory could be usable, but
            // I'm not at the point to be reclaiming the bootloader memory
            .usable = entry.kind == limine.MemoryMapEntryType.usable,
        };
        next_memmap_idx += 1;
    }

    var framebuffers: [8]?Framebuffer = [1]?Framebuffer{null} ** 8;

    for (framebuffer_resp.framebuffers(), 0..) |fb, idx| {
        // It would be quite odd to have more than 8 framebuffers
        if (idx >= framebuffers.len) {
            log.warn("more than {} framebuffers, skipping the rest", .{framebuffers.len});
        }
        framebuffers[idx] = .{
            .width = fb.width,
            .height = fb.height,
            .pitch = fb.pitch,
            .bpp = fb.bpp,
            .pixels = fb.address[0 .. fb.height * fb.pitch],
        };
    }

    return .{
        .rsdp_phys_addr = @intFromPtr(rsdt_resp.address) - hhdm_start_resp.offset,
        .kernel_vstart = kernel_loc_resp.virtual_base,
        .kernel_pstart = kernel_loc_resp.physical_base,
        .kernel_length = klen orelse return error.LimineMemmapMissingKernel,
        .highest_physical_addr = highest_physical_addr,
        .memmap = memmap,
        .hhdm_start = hhdm_start_resp.offset,
        .kernel_elf_pstart = @intFromPtr(kernel_file_resp.kernel_file.address) - hhdm_start_resp.offset,
        .kernel_elf_len = kernel_file_resp.kernel_file.size,
        .framebuffers = framebuffers,
        .stack_size = stack_req.stack_size,
    };
}

/// An entry in the memory map
const MemmapEntry = struct {
    /// Start of the segment
    start: usize,
    /// length of the segment
    len: usize,
    /// whether or not the segment is usable to operations
    usable: bool,
};

/// A structure representing a framebuffer device
const Framebuffer = struct {
    /// width of the screen in pixels
    width: usize,
    /// height of the screen in pixels
    height: usize,
    /// bytes per line of the screen
    pitch: usize,
    /// bits per pixel of the screen
    bpp: u16,
    /// The actual pixel data of the screen.
    /// This is not guaranteed to be mapped.
    pixels: []u8,
};
