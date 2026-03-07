const std = @import("std");
const ui_mod = @import("ui.zig");

pub const ParsedInput = union(enum) {
    chat: []const u8,
    private_message: struct {
        nick: []const u8,
        text: []const u8,
    },
    invalid: []const u8,
};

const CommandParser = *const fn (active_tab: ui_mod.ViewTab, args: []const u8) ParsedInput;

const CommandSpec = struct {
    name: []const u8,
    parser: CommandParser,
};

const command_specs = [_]CommandSpec{
    .{ .name = "msg", .parser = parseMsgCommand },
};

pub fn parseInput(active_tab: ui_mod.ViewTab, message: []const u8) ParsedInput {
    const trimmed = std.mem.trim(u8, message, " ");
    if (trimmed.len == 0) return .{ .chat = "" };

    if (!std.mem.startsWith(u8, trimmed, "/")) {
        if (active_tab == .pms) {
            return .{ .invalid = "Use /msg <nick> <message> in the PM tab" };
        }
        return .{ .chat = trimmed };
    }

    const command_line = std.mem.trimLeft(u8, trimmed[1..], " ");
    if (command_line.len == 0) {
        return .{ .invalid = "Unknown command. Supported: /msg <nick> <message>" };
    }

    const command_end = std.mem.indexOfScalar(u8, command_line, ' ') orelse command_line.len;
    const command_name = command_line[0..command_end];
    const command_args = std.mem.trimLeft(u8, command_line[command_end..], " ");

    for (command_specs) |spec| {
        if (std.mem.eql(u8, command_name, spec.name)) {
            return spec.parser(active_tab, command_args);
        }
    }

    return .{ .invalid = "Unknown command. Supported: /msg <nick> <message>" };
}

fn parseMsgCommand(_: ui_mod.ViewTab, args: []const u8) ParsedInput {
    if (args.len == 0) {
        return .{ .invalid = "Usage: /msg <nick> <message>" };
    }

    const nick_end = std.mem.indexOfScalar(u8, args, ' ') orelse {
        return .{ .invalid = "Usage: /msg <nick> <message>" };
    };

    const nick = std.mem.trim(u8, args[0..nick_end], " ");
    if (nick.len == 0) {
        return .{ .invalid = "Usage: /msg <nick> <message>" };
    }

    const text = std.mem.trimLeft(u8, args[nick_end + 1 ..], " ");
    if (text.len == 0) {
        return .{ .invalid = "Usage: /msg <nick> <message>" };
    }

    return .{ .private_message = .{ .nick = nick, .text = text } };
}

test "parseInput parses private message command" {
    const parsed = parseInput(.chat, "/msg alice hello there");

    switch (parsed) {
        .private_message => |message| {
            try std.testing.expectEqualStrings("alice", message.nick);
            try std.testing.expectEqualStrings("hello there", message.text);
        },
        else => return error.UnexpectedInputKind,
    }
}

test "parseInput rejects malformed msg command" {
    const parsed = parseInput(.chat, "/msg alice");

    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings("Usage: /msg <nick> <message>", reason),
        else => return error.ExpectedInvalidInput,
    }
}

test "parseInput trims command spacing" {
    const parsed = parseInput(.chat, "   /msg   alice    hello there   ");

    switch (parsed) {
        .private_message => |message| {
            try std.testing.expectEqualStrings("alice", message.nick);
            try std.testing.expectEqualStrings("hello there", message.text);
        },
        else => return error.UnexpectedInputKind,
    }
}

test "parseInput rejects unknown command" {
    const parsed = parseInput(.chat, "/join #zig");

    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings(
            "Unknown command. Supported: /msg <nick> <message>",
            reason,
        ),
        else => return error.ExpectedInvalidInput,
    }
}

test "parseInput rejects missing command name" {
    const parsed = parseInput(.chat, "/   ");

    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings(
            "Unknown command. Supported: /msg <nick> <message>",
            reason,
        ),
        else => return error.ExpectedInvalidInput,
    }
}

test "parseInput blocks plain text in PM tab" {
    const parsed = parseInput(.pms, "hello everyone");

    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings(
            "Use /msg <nick> <message> in the PM tab",
            reason,
        ),
        else => return error.ExpectedInvalidInput,
    }
}

test "parseInput still allows plain text in chat tab" {
    const parsed = parseInput(.chat, "hello everyone");

    switch (parsed) {
        .chat => |text| try std.testing.expectEqualStrings("hello everyone", text),
        else => return error.UnexpectedInputKind,
    }
}
