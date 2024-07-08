const assembly = @import("assembly.zig");

const pic1_command = 0x20;
const pic1_data = 0x21;

const pic2_command = 0xA0;
const pic2_data = 0xA1;

pub fn setupAndDisable() void {
    const master_vec = 32;
    const slave_vec = 40;

    const icw1_init = 0x10;

    assembly.outb(pic1_command, icw1_init);
    wait();
    assembly.outb(pic2_command, icw1_init);
    wait();
    assembly.outb(pic1_data, master_vec);
    wait();
    assembly.outb(pic2_data, slave_vec);
    wait();
    // Not sure if these numbers are necessary since
    // we are permanently disabling the chip, but
    // this is what OSDEV used
    assembly.outb(pic1_data, 4);
    wait();
    assembly.outb(pic2_data, 2);
    wait();

    assembly.outb(pic1_data, 0xff);
    assembly.outb(pic2_data, 0xff);
}

fn wait() void {
    // Write to some random port just to burn a few microseconds
    assembly.outb(0x80, 0);
}
