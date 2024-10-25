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

/// The current row of the cursor
row: u8 = 0,
/// The current column of the cursor
col: u8 = 0,
/// Index of the top row of the screen
top_row: u8 = 0,
/// Actual chars
chars: [height][width]u8 = .{.{' '} ** width} ** height,
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

pub fn scroll(self: *Terminal, rows: u8) void {
    self.top_row = (self.top_row + rows) % width;
}

pub fn getChar(self: *Terminal, row: u8, col: u8) u8 {
    return self.chars[(self.top_row + row) % self.chars.len][col];
}

fn setChar(self: *Terminal, row: u8, col: u8, c: u8) void {
    self.chars[(self.top_row + row) % self.chars.len][col] = c;
}

/// Move cursor down, or scroll if necessary
fn advanceLine(self: *Terminal) void {
    if (self.row + 1 == height) {
        self.scroll(1);
    } else {
        self.row += 1;
    }
    for (0..width) |i| {
        self.setChar(self.row, @intCast(i), ' ');
    }
    self.col = 0;
}

/// set the next character
fn putChar(self: *Terminal, char: u8) void {
    self.setChar(self.row, self.col, char);
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
            '\x08' => {
                if (self.col == 0) {
                    if (self.row != 0) {
                        self.col = width - 1;
                        self.row -= 1;
                        while (self.col > 0 and self.getChar(self.row, self.col) == ' ') {
                            self.col -= 1;
                        }
                        self.setChar(self.row, self.col, ' ');
                    }
                    continue;
                }
                self.col -= 1;
                self.setChar(self.row, self.col, ' ');
            },
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
                self.getChar(
                    @intCast(y),
                    @intCast(x),
                ),
                x,
                y,
            );
        }
    }
}

/// print formatted text to the terminal
pub fn print(self: *Terminal, comptime str: []const u8, args: anytype) void {
    std.fmt.format(self.writer, str, args) catch unreachable;
    self.refresh();
}
