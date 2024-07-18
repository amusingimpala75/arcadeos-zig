//! The logging interface for the kernel
//!
//! logs both the message leve and the scope
//! of the message to organize the log

const std = @import("std");

const kernel = @import("kernel.zig");

const Log = struct {
    prefix: []const u8,
};
const LogError = error{};

const LogWriter = std.io.GenericWriter(
    *const Log,
    LogError,
    logWrite,
);

/// Write a slice of bytes to serial
/// adding the necessary prefix after newlines
// TODO: write all bytes between '\n's once as a slice
fn logWrite(self: *const Log, data: []const u8) LogError!usize {
    for (data) |c| {
        kernel.main_serial.print("{c}", .{c});
        if (c == '\n') {
            kernel.main_serial.print("{s} ", .{self.prefix});
        }
    }
    return data.len;
}

/// log a message to the main_serial port
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = "\x1B[" ++ switch (message_level) {
        .debug => "37",
        .info => "97",
        .warn => "33",
        .err => "91",
    } ++ "m";
    const color_reset = "\x1B[0m";
    const log: Log = .{
        .prefix = "[" ++ comptime message_level.asText() ++ "] (" ++ @tagName(scope) ++ ") ",
    };
    const writer: LogWriter = .{ .context = &log };
    kernel.main_serial.print(color ++ log.prefix, .{});
    std.fmt.format(writer, format, args) catch unreachable;
    kernel.main_serial.print("{s}\n", .{color_reset});
}
