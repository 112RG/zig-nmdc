//! NMDC protocol utilities for client and server
const std = @import("std");

pub const NMDC = struct {
    pub const MessageBuffer = struct {
        bytes: std.ArrayList(u8) = .empty,
        cursor: usize = 0,

        pub fn deinit(self: *MessageBuffer, allocator: std.mem.Allocator) void {
            self.bytes.deinit(allocator);
        }

        pub fn append(self: *MessageBuffer, allocator: std.mem.Allocator, data: []const u8) !void {
            try self.bytes.appendSlice(allocator, data);
        }

        pub fn next(self: *MessageBuffer) ?[]const u8 {
            const end = std.mem.indexOfScalarPos(u8, self.bytes.items, self.cursor, '|') orelse return null;
            const message = std.mem.trim(u8, self.bytes.items[self.cursor..end], "\r\n");
            self.cursor = end + 1;
            return message;
        }

        pub fn compact(self: *MessageBuffer) void {
            if (self.cursor == 0) return;

            const remaining = self.bytes.items.len - self.cursor;
            std.mem.copyForwards(u8, self.bytes.items[0..remaining], self.bytes.items[self.cursor..]);
            self.bytes.items.len = remaining;
            self.cursor = 0;
        }
    };

    pub const CommandType = enum {
        Supports,
        Hello,
        Lock,
        Key,
        ValidateNick,
        Version,
        GetNickList,
        MyINFO,
        HubName,
        NickList,
        Quit,
        OpList,
        BotList,
        LogedIn,
        Unknown,
    };

    pub const ParsedCommand = struct {
        kind: CommandType,
        payload: []const u8,
    };

    pub const ChatLine = struct {
        nick: []const u8,
        text: []const u8,
    };

    pub const ParsedMessage = union(enum) {
        chat: ChatLine,
        command: ParsedCommand,
        unknown: []const u8,
    };

    pub fn getCommandType(msg: []const u8) CommandType {
        if (msg.len == 0 or msg[0] != '$') return .Unknown;

        // Find end of command name
        var end: usize = 1;
        while (end < msg.len and msg[end] != ' ' and msg[end] != '|') : (end += 1) {}

        const cmd = msg[1..end];
        return std.meta.stringToEnum(CommandType, cmd) orelse .Unknown;
    }

    pub fn parseCommand(msg: []const u8) ?ParsedCommand {
        if (msg.len == 0 or msg[0] != '$') return null;

        var end: usize = 1;
        while (end < msg.len and msg[end] != ' ' and msg[end] != '|') : (end += 1) {}

        const kind = std.meta.stringToEnum(CommandType, msg[1..end]) orelse .Unknown;
        const payload = if (end < msg.len and msg[end] == ' ') msg[end + 1 ..] else "";

        return .{
            .kind = kind,
            .payload = payload,
        };
    }

    pub fn parseMessage(msg: []const u8) ParsedMessage {
        if (msg.len == 0) return .{ .unknown = msg };
        if (parseChat(msg)) |chat| return .{ .chat = chat };
        if (parseCommand(msg)) |command| return .{ .command = command };
        return .{ .unknown = msg };
    }

    pub fn parseChat(msg: []const u8) ?ChatLine {
        if (msg.len == 0 or msg[0] != '<') return null;

        const end_nick = std.mem.indexOfScalar(u8, msg, '>') orelse return null;
        if (end_nick <= 1) return null;

        const text_start = if (msg.len > end_nick + 1 and msg[end_nick + 1] == ' ')
            end_nick + 2
        else
            end_nick + 1;

        return .{
            .nick = msg[1..end_nick],
            .text = if (text_start <= msg.len) msg[text_start..] else "",
        };
    }

    pub fn firstWord(text: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return null;

        const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        return trimmed[0..end];
    }

    pub fn countNickListEntries(payload: []const u8) usize {
        if (payload.len == 0) return 0;

        var count: usize = 0;
        var iterator = std.mem.splitSequence(u8, payload, "$$");
        while (iterator.next()) |entry| {
            if (entry.len != 0) count += 1;
        }
        return count;
    }

    pub fn makeMyNick(allocator: std.mem.Allocator, nick: []const u8) ![]u8 {
        // Compose $MyNick <nick>|\n
        const buf = try std.fmt.allocPrint(allocator, "$MyNick {s}|\n", .{nick});
        return buf;
    }

    pub fn parseHello(hello_msg: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, hello_msg, "$Hello ")) return null;
        const nick_start = 7; // "$Hello ".len
        if (hello_msg.len > nick_start) {
            return hello_msg[nick_start..];
        }
        return null;
    }

    pub fn makeHello(allocator: std.mem.Allocator, nick: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "$Hello {s}|", .{nick});
    }

    pub fn parseLock(lock_msg: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, lock_msg, "$Lock ")) return null;
        const start = 6; // "$Lock ".len
        var end: usize = start;
        while (end < lock_msg.len) : (end += 1) {
            const c = lock_msg[end];
            if (c == ' ' or c == '|') break;
        }
        if (end > start) {
            return lock_msg[start..end];
        }
        return null;
    }

    pub fn escapeChatText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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

    pub fn decodeChatText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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

    pub fn formatChatMessage(
        allocator: std.mem.Allocator,
        nick: []const u8,
        text: []const u8,
    ) ![]u8 {
        const escaped = try escapeChatText(allocator, text);
        defer allocator.free(escaped);

        return std.fmt.allocPrint(allocator, "<{s}> {s}|", .{ nick, escaped });
    }

    pub fn calculateKey(allocator: std.mem.Allocator, lock: []const u8) ![]u8 {
        const len = lock.len;
        if (len < 2) {
            return error.InvalidLock;
        }
        var key = try allocator.alloc(u8, len);
        defer allocator.free(key);

        // Step 1: XOR calculation
        key[0] = lock[0] ^ lock[len - 1] ^ lock[len - 2] ^ 5;
        for (lock[1..], 0..) |byte, i| {
            key[i + 1] = byte ^ lock[i];
        }

        // Step 2: Nibble-swap
        for (key) |*c| {
            c.* = (c.* << 4) | (c.* >> 4);
        }

        // Step 3: Escape special characters
        var escaped_key = try std.ArrayList(u8).initCapacity(allocator, key.len);
        errdefer escaped_key.deinit(allocator);

        for (key) |byte| {
            switch (byte) {
                0, 5, 36, 96, 124, 126 => {
                    try escaped_key.writer(allocator).print("/%DCN{d:0>3}%/", .{byte});
                },
                else => try escaped_key.append(allocator, byte),
            }
        }

        return escaped_key.toOwnedSlice(allocator);
    }
};

test "calculateKey simple" {
    const allocator = std.testing.allocator;
    const lock = "LOCK";
    const expected = "\x14\x30\xC0\x80"; // 0x14 = 20, 0x30 = '0', 0xC0 = 192, 0x80 = 128

    // Calculation:
    // Key[0] = 76^75^67^5 = 65 ('A') -> 0x41 -> swap nibbles -> 0x14
    // Key[1] = 79^76 = 3 -> 0x03 -> swap nibbles -> 0x30
    // Key[2] = 67^79 = 12 -> 0x0C -> swap nibbles -> 0xC0
    // Key[3] = 75^67 = 8 -> 0x08 -> swap nibbles -> 0x80

    const key = try NMDC.calculateKey(allocator, lock);
    defer allocator.free(key);

    try std.testing.expectEqualSlices(u8, expected, key);
}

test "parseMessage parses chat lines" {
    const parsed = NMDC.parseMessage("<alice> hello");

    switch (parsed) {
        .chat => |chat| {
            try std.testing.expectEqualStrings("alice", chat.nick);
            try std.testing.expectEqualStrings("hello", chat.text);
        },
        else => return error.UnexpectedMessageKind,
    }
}

test "formatChatMessage escapes reserved chat characters" {
    const allocator = std.testing.allocator;

    const formatted = try NMDC.formatChatMessage(allocator, "alice", "a & b | c $");
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings("<alice> a &amp; b &#124; c &#36;|", formatted);
}

test "decodeChatText handles html and dcn escapes" {
    const allocator = std.testing.allocator;

    const decoded = try NMDC.decodeChatText(allocator, "&#36;/%DCN124%/&amp;");
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("$|&", decoded);
}

test "message buffer yields complete pipe-delimited messages" {
    var buffer = NMDC.MessageBuffer{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, "$Lock abc|<nick> hi|");

    try std.testing.expectEqualStrings("$Lock abc", buffer.next().?);
    try std.testing.expectEqualStrings("<nick> hi", buffer.next().?);
    try std.testing.expect(buffer.next() == null);
}

test "message buffer compacts partial trailing data" {
    var buffer = NMDC.MessageBuffer{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, "$Hello a|$Supp");
    try std.testing.expectEqualStrings("$Hello a", buffer.next().?);
    try std.testing.expect(buffer.next() == null);
    buffer.compact();

    try std.testing.expectEqualStrings("$Supp", buffer.bytes.items);
}

test "countNickListEntries counts non-empty nicks" {
    try std.testing.expectEqual(@as(usize, 3), NMDC.countNickListEntries("alice$$bob$$$$carol$$"));
}
