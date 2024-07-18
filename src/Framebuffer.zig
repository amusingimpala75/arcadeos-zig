//! Framebuffer.zig contains the data and functions for
//! controlling the user-visible framebuffer associated
//! with the visible screens.

const Framebuffer = @This();

const std = @import("std");

const log = std.log.scoped(.framebuffer);

const Palette = @import("Palette.zig");
const kernel = @import("kernel.zig");
const paging = @import("paging.zig");

/// Width of the framebuffer. Should not be modified after initialization
width: u64,
/// Height of the framebuffer. Should not be modified after initialization
height: u64,
/// Bytes per row of pixels
pitch: u64,
/// bits per byte
bpp: u16,
/// start of the framebuffer. the length is pitch * height
addr: []u8,
/// the color to be used with clear(), for clearing the screen
clear_color: [4]u8,

/// Creates a framebuffer at a given `index` into the list
/// provided from the bootloader. This also registers the framebuffer
/// to be mapped just as it was when the paging is enabled.
///
/// The framebuffer used Palette.default.bg as the default clear color
///
/// Returns null if there is no framebuffer at the given index.
pub fn init(index: u3) ?Framebuffer {
    if (kernel.arch.bootloader_info.framebuffers[index]) |fb| {
        const vaddr = @intFromPtr(fb.pixels.ptr);
        // The framebuffer is always mapped
        const paddr = paging.resolve(vaddr) catch unreachable;
        // Just map the frame buffer to where it already is
        paging.addInitialMapping(.{
            .virtual_addr = vaddr,
            .physical_addr = paddr,
            .len = fb.pixels.len,
            .access = .kernel_rw,
        });

        return .{
            .width = fb.width,
            .height = fb.height,
            .pitch = fb.pitch,
            .bpp = fb.bpp,
            .addr = fb.pixels,
            .clear_color = Palette.default.bg.rgbByteArray(),
        };
    } else return null;
}

/// byte offset of pixel at `x` by `y` pixels.
/// if x or y are out of bounds, this will yeild faulty results
inline fn offset(self: Framebuffer, x: u64, y: u64) u64 {
    return self.pitch * y + (self.bpp / 8) * x;
}

/// set the pixel at (`x`, `y`) to be `col`
///
/// `x` and `y` should be within bounds of the array, or else this will crash
/// `col` should be RGBA format
pub fn setPixel(self: *const Framebuffer, x: u64, y: u64, col: [4]u8) void {
    // offset into byte array
    const off = self.offset(x, y);
    // pixel at offset
    const pixel = self.addr[off..];
    pixel[2] = col[0];
    pixel[1] = col[1];
    pixel[0] = col[2];
}

/// literally just `setPixel` but with runtime safety disabled to (hopefully?)
/// improve performance
fn setPixelUnsafe(self: *const Framebuffer, x: u64, y: u64, col: [4]u8) void {
    @setRuntimeSafety(false);
    // offset into byte array
    const off = self.offset(x, y);
    // pixel at offset
    const pixel = self.addr[off..];
    pixel[2] = col[0];
    pixel[1] = col[1];
    pixel[0] = col[2];
}

/// clears the screen with the color of the clear color
pub fn clear(self: *const Framebuffer) void {
    for (0..self.height) |y| {
        for (0..self.width) |x| {
            self.setPixelUnsafe(x, y, self.clear_color);
        }
    }
}

/// Renders a texture onto the screen
///
/// parts of the image off screen are clipped
/// texture's image data should be in RGBA format
pub fn renderTexture(self: *const Framebuffer, x: u64, y: u64, w: u64, h: u64, texture: []const []const [4]u8) void {
    @setRuntimeSafety(false);
    // loop over the request rows, clamped to the screen's height
    for (y..@min(y + h, self.height)) |hi| {
        const row = texture[
            // height offset of pixel's row, clamped to within texture bounds
            @min(@divTrunc((hi - y) * texture.len, h), texture.len - 1)
        ];
        // loop over pixels of the row, clamped to the row's screen width
        for (x..@min(x + w, self.width)) |wi| {
            const color = row[
                // width offset of the pixel's column, clamped to within the texture's row's bounds
                @min(@divTrunc((wi - x) * row.len, w), row.len - 1)
            ];
            // TODO: middle-ground transparency
            if (color[3] != 0x00) {
                self.setPixelUnsafe(wi, hi, color);
            }
        }
    }
}
