const Framebuffer = @import("../Framebuffer.zig");
const Palette = @import("../Palette.zig");
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

pub fn drawCharScaled(self: *const Font, framebuffer: Framebuffer, char: u8, palette: *const Palette, x: usize, y: usize, scale: usize) void {
    const bitmap = self.charBitmap(char);

    for (bitmap, 0..height) |row, rowi| {
        for (0..width) |col| {
            if (row & (@as(u8, 0b10000000) >> @as(u3, @intCast(col))) != 0) {
                for (0..scale) |iy| {
                    for (0..scale) |ix| {
                        framebuffer.setPixel(x + col * scale + ix, y + rowi * scale + iy, palette.fg_bright.r, palette.fg_bright.g, palette.fg_bright.b);
                    }
                }
            } else {
                if (palette.bg.a != 0xff) {
                    for (0..scale) |iy| {
                        for (0..scale) |ix| {
                            framebuffer.setPixel(x + col * scale + ix, y + rowi * scale + iy, palette.bg.r, palette.bg.g, palette.bg.b);
                        }
                    }
                }
            }
        }
    }
}

pub fn drawChar(self: *const Font, framebuffer: Framebuffer, char: u8, palette: *const Palette, x: usize, y: usize) void {
    self.drawCharScaled(framebuffer, char, palette, x, y, 1);
}
