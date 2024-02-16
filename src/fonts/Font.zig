const Framebuffer = @import("../Framebuffer.zig");
const config = @import("config");

bytes: []const u8,
name: []const u8,

pub const width = 8;
pub const height = 16;

const Font = @This();

pub const fonts = importFonts();

fn importFonts() []const Font {
    comptime {
        return &[1]Font{.{
            .name = config.font_name,
            .bytes = @embedFile("vga-text-mode-fonts/FONTS/" ++ config.font_name),
        }};
    }
}

fn charBitmap(self: *const Font, char: u8) []const u8 {
    const start_index: usize = @as(usize, @intCast(char)) * (8 / width) * height;
    const end_index: usize = start_index + (8 / width) * height;
    return self.bytes[start_index..end_index];
}

pub fn drawCharScaled(self: *const Font, framebuffer: Framebuffer, char: u8, fg: u32, bg: u32, bga: bool, x: usize, y: usize, scale: usize) void {
    const bitmap = self.charBitmap(char);

    const r: u8 = @intCast((fg >> 16) & 0xff);
    const g: u8 = @intCast((fg >> 8) & 0xff);
    const b: u8 = @intCast((fg >> 0) & 0xff);

    const bgr: u8 = @intCast((bg >> 16) & 0xff);
    const bgg: u8 = @intCast((bg >> 8) & 0xff);
    const bgb: u8 = @intCast((bg >> 0) & 0xff);

    for (bitmap, 0..height) |row, rowi| {
        for (0..width) |col| {
            if (row & (@as(u8, 0b10000000) >> @as(u3, @intCast(col))) != 0) {
                for (0..scale) |iy| {
                    for (0..scale) |ix| {
                        framebuffer.setPixel(x + col * scale + ix, y + rowi * scale + iy, r, g, b);
                    }
                }
            } else {
                if (bga) {
                    for (0..scale) |iy| {
                        for (0..scale) |ix| {
                            framebuffer.setPixel(x + col * scale + ix, y + rowi * scale + iy, bgr, bgg, bgb);
                        }
                    }
                }
            }
        }
    }
}

pub fn drawChar(self: *const Font, framebuffer: Framebuffer, char: u8, fg: u32, x: usize, y: usize) void {
    self.drawCharScaled(framebuffer, char, fg, x, y, 1);
}
