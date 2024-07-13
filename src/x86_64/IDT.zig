// TODO define custom zig_panic function

const std = @import("std");

const log = std.log.scoped(.interrupt_table);

const kernel = @import("../kernel.zig");

const assembly = @import("assembly.zig");
const GDT = @import("GDT.zig");

/// Interrupt Descriptor Table
///
/// Holds entries for the entire set of interrupts
/// possible, including stubs for unregistered ones
var idt: [256]Entry align(0x10) = undefined;
/// IDT pointer - data structure the CPU uses
/// to know where to find the IDT
var idtr: Descriptor = .{
    .limit = @sizeOf(@TypeOf(idt)) - 1,
    .base = undefined,
};

/// An entry in the IDT
const Entry = packed struct(u128) {
    /// The offset in the segment of the interrupt sub-routine
    offset_low: u16,
    /// the segment selector - we just always make it the code selector
    selector: u16 = GDT.kernel_code_offset,
    /// Index of the interrupt stack table
    /// for now, we ignore that and set it to '0' to use no
    /// interrupt stack table, ie just continure where we left off
    ist: u3 = 0,
    reserved1: u5 = 0,
    /// 0xE = interrupt, 0xF = trap
    type_attr: u8,
    /// see `offset_low`
    offset_mid: u16,
    /// see `offset_low`
    offset_high: u32,
    reserved2: u32 = 0,
};

/// CPU structure to find the IDT.
///
/// see the comment on GDT.Descriptor for why
/// extern struct instead of packed struct
const Descriptor = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

/// list of the handler to be run in the caase of an interrupt
/// non-assigned ones are stubbed with a defult to just tell us
/// a descriptor for the interrupt signaled
var exception_handlers: [256]*const ExceptionHandler = [1]*const ExceptionHandler{&exceptionHandlerDefault} ** 256;

/// we have a stub call into our table of exception handlers.
/// the stub sets up the interrupt stack fame to keep track of
/// the CPU prior to the interrupt.
pub const ExceptionHandler = fn (*ISF) void;

/// default exception handler, present if and only if
/// there is not a registered interrupt at a given gate
fn exceptionHandlerDefault(isf: *ISF) void {
    inline for (@typeInfo(ISF).Struct.fields) |*field| {
        const val: u64 = @field(isf, field.name);
        log.debug("{s} = {x}", .{ field.name, val });
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

/// called by our exception handler stuber, calls the respective exception handler
export fn exceptionHandler(isf: *ISF) callconv(.C) void {
    exception_handlers[isf.int](isf);
}

/// holds the CPU state prior to the interrupt, as well
/// as some extra information from the CPU
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
    /// The interrupt vector
    int: u64,
    // Set by CPU
    /// error value for the exception
    /// for exceptions without an error value we push a value of 0
    /// to make our lives easier on the exiting process
    err: u64,
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

/// stub that is called at the start of every interrupt
/// first all of the registers are saved, and kernel data segments
/// are set. Then the exception handler is called, after which the
/// CPU state from before the interrupt is resotred, and the
/// exception is exited
export fn exceptionStubHandler() callconv(.Naked) void {
    // Save general purpose registers
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
    // Save segment registers
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
        \\mov %cr3,%rax
        \\push %rax
    );
    // Load kernel segment values
    asm volatile (
        \\mov %[val], %ds
        \\mov %[val], %es
        \\mov %[val], %fs
        \\mov %[val], %gs
        :
        : [val] "{ax}" (GDT.kernel_data_offset),
    );
    // Call exception handler
    asm volatile (
        \\mov %rsp,%rdi
        \\call exceptionHandler
    );
    // Restore segment registers
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
    // Restore general purpose registers
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
    // Clear the int and the error
    asm volatile (
        \\add $16,%rsp
    );
    // Return from interrupt handler
    asm volatile (
        \\sti
        \\iretq
    );
}

fn GenerateExceptionStub(comptime index: u8) type {
    return struct {
        /// When an interrupt begins:
        /// - disable interrupts
        /// - push an error if one is not provided, to even out the stack
        /// - push the interrupt vector
        /// - call the proper delegation function
        fn func() callconv(.Naked) void {
            asm volatile ("cli");

            // These interrupts do not provide an error code
            if ((index < 10 and index != 8) or
                (index >= 15 and index <= 28 and index != 21 and index != 17) or
                index >= 31)
            {
                asm volatile ("pushq $0");
            }

            asm volatile ("pushq %[interrupt]"
                :
                : [interrupt] "i" (@as(u64, @intCast(index))),
            );

            asm volatile ("jmp exceptionStubHandler");
        }
    };
}

// TODO can we reduce this to just one function?
const exceptionStubs = blk: {
    var ret: [256]type = undefined;

    for (0..256) |i| {
        ret[i] = GenerateExceptionStub(i);
    }

    break :blk ret;
};

/// Sets gate as enabled, with the requsted type attributes
// Theoretically most of this function can be done at comptime,
// and the only thing that would need to be done at runtime would be
// setting the exceptionHandler[index] and updating the type attributes
// (no idea of there would be any issue with comptime handling of ptr->int,
// maybe that would have to be done at initialization instead)
pub fn setGate(comptime index: u8, handler: *const ExceptionHandler, type_attr: u8) !void {
    if (exception_handlers[index] != &exceptionHandlerDefault) {
        return error.InUse;
    }
    const address_int: u64 = @intFromPtr(&(exceptionStubs[index].func));
    idt[index] = .{
        .offset_low = @truncate(address_int),
        .type_attr = type_attr,
        .offset_mid = @truncate(address_int >> 16),
        .offset_high = @truncate(address_int >> 32),
    };

    exception_handlers[index] = handler;
}

/// sets up the IDT with the bottom 32 gates opened for the regularly expected CPU interrupts
pub fn init() void {
    idtr.base = @intFromPtr(&idt);

    inline for (0..32) |i| {
        setGate(@intCast(i), &exceptionHandlerDefault, 0x8F) catch unreachable;
    }

    // Loads the IDT
    asm volatile ("lidt (%%rax)"
        :
        : [idtr] "{rax}" (&idtr),
    );
    assembly.enableInterrupts();
}

comptime {
    std.debug.assert(@sizeOf(Descriptor) == 10);
}
