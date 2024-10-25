const PS2Keyboard = @This();

const std = @import("std");
const arch = @import("kernel.zig").arch;

const Ringbuffer = @import("util.zig").Ringbuffer(Keypress, 200);

buffer: Ringbuffer,
shifted: bool = false,

pub fn nextKeypress(self: *PS2Keyboard) ?Keypress {
    return self.buffer.dequeue();
}

pub fn keyHandler(self: *PS2Keyboard) void {
    const b = arch.assembly.inb(0x60);
    if (b == 0x2A or b == 0x36) {
        self.shifted = true;
        return;
    } else if (b == 0x80 + 0x2A or b == 0x80 + 0x36) {
        self.shifted = false;
        return;
    }
    self.buffer.enqueue(Keypress.fromInb(arch.assembly.inb(0x60), self.shifted)) catch
        @panic("increase size of PS2Keyboard keypress buffer");
}

const Keypress = union(enum) {
    pressed: u8,
    released: u8,
    unsupported: u8,

    fn fromInb(byte: u8, shifted: bool) Keypress {
        if (byte >= 0xE0) {
            return .{ .unsupported = byte };
        }

        if (byte > 0x58) {
            const c = keymap[byte - 0x80] orelse return .{ .unsupported = byte };
            if (shifted) {
                if (shift_map[c]) |c1| {
                    return .{ .released = c1 };
                }
            }
            return .{ .released = c };
        } else {
            const c = keymap[byte] orelse return .{ .unsupported = byte };
            if (shifted) {
                if (shift_map[c]) |c1| {
                    return .{ .pressed = c1 };
                }
            }
            return .{ .pressed = c };
        }
    }
};

const keymap = [_]?u8{
    null,
    0x1B, // escape
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '0',
    '-',
    '=',
    0x08, // backspace
    0x09, // tab
    'q',
    'w',
    'e',
    'r',
    't',
    'y',
    'u',
    'i',
    'o',
    'p',
    '[',
    ']',
    '\n', // TODO enter
    null, // TODO lctrl
    'a',
    's',
    'd',
    'f',
    'g',
    'h',
    'j',
    'k',
    'l',
    ';',
    '\'',
    '`',
    null, // TODO lshift
    '\\',
    'z',
    'x',
    'c',
    'v',
    'b',
    'n',
    'm',
    ',',
    '.',
    '/',
    null, // TODO rshift
    null, // TODO keypad *
    null, // TODO lalt
    ' ',
    null, // TODO capslock
    null, // TODO f1
    null, // TODO f2
    null, // TODO f3
    null, // TODO f4
    null, // TODO f5
    null, // TODO f6
    null, // TODO f7
    null, // TODO f8
    null, // TODO f9
    null, // TODO f10
    null, // TODO numlock
    null, // TODO scroll lock
    null, // TODO keypad 7
    null, // TODO keypad 8
    null, // TODO keypad 9
    null, // TODO keypad -
    null, // TODO keypad 4
    null, // TODO keypad 5
    null, // TODO keypad 6
    null, // TODO keypad +
    null, // TODO keypad 1
    null, // TODO keypad 2
    null, // TODO keypad 3
    null, // TODO keypad .
    null,
    null,
    null,
    null, // TODO f11
    null, // TODO f12
};

const shift_map = blk: {
    var m: [128]?u8 = .{null} ** 128;

    for ('a'..'z' + 1) |c| {
        m[c] = (c - 'a') + 'A';
    }

    m['`'] = '~';
    m['1'] = '!';
    m['2'] = '@';
    m['3'] = '#';
    m['4'] = '$';
    m['5'] = '%';
    m['6'] = '^';
    m['7'] = '&';
    m['8'] = '*';
    m['9'] = '(';
    m['0'] = ')';
    m['-'] = '_';
    m['='] = '+';
    m['['] = '{';
    m[']'] = '}';
    m['\\'] = '|';
    m[';'] = ':';
    m['\''] = '"';
    m[','] = '<';
    m['.'] = '>';
    m['/'] = '?';

    break :blk m;
};
