const std = @import("std");

const log = std.log.scoped(.x86_64);

const Framebuffer = @import("../Framebuffer.zig");
const GDT = @import("GDT.zig");
const IDT = @import("IDT.zig");
const ACPI = @import("../acpi.zig");
const BootloaderInfo = @import("../BootloaderInfo.zig");
const kernel = @import("../kernel.zig");
const paging = @import("../paging.zig");
const panic = @import("../panic.zig");

pub const assembly = @import("assembly.zig");

var stack_start: usize = undefined;

pub fn getStackStart() usize {
    return stack_start;
}

var bl_info: BootloaderInfo = undefined;
pub const bootloader_info: *const BootloaderInfo = &bl_info;

export fn _start() callconv(.C) noreturn {
    // store the stack pointer
    asm volatile (
        \\mov %rsp, %[addr]
        : [addr] "={rax}" (stack_start),
    );

    // Initialize serial output on COM1
    kernel.main_serial.init() catch unreachable;
    bl_info = BootloaderInfo.init() catch |err| {
        log.err("{}", .{err});
        @panic("error retrieving info from limine");
    };
    // Initialize panic handler (for debugging extra things)
    panic.init() catch |err| {
        if (err == error.OutOfMemory) {
            log.err("Please increase the size of addr_map_buffer in panic.zig", .{});
        } else {
            log.err("{s}", .{@errorName(err)});
        }
        @panic("error loading dwarf info");
    };
    // Initialize main framebuffer for display
    kernel.main_framebuffer = Framebuffer.init(0) orelse {
        @panic("Could not find the framebuffer!\n");
    };
    kernel.main_framebuffer.clear();
    // Initialize terminal for printing
    kernel.terminal.init(&kernel.main_framebuffer);

    // Load GDT with generic full-range descriptors
    GDT.initializeGDT();
    // Load interrupts, settings all gates to a default handler
    IDT.init();
    // Install the page fault handler
    paging.handler.install() catch @panic("page handler already installed");

    const acpi_info = ACPI.getInfo() catch |err| switch (err) {
        error.MalformedACPI => @panic("ACPI tables are corrupted"),
    };
    log.debug("found {} acpi", .{acpi_info});

    kernel.kmain();
}
