const std = @import("std");

const assembly = @import("assembly.zig");

/// GDT structure, used for controlling segment information
/// On x86-64, it means very little and can be stubbed out
/// with generic information in all of the entries
///
/// Because this needs to be a packed struct, we cannot make
/// the root declaration
pub const GDT = extern struct {
    null_descriptor: SegmentDescriptor,
    kernel_code: SegmentDescriptor,
    kernel_data: SegmentDescriptor,
    user_code: SegmentDescriptor,
    user_data: SegmentDescriptor,
    tss_lower: SegmentDescriptor,
    tss_upper: SegmentDescriptor,
};

/// Field / byte offset of the 'kernel_data' segment in the GDT
pub const kernel_data_offset: u16 = @truncate(@offsetOf(GDT, "kernel_data"));
/// Field / byte offset of the 'kernel_code' segment in the GDT
pub const kernel_code_offset: u16 = @truncate(@offsetOf(GDT, "kernel_code"));

// TODO actually make struct
var tss: [64]u8 = [1]u8{0} ** 64;

/// The actual GDT that the kernel uses. Needs to be
var gdt: GDT = .{
    .null_descriptor = SegmentDescriptor.init(0, 0, std.mem.zeroes(SegmentDescriptor.Access), std.mem.zeroes(SegmentDescriptor.Flags)),
    .kernel_code = SegmentDescriptor.initLongMode(
        SegmentDescriptor.Access.init(.kernel, .code),
        SegmentDescriptor.Flags.init(.code),
    ),
    .kernel_data = SegmentDescriptor.initLongMode(
        SegmentDescriptor.Access.init(.kernel, .data),
        SegmentDescriptor.Flags.init(.data),
    ),
    .user_code = SegmentDescriptor.initLongMode(
        SegmentDescriptor.Access.init(.user, .code),
        SegmentDescriptor.Flags.init(.code),
    ),
    .user_data = SegmentDescriptor.initLongMode(
        SegmentDescriptor.Access.init(.user, .data),
        SegmentDescriptor.Flags.init(.data),
    ),
    .tss_lower = undefined,
    .tss_upper = undefined,
};

/// GDTR - fancy pointer to the GDT
var gdtr: Descriptor = .{
    .size = @truncate(@sizeOf(GDT) - 1),
    .ptr = undefined,
};

/// Set up of the GDT
///
/// This consists of fixing the GDT's tss pointers,
/// as well as the GDTR's GDT pointer.
/// Then the GDTR is loaded, and all of the segments reloaded
pub fn initializeGDT() void {
    gdt.tss_lower = SegmentDescriptor.init(
        @sizeOf(@TypeOf(tss)),
        @truncate(@intFromPtr(&tss)),
        SegmentDescriptor.Access.initTSS(),
        std.mem.zeroes(SegmentDescriptor.Flags),
    );
    gdt.tss_upper = SegmentDescriptor.initTSSUpper(@intCast(@intFromPtr(&tss) >> 32));
    gdtr.ptr = &gdt;

    // Load GDTR
    assembly.loadGDTR(&gdtr);

    // Reload non-CS segments
    inline for ([_][]const u8{ "ds", "es", "fs", "gs", "ss" }) |reg| {
        assembly.loadSegmentRegister(reg, kernel_data_offset);
    }

    // Reload CS
    assembly.loadCodeSegmentRegister(kernel_code_offset);
}

// Packed struct still pads size to more than 16 bits
/// GDTR data structure
///
/// For whatever reason,
/// sizeof(packed struct) >= sizeof(extern struct),
/// and since we need the literl smalled size to
/// fit spec, we use extern struct
const Descriptor = extern struct {
    size: u16 align(1),
    ptr: *const GDT align(1),
};

/// Describes an individual segment
///
/// In Long mode (x86-64), base and limit are ignored, and paging
/// is the preferred method of protecting memory. As such, the
/// segment are fairly basic.
const SegmentDescriptor = packed struct {
    /// Together with `limit_high` describes how long the segment is
    limit_low: u16,
    /// Together with `base_high` describes the location of the segment
    base_low: u24,
    ///  who can access segment how
    access: Access,
    /// Together with `limit_low` describes how long the segment is
    limit_high: u4,
    /// Describes segment layout
    flags: Flags,
    /// Together with `base_low` describes the location of the segment
    base_high: u8,

    /// Creats a `SegmentDescriptor`, properly splitting the `limit` and the `base`
    fn init(limit: u20, base: u32, access: Access, flags: Flags) SegmentDescriptor {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .access = access,
            .limit_high = @truncate(limit >> 16),
            .flags = flags,
            .base_high = @truncate(base >> 24),
        };
    }

    /// Create a `SegmentDescriptor` for long mode - this results in the lowest
    /// base and highest limit
    fn initLongMode(access: Access, flags: Flags) SegmentDescriptor {
        return SegmentDescriptor.init(0xFFFFF, 0, access, flags);
    }

    /// Creates a `SegmentDescriptor` for the upper half of the TSS
    /// This must immediately follow any lower half of a TSS, and only
    /// that type of segment
    fn initTSSUpper(base_upper: u32) SegmentDescriptor {
        return .{
            .limit_low = @truncate(base_upper),
            .base_low = @truncate(base_upper >> 16),
            .access = std.mem.zeroes(Access),
            .limit_high = 0,
            .flags = std.mem.zeroes(Flags),
            .base_high = 0,
        };
    }

    /// Permission levels for segments
    const Authority = enum { user, kernel };
    /// Segment type
    const Mode = enum { code, data };

    /// Type to store information about access control for the segment
    const Access = packed struct {
        /// Set by cpu
        accessed: u1 = 0,
        /// Different depnding on the mode
        /// - for code, 1 = readable
        /// - for data, 1 = writable
        rw: u1,
        /// Different depending on mode
        /// - for data, 1 = grows down
        /// - for code, 0 = no inter-privelege jumps (1 = lower privelege can jump to higher privelege)
        direction_conforming: u1,
        /// executablity. ie code = 1, data = 0
        exec: u1,
        /// 0 = is TSS
        not_sys: u1,
        /// which perm levels. 0 = kernel, 3 = user
        privilege: u2,
        /// must be 1 to be valid
        present: u1,

        /// Create a Access mode with given permissions and type
        fn init(auth: Authority, mode: Mode) Access {
            return .{
                .present = 1,
                .privilege = if (auth == .kernel) 0 else 3,
                .not_sys = 1,
                .exec = if (mode == .code) 1 else 0,
                .direction_conforming = 0,
                .rw = 1,
            };
        }

        // exec=1 and accessed=1 means the lower 4bits = 9=64TSS Available
        fn initTSS() Access {
            return .{
                .present = 1,
                .privilege = 0,
                .not_sys = 0,
                .exec = 1,
                .direction_conforming = 0,
                .rw = 0,
                .accessed = 1,
            };
        }
    };

    /// Describes the layout of the segment
    const Flags = packed struct {
        /// DO NOT SET
        reserved: u1 = 0,
        /// Only to be added with code mode
        /// indicates that the segment is 64 bit,
        /// and which is always the case for 64-bit code
        long_code: u1,
        /// 0 = 16-bit, 1 = 32-bit
        size: u1,
        /// 0 = byte granularity, 1 = page granularity
        granularity: u1,

        /// Create a `Flags` given a mode
        /// code gets:
        /// - page granularity,
        /// - long code
        /// - 16-bit size (ignored b/c long code ?)
        fn init(mode: Mode) Flags {
            return .{
                .granularity = 1, // Page granularity
                .size = if (mode == .code) 0 else 1,
                .long_code = if (mode == .code) 1 else 0, //  data segments cannot have long_code set
            };
        }
    };
};

// various size tests. I've shot myself in the foot a few too many times previously
comptime {
    std.debug.assert(@sizeOf(SegmentDescriptor.Access) == @sizeOf(u8));
    std.debug.assert(@sizeOf(SegmentDescriptor.Flags) == @sizeOf(u4));
    std.debug.assert(@sizeOf(SegmentDescriptor) == @sizeOf(u64));
    std.debug.assert(@sizeOf(GDT) == @sizeOf(SegmentDescriptor) * 7); //null, kernel code/data, user code/data, tss lower/upper
    std.debug.assert(@sizeOf(Descriptor) == @sizeOf(usize) + @sizeOf(u16));
    std.debug.assert(@offsetOf(Descriptor, "ptr") == 2);
}
