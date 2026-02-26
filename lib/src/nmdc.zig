//! NMDC protocol utilities for client and server
const std = @import("std");

pub const NMDC = struct {
    pub const CommandType = enum {
        Supports,
        Hello,
        Lock,
        Key,
        ValidateNick,
        Version,
        GetNickList,
        MyINFO,
        Unknown,
    };

    pub fn getCommandType(msg: []const u8) CommandType {
        if (msg.len == 0 or msg[0] != '$') return .Unknown;

        // Find end of command name
        var end: usize = 1;
        while (end < msg.len and msg[end] != ' ' and msg[end] != '|') : (end += 1) {}

        const cmd = msg[1..end];
        return std.meta.stringToEnum(CommandType, cmd) orelse .Unknown;
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
