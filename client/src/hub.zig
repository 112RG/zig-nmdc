const std = @import("std");
const net = std.net;
const nmdc = @import("nmdc").NMDC;

pub const ChatMessage = struct {
    nick: []u8,
    text: []u8,
};

pub const Event = union(enum) {
    log: []u8,
    chat: ChatMessage,
    op_list: []u8,
    bot_list: []u8,
    connected,
};

pub fn deinitEvent(allocator: std.mem.Allocator, event: *Event) void {
    switch (event.*) {
        .log => |line| allocator.free(line),
        .op_list => |payload| allocator.free(payload),
        .bot_list => |payload| allocator.free(payload),
        .chat => |chat| {
            allocator.free(chat.nick);
            allocator.free(chat.text);
        },
        .connected => {},
    }
}

pub const DccHub = struct {
    allocator: std.mem.Allocator,
    connection: std.net.Stream,
    nick: []u8,
    read_buffer: std.ArrayList(u8),
    hello_seen: bool = false,
    closed: bool = false,

    pub fn connect(
        allocator: std.mem.Allocator,
        address: std.net.Address,
        nick: []const u8,
    ) !DccHub {
        return .{
            .allocator = allocator,
            .connection = try net.tcpConnectToAddress(address),
            .nick = try allocator.dupe(u8, nick),
            .read_buffer = .empty,
        };
    }

    pub fn deinit(self: *DccHub) void {
        self.close();
        self.allocator.free(self.nick);
        self.read_buffer.deinit(self.allocator);
    }

    pub fn close(self: *DccHub) void {
        if (self.closed) return;
        self.closed = true;

        std.posix.shutdown(self.connection.handle, .both) catch {};
        self.connection.close();
    }

    pub fn readEvents(self: *DccHub, events: *std.ArrayList(Event)) !usize {
        var buffer: [4096]u8 = undefined;
        const bytes_read = try self.connection.read(buffer[0..]);
        if (bytes_read == 0) return 0;

        try self.read_buffer.appendSlice(self.allocator, buffer[0..bytes_read]);
        try self.drainMessages(events);
        return bytes_read;
    }

    pub fn sendChat(self: *DccHub, text: []const u8) !void {
        const payload = try nmdc.formatChatMessage(self.allocator, self.nick, text);
        defer self.allocator.free(payload);

        try self.connection.writeAll(payload);
    }

    fn drainMessages(self: *DccHub, events: *std.ArrayList(Event)) !void {
        var start: usize = 0;

        while (std.mem.indexOfScalarPos(u8, self.read_buffer.items, start, '|')) |end| {
            const raw = std.mem.trim(u8, self.read_buffer.items[start..end], "\r\n");
            if (raw.len != 0) {
                try self.handleMessage(raw, events);
            }
            start = end + 1;
        }

        if (start == 0) return;

        const remaining = self.read_buffer.items.len - start;
        std.mem.copyForwards(u8, self.read_buffer.items[0..remaining], self.read_buffer.items[start..]);
        self.read_buffer.items.len = remaining;
    }

    fn handleMessage(self: *DccHub, message: []const u8, events: *std.ArrayList(Event)) !void {
        switch (nmdc.parseMessage(message)) {
            .chat => |chat| try self.handleChatMessage(chat, events),
            .command => |command| try self.handleCommand(command, events),
            .unknown => |raw| try appendLog(events, self.allocator, "Unhandled: {s}", .{raw}),
        }
    }

    fn handleCommand(self: *DccHub, command: nmdc.ParsedCommand, events: *std.ArrayList(Event)) !void {
        switch (command.kind) {
            .Lock => try self.handleLock(command.payload, events),
            .Hello => try self.handleHello(command.payload, events),
            .HubName => try appendLog(events, self.allocator, "Hub: {s}", .{command.payload}),
            .Supports => try appendLog(events, self.allocator, "Hub supports: {s}", .{command.payload}),
            .NickList => try appendLog(
                events,
                self.allocator,
                "Received nick list ({d} users)",
                .{countNickListEntries(command.payload)},
            ),
            .Quit => try appendLog(events, self.allocator, "User left: {s}", .{command.payload}),
            .OpList => try events.append(self.allocator, .{ .op_list = try self.allocator.dupe(u8, command.payload) }),
            .BotList => try events.append(self.allocator, .{ .bot_list = try self.allocator.dupe(u8, command.payload) }),
            .MyINFO, .LogedIn => {},
            .Unknown,
            .Key,
            .ValidateNick,
            .Version,
            .GetNickList,
            => try appendLog(events, self.allocator, "Unhandled: ${s} {s}", .{ @tagName(command.kind), command.payload }),
        }
    }

    fn handleChatMessage(self: *DccHub, chat: nmdc.ChatLine, events: *std.ArrayList(Event)) !void {
        const decoded = try nmdc.decodeChatText(self.allocator, chat.text);
        errdefer self.allocator.free(decoded);

        try events.append(self.allocator, .{
            .chat = .{
                .nick = try self.allocator.dupe(u8, chat.nick),
                .text = decoded,
            },
        });
    }

    fn handleLock(self: *DccHub, payload: []const u8, events: *std.ArrayList(Event)) !void {
        const lock = nmdc.firstWord(payload) orelse return;
        const key = try nmdc.calculateKey(self.allocator, lock);
        defer self.allocator.free(key);

        const response = try std.fmt.allocPrint(
            self.allocator,
            "$Supports NoHello NoGetINFO ChatOnly|$Key {s}|$ValidateNick {s}|",
            .{ key, self.nick },
        );
        defer self.allocator.free(response);

        try self.connection.writeAll(response);
        try appendLog(events, self.allocator, "Handshake started", .{});
    }

    fn handleHello(self: *DccHub, payload: []const u8, events: *std.ArrayList(Event)) !void {
        const hello_nick = std.mem.trim(u8, payload, " ");
        if (hello_nick.len == 0) return;

        if (std.mem.eql(u8, hello_nick, self.nick) and !self.hello_seen) {
            self.hello_seen = true;

            const hello_response = try std.fmt.allocPrint(
                self.allocator,
                "$Version 1,0091|$GetNickList|$MyINFO $ALL {s} <GitHub Copilot V:0.1.0,M:P,H:0/0/0,S:1>$ $LAN(T3)1$$0$|",
                .{self.nick},
            );
            defer self.allocator.free(hello_response);

            try self.connection.writeAll(hello_response);
            try appendLog(events, self.allocator, "Logged in as {s}", .{self.nick});
            try events.append(self.allocator, .connected);
            return;
        }

        try appendLog(events, self.allocator, "User joined: {s}", .{hello_nick});
    }
};

fn appendLog(
    events: *std.ArrayList(Event),
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) !void {
    try events.append(allocator, .{ .log = try std.fmt.allocPrint(allocator, format, args) });
}

fn countNickListEntries(payload: []const u8) usize {
    if (payload.len == 0) return 0;

    var count: usize = 0;
    var it = std.mem.splitSequence(u8, payload, "$$");
    while (it.next()) |entry| {
        if (entry.len != 0) count += 1;
    }
    return count;
}

test "parseMessage classifies chat lines" {
    const parsed = nmdc.parseMessage("<alice> hello");

    switch (parsed) {
        .chat => |chat| {
            try std.testing.expectEqualStrings("alice", chat.nick);
            try std.testing.expectEqualStrings("hello", chat.text);
        },
        else => return error.UnexpectedMessageKind,
    }
}

test "parseMessage classifies commands" {
    const parsed = nmdc.parseMessage("$Supports NoHello NoGetINFO|");

    switch (parsed) {
        .command => |command| {
            try std.testing.expectEqual(nmdc.CommandType.Supports, command.kind);
            try std.testing.expectEqualStrings("NoHello NoGetINFO|", command.payload);
        },
        else => return error.UnexpectedMessageKind,
    }
}

test "firstWord returns first token" {
    try std.testing.expectEqualStrings("EXTENDEDPROTOCOLABC", nmdc.firstWord(" EXTENDEDPROTOCOLABC Pk=client ").?);
    try std.testing.expect(nmdc.firstWord("   ") == null);
}

test "countNickListEntries ignores empty segments" {
    try std.testing.expectEqual(@as(usize, 3), countNickListEntries("alice$$bob$$$$carol$$"));
}

test "escape and decode chat text roundtrip protocol escapes" {
    const allocator = std.testing.allocator;

    const escaped = try nmdc.escapeChatText(allocator, "hi & $ |\nthere");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("hi &amp; &#36; &#124; there", escaped);

    const decoded = try nmdc.decodeChatText(allocator, escaped);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hi & $ | there", decoded);
}

test "decodeChatText handles DCN escapes" {
    const allocator = std.testing.allocator;

    const decoded = try nmdc.decodeChatText(allocator, "a/%DCN036%/b/%DCN124%/c");
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("a$b|c", decoded);
}
