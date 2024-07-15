const std = @import("std");

const log = std.log.scoped(.main);

const APIC = @import("x86_64/APIC.zig").APIC;
const Framebuffer = @import("Framebuffer.zig");
const GDT = @import("x86_64/GDT.zig");
const IDT = @import("x86_64/IDT.zig");
const PIC = @import("x86_64/PIC.zig");
const Palette = @import("Palette.zig");
const Panic = @import("Panic.zig");
const RSDT = @import("x86_64/RSDT.zig");
const Serial = @import("Serial.zig");
const Terminal = @import("Terminal.zig");
const logging = @import("log.zig");
const paging = @import("x86_64/paging.zig");

const limine = @import("limine");

pub const std_options = .{ .logFn = logging.logFn };

/// Ask limine for a 64K stack.
/// Should probably be moved to a different location,
/// possibly one tasked with setting up a stack for
/// the kernel that isn't in bootloader-reclaimable memory
pub export var stack_req = limine.StackSizeRequest{
    .stack_size = 1 << 16,
};

/// the value of %rsp when the kernel starts
/// see note above about being moved elsewhere
pub var stack_start: usize = undefined;

pub const panic = Panic.panic;

// Kernel global serial output, main screen framebuffer, and terminal
pub var main_serial: Serial = Serial{ .port = Serial.serial1_port };
pub var main_framebuffer: Framebuffer = undefined;
pub var terminal = Terminal{};

var count: u8 = 0;

fn timerHandler(_: *IDT.ISF) void {
    count += 1;
    apic.eoi.clear();
}

var apic: *APIC = undefined;

export fn _start() callconv(.C) noreturn {
    // store the stack pointer
    asm volatile (
        \\mov %rsp, %[addr]
        : [addr] "={rax}" (stack_start),
    );
    // Initialize serial output on COM1
    main_serial.init() catch unreachable;
    // Initialize main framebuffer for display
    main_framebuffer = Framebuffer.init(0) orelse {
        @panic("Could not initialize framebuffer!\n");
    };
    main_framebuffer.setClearColor(Palette.default.bg.rgbByteArray());
    main_framebuffer.clear();
    // Initialize terminal for printing
    terminal.init();
    // Load GDT with generic full-range descriptors
    GDT.initializeGDT();
    // Load interrupts, settings all gates to a default handler
    IDT.init();
    // Install the page fault handler
    paging.installPageFaultHandler() catch @panic("page handler already installed");
    // Intialize kernel-controlled recursive mapping scheme
    // so we don't need the bootloader
    paging.initKernelPaging();

    // ANY BOOTLOADER SERVICES NEED TO NOT BE USED AFTER THIS POINT

    PIC.setupAndDisable();
    apic = APIC.map(0x1000000) catch @panic("unhandled apic init error");

    terminal.print("booting", .{});

    apic.timer_divide_configuration.write(1);
    const gate = 48;
    IDT.setGate(gate, &timerHandler, 0x8F) catch @panic("gate 32 already in use");
    apic.lvt_timer.setVector(gate);
    apic.lvt_timer.unmask();

    apic.timer_initial_count.write(@as(u32, 1) << 28);

    var current = count;
    while (true) {
        // Has to be volatile otherwise it gets optimized to while (true) {}
        while (@as(*volatile u8, &count).* == current) {}
        if (count >= 4) {
            break;
        }
        terminal.print(".", .{});
        current = count;
        apic.timer_initial_count.write(@as(u32, 1) << 28);
    }

    // Once we get going places, this function should never return,
    // and so we have to panic first
    @panic("Kernel exited _start method!");
}
