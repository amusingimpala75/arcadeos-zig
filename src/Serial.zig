///! Serial interface adaptor
///! provides easy access for printing
///! data to a serial port
const Serial = @This();

const std = @import("std");

const kernel = @import("kernel.zig");
const assembly = kernel.arch.assembly;

const SerialError = error{};
const SerialWriter = std.io.Writer(
    *Serial,
    SerialError,
    serialWrite,
);

/// Serial port for printing the data
port: u16,
writer: SerialWriter = .{ .context = undefined },

/// COM1
pub const serial1_port = 0x3f8;

/// Initialize serial port.
/// ensures serial port isn't faulty (returns error.SerialFaulty if so)
/// and sets up the writer for printing
pub fn init(self: *Serial) !void {
    self.writer.context = self;
    assembly.outb(self.port + 1, 0x00); // Disable all interrupts
    assembly.outb(self.port + 3, 0x80); // Enable DLAB (set baud rate divisor)
    assembly.outb(self.port + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
    assembly.outb(self.port + 1, 0x00); //                  (hi byte)
    assembly.outb(self.port + 3, 0x03); // 8 bits, no parity, one stop bit
    assembly.outb(self.port + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    assembly.outb(self.port + 4, 0x0B); // IRQs enabled, RTS/DSR set
    assembly.outb(self.port + 4, 0x1E); // Set in loopback mode, test the serial chip
    assembly.outb(self.port + 0, 0xAE); // Test serial chip (send byte 0xAE and check if serial
    // returns same byte)

    // Check if serial is faulty (i.e: not same byte as sent)
    if (assembly.inb(self.port + 0) != 0xAE) {
        return error.SerialFaulty;
    }

    // If serial is not faulty set it in normal operation mode
    // (not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled)
    assembly.outb(self.port + 4, 0x0F);
}

/// write a slice of bytes to serial
/// While is it marked as throwing a serial error
/// this is purely to appease the writer interface
/// which assumes that the writer can return errors
///
/// TODO perhaps have a timeout related error
fn serialWrite(self: *Serial, data: []const u8) SerialError!usize {
    for (data) |c| {
        self.putc(c);
    }
    return data.len;
}

/// blocks until the serial port is clear, then writes the characters
fn putc(self: Serial, char: u8) void {
    while (assembly.inb(self.port + 5) & 0x20 == 0x00) {}
    assembly.outb(self.port, char);
}

/// format-prints the data, assumes no errors will be thrown
/// (which is true for now)
pub fn print(self: Serial, comptime fmt: []const u8, args: anytype) void {
    std.fmt.format(self.writer, fmt, args) catch unreachable;
}
