//! Interface for a terminal writing to a framebuffer

const Terminal = @This();

const std = @import("std");

const Font = @import("fonts/Font.zig");
const Framebuffer = @import("Framebuffer.zig");
const Palette = @import("Palette.zig");

const TerminalError = error{};
const TerminalWriter = std.io.GenericWriter(
    *Terminal,
    TerminalError,
    terminalWrite,
);

// these are the default widths/heights of terminals
const width = 80;
const height = 24;

const TerminalRingbuffer = @import("util.zig").Ringbuffer(
    [width]u8,
    height,
    [1]u8{' '} ** width,
);

/// Character rolling-buffer, representing the screen
chars: TerminalRingbuffer = TerminalRingbuffer.init(),
/// The current row of the cursor
row: u8 = 0,
/// The current column of the cursor
col: u8 = 0,
/// The palette of the terminal
palette: *const Palette = Palette.default,
/// GenericWriter interface for the term
writer: TerminalWriter = .{ .context = undefined },
/// Scale of the characters in pixels
char_scale: u8 = 1,
/// The framebuffer to draw to
framebuffer: *Framebuffer = undefined,

/// Initialize the terminal to use the given framebuffer
pub fn init(self: *Terminal, fb: *Framebuffer) void {
    // Scale the characters by as large as possible to fit the 24:80
    const max_width_scale = fb.width / (Font.width * width);
    const max_height_scale = fb.height / (Font.height * height);
    self.char_scale = @intCast(@min(max_width_scale, max_height_scale));

    self.framebuffer = fb;
    self.writer.context = @ptrCast(self);
}

/// move the text one line up the screen
fn advanceLine(self: *Terminal) void {
    self.chars.advanceHead();
    var curr = self.chars.get(0);
    for (0..curr.len) |i| {
        curr[i] = ' ';
    }
    self.row = @min(self.row + 1, height - 1);
    self.col = 0;
}

/// set the next character
fn putChar(self: *Terminal, char: u8) void {
    self.chars.get(0)[self.col] = char;
    self.col += 1;
    if (self.col == width) {
        self.advanceLine();
    }
}

/// write a slice to the terminal, wrapping if necessary
fn terminalWrite(self: *Terminal, chars: []const u8) TerminalError!usize {
    var i: usize = 0;
    while (i < chars.len) : (i += 1) {
        switch (chars[i]) {
            '\n' => self.advanceLine(),
            else => |char| self.putChar(char),
        }
    }
    return chars.len;
}

/// draw the given character
fn drawChar(self: *Terminal, char: u8, x: usize, y: usize) void {
    const char_width = Font.width * self.char_scale;
    const char_height = Font.height * self.char_scale;

    // TODO set blank spaces when drawing the character,
    //      rather than here as it doubles the amount of
    //      time this part takes
    if (char != ' ') {
        Font.fonts[0].drawCharScaled(
            self.framebuffer,
            char,
            self.palette,
            true,
            x * char_width,
            y * char_height,
            self.char_scale,
        );
    } else {
        self.framebuffer.renderTexture(
            x * char_width,
            y * char_height,
            char_width,
            char_height,
            &[_][]const [4]u8{
                &[_][4]u8{self.palette.bg.rgbByteArray()},
            },
        );
    }
}

/// redraw the terminal
pub fn refresh(self: *Terminal) void {
    for (0..self.row + 1) |y| {
        for (0..width) |x| {
            self.drawChar(
                self.chars.get(y)[x],
                x,
                height - 1 - y,
            );
        }
    }
}

/// print formatted text to the terminal
pub fn print(self: *Terminal, comptime str: []const u8, args: anytype) void {
    std.fmt.format(self.writer, str, args) catch unreachable;
    self.refresh();
}
