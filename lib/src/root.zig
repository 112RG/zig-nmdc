const std = @import("std");

pub const NMDC = @import("nmdc.zig").NMDC;
pub const logFn = @import("logger.zig").logFn;

test "root exports NMDC" {
    try std.testing.expectEqual(NMDC.CommandType.Hello, NMDC.getCommandType("$Hello nick|"));
}
