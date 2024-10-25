const std = @import("std");

const kernel = @import("../kernel.zig");

pub fn Ringbuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        arr: [capacity]T = .{undefined} ** capacity,
        front: usize = 0, // next space to be filled by enqueue
        back: usize = 0, // next item returned by dequeue
        size: usize = 0,

        const RB = @This();

        pub fn enqueue(self: *RB, val: T) !void {
            if (self.size == self.arr.len) {
                return error.BufferFull;
            }
            self.arr[self.front] = val;
            self.front = (self.front + 1) % capacity;
            self.size += 1;
        }

        pub fn dequeue(self: *RB) ?T {
            if (self.size == 0) {
                return null;
            }
            const ptr: *T = &self.arr[self.back];
            self.back = (self.back + 1) % capacity;
            self.size -= 1;
            return ptr.*;
        }
    };
}
