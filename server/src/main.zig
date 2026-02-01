const std = @import("std");
const lib = @import("server_lib");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // Port 4111 to match the client
    const port: u16 = 4111;

    const loopback = try std.net.Ip4Address.parse("127.0.0.1", port);
    const self_addr = std.net.Address{ .in = loopback };

    // Listen
    var server = try std.net.Address.listen(self_addr, .{ .reuse_address = true, .kernel_backlog = 128 });
    defer server.deinit();

    std.debug.print("Server listening on 127.0.0.1:{d}...\n", .{port});

    while (true) {
        // Accept connection
        const connection = try server.accept();
        std.debug.print("Client connected from: {}\n", .{connection.address});

        // Handle client in a separate function (blocking for now is fine for a test)
        handleClient(allocator, connection.stream) catch |err| {
            std.debug.print("Client error: {}\n", .{err});
        };
    }
}

fn handleClient(allocator: std.mem.Allocator, stream: std.net.Stream) !void {
    _ = allocator;
    defer stream.close();

    // The client expects newline-delimited messages currently.
    // We send | and \n to satisfy protocol and client's readUntilDelimiter.

    // 1. Send $Lock
    // Format: $Lock <LOCK> Pk=<PK>|
    const lock_msg = "$Lock EXTENDEDPROTOCOLABC Pk=ZigNMDC1.0.0|";
    try stream.writer().print("{s}\n", .{lock_msg});
    std.debug.print("Sent: {s}\n", .{lock_msg});

    var buf: [4096]u8 = undefined;

    // 2. Read loop
    while (true) {
        const msg = stream.reader().readUntilDelimiterOrEof(&buf, '\n') catch |err| {
            if (err == error.EndOfStream) {
                return;
            }
            return err;
        };

        if (msg) |line| {
            std.debug.print("Received: {s}\n", .{line});

            if (std.mem.startsWith(u8, line, "$Key")) {
                try stream.writer().print("$Hello ZigUser|\n", .{});
            }
        } else {
            break;
        }
    }
}
