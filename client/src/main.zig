const std = @import("std");

const ClientContext = struct {
    stream: std.net.Stream,
    write_mutex: std.Thread.Mutex = .{},
    nick: []const u8,
    allocator: std.mem.Allocator,

    pub fn send(self: *ClientContext, comptime format: []const u8, args: anytype) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.stream.writer().print(format, args);
    }

    pub fn sendRaw(self: *ClientContext, data: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.stream.writer().writeAll(data);
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const address = "127.0.0.1";
    const port: u16 = 411;

    // Try to connect to the NMDC server
    var stream = try std.net.tcpConnectToHost(allocator, address, port);
    defer stream.close();

    std.log.info("Connected to NMDC server at {s}:{d}", .{ address, port });

    // Initialize TUI
    try tui.init(allocator);
    // Be careful with defer tui.deinit(); inside main if inputLoop runs forever or we use std.process.exit
    // We'll handle cleanup manually or on Ctrl-C

    var ctx = ClientContext{
        .stream = stream,
        .nick = "ZigClient",
        .allocator = allocator,
    };

    // Spawn listener thread
    const listener_thread = try std.Thread.spawn(.{}, listenerLoop, .{&ctx});
    listener_thread.detach();

    // Input loop
    try inputLoop(&ctx);
}

fn inputLoop(ctx: *ClientContext) !void {
    // Initial prompt
    {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("> ", .{});
    }

    while (true) {
        // Blocks until a full line is ready (Enter pressed)
        // processInput handles raw chars, backspace, redraws
        const line = try tui.processInput();

        if (line) |cmd_slice| {
            defer ctx.allocator.free(cmd_slice);
            if (cmd_slice.len == 0) continue;

            if (std.mem.startsWith(u8, cmd_slice, "/quit")) {
                tui.deinit();
                break;
            } else if (std.mem.startsWith(u8, cmd_slice, "/raw ")) {
                try ctx.sendRaw(cmd_slice[5..]);
                try ctx.sendRaw("|");
            } else {
                // Chat message: <Nick> Message|
                try ctx.send("<{s}> {s}|", .{ ctx.nick, cmd_slice });
                // Echo local message
                std.log.info("<{s}> {s}", .{ ctx.nick, cmd_slice });
            }
        }
    }
}

fn listenerLoop(ctx: *ClientContext) !void {
    // Increase buffer size to handle larger messages (e.g. MOTD)
    var buf: [16384]u8 = undefined;

    // We can assume the first message is likely Lock, but we can process generally.
    // However, the handshake is stateful.
    // But since the current implementation is reactive (Get Lock -> Send Key),
    // we can just run the loop. The only thing is "Send Key" requires knowledge of Lock.

    // Main message loop
    while (true) {
        // NMDC uses | as delimiter
        const response = ctx.stream.reader().readUntilDelimiterOrEof(&buf, '|') catch |err| {
            if (err == error.EndOfStream) {
                std.log.info("Connection closed by server.", .{});
            } else {
                std.log.err("Read error: {}", .{err});
            }
            tui.disableRawMode();
            std.process.exit(0); // Exit processed if server dies
        };

        if (response) |payload| {
            if (payload.len == 0) continue;
            std.log.debug("Received: {s}|", .{payload});

            // Check for Lock specially if not strictly using command handler for it (since it needs logic)
            if (nmdc.NMDC.parseLock(payload)) |lock_key| {
                const key = nmdc.NMDC.calculateKey(ctx.allocator, lock_key) catch |err| {
                    std.log.err("Failed to calculate key: {}", .{err});
                    continue;
                };
                defer ctx.allocator.free(key);

                // Send handshake commands
                const supports = "$Supports NoGetINFO NoHello UserIP2|";

                ctx.send("{s}$Key {s}|$ValidateNick {s}|", .{ supports, key, ctx.nick }) catch |err| {
                    std.log.err("Failed to send handshake: {}", .{err});
                };

                std.log.debug("Sent Handshake", .{});
            } else {
                handleCommand(payload, ctx) catch |err| {
                    std.log.err("Error handling command: {}", .{err});
                };
            }
        } else {
            std.log.info("Connection closed by server.", .{});
            tui.disableRawMode();
            std.process.exit(0);
        }
    }
}

fn handleCommand(payload: []const u8, ctx: *ClientContext) !void {
    const cmd_type = nmdc.NMDC.getCommandType(payload);

    switch (cmd_type) {
        .Supports => {
            // e.g. $Supports ...
            // No specific action needed for simple client yet; just log
            // The main loop already logs "Received: ..."
        },
        .Hello => {
            if (nmdc.NMDC.parseHello(payload)) |hello_nick| {
                const trimmed_nick = std.mem.trim(u8, hello_nick, " ");
                if (std.mem.eql(u8, trimmed_nick, ctx.nick)) {
                    std.log.info("Logged in successfully as {s}", .{ctx.nick});
                    try handleLoginSuccess(ctx);
                }
            }
        },
        else => {
            // Check for specific unhandled commands or just ignore
            // std.debug.print("Unhandled command: {s}\n", .{payload});
        },
    }
}

fn handleLoginSuccess(ctx: *ClientContext) !void {
    const flag: u8 = 1; // Normal user (1)
    try ctx.send("$Version 1,0091|$GetNickList|$MyINFO $ALL {s} ZigClient$ $Cable{c}${s}${d}$|", .{ ctx.nick, flag, "email@example.com", 0 });

    std.log.info("Sent $Version, $GetNickList, $MyINFO", .{});
}

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("client_lib");
const nmdc = @import("nmdc");
const tui = @import("tui.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = tui.logFn,
};
