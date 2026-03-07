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
        std.debug.print("Client connected from: {}\n", .{connection.address});

        // Handle client in a separate function (blocking for now is fine for a test)
        handleClient(allocator, connection.stream) catch |err| {
            std.debug.print("Client error: {}\n", .{err});
        };
    }
}

fn handleClient(allocator: std.mem.Allocator, stream: std.net.Stream) !void {
    var read_buffer: std.ArrayList(u8) = .empty;
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

        try read_buffer.appendSlice(allocator, buf[0..bytes_read]);

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, read_buffer.items, start, '|')) |end| {
            const line = std.mem.trim(u8, read_buffer.items[start..end], "\r\n");
            start = end + 1;

            if (line.len == 0) continue;
            std.debug.print("Received: {s}\n", .{line});

            switch (nmdc.parseMessage(line)) {
                .command => |command| switch (command.kind) {
                    .ValidateNick => {
                        const hello = try std.fmt.allocPrint(allocator, "$Hello {s}|", .{command.payload});
                        defer allocator.free(hello);
                        try stream.writeAll(hello);
                        std.debug.print("Sent: {s}\n", .{hello});
                    },
                    else => {},
                },
                else => {},
            }
        }

        if (start == 0) continue;

        const remaining = read_buffer.items.len - start;
        std.mem.copyForwards(u8, read_buffer.items[0..remaining], read_buffer.items[start..]);
        read_buffer.items.len = remaining;
    }
}
