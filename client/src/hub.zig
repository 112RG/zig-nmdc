const std = @import("std");
const net = std.net;
const nmdc = @import("nmdc").NMDC;

const ParsedMessage = union(enum) {
    chat: []const u8,
    command: nmdc.ParsedCommand,
    unknown: []const u8,
};

pub const ChatMessage = struct {
    nick: []u8,
    text: []u8,
};

pub const Event = union(enum) {
    log: []u8,
    chat: ChatMessage,
    connected,
};

pub fn deinitEvent(allocator: std.mem.Allocator, event: *Event) void {
    switch (event.*) {
        .log => |line| allocator.free(line),
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
        const escaped = try escapeChatText(self.allocator, text);
        defer self.allocator.free(escaped);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "<{s}> {s}|",
            .{ self.nick, escaped },
        );
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
        switch (parseMessage(message)) {
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
            .MyINFO, .OpList, .BotList, .LogedIn => {},
            .Unknown,
            .Key,
            .ValidateNick,
            .Version,
            .GetNickList,
            => try appendLog(events, self.allocator, "Unhandled: ${s} {s}", .{ @tagName(command.kind), command.payload }),
        }
    }

    fn handleChatMessage(self: *DccHub, message: []const u8, events: *std.ArrayList(Event)) !void {
        const end_nick = std.mem.indexOfScalar(u8, message, '>') orelse {
            try appendLog(events, self.allocator, "Malformed chat: {s}", .{message});
            return;
        };
        if (end_nick <= 1) return;

        const nick = message[1..end_nick];
        const text_start = if (message.len > end_nick + 1 and message[end_nick + 1] == ' ')
            end_nick + 2
        else
            end_nick + 1;
        const raw_text = if (text_start <= message.len) message[text_start..] else "";

        const decoded = try decodeChatText(self.allocator, raw_text);
        errdefer self.allocator.free(decoded);

        try events.append(self.allocator, .{
            .chat = .{
                .nick = try self.allocator.dupe(u8, nick),
                .text = decoded,
            },
        });
    }

    fn handleLock(self: *DccHub, payload: []const u8, events: *std.ArrayList(Event)) !void {
        const lock = firstWord(payload) orelse return;
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

fn parseMessage(message: []const u8) ParsedMessage {
    if (message.len == 0) return .{ .unknown = message };
    if (message[0] == '<') return .{ .chat = message };
    if (nmdc.parseCommand(message)) |command| {
        return .{ .command = command };
    }
    return .{ .unknown = message };
}

fn firstWord(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return null;

    const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    return trimmed[0..end];
}

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

fn escapeChatText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (text) |byte| {
        switch (byte) {
            '\n', '\r' => try output.append(allocator, ' '),
            '&' => try output.appendSlice(allocator, "&amp;"),
            '$' => try output.appendSlice(allocator, "&#36;"),
            '|' => try output.appendSlice(allocator, "&#124;"),
            else => try output.append(allocator, byte),
        }
    }

    return output.toOwnedSlice(allocator);
}

fn decodeChatText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], "&#124;")) {
            try output.append(allocator, '|');
            index += 6;
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], "&#36;")) {
            try output.append(allocator, '$');
            index += 5;
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], "&amp;")) {
            try output.append(allocator, '&');
            index += 5;
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], "/%DCN124%/")) {
            try output.append(allocator, '|');
            index += 10;
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], "/%DCN036%/")) {
            try output.append(allocator, '$');
            index += 10;
            continue;
        }

        try output.append(allocator, text[index]);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}
