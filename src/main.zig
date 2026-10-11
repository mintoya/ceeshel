const std = @import("std");
const Io = std.Io;

const ceeshel = @import("ceeshel");

pub fn println(comptime fmt: []const u8, args: anytype) void {
    return std.debug.print(fmt ++ "\n", args);
}
pub fn main(init: std.process.Init) !void {
    {
        var args = init.minimal.args.iterate();
        while (args.next()) |arg|
            println("{s}", .{arg});
    }

    println("hello world", .{});
}
