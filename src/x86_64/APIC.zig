const std = @import("std");

const paging = @import("paging.zig");

const assembly = @import("assembly.zig");

pub const APIC = extern struct {
    reserved1: [2]RegisterInt,
    id: RWRegister,
    version: RRegister,
    reserved2: [4]RegisterInt,
    task_priority: RWRegister,
    arbitration_policy: RRegister,
    proccessor_priority: RRegister,
    eoi: EOIRegister,
    remote_read: RRegister,
    local_destination: RWRegister,
    destination_format: RWRegister,
    spurious_interrupt_vector: SpuriousInterruptRegister,
    in_service: [8]RRegister,
    trigger_mode: [8]RRegister,
    interrupt_request: [8]RRegister,
    error_status: RRegister,
    reserved3: [6]RegisterInt,
    lvt_corrected_machine_check_interrupt: LocalVectorTableRegister,
    interrupt_command: [2]RWRegister,
    lvt_timer: LocalVectorTableRegister,
    lvt_thermal: LocalVectorTableRegister,
    lvt_performance_monitoring_counter: LocalVectorTableRegister,
    lvt_lint0: LocalVectorTableRegister,
    lvt_lint1: LocalVectorTableRegister,
    lvt_error: LocalVectorTableRegister,
    timer_intial_count: RWRegister,
    timer_current_count: RRegister,
    reserved4: [4]RegisterInt,
    timer_divide_configuration: RWRegister,
    reserved5: RegisterInt,

    pub fn map(vaddr: usize) !*APIC {
        const pml4 = paging.PageTable.pml4Recurse();

        // or can I just assume it's at 0xFEE00000 since I don't move it?
        var eax: u32 = undefined;
        var edx: u32 = undefined;
        const msr: u32 = 0x1b;
        assembly.readmsr(msr, &eax, &edx);
        eax &= 0xfffff000;
        edx &= 0x0f;
        assembly.writemsr(msr, eax | 0x800, edx);
        const paddr = eax | (@as(u64, @intCast(edx)) << 32);

        try pml4.map(vaddr, paddr);
        var self: *APIC = @ptrFromInt(vaddr);
        self.init();
        return self;
    }

    fn init(self: *APIC) void {
        self.lvt_error.mask();
        self.lvt_lint0.mask();
        self.lvt_lint1.mask();
        self.lvt_timer.mask();
        self.lvt_thermal.mask();
        self.lvt_performance_monitoring_counter.mask();
        self.lvt_corrected_machine_check_interrupt.mask();
        self.spurious_interrupt_vector.setVector(0xFF);
        self.spurious_interrupt_vector.enableApic();
    }
};

const RegisterInt = std.meta.Int(.unsigned, 16 * 8);

const RRegister = packed struct(RegisterInt) {
    val: u32,
    padding: u96,

    pub fn read(self: *RRegister) u32 {
        return self.val;
    }
};

const WRegister = packed struct(RegisterInt) {
    val: u32,
    padding: u96,

    pub fn write(self: *WRegister, val: u32) void {
        self.val = val;
    }
};

const RWRegister = packed struct(RegisterInt) {
    val: u32,
    padding: u96,

    pub fn read(self: *RWRegister) u32 {
        return self.val;
    }

    pub fn write(self: *RWRegister, val: u32) void {
        self.val = val;
    }
};

const EOIRegister = packed struct(RegisterInt) {
    reg: WRegister,

    pub fn clear(self: *EOIRegister) void {
        self.reg.write(0);
    }
};

const LocalVectorTableRegister = packed struct(RegisterInt) {
    reg: RWRegister,

    const Backing = packed struct(u32) {
        vector: u8,
        nmi: bool,
        _padding: u2,
        _reserved1: u1,
        pending: bool,
        polarity: Polarity,
        remote_irr: bool,
        trigger_mode: Trigger,
        masked: bool,
        _reserved2: u15,
    };

    pub const Polarity = enum(u1) {
        high_triggered = 0,
        low_triggered = 1,
    };

    pub const Trigger = enum(u1) {
        edge_trigger = 0,
        level_trigger = 1,
    };

    const Self = LocalVectorTableRegister;

    fn getBacking(self: *Self) Backing {
        return @bitCast(self.reg.read());
    }

    fn setBacking(self: *Self, backing: Backing) void {
        self.reg.write(@bitCast(backing));
    }

    pub fn getVector(self: *Self) u8 {
        return self.getBacking().vector;
    }

    pub fn setVector(self: *Self, vector: u8) void {
        var backing = self.getBacking();
        backing.vector = vector;
        self.setBacking(backing);
    }

    pub fn isNMI(self: *Self) bool {
        return self.getBacking().nmi;
    }

    pub fn setNMI(self: *Self, nmi: bool) void {
        var backing = self.getBacking();
        backing.nmi = nmi;
        self.setBacking(backing);
    }

    pub fn isPending(self: *Self) bool {
        return self.getBacking().pending;
    }

    // setPending ?

    pub fn getPolarity(self: *Self) Polarity {
        return self.getBacking().polarity;
    }

    pub fn setPolarity(self: *Self, polarity: Polarity) void {
        var backing = self.getBacking();
        backing.polarity = polarity;
        self.setBacking(backing);
    }

    pub fn isRemoteIRR(self: *Self) bool {
        return self.getBacking().remote_irr;
    }

    // setRemoteIRR ?

    pub fn getTriggerMode(self: *Self) Trigger {
        return self.getBacking().trigger_mode;
    }

    pub fn setTriggerMode(self: *Self, trigger: Trigger) void {
        var backing = self.getBacking();
        backing.trigger_mode = trigger;
        self.setBacking(backing);
    }

    pub fn masked(self: *Self) bool {
        return self.getBacking().masked;
    }

    pub fn mask(self: *Self) void {
        var backing = self.getBacking();
        backing.masked = true;
        self.setBacking(backing);
    }

    pub fn unmask(self: *Self) void {
        var backing = self.getBacking();
        backing.masked = false;
        self.setBacking(backing);
    }
};

const SpuriousInterruptRegister = packed struct(RegisterInt) {
    reg: RWRegister,

    const Backing = packed struct(u32) {
        vector: u8,
        enable_apic: bool,
        _reserved1: u3,
        dont_broadcast_eoi: bool,
        _reserved2: u19,
    };

    const Self = SpuriousInterruptRegister;

    fn getBacking(self: *Self) Backing {
        return @bitCast(self.reg.read());
    }

    fn setBacking(self: *Self, backing: Backing) void {
        self.reg.write(@bitCast(backing));
    }

    pub fn apicEnabled(self: *Self) bool {
        return self.getBacking().enable_apic;
    }

    pub fn enableApic(self: *Self) void {
        var backing = self.getBacking();
        backing.enable_apic = true;
        self.setBacking(backing);
    }

    pub fn disableApic(self: *Self) void {
        var backing = self.getBacking();
        backing.enable_apic = false;
        self.setBacking(backing);
    }

    pub fn eoiBroadcasted(self: *Self) bool {
        return !self.getBacking().dont_broadcast_eoi;
    }

    pub fn dontBroadcastEoi(self: *Self) void {
        var backing = self.getBacking();
        backing.dont_broadcast_eoi = true;
        self.setBacking(backing);
    }

    pub fn doBroadcastEoi(self: *Self) void {
        var backing = self.getBacking();
        backing.dont_broadcast_eoi = false;
        self.setBacking(backing);
    }

    pub fn getVector(self: *Self) u8 {
        return self.getBacking().vector;
    }

    pub fn setVector(self: *Self, vector: u8) void {
        var backing = self.getBacking();
        backing.vector = vector;
        self.setBacking(backing);
    }
};

comptime {
    std.debug.assert(@sizeOf(APIC) == 0x400);
}
