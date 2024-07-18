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

pub inline fn readmsr(reg: u32, eax: *u32, edx: *u32) void {
    var eax1: u32 = undefined;
    var edx1: u32 = undefined;
    asm volatile ("rdmsr"
        : [eax] "={eax}" (eax1),
          [edx] "={edx}" (edx1),
        : [reg] "{ecx}" (reg),
    );
    eax.* = eax1;
    edx.* = edx1;
}

pub inline fn writemsr(reg: u32, eax: u32, edx: u32) void {
    asm volatile ("wrmsr"
        :
        : [eax] "{eax}" (eax),
          [edx] "{edx}" (edx),
          [reg] "{ecx}" (reg),
    );
}

pub inline fn getPageTablePhysAddr() usize {
    const bitmask: usize = ~@as(usize, 0b111111111111);
    return asm volatile (
        \\mov %cr3, %[addr]
        : [addr] "={rax}" (-> u64),
    ) & bitmask;
}

pub fn setPageTablePhysAddr(addr: usize) void {
    // Retrive the old value of cr3
    const old_cr3 = getPageTablePhysAddr();
    // Preserve the lower 12 bits of the old cr3
    const new_cr3 = addr | (old_cr3 & 0b111111111111);
    // Load this into the cr3 register
    asm volatile (
        \\mov %[addr], %cr3
        :
        : [addr] "rax" (new_cr3),
    );
}

pub fn getPageFaultAddr() usize {
    return asm volatile (
        \\mov %cr2, %[addr]
        : [addr] "={rax}" (-> usize),
    );
}

pub fn halt() void {
    asm volatile ("hlt");
}
