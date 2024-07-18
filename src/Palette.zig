//! Palette.zig contains basic data structures to
//! describe a visual theme of the system, as well
//! as keeping track of the selected palette.

const Palette = @This();

/// The default palette, which is gruvbox
pub const default: *const Palette = &gruvbox;

const gruvbox: Palette = .{
    .bg = Color.fromRGB(0x282828),
    .red = Color.fromRGB(0xcc241d),
    .green = Color.fromRGB(0x98971a),
    .yellow = Color.fromRGB(0xd79921),
    .blue = Color.fromRGB(0x458588),
    .purple = Color.fromRGB(0xb16286),
    .aqua = Color.fromRGB(0x689d6a),
    .fg = Color.fromRGB(0xa89984),

    .bg_bright = Color.fromRGB(0x928374),
    .red_bright = Color.fromRGB(0xfb4934),
    .green_bright = Color.fromRGB(0xb8bb26),
    .yellow_bright = Color.fromRGB(0xfabd2f),
    .blue_bright = Color.fromRGB(0x83a598),
    .purple_bright = Color.fromRGB(0xd3869b),
    .aqua_bright = Color.fromRGB(0x8ec07c),
    .fg_bright = Color.fromRGB(0xebdbb2),
};

/// A color represented as the individual components,
pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    /// create an opaque color `rgb` assuming `rgb` is
    /// is inn the RGB format
    pub fn fromRGB(rgb: u24) Color {
        return .{
            .r = rgb >> 16 & 0xFF,
            .g = rgb >> 8 & 0xFF,
            .b = rgb >> 0 & 0xFF,
        };
    }

    /// Convert the color into a 4-byte array
    /// in the RGBA format
    pub fn rgbByteArray(self: Color) [4]u8 {
        return [4]u8{ self.r, self.g, self.b, self.a };
    }
};

bg: Color,
fg: Color,
red: Color,
green: Color,
yellow: Color,
aqua: Color,
blue: Color,
purple: Color,

bg_bright: Color,
fg_bright: Color,
red_bright: Color,
green_bright: Color,
yellow_bright: Color,
aqua_bright: Color,
blue_bright: Color,
purple_bright: Color,
