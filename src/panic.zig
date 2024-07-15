const std = @import("std");

const log = std.log.scoped(.panic);

const Font = @import("fonts/Font.zig");
const Palette = @import("Palette.zig");
const kernel = @import("kernel.zig");

// TODO prettify with dwarf info
//      waiting on ziglang/zig#7962
fn dumpStacktrace(return_addr: u64) void {
    var iterator = std.debug.StackIterator.init(return_addr, null);
    defer iterator.deinit();

    while (iterator.next()) |addr| {
        log.err("at {X}", .{addr});
    }
}

/// This method relies on three things to be in a sane state:
///   1. The framebuffer |
///   2. The serial port | Both of which requires the code data from std
///   3. The main Font (independent)
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, return_addr: ?usize) noreturn {
    // In case of really bad failure, at least print something to serial port
    log.err("{s}", .{msg});
    dumpStacktrace(return_addr orelse @returnAddress());
    // Get color palette
    const palette = Palette.default;
    // Draw error message background
    kernel.main_framebuffer.renderTexture(0, 0, kernel.main_framebuffer.width, kernel.main_framebuffer.height, &[_][]const [4]u8{
        &[_][4]u8{ palette.red.rgbByteArray(), palette.green.rgbByteArray(), palette.blue.rgbByteArray() },
        &[_][4]u8{ palette.yellow.rgbByteArray(), palette.aqua.rgbByteArray(), palette.purple.rgbByteArray() },
        &[_][4]u8{ palette.fg_bright.rgbByteArray(), palette.aqua.rgbByteArray(), palette.bg.rgbByteArray() },
    });

    // start 100px 100px away from top left corner
    const msg_rect_x = 100;
    const msg_rect_y = 100;

    // go to 100px 100px away from bottom right corner
    const msg_rect_width = kernel.main_framebuffer.width - msg_rect_x * 2;
    const msg_rect_height = kernel.main_framebuffer.height - msg_rect_y * 2;

    // render text box background
    kernel.main_framebuffer.renderTexture(msg_rect_x, msg_rect_y, msg_rect_width, msg_rect_height, &[_][]const [4]u8{
        &[_][4]u8{palette.blue_bright.rgbByteArray()},
    });

    // grab main font, scale by 4x for header font
    const font = &Font.fonts[0];
    const title_scale = 4;
    const title_char_width = Font.width * title_scale;
    const title_char_height = Font.height * title_scale;

    // start 50px 50px from top left of text box
    const title_x = 150;
    const title_y = 150;

    // Print header
    for ("A critical error has occured!", 0..) |c, i| {
        font.drawCharScaled(
            kernel.main_framebuffer,
            c,
            palette,
            false,
            title_x + i * title_char_width,
            title_y,
            title_scale,
        );
    }

    // Start message just below header, scale one of font
    const msg_x = 200;
    const msg_y = title_y + title_char_height * 2;
    const msg_wrap_x = kernel.main_framebuffer.width - msg_x;
    const msg_scale = 1;
    const msg_char_width = Font.width * msg_scale;
    const msg_char_height = Font.height * msg_scale;

    var x: usize = 0;
    var y: usize = 0;
    for (msg) |c| {
        // We even have to handle newlines.
        // Just set it to the position of wrapping
        // so that the code below handles the reset
        if (c == '\n') {
            x = msg_wrap_x;
        } else {
            font.drawCharScaled(
                kernel.main_framebuffer,
                c,
                palette,
                false,
                msg_x + x,
                msg_y + y,
                msg_scale,
            );
        }
        x += msg_char_width;
        // if past the boundary point,
        // go to next line
        if (msg_x + x > msg_wrap_x) {
            x = 0;
            y += msg_char_height;
        }
    }

    // Disable all interrupts and halt the CPU
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
