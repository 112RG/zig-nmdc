const std = @import("std");
const hub_mod = @import("hub.zig");

const default_host = "127.0.0.1";
const default_port: u16 = 4111;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const host = if (args.len > 1) args[1] else default_host;
    const port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else default_port;
    const address = try std.net.Address.parseIp4(host, port);

    var server = try std.net.Address.listen(address, .{ .reuse_address = true, .kernel_backlog = 128 });
    defer server.deinit();

    var hub = hub_mod.Hub{ .allocator = allocator };
    defer hub.deinit();

    std.debug.print("Hub listening on {any}\n", .{address});

    while (true) {
        const connection = try server.accept();
        std.debug.print("Client connected from: {any}\n", .{connection.address});
        hub.startClient(connection.stream, connection.address) catch |err| {
            std.debug.print("Failed to start client session: {}\n", .{err});
            connection.stream.close();
        };
    }
}
