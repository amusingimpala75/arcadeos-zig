const Terminal = @This();

const std = @import("std");

const Font = @import("fonts/Font.zig");
const kernel = @import("kernel.zig");

const TerminalError = error{};

const width = 80;
const height = 24;

const TerminalRingbuffer = @import("util.zig").Ringbuffer(
    [width]u8,
    height,
    [1]u8{' '} ** width,
);

const TerminalWriter = std.io.Writer(
    *Terminal,
    TerminalError,
    terminalWrite,
);

chars: TerminalRingbuffer = TerminalRingbuffer.init(),
row: u8 = 0,
col: u8 = 0,
color: u24 = 0xffffff,
writer: TerminalWriter = .{ .context = undefined },
char_scale: u8 = 0,

pub fn init(self: *Terminal) void {
    const max_width_scale = kernel.main_framebuffer.width() / (Font.width * width);
    const max_height_scale = kernel.main_framebuffer.height() / (Font.height * height);

    self.char_scale = @intCast(@min(max_width_scale, max_height_scale));

    self.writer.context = self;
}

fn advanceLine(self: *Terminal) void {
    self.chars.advanceHead();
    var curr = self.chars.get(0);
    for (0..curr.len) |i| {
        curr[i] = ' ';
    }
    self.row = @min(self.row + 1, height - 1);
    self.col = 0;
}

fn putChar(self: *Terminal, char: u8) void {
    self.chars.get(0)[self.col] = char;
    self.col += 1;
    if (self.col == width) {
        self.advanceLine();
    }
}

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

fn drawChar(self: *Terminal, char: u8, x: usize, y: usize) void {
    const char_width = Font.width * self.char_scale;
    const char_height = Font.height * self.char_scale;

    // TODO set blank spaces when drawing the character,
    //      rather than here as it doubles the amount of
    //      time this part takes
    if (char != ' ') {
        Font.fonts[0].drawCharScaled(
            kernel.main_framebuffer,
            char,
            self.color,
            0x00,
            true,
            x * char_width,
            y * char_height,
            self.char_scale,
        );
    } else {
        kernel.main_framebuffer.renderTexture(
            x * char_width,
            y * char_height,
            char_width,
            char_height,
            &[_][]const []const u8{
                &[_][]const u8{&[_]u8{ 0x00, 0x00, 0x00, 0xff }},
            },
        );
    }
}

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

pub fn print(self: *Terminal, comptime str: []const u8, args: anytype) void {
    std.fmt.format(self.writer, str, args) catch unreachable;
    self.refresh();
}
