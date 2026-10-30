const std = @import("std");
pub fn SgList(T: type, comptime starting_shift: u7, comptime ending_shift: u7) type {
    return struct {
        const Self = @This();

        pub const empty: Self = .{};

        len: usize = 0,
        arrays: [ending_shift - starting_shift]?[*]T = @splat(null),

        fn idx1(i: usize) usize {
            return std.math.log2_int(usize, i + (1 << starting_shift)) - starting_shift;
        }

        fn sectionLen(section: usize) usize {
            return @as(usize, 1) << @intCast(section + starting_shift);
        }

        fn idx2(i: usize) usize {
            return i - (sectionLen(idx1(i)) - (1 << starting_shift));
        }

        pub fn get(self: *Self, index: usize) *T {
            std.debug.assert(index < self.len);
            return &self.arrays[idx1(index)].?[idx2(index)];
        }

        pub fn getConst(self: *const Self, index: usize) *const T {
            std.debug.assert(index < self.len);
            return &self.arrays[idx1(index)].?[idx2(index)];
        }
        pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            try self.push(allocator, value);
        }
        pub fn push(self: *Self, allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!void {
            if (self.len > std.math.maxInt(usize) - (1 << starting_shift)) return error.OutOfMemory;
            const section = idx1(self.len);
            if (section >= self.arrays.len or section + starting_shift >= @bitSizeOf(usize))
                return error.OutOfMemory;
            if (self.arrays[section] == null) {
                const items = try allocator.alloc(T, sectionLen(section));
                self.arrays[section] = items.ptr;
            }
            self.arrays[section].?[idx2(self.len)] = value;
            self.len += 1;
        }
        pub fn appendNTimes(self: *Self, allocator: std.mem.Allocator, it: T, N: usize) !void {
            for (0..N) |_| try self.push(allocator, it);
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.arrays, 0..) |*array, section| {
                const ptr = array.* orelse break;
                allocator.free(ptr[0..sectionLen(section)]);
                array.* = null;
            }
            self.len = 0;
        }
    };
}
