const std = @import("std");
const lib = @import("server_lib");
const nmdc = @import("nmdc").NMDC;

pub fn main() !void {
    _ = lib;
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
        std.debug.print("Client connected from: {any}\n", .{connection.address});

        // Handle client in a separate function (blocking for now is fine for a test)
        handleClient(allocator, connection.stream) catch |err| {
            std.debug.print("Client error: {}\n", .{err});
        };
    }
}

fn handleClient(allocator: std.mem.Allocator, stream: std.net.Stream) !void {
    var read_buffer = nmdc.MessageBuffer{};
    defer read_buffer.deinit(allocator);
    defer stream.close();

    // 1. Send $Lock
    // Format: $Lock <LOCK> Pk=<PK>|
    const lock_msg = "$Lock EXTENDEDPROTOCOLABC Pk=ZigNMDC1.0.0|";
    try stream.writeAll(lock_msg);
    std.debug.print("Sent: {s}\n", .{lock_msg});

    var buf: [4096]u8 = undefined;

    // 2. Read loop
    while (true) {
        const bytes_read = try stream.read(buf[0..]);
        if (bytes_read == 0) return;

        try read_buffer.append(allocator, buf[0..bytes_read]);

        while (read_buffer.next()) |line| {
            if (line.len == 0) continue;
            std.debug.print("Received: {s}\n", .{line});

            switch (nmdc.parseMessage(line)) {
                .command => |command| switch (command.kind) {
                    .ValidateNick => {
                        const hello = try nmdc.makeHello(allocator, command.payload);
                        defer allocator.free(hello);
                        try stream.writeAll(hello);
                        std.debug.print("Sent: {s}\n", .{hello});
                    },
                    else => {},
                },
                else => {},
            }
        }
        read_buffer.compact();
    }
}
