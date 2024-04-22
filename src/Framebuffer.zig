const limine = @import("limine");

const Framebuffer = @This();

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
/// the color to be used with clear(). set using setClearColor()
clear_color: [4]u8,

export var fb_request: limine.FramebufferRequest = .{};

/// Creates a framebuffer at a given `index` into the list
/// provided from the bootloader. If there is not a framebuffer
/// at the requested index, `null` is returned
pub fn init(index: u64) ?Framebuffer {
    if (fb_request.response) |resp| {
        if (resp.framebuffer_count > index) {
            const fb: *limine.Framebuffer = resp.framebuffers()[index];

            return .{
                .width = fb.width,
                .height = fb.height,
                .pitch = fb.pitch,
                .bpp = fb.bpp,
                .addr = fb.address[0 .. fb.pitch * fb.height],
                .clear_color = [4]u8{ 0, 0, 0, 0xff },
            };
        }
    }
    return null;
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
pub fn setPixel(self: Framebuffer, x: u64, y: u64, col: [4]u8) void {
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
fn setPixelUnsafe(self: Framebuffer, x: u64, y: u64, col: [4]u8) void {
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
pub fn clear(self: Framebuffer) void {
    for (0..self.height) |y| {
        for (0..self.width) |x| {
            self.setPixelUnsafe(x, y, self.clear_color);
        }
    }
}

/// set the clear color to be `col`
// TODO should the be removed instead just use
// framebuffer.clear_color = color
// instead? reduces the amount of function calls necessary,
// and no privacy is provided through the current method anyways
pub fn setClearColor(self: *Framebuffer, col: [4]u8) void {
    self.clear_color = col;
}

/// Renders a texture onto the screen
///
/// parts of the image off screen are clipped
/// texture's image data should be in RGBA format
pub fn renderTexture(self: Framebuffer, x: u64, y: u64, w: u64, h: u64, texture: []const []const [4]u8) void {
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
