const std = @import("std");

const ClientContext = struct {
    stream: std.net.Stream,
    write_mutex: std.Thread.Mutex = .{},
    nick: []const u8,
    allocator: std.mem.Allocator,
    write_buffer: [16384]u8 = undefined,

    pub fn send(self: *ClientContext, comptime format: []const u8, args: anytype) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        var stream_writer = self.stream.writer(&self.write_buffer);
        try stream_writer.interface.print(format, args);
        std.debug.print("TX: " ++ format ++ "\n", args);
    }

    pub fn sendRaw(self: *ClientContext, data: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        var stream_writer = self.stream.writer(&self.write_buffer);
        try stream_writer.interface.writeAll(data);
        std.debug.print("TX: {s}\n", .{data});
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Parse command line args: client [address] [port]
    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("Failed to parse args\n", .{});
        return;
    };
    defer std.process.argsFree(allocator, args);

    const address = if (args.len > 1) args[1] else "10.0.1.141";
    const port: u16 = if (args.len > 2) std.fmt.parseInt(u16, args[2], 10) catch 411 else 411;

    std.debug.print("Connecting to {s}:{d}...\n", .{ address, port });

    // Try to connect to the NMDC server
    var stream = try std.net.tcpConnectToHost(allocator, address, port);
    defer stream.close();

    std.debug.print("Connected! Starting handshake...\n", .{});

    // Initialize TUI
    tui.init(allocator) catch {
        std.debug.print("TUI not available (not a terminal)\n", .{});
    };

    var ctx = ClientContext{
        .stream = stream,
        .nick = "ZigClient",
        .allocator = allocator,
    };

    // Spawn listener thread
    const listener_thread = try std.Thread.spawn(.{}, listenerLoop, .{&ctx});
    listener_thread.detach();

    // Input loop
    inputLoop(&ctx) catch {};
}

fn inputLoop(ctx: *ClientContext) !void {
    // Initial prompt
    {
        var stderr_file_writer = std.fs.File.stderr().writer(&[0]u8{});
        const stderr = &stderr_file_writer.interface;
        try stderr.print("> ", .{});
    }

    while (true) {
        // Blocks until a full line is ready (Enter pressed)
        // processInput handles raw chars, backspace, redraws
        const cmd_slice = try tui.processInput();

        if (cmd_slice.len == 0) continue;

        defer ctx.allocator.free(cmd_slice);

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

fn listenerLoop(ctx: *ClientContext) !void {
    // Increase buffer size to handle larger messages (e.g. MOTD)
    var buf: [16384]u8 = undefined;
    var pos: usize = 0;

    std.debug.print("Waiting for server messages...\n", .{});

    // Main message loop
    while (true) {
        // NMDC uses | as delimiter - read until we find one
        // Using deprecated read method from Stream
        const bytes_read = ctx.stream.read(buf[pos..]) catch |err| {
            std.debug.print("Read error: {}\n", .{err});
            std.process.exit(0);
        };

        if (bytes_read == 0) {
            std.debug.print("Connection closed by server.\n", .{});
            std.process.exit(0);
        }

        pos += bytes_read;

        std.debug.print("Read {d} bytes, buffer pos: {d}\n", .{ bytes_read, pos });

        // Check for delimiter
        var i: usize = 0;
        while (i < pos) : (i += 1) {
            if (buf[i] == '|') {
                // Found delimiter - process message
                const payload = buf[0..i];
                pos -= i + 1;
                // Shift remaining data
                @memcpy(buf[0..pos], buf[i + 1 .. i + 1 + pos]);

                if (payload.len == 0) continue;
                std.debug.print("RX: {s}\n", .{payload});

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
                        std.debug.print("Failed to send handshake: {}\n", .{err});
                    };

                    std.debug.print("TX: {s}$Key {s}|$ValidateNick {s}|\n", .{ supports, key, ctx.nick });
                } else {
                    handleCommand(payload, ctx) catch |err| {
                        std.debug.print("Error handling command: {}\n", .{err});
                    };
                }

                break; // Check for more messages in buffer
            }
        }
    }
}

fn handleCommand(payload: []const u8, ctx: *ClientContext) !void {
    const cmd_type = nmdc.NMDC.getCommandType(payload);

    std.debug.print("RX_CMD: {s}\n", .{payload});

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
                    std.debug.print("Logged in successfully as {s}\n", .{ctx.nick});
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

    std.debug.print("TX: $Version, $GetNickList, $MyINFO\n", .{});
}

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("client_lib");
const nmdc = @import("nmdc");
const tui = @import("tui.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = tui.logFn,
};
