//! Contains assembly routines for the x86-64 architecture
//!
//! Although void inline functions with only comptime parameters
//! theoretically shouldn't need to modify the stack, they stil
//! do, which is why the IDT still has so much inline asm, as
//! the save/restore section cannot be converted to functions

/// Loads a value into a segment register
pub inline fn loadSegmentRegister(comptime reg: []const u8, val: u16) void {
    asm volatile ("mov %[val], %" ++ reg
        :
        : [val] "{ax}" (val),
    );
}

/// Loads the GDTR
pub inline fn loadGDTR(gdtr: *anyopaque) void {
    asm volatile ("lgdt (%%rax)"
        :
        : [gdtr] "{rax}" (gdtr),
    );
}

/// Loads a value into the code segment, performing a long return
pub inline fn loadCodeSegmentRegister(val: usize) void {
    asm volatile (
        \\pushq %[kernel_code]
        \\lea .gdtDone(%rip),%rax
        \\push %rax
        \\lretq
        \\.gdtDone:
        :
        : [kernel_code] "{dx}" (val),
    );
}

/// Disable interrupts from occuring
///
/// see also `enableInterrupts`
pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

/// Enable enterrupts
///
/// see also `disableInterrupts`
pub inline fn enableInterrupts() void {
    asm volatile ("sti");
}

/// write to serial port
pub inline fn outb(port: u16, byte: u8) void {
    asm volatile ("outb %[byte], %[port]"
        :
        : [byte] "{al}" (byte),
          [port] "{dx}" (port),
    );
}

/// read from serial port
pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[byte]"
        : [byte] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}
