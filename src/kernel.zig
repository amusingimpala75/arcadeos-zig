const std = @import("std");
const Serial = @import("Serial.zig");
const Framebuffer = @import("Framebuffer.zig");
const Font = @import("fonts/Font.zig");
const GDT = @import("x86_64/GDT.zig");
const IDT = @import("x86_64/IDT.zig");
const builtin = @import("std").builtin;
const Terminal = @import("Terminal.zig");
const paging = @import("x86_64/paging.zig");
const Palette = @import("Palette.zig");
const APIC = @import("x86_64/APIC.zig").APIC;
const PIC = @import("x86_64/PIC.zig");

const limine = @import("limine");

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = switch (message_level) {
        .debug => "37",
        .info => "97",
        .warn => "33",
        .err => "91",
    };
    const fmt = "\x1B[" ++ color ++ "m[" ++ comptime message_level.asText() ++ "] (" ++ @tagName(scope) ++ ") " ++ format ++ "\x1B[0m";
    main_serial.print(fmt, args);
}

pub const std_options = .{ .logFn = log };

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

// TODO handle stack trace
/// This method relies on three things to be in a sane state:
///   1. The framebuffer |
///   2. The serial port | Both of which requires the code data from std
///   3. The main Font (independent)
pub fn panic(msg: []const u8, st: ?*builtin.StackTrace, s: ?usize) noreturn {
    _ = st;
    _ = s;
    // In case of really bad failure, at least print something to serial port
    std.log.err("panic! {s} \n", .{msg});
    // Get color palette
    const palette = Palette.default;
    // Draw error message background
    main_framebuffer.renderTexture(0, 0, main_framebuffer.width, main_framebuffer.height, &[_][]const [4]u8{
        &[_][4]u8{ palette.red.rgbByteArray(), palette.green.rgbByteArray(), palette.blue.rgbByteArray() },
        &[_][4]u8{ palette.yellow.rgbByteArray(), palette.aqua.rgbByteArray(), palette.purple.rgbByteArray() },
        &[_][4]u8{ palette.fg_bright.rgbByteArray(), palette.aqua.rgbByteArray(), palette.bg.rgbByteArray() },
    });

    // start 100px 100px away from top left corner
    const msg_rect_x = 100;
    const msg_rect_y = 100;

    // go to 100px 100px away from bottom right corner
    const msg_rect_width = main_framebuffer.width - msg_rect_x * 2;
    const msg_rect_height = main_framebuffer.height - msg_rect_y * 2;

    // render text box background
    main_framebuffer.renderTexture(msg_rect_x, msg_rect_y, msg_rect_width, msg_rect_height, &[_][]const [4]u8{
        &[_][4]u8{palette.blue_bright.rgbByteArray()},
    });

    // grab main font, scale by 4x for header font
    const font = &Font.fonts[0];
    const title_scale = 4;
    const title_char_width = Font.width * title_scale;
    const title_char_height = Font.height * title_scale;

    // start 50px 50px from top left of text box
    const title_x = 150;
    const title_y = 150;

    // Print header
    for ("A critical error has occured!", 0..) |c, i| {
        font.drawCharScaled(
            main_framebuffer,
            c,
            palette,
            false,
            title_x + i * title_char_width,
            title_y,
            title_scale,
        );
    }

    // Start message just below header, scale one of font
    const msg_x = 200;
    const msg_y = title_y + title_char_height * 2;
    const msg_wrap_x = main_framebuffer.width - msg_x;
    const msg_scale = 1;
    const msg_char_width = Font.width * msg_scale;
    const msg_char_height = Font.height * msg_scale;

    var x: usize = 0;
    var y: usize = 0;
    for (msg) |c| {
        // We even have to handle newlines.
        // Just set it to the position of wrapping
        // so that the code below handles the reset
        if (c == '\n') {
            x = msg_wrap_x;
        } else {
            font.drawCharScaled(
                main_framebuffer,
                c,
                palette,
                false,
                msg_x + x,
                msg_y + y,
                msg_scale,
            );
        }
        x += msg_char_width;
        // if past the boundary point,
        // go to next line
        if (msg_x + x > msg_wrap_x) {
            x = 0;
            y += msg_char_height;
        }
    }

    // Disable all interrupts and halt the CPU
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

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
