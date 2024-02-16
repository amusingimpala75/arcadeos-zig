// TODO define custom zig_panic function

const std = @import("std");

const kernel = @import("../kernel.zig");

var idt: [256]Entry align(0x10) = undefined;
var idtr: Descriptor = .{
    .limit = @sizeOf(@TypeOf(idt)) - 1,
    .base = undefined,
};

const Entry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    zero: u32,
};

const Descriptor = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

var exception_handlers: [256]*const ExceptionHandler = [1]*const ExceptionHandler{&exceptionHandlerDefault} ** 256;
pub const ExceptionHandler = fn (*ISF) void;

fn exceptionHandlerDefault(isf: *ISF) void {
    inline for (@typeInfo(ISF).Struct.fields) |*field| {
        const val: u64 = @field(isf, field.name);
        kernel.main_serial.print("{s} = {x}\n", .{ field.name, val });
    }

    // Thank you Copilot for (largely independently) auto-generating this
    @panic(switch (isf.int) {
        0 => "Divide by zero",
        1 => "Debug",
        2 => "Non-maskable interrupt",
        3 => "Breakpoint",
        4 => "Overflow",
        5 => "Bound range exceeded",
        6 => "Invalid opcode",
        7 => "Device not available",
        8 => "Double fault",
        9 => "Coprocessor segment overrun",
        10 => "Invalid TSS",
        11 => "Segment not present",
        12 => "Stack-segment fault",
        13 => "General protection fault",
        14 => "Page fault",
        15, 21...27 => "Reserved",
        16 => "x87 floating-point exception",
        17 => "Alignment check",
        18 => "Machine check",
        19 => "SIMD floating-point exception",
        20 => "Virtualization exception",
        28 => "Hypervisor exception",
        29 => "VMM Communication exception",
        30 => "Security exception",
        31 => "Triple fault",
        32...47 => "8259 PIC interrupt (should be masked)",
        else => "Unknown exception",
    });
}

export fn exceptionHandler(isf: *ISF) callconv(.C) void {
    exception_handlers[isf.int](isf);
}

pub const ISF = packed struct {
    // Set by us
    cr3: u64,
    gs: u64,
    fs: u64,
    es: u64,
    ds: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,
    rsp: u64,
    int: u64,
    // Set by CPU
    err: u64, // For exceptions w/o err code we push 0
    rip: u64,
    cs: u64,
    flags: u64,
    excp_rsp: u64, // TODO stack tracing?
    excp_ss: u64,

    pub fn format(self: *const ISF, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const max_field_length = blk: {
            comptime {
                var max = 0;
                for (@typeInfo(ISF).Struct.fields) |field| {
                    if (field.name.len > max) {
                        max = field.name.len;
                    }
                }
                break :blk max;
            }
        };
        const fmt = std.fmt.comptimePrint("{{s: <{d}}} = 0x{{X: <16}}{{c}}", .{max_field_length});

        inline for (@typeInfo(ISF).Struct.fields, 0..) |*field, index| {
            const val: u64 = @field(self, field.name);
            try std.fmt.format(
                writer,
                fmt,
                .{ field.name, val, if (index % 2 == 0) ' ' else '\n' },
            );
        }
    }
};

export fn exceptionStubHandler() callconv(.Naked) void {
    // Push general purpose registers
    asm volatile (
        \\push %rsp
        \\push %rax
        \\push %rcx
        \\push %rdx
        \\push %rbx
        \\push %rbp
        \\push %rsi
        \\push %rdi
    );
    // Push segment registers
    asm volatile (
        \\xor %rax,%rax
        \\mov %ds,%rax
        \\push %rax
        \\mov %es,%rax
        \\push %rax
        \\mov %fs,%rax
        \\push %rax
        \\mov %gs,%rax
        \\push %rax
        \\mov %[kernel_data],%ds
        \\mov %ax,%es
        \\mov %ax,%fs
        \\mov %ax,%gs
        \\mov %cr3,%rax
        \\push %rax
        :
        : [kernel_data] "{ax}" (@as(u16, @truncate(@offsetOf(@import("GDT.zig").GDT, "kernel_data")))),
    );
    // Call exception handler
    asm volatile (
        \\mov %rsp,%rdi
        //\\push %rsp
        \\call exceptionHandler
        //\\mov %rax,%rsp // TODO do i need to remove this?
    );
    // Pop segment registers
    asm volatile (
        \\pop %rax
        \\mov %rax,%cr3
        \\pop %gs
        \\pop %fs
        \\pop %rax
        \\mov %rax,%es
        \\pop %rax
        \\mov %rax,%ds
    );
    // Pop general purpose registers
    asm volatile (
        \\pop %rdi
        \\pop %rsi
        \\pop %rbp
        \\pop %rbx
        \\pop %rdx
        \\pop %rcx
        \\pop %rax
        \\pop %rsp
    );
    // Pop what the error was
    asm volatile (
        \\add $8,%rsp
    );
    // Return from interrupt handler back to stub
    asm volatile (
        \\sti
        \\iretq
    );
}

const ExceptionStub = struct {
    fn () callconv(.Naked) void;
};

fn generateExceptionStub(comptime index: u8) type {
    return struct {
        fn func() callconv(.Naked) void {
            asm volatile ("cli");

            // These interrupts do not provide an error code
            if ((index < 10 and index != 8) or
                (index >= 15 and index <= 28 and index != 21 and index != 17) or
                index == 31)
            {
                asm volatile ("pushq $0x0");
            }

            asm volatile ("pushq %[interrupt]"
                :
                : [interrupt] "i" (@as(u64, @intCast(index))),
            );

            asm volatile ("jmp exceptionStubHandler");
        }
    };
}

const exceptionStubs = blk: {
    var ret: [256]type = undefined;

    for (0..256) |i| {
        ret[i] = generateExceptionStub(i);
    }

    break :blk ret;
};

// Theoretically most of this function can be done at comptime,
// and the only thing that would need to be done at runtime would be
// setting the exceptionHandler[index] and updating the type attributes
// (no idea of there would be any issue with comptime handling of ptr->int,
// maybe that would have to be done at initialization instead)
pub fn setGate(comptime index: u8, handler: *const ExceptionHandler, type_attr: u8) void {
    const address_int: u64 = @intFromPtr(&(exceptionStubs[index].func));
    idt[index].offset_low = @truncate(address_int);
    idt[index].selector = @truncate(@offsetOf(@import("GDT.zig").GDT, "kernel_code"));
    idt[index].ist = 0;
    idt[index].type_attr = type_attr;
    idt[index].offset_mid = @truncate(address_int >> 16);
    idt[index].offset_high = @truncate(address_int >> 32);
    idt[index].zero = 0;

    exception_handlers[index] = handler;
}

pub fn init() void {
    idtr.base = @intFromPtr(&idt);

    inline for (0..32) |i| {
        setGate(@intCast(i), &exceptionHandlerDefault, 0x8F);
    }

    asm volatile ("lidt (%%rax)"
        :
        : [idtr] "{rax}" (&idtr),
    );
    asm volatile ("sti");
}

comptime {
    std.debug.assert(@sizeOf(Entry) == 16);
    std.debug.assert(@sizeOf(Descriptor) == 10);
}
