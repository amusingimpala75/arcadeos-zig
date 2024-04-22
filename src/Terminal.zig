const Terminal = @This();

const std = @import("std");

const Font = @import("fonts/Font.zig");
const kernel = @import("kernel.zig");
const Palette = @import("Palette.zig");

const TerminalError = error{};

const width = 80;
const height = 24;

const TerminalRingbuffer = @import("util.zig").Ringbuffer(
    [width]u8,
    height,
    [1]u8{' '} ** width,
);

chars: TerminalRingbuffer = TerminalRingbuffer.init(),
row: u8 = 0,
col: u8 = 0,
palette: *const Palette = Palette.default,
self_ptr: *Terminal = undefined,
writer: std.io.AnyWriter = .{ .context = undefined, .writeFn = &terminalWrite },
char_scale: u8 = 0,

pub fn init(self: *Terminal) void {
    const max_width_scale = kernel.main_framebuffer.width / (Font.width * width);
    const max_height_scale = kernel.main_framebuffer.height / (Font.height * height);

    self.char_scale = @intCast(@min(max_width_scale, max_height_scale));

    self.self_ptr = self;
    self.writer.context = @ptrCast(&self.self_ptr);

    kernel.main_framebuffer.renderTexture(
        0,
        0,
        kernel.main_framebuffer.width,
        kernel.main_framebuffer.height,
        &[_][]const [4]u8{
            &[_][4]u8{self.palette.bg.rgbByteArray()},
        },
    );
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

fn terminalWrite(ctx: *const anyopaque, chars: []const u8) anyerror!usize {
    const self: *Terminal = @as(
        *const *Terminal,
        @alignCast(@ptrCast(ctx)),
    ).*;
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
            self.palette,
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
            &[_][]const [4]u8{
                &[_][4]u8{self.palette.bg.rgbByteArray()},
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
