const limine = @import("limine");

const Framebuffer = @This();

//fb: *limine.Framebuffer,
_width: u64,
_height: u64,
pitch: u64,
bpp: u16,
addr: []u8,
clear_color: [4]u8,

export var fb_request: limine.FramebufferRequest = .{};

pub fn init(index: u64) ?Framebuffer {
    if (fb_request.response) |resp| {
        if (resp.framebuffer_count > index) {
            const fb: *limine.Framebuffer = resp.framebuffers()[index];

            return .{
                ._width = fb.width,
                ._height = fb.height,
                .pitch = fb.pitch,
                .bpp = fb.bpp,
                .addr = fb.address[0 .. fb.pitch * fb.height],
                .clear_color = [4]u8{ 0, 0, 0, 0xff },
            };
        }
    }
    return null;
}

pub fn width(self: Framebuffer) u64 {
    return self._width;
}

pub fn height(self: Framebuffer) u64 {
    return self._height;
}

pub fn setPixel(self: Framebuffer, x: u64, y: u64, r: u8, g: u8, b: u8) void {
    const offset = self.pitch * y + self.bpp / 8 * x;
    const pixel = self.addr[offset..];
    pixel[2] = r;
    pixel[1] = g;
    pixel[0] = b;
}

fn setPixelUnsafe(self: Framebuffer, x: u64, y: u64, r: u8, g: u8, b: u8) void {
    @setRuntimeSafety(false);
    const offset = self.pitch * y + self.bpp / 8 * x;
    const pixel = self.addr[offset..];
    pixel[2] = r;
    pixel[1] = g;
    pixel[0] = b;
}

pub fn clear(self: Framebuffer) void {
    for (0..self.height) |y| {
        for (0..self.height) |x| {
            self.setPixelUnsafe(x, y, self.clear_color.r, self.clear_color.g, self.clear_color.b);
        }
    }
}

pub fn setClearColor(self: *Framebuffer, col: [4]u8) void {
    self.clear_color = col;
}

pub fn renderTexture(self: Framebuffer, x: u64, y: u64, w: u64, h: u64, texture: []const []const [4]u8) void {
    for (y..@min(y + h, self._height)) |hi| {
        for (x..@min(x + w, self._width)) |wi| {
            @setRuntimeSafety(false);
            const color = blk: {
                const row_index: u64 = @divTrunc((hi - y) * (texture.len), h);
                const row = texture[@min(row_index, texture.len - 1)];
                const pixel_index: u64 = @divTrunc((wi - x) * (row.len), w);
                const pixel = row[@min(pixel_index, row.len - 1)];
                break :blk pixel;
            };
            // TODO: middle-ground transparency
            if (color[3] != 0x00) {
                self.setPixelUnsafe(wi, hi, color[0], color[1], color[2]);
            }
        }
    }
}

fn framebufferCount() u64 {
    if (fb_request.respose) |resp| {
        return resp.framebuffer_count;
    }
    return 0;
}
