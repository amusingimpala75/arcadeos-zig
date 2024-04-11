const assert = @import("std").debug.assert;

pub const GDT = packed struct {
    null_descriptor: SegmentDescriptor,
    kernel_code: SegmentDescriptor,
    kernel_data: SegmentDescriptor,
    user_code: SegmentDescriptor,
    user_data: SegmentDescriptor,
    tss_lower: SegmentDescriptor,
    tss_upper: SegmentDescriptor,
};

// TODO actually make struct
var tss: [64]u8 = [1]u8{0} ** 64;

var gdt: GDT = .{
    .null_descriptor = SegmentDescriptor.init(0, 0, SegmentDescriptor.Access.initNull(), SegmentDescriptor.Flags.initEmpty()),
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

var gdtr: Descriptor = .{
    .size = @truncate(@sizeOf(GDT) - 1),
    .ptr = undefined,
};

extern fn reload_gdt(limit: u16, base: *const GDT) void;

pub fn initializeGDT() void {
    gdt.tss_lower = SegmentDescriptor.init(
        @sizeOf(@TypeOf(tss)),
        @truncate(@intFromPtr(&tss)),
        SegmentDescriptor.Access.initTSS(),
        SegmentDescriptor.Flags.initEmpty(),
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
const Descriptor = extern struct {
    size: u16 align(1),
    ptr: *const GDT align(1),
};

const SegmentDescriptor = packed struct {
    limit_low: u16,
    base_low: u24,
    access: Access,
    limit_high: u4,
    flags: Flags,
    base_high: u8,

    const CODE_FLAG = 0xA;
    const DATA_FLAG = 0xC;

    const USER_ACCESS = 0xF0;
    const KERNEL_ACCESS = 0x90;
    const CODE_ACCESS = 0x0A;
    const DATA_ACCESS = 0x02;

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

    fn initLongMode(access: Access, flags: Flags) SegmentDescriptor {
        return SegmentDescriptor.init(0xFFFFF, 0, access, flags);
    }

    fn initTSSUpper(base_upper: u32) SegmentDescriptor {
        return .{
            .limit_low = @truncate(base_upper),
            .base_low = @truncate(base_upper >> 16),
            .access = @import("std").mem.zeroes(Access),
            .limit_high = 0,
            .flags = @import("std").mem.zeroes(Flags),
            .base_high = 0,
        };
    }

    const Access = packed struct {
        accessed: u1,
        rw: u1,
        direction_conforming: u1,
        exec: u1,
        not_sys: u1,
        privilege: u2,
        present: u1,

        const Authority = enum { user, kernel };
        const Mode = enum { code, data };

        fn init(auth: Authority, mode: Mode) Access {
            return .{
                .present = 1,
                .privilege = if (auth == .kernel) 0 else 3,
                .not_sys = 1,
                .exec = if (mode == .code) 1 else 0,
                .direction_conforming = 0,
                .rw = 1,
                .accessed = 1,
            };
        }

        fn initNull() Access {
            return .{
                .present = 0,
                .privilege = 0,
                .not_sys = 0,
                .exec = 0,
                .direction_conforming = 0,
                .rw = 0,
                .accessed = 0,
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

    const Flags = packed struct {
        reserved: u1,
        long_code: u1,
        size: u1,
        granularity: u1,

        const Mode = enum { code, data };

        fn init(mode: Mode) Flags {
            return .{
                .granularity = 1, // Page granularity
                .size = if (mode == .code) 0 else 1,
                .long_code = if (mode == .code) 1 else 0,
                .reserved = 0,
            };
        }

        fn initEmpty() Flags {
            return .{
                .granularity = 0,
                .size = 0,
                .long_code = 0,
                .reserved = 0,
            };
        }
    };
};

comptime {
    assert(@sizeOf(SegmentDescriptor.Access) == @sizeOf(u8));
    assert(@sizeOf(SegmentDescriptor.Flags) == @sizeOf(u4));
    assert(@sizeOf(SegmentDescriptor) == @sizeOf(u64));
    assert(@sizeOf(GDT) == @sizeOf(SegmentDescriptor) * 7); //null, kernel code/data, user code/data, tss lower/upper
    assert(@sizeOf(Descriptor) == @sizeOf(usize) + @sizeOf(u16));
    assert(@offsetOf(Descriptor, "ptr") == 2);
}
