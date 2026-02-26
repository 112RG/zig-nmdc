const std = @import("std");
const hub = @import("hub.zig").DccHub;
const net = std.net;
const print = std.debug.print;
const hash = std.crypto.hash;
const Command = enum { Lock, Hello, Supports, HubName };
const Encoder = std.base64.standard.Encoder;
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("dc_lock.c");
});
pub fn main() !void {
    const address = try net.Address.parseIp4("127.0.0.1", 1411);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    //const conn = try net.tcpConnectToAddress(hub);

    const dccHub = try hub.connect(allocator, address);
    defer dccHub.connection.close();

    print("Connecting to {}\n", .{address});
    const bufferSize: usize = 4096; // Adjust buffer size according to your needs
    var buffer: [bufferSize]u8 = undefined;

    while (true) {
        const bytesRead = try dccHub.connection.read(buffer[0..]);
        if (bytesRead != 0) {
            try dccHub.processMessage(buffer[0..bytesRead]);
        }
        // Process data here, for example, print it
        // std.debug.print("{s}", .{buffer[0..bytesRead]});
        //const size = try writer.write(data);
    }
}
