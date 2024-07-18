const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.panic);

const Font = @import("fonts/Font.zig");
const Palette = @import("Palette.zig");
const kernel = @import("kernel.zig");

// TODO base on allocated pages
var addr_map_buffer: [1 << 19]u8 = undefined;
var addr_map_allocator = std.heap.FixedBufferAllocator.init(&addr_map_buffer);

var dwarf_info: std.dwarf.DwarfInfo = .{
    .endian = builtin.cpu.arch.endian(),
    .is_macho = false,
};
var debug_info: std.debug.DebugInfo = undefined;

const SelfParseSource = struct {
    var pos: usize = 0;

    const SeekableStream = std.io.SeekableStream(
        ?void,
        anyerror,
        anyerror,
        seekTo,
        seekBy,
        getPos,
        getEndPos,
    );

    fn seekTo(_: ?void, pos1: u64) anyerror!void {
        pos = pos1;
    }

    fn seekBy(_: ?void, pos1: i64) anyerror!void {
        if (pos1 > 0) {
            pos += @abs(pos1);
        } else {
            pos -= @abs(pos1);
        }
    }

    fn getPos(_: ?void) anyerror!u64 {
        return pos;
    }

    fn getEndPos(_: ?void) anyerror!u64 {
        return kernel.arch.bootloader_info.kernel_elf_len;
    }

    pub fn seekableStream(_: SelfParseSource) SeekableStream {
        return .{ .context = null };
    }

    const Reader = struct {
        pub fn readNoEof(_: Reader, buf: []u8) anyerror!void {
            const address: [*]u8 = @ptrFromInt(kernel.arch.bootloader_info.kernel_elf_pstart + kernel.arch.bootloader_info.hhdm_start);
            @memcpy(buf, address[pos .. pos + buf.len]);
        }
    };

    pub fn reader(_: SelfParseSource) Reader {
        return .{};
    }
};

var initialized: bool = false;

pub fn init() !void {
    const address: [*]u8 = @ptrFromInt(kernel.arch.bootloader_info.kernel_elf_pstart + kernel.arch.bootloader_info.hhdm_start);
    const elf_header = try std.elf.Header.parse(@alignCast(@ptrCast(address)));
    // find strshdr
    const strshdr = blk: {
        var shdr_iterator: std.elf.SectionHeaderIterator(SelfParseSource) = .{
            .elf_header = elf_header,
            .parse_source = .{},
        };
        var idx: u16 = 0;
        while (try shdr_iterator.next()) |shdr| {
            if (idx == elf_header.shstrndx) {
                break :blk shdr;
            }
            idx += 1;
        }
        return error.CorruptedDwarfInfo;
    };

    SelfParseSource.pos = 0;

    var shdr_iterator: std.elf.SectionHeaderIterator(SelfParseSource) = .{
        .elf_header = elf_header,
        .parse_source = .{},
    };

    while (try shdr_iterator.next()) |shdr| {
        const name: []const u8 = blk: {
            const cstr: [*c]const u8 = @ptrCast(address[strshdr.sh_offset + shdr.sh_name ..]);
            var len: u16 = 0;
            while (cstr[len] != 0) : (len += 1) {}
            break :blk cstr[0..len];
        };
        const section: std.dwarf.DwarfInfo.Section = .{
            .data = address[shdr.sh_offset .. shdr.sh_offset + shdr.sh_size],
            .virtual_address = @intFromPtr(address[shdr.sh_offset..]),
            .owned = false,
        };
        const section_type: ?std.dwarf.DwarfSection = if (std.mem.eql(u8, name, ".debug_loc"))
            .debug_loclists
        else if (std.mem.eql(u8, name, ".debug_abbrev"))
            .debug_abbrev
        else if (std.mem.eql(u8, name, ".debug_info"))
            .debug_info
        else if (std.mem.eql(u8, name, ".debug_ranges"))
            .debug_ranges
        else if (std.mem.eql(u8, name, ".debug_str"))
            .debug_str
        else if (std.mem.eql(u8, name, ".debug_pubnames"))
            .debug_names
        else if (std.mem.eql(u8, name, ".debug_frame"))
            .debug_frame
        else if (std.mem.eql(u8, name, ".debug_line"))
            .debug_line
        else
            null;
        if (section_type) |t| {
            dwarf_info.sections[@intFromEnum(t)] = section;
        }
    }

    try std.dwarf.openDwarfDebugInfo(&dwarf_info, addr_map_allocator.allocator());

    debug_info = try std.debug.DebugInfo.init(addr_map_allocator.allocator());
    try debug_info.address_map.putNoClobber(@intFromPtr(address), &dwarf_info);

    initialized = true;
}

const LogErrOutStream = struct {
    pub fn print(comptime fmt: []const u8, args: anytype) anyerror!void {
        log.err(fmt, args);
    }

    pub fn writeAll(comptime str: []const u8) anyerror!void {
        log.err(str, .{});
    }
};

// TODO prettify with dwarf info
//      waiting on ziglang/zig#7962
fn dumpStacktrace(return_addr: u64) void {
    var iterator = std.debug.StackIterator.init(return_addr, null);
    defer iterator.deinit();

    while (iterator.next()) |addr| {
        const err: anyerror = if (initialized) blk: {
            const comp_unit = dwarf_info.findCompileUnit(
                addr,
            ) catch |err| break :blk err;

            const line_info = dwarf_info.getLineNumberInfo(
                addr_map_allocator.allocator(),
                comp_unit.*,
                addr,
            ) catch |err| break :blk err;
            defer line_info.deinit(addr_map_allocator.allocator());

            log.err("in {s} at {}:{}", .{
                line_info.file_name,
                line_info.line,
                line_info.column,
            });
            continue;
        } else error.Uninitialized;
        log.err("at {X} (could not read because {})", .{ addr, err });
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
    kernel.arch.assembly.disableInterrupts();
    while (true) {
        kernel.arch.assembly.halt();
    }
}
