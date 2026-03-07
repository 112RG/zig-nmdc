const std = @import("std");
const net = std.net;

const Command = enum { Lock, Hello, Supports, HubName };

const c = @cImport({
    @cInclude("dc_lock.c");
});

pub const DccHub = struct {
    allocator: std.mem.Allocator,
    connection: std.net.Stream,
    writer: std.net.Stream.Writer,

    pub fn connect(allocator: std.mem.Allocator, address: std.net.Address) !DccHub {
        const connection = try net.tcpConnectToAddress(address);
        var buffer: [4096]u8 = undefined;
        return DccHub{
            .allocator = allocator,
            .connection = connection,
            .writer = connection.writer(&buffer),
        };
    }

    fn write(self: DccHub, message: []const u8) !void {
        std.debug.print("Sending: {s}\n", .{message});
        _ = try self.connection.write(message);
    }
    pub fn processMessage(self: DccHub, message: []const u8) !void {
        var _message = std.mem.splitAny(u8, message, "|");

        while (_message.next()) |x| {
            if (x.len == 0) return; // Split can return empty if 1 command
            var command_message = std.mem.splitSequence(u8, x, " ");
            const command = command_message.first()[1..]; // Slice $
            const params = command_message.rest();
            const action = std.meta.stringToEnum(Command, command) orelse return;

            std.debug.print("Command: {s} Params: {s}\n", .{ @as([]const u8, command), @as([]const u8, params) });
            switch (action) {
                .Lock => {
                    try self.handleLock(params);
                },
                .Hello => {
                    try self.handleHello();
                },
                .Supports => {},
                .HubName => {},
            }
        }
    }
    pub fn handleHello(self: DccHub) !void {
        self.write("$Version 1,0091|$GetNickList|$MyINFO $ALL TestBot Share<DoomBot V:0.0.1,M:A,H:1/0/0,S:10>$ $543841986$uc.email$543841986$|") catch |e| std.debug.print("unable to send: {}\n", .{e});
    }
    fn splitCommandParams(params: []const u8) std.mem.SplitIterator(u8, .sequence) {
        return std.mem.splitSequence(u8, params, " ");
    }

    fn handleSupports(_params: []const u8) !void {
        std.debug.print("{any}\n", .{_params});
    }

    fn handleLock(self: DccHub, _params: []const u8) !void {
        var params = splitCommandParams(_params);
        const lock = params.first();
        const _lock = try self.allocator.dupeZ(u8, lock[0..lock.len]);

        const responseKey: [*:0]u8 = c.lock_to_key(_lock.ptr);
        var buffer: [128]u8 = undefined;
        const formattedString = try std.fmt.bufPrint(&buffer, "$Supports NoHello NoGetINFO|$Key {s}|", .{responseKey});

        self.write(formattedString) catch |e| std.debug.print("unable to send: {}\n", .{e});
        const nick = "$ValidateNick TestBot|";
        self.write(nick) catch |e| std.debug.print("unable to send: {}\n", .{e});
    }
};
