const std = @import("std");

const log = std.log.scoped(.bootloader_info);

const limine = @import("limine");

rsdt_phys_addr: *anyopaque,
kernel_vstart: usize,
kernel_pstart: usize,
kernel_length: usize,
kernel_elf_pstart: usize,
kernel_elf_len: usize,
highest_physical_addr: usize,
memmap: [20]?MemmapEntry,
hhdm_start: usize,
framebuffers: [8]?Framebuffer,
stack_size: usize,

export var rsdp_req: limine.RsdpRequest = .{};
export var memmap_req: limine.MemoryMapRequest = .{};
export var hhdm_start_req: limine.HhdmRequest = .{};
export var kernel_loc_req: limine.KernelAddressRequest = .{};
export var kernel_file_req: limine.KernelFileRequest = .{};
export var fb_request: limine.FramebufferRequest = .{};
/// Ask limine for a 64K stack.
/// Should probably be moved to a different location,
/// possibly one tasked with setting up a stack for
/// the kernel that isn't in bootloader-reclaimable memory
export var stack_req = limine.StackSizeRequest{
    .stack_size = 1 << 16,
};

pub fn init() !@This() {
    const rsdt_resp = rsdp_req.response orelse return error.LimineMissingRsdt;

    const memmap_resp = memmap_req.response orelse return error.LimineMissingMemmap;
    var memmap: [20]?MemmapEntry = [1]?MemmapEntry{null} ** 20;
    var klen: ?usize = null;
    var highest_physical_addr: usize = 0;

    var next_memmap_idx: usize = 0;
    for (memmap_resp.entries_ptr[0..memmap_resp.entry_count]) |entry| {
        if (next_memmap_idx > memmap.len) {
            @panic("too many limine memmap entries");
        }
        log.info("{} {} {}", .{
            entry.kind,
            entry.base >> 12,
            entry.length >> 12,
        });
        if (entry.kind == limine.MemoryMapEntryType.kernel_and_modules) {
            klen = entry.length;
        }

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
            .usable = entry.kind == limine.MemoryMapEntryType.usable,
        };
        next_memmap_idx += 1;
    }

    const hhdm_start_resp = hhdm_start_req.response orelse return error.LimineMissingHhdmStart;

    const kernel_loc_resp = kernel_loc_req.response orelse return error.LimineMissingKernelLocation;

    const kernel_file_resp = kernel_file_req.response orelse return error.LimineMissingKernelElf;

    const framebuffer_resp = fb_request.response orelse return error.LimineMissingFramebuffers;
    var framebuffers: [8]?Framebuffer = [1]?Framebuffer{null} ** 8;

    for (framebuffer_resp.framebuffers_ptr, 0..framebuffer_resp.framebuffer_count) |fb, idx| {
        if (idx >= framebuffers.len) {
            log.warn("more than {} framebuffers, skipping the rest", .{framebuffers.len});
        }
        framebuffers[idx] = .{
            .width = fb.width,
            .height = fb.height,
            .pitch = fb.pitch,
            .bpp = fb.bpp,
            .address = fb.address,
        };
    }

    if (stack_req.response == null) {
        return error.LimineMissingStackInfo;
    }

    return .{
        .rsdt_phys_addr = rsdt_resp.address,
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

const MemmapEntry = struct {
    start: usize,
    len: usize,
    usable: bool,
};

const Framebuffer = struct {
    width: usize,
    height: usize,
    pitch: usize,
    bpp: u16,
    address: [*]u8,
};
