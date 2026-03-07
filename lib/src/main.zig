pub fn main() !void {
    try std.fs.File.stdout().writeAll("Run `zig build test` to run the tests.\n");
}

const std = @import("std");

test "main compiles" {
    try std.testing.expect(true);
}
