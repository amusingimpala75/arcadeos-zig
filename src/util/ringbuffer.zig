const std = @import("std");

const kernel = @import("../kernel.zig");

pub fn Ringbuffer(comptime T: type, comptime capacity: usize, comptime empty: T) type {
    return struct {
        arr: [capacity]T,
        head: usize,

        pub fn init() @This() {
            return .{
                .arr = [1]T{empty} ** capacity,
                .head = 0,
            };
        }

        pub fn len(self: @This()) usize {
            return self.arr.len;
        }

        pub fn advanceHead(self: *@This()) void {
            self.head = (self.head + 1) % self.arr.len;
        }

        pub fn get(self: *@This(), index: usize) *T {
            const actual_index = ((self.head + self.arr.len) - index) % self.arr.len;
            return &self.arr[actual_index];
        }
    };
}
