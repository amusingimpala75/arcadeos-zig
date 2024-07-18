const std = @import("std");

const IDT = @import("../x86_64/IDT.zig");
const kernel = @import("../kernel.zig");

const log = std.log.scoped(.page_fault_handler);

const handler_fmt =
    \\Page Fault!
    \\  reason: 0x{X}
    \\  addr: 0x{X}
    \\  ISF:
    \\{}
;

var handler_buf: [handler_fmt.len + @sizeOf(IDT.ISF) * 8:0]u8 = undefined;

fn pageFaultHandler(isf: *IDT.ISF) void {
    const addr = kernel.arch.assembly.getPageFaultAddr();
    log.err("page fault at 0x{X} because 0x{X}!", .{ addr, isf.err });
    const msg = std.fmt.bufPrintZ(&handler_buf, handler_fmt, .{ isf.err, addr, isf }) catch {
        @panic("Page fault, but could not format the crash message!");
    };
    @panic(msg);
}

pub fn install() !void {
    try IDT.setGate(@intCast(14), &pageFaultHandler, 0x8F);
}
