const std = @import("std");

const default_host = "10.0.1.141";
const default_port: u16 = 411;
const default_nick = "TestBot";

pub const Config = struct {
    host: []const u8,
    port: u16,
    nick: []const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.nick);
    }
};

pub fn parseConfig(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    return .{
        .host = try allocator.dupe(u8, if (args.len > 1) args[1] else default_host),
        .port = if (args.len > 2)
            try std.fmt.parseInt(u16, args[2], 10)
        else
            default_port,
        .nick = try allocator.dupe(u8, if (args.len > 3) args[3] else default_nick),
    };
}
