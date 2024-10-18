const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.main);

const APIC = @import("x86_64/APIC.zig").APIC;
const IOAPIC = @import("x86_64/IOAPIC.zig");
const Framebuffer = @import("Framebuffer.zig");
const IDT = @import("x86_64/IDT.zig");
const PIC = @import("x86_64/PIC.zig");
const panic_handler = @import("panic.zig");
const PhysicalMemoryManager = @import("PhysicalMemoryManager.zig");
const Serial = @import("Serial.zig");
const Terminal = @import("Terminal.zig");
const logging = @import("log.zig");
const paging = @import("paging.zig");

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/arch.zig"),
    else => |a| @compileError(@tagName(a) ++ "is unsupported"),
};

// Otherwise Zig discards the file and doesn't export the _start fn
comptime {
    _ = arch;
}

pub const std_options = .{ .logFn = logging.logFn };

pub const os = struct {
    pub const heap = struct {
        //pub const page_allocator = paging.allocator;
    };
};

pub const panic = panic_handler.panic;

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

pub fn kmain() noreturn {
    PhysicalMemoryManager.init() catch |err| {
        log.err("{}", .{err});
        @panic("error initializing physical memory manager");
    };

    // Intialize kernel-controlled recursive mapping scheme
    // so we don't need the bootloader
    paging.initKernelPaging();

    // ANY BOOTLOADER SERVICES NEED TO NOT BE USED AFTER THIS POINT

    PIC.setupAndDisable();
    apic = APIC.map(0x1000000) catch @panic("unhandled apic init error");

    const val = IDT.requestGate(.low, &keyHandler, 0x8F) catch @panic("could not request key gate");

    const ioapic = IOAPIC.init(0xFEC00000);
    log.debug("ioapic: {}", .{ioapic});
    ioapic.configureVector(1, .{
        .vector = val,
        .del_mode = .lowest_priority,
        .dest_mode = .physical,
        .waiting_on_lapic = false,
        .remote_irr = false,
        .trigger_level = true,
        .mask = false,
        .destination = 0, // TODO de-hardcode this
    });

    log.debug("apic keyboard enabled", .{});

    terminal.print("booting", .{});

    apic.timer_divide_configuration.write(1);
    // const gate = 48;
    // IDT.setGate(gate, &timerHandler, 0x8F) catch @panic("gate 32 already in use");
    const gate = IDT.requestGate(.low, &timerHandler, 0x8F) catch @panic("no gates available");
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
    @panic("Kernel exited kmain!");
}

fn keyHandler(_: *IDT.ISF) void {
    log.debug("key pressed", .{});

    _ = arch.assembly.inb(0x60);

    apic.eoi.clear();
}
